import Foundation
import UHFCore

/// Parseur M3U étendu, écrit comme une machine à états alimentée **ligne par ligne**.
///
/// Une playlist IPTV courante fait 10 000 à 150 000 chaînes, soit 30 à 60 Mo de texte :
/// tout charger en mémoire avant de parser est le premier réflexe à ne pas avoir.
/// Cette forme permet de brancher indifféremment une chaîne de caractères (tests),
/// un fichier ou une réponse réseau, en mémoire constante.
public struct M3UParser: Sendable {

    public struct Header: Sendable, Equatable {
        /// `url-tvg` / `x-tvg-url` : l'EPG déclaré par la playlist elle-même.
        public var epgURLs: [URL] = []
        public var attributes: [String: String] = [:]
    }

    public private(set) var header = Header()
    public private(set) var lineNumber = 0
    /// Lignes ignorées faute d'être exploitables, conservées pour l'écran de diagnostic.
    public private(set) var skipped: [(line: Int, reason: String)] = []

    private var pending: PendingEntry?
    private var sortIndex = 0
    private var sawExtM3U = false

    private struct PendingEntry {
        var attributes: [String: String]
        var title: String?
        var group: String?
        var headers: [String: String] = [:]
    }

    public init() {}

    // MARK: - Alimentation

    /// Consomme une ligne. Renvoie une chaîne dès qu'une entrée est complète,
    /// c'est-à-dire quand la ligne d'URL referme le `#EXTINF` courant.
    public mutating func consume(line rawLine: String) -> ParsedChannel? {
        lineNumber += 1
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }

