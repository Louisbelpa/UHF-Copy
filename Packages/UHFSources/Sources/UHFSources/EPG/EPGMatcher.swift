import Foundation
import UHFCore

/// Rapproche les chaînes d'une playlist des chaînes d'un fichier EPG.
///
/// En théorie `tvg-id` suffit. En pratique aucune playlist du marché n'a des `tvg-id`
/// propres sur la totalité de ses chaînes : ils sont vides, mal orthographiés, ou
/// pointent vers un fichier XMLTV que l'utilisateur n'a pas chargé. D'où cette cascade
/// de rapprochements, du plus sûr au plus approximatif, chacun rendant son niveau de
/// confiance pour que l'interface puisse proposer une correction manuelle sur les cas
/// douteux plutôt que d'afficher un guide silencieusement faux.
public struct EPGMatcher: Sendable {

    public enum Confidence: Int, Sendable, Comparable, CaseIterable {
        /// `tvg-id` identique à l'identifiant XMLTV. Aucun doute.
        case exactID = 3
        /// Identifiants équivalents après normalisation.
        case normalizedID = 2
        /// Le nom de la chaîne correspond à un `display-name` du guide.
        case name = 1
        /// Correspondance obtenue en supprimant jusqu'aux espaces. À faire confirmer.
        case weak = 0

        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

        /// En deçà, mieux vaut ne rien afficher que d'afficher le mauvais programme.
        public var isTrustworthy: Bool { self >= .name }
    }

    public struct Match: Sendable, Equatable {
        public let xmltvID: String
        public let confidence: Confidence
    }

    public struct Report: Sendable {
        public var matches: [String: Match] = [:]
        public var unmatched: [String] = []
        public var countsByConfidence: [Confidence: Int] = [:]

        public var matchedCount: Int { matches.count }
        public var total: Int { matchedCount + unmatched.count }
        public var rate: Double { total == 0 ? 0 : Double(matchedCount) / Double(total) }
    }

    private var byExactID: [String: String] = [:]
    private var byNormalizedID: [String: String] = [:]
    private var byName: [String: String] = [:]
    private var byCompactedName: [String: String] = [:]

    public init(epgChannels: [EPGChannel]) {
        for channel in epgChannels {
            let id = channel.xmltvID
            byExactID[id] = id
            // `setdefault` plutôt qu'écrasement : en cas d'ambiguïté, la première
            // chaîne déclarée gagne, ce qui rend le résultat reproductible d'un
            // import à l'autre.
            byNormalizedID[id.lowercased()] = byNormalizedID[id.lowercased()] ?? id
            byName[id.normalizedForMatching] = byName[id.normalizedForMatching] ?? id

            for name in channel.displayNames {
                let normalized = name.normalizedForMatching
                guard !normalized.isEmpty else { continue }
                byName[normalized] = byName[normalized] ?? id
                let compacted = name.compactedForMatching
                byCompactedName[compacted] = byCompactedName[compacted] ?? id
            }
        }
    }

    public func match(_ channel: ParsedChannel) -> Match? {
        if let tvgID = channel.tvgID, !tvgID.isEmpty {
            if let id = byExactID[tvgID] { return Match(xmltvID: id, confidence: .exactID) }
            if let id = byNormalizedID[tvgID.lowercased()] {
                return Match(xmltvID: id, confidence: .normalizedID)
            }
            if let id = byName[tvgID.normalizedForMatching] {
                return Match(xmltvID: id, confidence: .normalizedID)
            }
        }

        let normalized = channel.name.normalizedForMatching
        if !normalized.isEmpty, let id = byName[normalized] {
            return Match(xmltvID: id, confidence: .name)
        }
        if let tvgName = channel.tvgName?.normalizedForMatching,
           !tvgName.isEmpty, let id = byName[tvgName] {
            return Match(xmltvID: id, confidence: .name)
        }

        let compacted = channel.name.compactedForMatching
        if !compacted.isEmpty, let id = byCompactedName[compacted] {
            return Match(xmltvID: id, confidence: .weak)
        }
        return nil
    }

    /// Rapproche une playlist entière et rend de quoi alimenter l'écran de diagnostic.
    public func match(channels: [ParsedChannel]) -> Report {
        var report = Report()
        for channel in channels {
            let key = channel.tvgID.flatMap { $0.isEmpty ? nil : $0 } ?? channel.name
            if let match = match(channel) {
                report.matches[key] = match
                report.countsByConfidence[match.confidence, default: 0] += 1
            } else {
                report.unmatched.append(channel.name)
            }
        }
        return report
    }
}
