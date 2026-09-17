import Foundation
import UHFCore

/// Construction des URLs de replay.
///
/// Trois conventions cohabitent dans les playlists réelles, plus celle de Xtream.
/// Aucune n'est documentée officiellement : les jetons ci-dessous sont ceux
/// effectivement acceptés par les serveurs et les autres lecteurs du marché.
public enum CatchupURLBuilder {

    /// - Parameters:
    ///   - channel: la chaîne, qui porte le mode et le gabarit de replay.
    ///   - start: début du programme demandé.
    ///   - duration: durée du programme.
    /// - Returns: `nil` si la chaîne n'annonce pas de replay exploitable.
    public static func url(for channel: ParsedChannel,
                           start: Date,
                           duration: TimeInterval) -> URL? {
        guard let mode = channel.catchup else { return nil }
        let end = start.addingTimeInterval(duration)

        switch mode {
        case .append:
            guard let source = channel.catchupSource else { return nil }
            // `catchup-source` est ici un suffixe à coller à l'URL live.
            let suffix = substitute(source, start: start, end: end, duration: duration)
                .drop(while: { $0 == "?" || $0 == "&" })
            guard !suffix.isEmpty else { return channel.url }
            let base = channel.url.absoluteString
            return URL(string: base + (base.contains("?") ? "&" : "?") + suffix)

        case .default, .shift:
            if let source = channel.catchupSource {
                // Gabarit complet fourni par la playlist : il fait autorité.
                return URL(string: substitute(source, start: start, end: end, duration: duration))
            }
            var components = URLComponents(url: channel.url, resolvingAgainstBaseURL: false)
            var items = components?.queryItems ?? []
            items.append(URLQueryItem(name: "utc", value: String(Int(start.timeIntervalSince1970))))
            items.append(URLQueryItem(name: "lutc", value: String(Int(Date().timeIntervalSince1970))))
            components?.queryItems = items
            return components?.url

        case .flussonic:
            if let source = channel.catchupSource {
                return URL(string: substitute(source, start: start, end: end, duration: duration))
            }
            // `.../ch/index.m3u8` devient `.../ch/index-{utc}-{durée}.m3u8`
            let utc = Int(start.timeIntervalSince1970)
            let seconds = Int(duration)
            var url = channel.url
            let ext = url.pathExtension.isEmpty ? "m3u8" : url.pathExtension
            let stem = url.deletingPathExtension().lastPathComponent
            url.deleteLastPathComponent()
            return url.appendingPathComponent("\(stem)-\(utc)-\(seconds).\(ext)")

        case .xtream:
            // Construite par ``XtreamClient/timeshiftURL(streamID:start:duration:)``,
            // qui seul détient les identifiants.
            return nil
        }
    }

    /// Remplace les jetons d'un gabarit `catchup-source`.
    ///
    /// Les deux graphies (`{utc}` et `${start}`) circulent, parfois dans la même playlist.
    static func substitute(_ template: String,
                           start: Date,
                           end: Date,
                           duration: TimeInterval) -> String {
        let startEpoch = Int(start.timeIntervalSince1970)
        let endEpoch = Int(end.timeIntervalSince1970)
        let now = Int(Date().timeIntervalSince1970)

        var result = template
        let replacements: [String: String] = [
            "utc": String(startEpoch),
            "start": String(startEpoch),
            "timestamp": String(startEpoch),
            "end": String(endEpoch),
            "utcend": String(endEpoch),
            "stop": String(endEpoch),
            "lutc": String(now),
            "now": String(now),
            "duration": String(Int(duration)),
            "durmin": String(Int(duration / 60)),
            "offset": String(now - startEpoch),
            "Y": component(.year, of: start),
            "m": component(.month, of: start),
            "d": component(.day, of: start),
            "H": component(.hour, of: start),
            "M": component(.minute, of: start),
            "S": component(.second, of: start),
        ]

        // Gabarits de date littéraux employés par certains panneaux. Traités avant la
        // boucle, sans quoi la substitution de "${start}" les aurait déjà éventrés.
        result = result.replacingOccurrences(
            of: "${start:YYYY-MM-DD-HH-mm}",
            with: xtreamTimestamp(start).replacingOccurrences(of: ":", with: "-"))

        for (token, value) in replacements {
            // "${token}" d'abord : l'inverse laisserait un "$" orphelin devant la valeur.
            result = result.replacingOccurrences(of: "${\(token)}", with: value)
            result = result.replacingOccurrences(of: "{\(token)}", with: value)
        }
        return result
    }

    private static func component(_ unit: Calendar.Component, of date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let value = calendar.component(unit, from: date)
        return unit == .year ? String(value) : String(format: "%02d", value)
    }

    /// Format attendu par `timeshift.php` : `YYYY-MM-DD:HH-MM`.
    public static func xtreamTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd:HH-mm"
        return formatter.string(from: date)
    }
}