        if line.hasPrefix("#") {
            consumeDirective(line)
            return nil
        }
        return consumeURL(line)
    }

    private mutating func consumeDirective(_ line: String) {
        switch true {
        case line.hasPrefix("#EXTM3U"):
            sawExtM3U = true
            let attributes = M3UAttributes.parse(line.dropFirst("#EXTM3U".count)[...])
            header.attributes = attributes
            for key in ["url-tvg", "x-tvg-url", "tvg-url"] {
                guard let raw = attributes[key] else { continue }
                // Plusieurs EPG peuvent être déclarés, séparés par des virgules.
                header.epgURLs += raw.split(separator: ",")
                    .compactMap { URL(string: $0.trimmingCharacters(in: .whitespaces)) }
            }

        case line.hasPrefix("#EXTINF:"):
            let body = String(line.dropFirst("#EXTINF:".count))
            let (attributes, title) = M3UAttributes.splitAttributesAndTitle(body)
            pending = PendingEntry(
                attributes: M3UAttributes.parse(attributes),
                title: title.map { String($0).trimmingCharacters(in: .whitespaces) },
                group: nil)

        case line.hasPrefix("#EXTGRP:"):
            // Forme historique du groupe, quand `group-title` est absent.
            pending?.group = String(line.dropFirst("#EXTGRP:".count)).trimmingCharacters(in: .whitespaces)

        case line.hasPrefix("#EXTVLCOPT:"):
            let option = String(line.dropFirst("#EXTVLCOPT:".count))
            guard let equals = option.firstIndex(of: "=") else { return }
            let key = option[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(option[option.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            if let headerName = Self.vlcOptionToHTTPHeader[key] {
                pending?.headers[headerName] = value
            }

        case line.hasPrefix("#EXTHTTP:"):
            // `#EXTHTTP:{"User-Agent":"…","Referer":"…"}`
            let json = String(line.dropFirst("#EXTHTTP:".count))
            if let data = json.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                for (key, value) in object {
                    pending?.headers[key] = String(describing: value)
                }
            }

        default:
            // `#KODIPROP:` (DRM Widevine, non lisible sur les plateformes Apple),
            // `#EXT-X-*`, commentaires libres : ignorés sans bruit.
            break
        }
    }

    private mutating func consumeURL(_ line: String) -> ParsedChannel? {
        guard let entry = pending else {
            // Une URL sans `#EXTINF` : playlist M3U « simple ». On l'accepte quand même.
            guard let parsed = Self.splitInlineHeaders(line), let url = URL(string: parsed.url) else {
                skipped.append((lineNumber, "URL non exploitable hors contexte #EXTINF"))
                return nil
            }
            defer { sortIndex += 1 }
            return ParsedChannel(name: parsed.url, url: url, httpHeaders: parsed.headers, sortIndex: sortIndex)
        }
        pending = nil

        guard let parsed = Self.splitInlineHeaders(line), let url = URL(string: parsed.url) else {
            skipped.append((lineNumber, "URL invalide"))
            return nil
        }

        let attributes = entry.attributes
        // Certaines playlists ne remplissent que `tvg-name`, d'autres que le libellé.
        let name = [entry.title, attributes["tvg-name"]]
            .compactMap { $0 }
            .first(where: { !$0.isEmpty })
            ?? url.lastPathComponent

        defer { sortIndex += 1 }
        return ParsedChannel(
            name: name,
            url: url,
            streamID: Self.xtreamStreamID(from: url),
            logoURL: attributes["tvg-logo"].flatMap { URL(string: $0) },
            groupTitle: [attributes["group-title"], entry.group]
                .compactMap { $0 }
                .first(where: { !$0.isEmpty }),
            tvgID: attributes["tvg-id"].flatMap { $0.isEmpty ? nil : $0 },
            tvgName: attributes["tvg-name"],
            // `tvg-shift` est exprimé en heures, éventuellement fractionnaires ("-1.5").
            tvgShift: (attributes["tvg-shift"] ?? attributes["timeshift"])
                .flatMap { Double($0) }.map { $0 * 3600 } ?? 0,
            catchup: attributes["catchup"].flatMap { CatchupMode(rawAttribute: $0) }
                ?? (attributes["catchup-source"] != nil ? .append : nil),
            catchupDays: (attributes["catchup-days"] ?? attributes["timeshift-days"])
                .flatMap { Int($0) },
            catchupSource: attributes["catchup-source"],
            httpHeaders: entry.headers.merging(parsed.headers) { _, inline in inline },
            sortIndex: sortIndex)
    }

    // MARK: - Utilitaires

    private static let vlcOptionToHTTPHeader: [String: String] = [
        "http-user-agent": "User-Agent",
        "http-referrer": "Referer",   // orthographe VLC
        "http-referer": "Referer",    // orthographe HTTP
        "http-origin": "Origin",
        "http-cookie": "Cookie",
    ]

    /// Gère la convention `http://host/flux.ts|User-Agent=Mozilla&Referer=http://x`.
    static func splitInlineHeaders(_ line: String) -> (url: String, headers: [String: String])? {
        guard let pipe = line.firstIndex(of: "|") else { return (line, [:]) }
        let urlPart = String(line[..<pipe])
        guard !urlPart.isEmpty else { return nil }

        var headers: [String: String] = [:]
        for pair in line[line.index(after: pipe)...].split(separator: "&") {
            guard let equals = pair.firstIndex(of: "=") else { continue }
            let key = String(pair[..<equals])
            let value = String(pair[pair.index(after: equals)...])
            headers[key] = value.removingPercentEncoding ?? value
        }
        return (urlPart, headers)
    }

    /// Récupère l'identifiant Xtream d'une URL de flux quand la playlist en est issue :
    /// `…/live/user/pass/12345.ts` → `"12345"`.
    static func xtreamStreamID(from url: URL) -> String? {
        let components = url.pathComponents
        guard components.count >= 2,
              let kindIndex = components.firstIndex(where: { ["live", "movie", "series"].contains($0) }),
              kindIndex + 3 < components.count else { return nil }
        let last = components[components.count - 1]
        let identifier = last.split(separator: ".").first.map(String.init) ?? last
        return Int(identifier) != nil ? identifier : nil
    }

    // MARK: - Entrées pratiques

    public struct Output: Sendable {
        public var header: Header
        public var channels: [ParsedChannel]
        public var skipped: [(line: Int, reason: String)]
    }

    /// Variante « tout en mémoire », réservée aux tests et aux petites playlists.
    public static func parse(text: String) -> Output {
        var parser = M3UParser()
        var channels: [ParsedChannel] = []
        // `split(separator: "\n")` serait un piège : en Swift, "\r\n" forme **un seul**
        // `Character` (grapheme cluster), qui n'est donc pas égal à "\n" et ne
        // découperait pas les playlists à fins de ligne Windows — majoritaires.
        // `isNewline` couvre \n, \r, \r\n et les séparateurs Unicode.
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            if let channel = parser.consume(line: String(line)) { channels.append(channel) }
        }
        return Output(header: parser.header, channels: channels, skipped: parser.skipped)
    }
}
