import Foundation
import UHFCore
#if canImport(FoundationXML)
import FoundationXML
#endif

/// Parseur XMLTV en flux (SAX).
///
/// Les chaînes et les programmes sont remontés au fil de la lecture : c'est au
/// consommateur de les accumuler par lots et de les écrire en base en une
/// transaction. À aucun moment le document complet n'est en mémoire.
public final class XMLTVParser: NSObject {

    public struct Options: Sendable {
        /// Langues préférées pour les titres et descriptions multilingues, par ordre.
        public var preferredLanguages: [String]
        /// Fenêtre à conserver. Tout programme entièrement hors fenêtre est ignoré,
        /// ce qui divise couramment par trois le volume écrit en base.
        public var window: ClosedRange<Date>?

        public init(preferredLanguages: [String] = [], window: ClosedRange<Date>? = nil) {
            self.preferredLanguages = preferredLanguages
            self.window = window
        }
    }

    public struct Summary: Sendable, Equatable {
        public var channelCount = 0
        public var programmeCount = 0
        /// Programmes écartés : hors fenêtre, sans date exploitable ou incohérents.
        public var skippedCount = 0
    }

    public enum Failure: Error, LocalizedError {
        case cannotOpen(URL)
        case malformed(String)
        case cancelled

        public var errorDescription: String? {
            switch self {
            case .cannotOpen(let url): "Fichier EPG illisible : \(url.lastPathComponent)"
            case .malformed(let detail): "Fichier EPG invalide : \(detail)"
            case .cancelled: "Import EPG annulé."
            }
        }
    }

    private let options: Options
    private let onChannel: (EPGChannel) -> Void
    private let onProgramme: (EPGProgramme) -> Void
    private let isCancelled: () -> Bool

    private var summary = Summary()
    private var failure: Error?

    // État courant
    private var currentElement = ""
    private var currentLanguage: String?
    private var text = ""

    private var channelID: String?
    private var displayNames: [String] = []
    private var channelIcon: URL?

    private var programme: PartialProgramme?

    private struct PartialProgramme {
        var channelID: String
        var start: Date
        var stop: Date
        var titles: [(language: String?, value: String)] = []
        var subtitles: [(language: String?, value: String)] = []
        var descriptions: [(language: String?, value: String)] = []
        var categories: [String] = []
        var icon: URL?
        var episodeNumber: String?
    }

    public init(options: Options = Options(),
                isCancelled: @escaping () -> Bool = { false },
                onChannel: @escaping (EPGChannel) -> Void,
                onProgramme: @escaping (EPGProgramme) -> Void) {
        self.options = options
        self.isCancelled = isCancelled
        self.onChannel = onChannel
        self.onProgramme = onProgramme
    }

    // MARK: - Entrées

    /// Parse un fichier XMLTV, en le décompressant d'abord s'il est en gzip.
    @discardableResult
    public func parse(fileAt url: URL) throws -> Summary {
        guard Gunzip.isGzip(fileAt: url) else {
            guard let stream = InputStream(url: url) else { throw Failure.cannotOpen(url) }
            return try parse(stream: stream)
        }
        let plain = FileManager.default.temporaryDirectory
            .appendingPathComponent("uhf-epg-\(UUID().uuidString).xml")
        defer { try? FileManager.default.removeItem(at: plain) }

        try Gunzip.decompress(from: url, to: plain, isCancelled: isCancelled)
        guard let stream = InputStream(url: plain) else { throw Failure.cannotOpen(plain) }
        return try parse(stream: stream)
    }

    @discardableResult
    public func parse(data: Data) throws -> Summary {
        try parse(stream: InputStream(data: data))
    }

    @discardableResult
    public func parse(stream: InputStream) throws -> Summary {
        let parser = XMLParser(stream: stream)
        parser.delegate = self
        // Les XMLTV réels contiennent des entités HTML non déclarées (&nbsp;, &eacute;) ;
        // les résoudre évite de perdre le document entier sur une entité inconnue.
        parser.shouldResolveExternalEntities = false

        guard parser.parse() else {
            if let failure { throw failure }
            if isCancelled() { throw Failure.cancelled }
            let error = parser.parserError
            throw Failure.malformed(error?.localizedDescription
                ?? "ligne \(parser.lineNumber), colonne \(parser.columnNumber)")
        }
        if let failure { throw failure }
        return summary
    }

    // MARK: - Sélection linguistique

    private func pick(_ candidates: [(language: String?, value: String)]) -> String? {
        guard !candidates.isEmpty else { return nil }
        for language in options.preferredLanguages {
            if let match = candidates.first(where: { $0.language?.hasPrefix(language) == true }) {
                return match.value
            }
        }
        return candidates.first?.value
    }
}

// MARK: - XMLParserDelegate

extension XMLTVParser: XMLParserDelegate {

    public func parser(_ parser: XMLParser,
                       didStartElement elementName: String,
                       namespaceURI: String?,
                       qualifiedName: String?,
                       attributes: [String: String] = [:]) {
        if isCancelled() {
            parser.abortParsing()
            return
        }
        currentElement = elementName
        currentLanguage = attributes["lang"]
        text = ""

        switch elementName {
        case "channel":
            channelID = attributes["id"]
            displayNames = []
            channelIcon = nil

        case "programme":
            guard let channel = attributes["channel"],
                  let startText = attributes["start"],
                  let start = XMLTVDate.parse(startText) else {
                summary.skippedCount += 1
                programme = nil
                return
            }
            // `stop` est facultatif dans bien des fichiers : on donne une durée par
            // défaut d'une heure plutôt que de jeter le programme.
            let stop = attributes["stop"].flatMap(XMLTVDate.parse)
                ?? start.addingTimeInterval(3600)
            guard stop > start else {
                summary.skippedCount += 1
                programme = nil
                return
            }
            programme = PartialProgramme(channelID: channel, start: start, stop: stop)

        case "icon":
            let source = attributes["src"].flatMap { URL(string: $0) }
            if programme != nil {
                programme?.icon = source
            } else if channelID != nil {
                channelIcon = source
            }

        case "episode-num":
            currentLanguage = attributes["system"]

        default:
            break
        }
    }

    public func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    public func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        text += String(data: CDATABlock, encoding: .utf8) ?? ""
    }

    public func parser(_ parser: XMLParser,
                       didEndElement elementName: String,
                       namespaceURI: String?,
                       qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = ""

        switch elementName {
        case "display-name":
            if !value.isEmpty { displayNames.append(value) }

        case "title":
            if !value.isEmpty { programme?.titles.append((currentLanguage, value)) }

        case "sub-title":
            if !value.isEmpty { programme?.subtitles.append((currentLanguage, value)) }

        case "desc":
            if !value.isEmpty { programme?.descriptions.append((currentLanguage, value)) }

        case "category":
            if !value.isEmpty { programme?.categories.append(value) }

        case "episode-num":
            if !value.isEmpty, programme?.episodeNumber == nil {
                programme?.episodeNumber = value
            }

        case "channel":
            defer { channelID = nil; displayNames = []; channelIcon = nil }
            guard let id = channelID, !id.isEmpty else { return }
            onChannel(EPGChannel(xmltvID: id, displayNames: displayNames, iconURL: channelIcon))
            summary.channelCount += 1

        case "programme":
            defer { programme = nil }
            guard let partial = programme else { return }

            if let window = options.window,
               partial.stop < window.lowerBound || partial.start > window.upperBound {
                summary.skippedCount += 1
                return
            }
            onProgramme(EPGProgramme(
                channelID: partial.channelID,
                start: partial.start,
                stop: partial.stop,
                title: pick(partial.titles) ?? "Sans titre",
                subtitle: pick(partial.subtitles),
                desc: pick(partial.descriptions),
                categories: partial.categories,
                iconURL: partial.icon,
                episodeNumber: partial.episodeNumber))
            summary.programmeCount += 1

        default:
            break
        }
    }

    public func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        guard !isCancelled() else { return }
        failure = Failure.malformed(parseError.localizedDescription)
    }
}
