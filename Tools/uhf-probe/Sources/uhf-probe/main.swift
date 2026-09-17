import Foundation
import UHFCore
import UHFSources
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Outil de diagnostic en ligne de commande.
//
// Permet d'éprouver les parseurs sur de vraies sources avant d'écrire la moindre ligne
// d'interface : c'est là que se découvrent les particularités d'un fournisseur, et le
// terminal est un bien meilleur endroit qu'un simulateur pour ça.
//
//   swift run uhf-probe m3u      <fichier|url>
//   swift run uhf-probe xtream   <url get.php complète>
//   swift run uhf-probe epg      <fichier|url>
//   swift run uhf-probe match    <m3u> <epg>

let usage = """
uhf-probe — diagnostic des sources IPTV

  uhf-probe m3u     <fichier|url>          Analyse une playlist M3U
  uhf-probe xtream  <url get.php|serveur>  Interroge un panneau Xtream Codes
  uhf-probe epg     <fichier|url>          Analyse un fichier XMLTV (gzip accepté)
  uhf-probe match   <m3u> <epg>            Taux d'appariement chaînes ↔ guide

Options :
  --limit <n>       Nombre d'exemples affichés (défaut : 10)
  --user-agent <ua> User-Agent à présenter au serveur
"""

// MARK: - Aides

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("Erreur : " + message + "\n").utf8))
    exit(1)
}

func percent(_ value: Double) -> String {
    String(format: "%.1f %%", value * 100)
}

func duration(since start: Date) -> String {
    String(format: "%.2f s", Date().timeIntervalSince(start))
}

/// Télécharge la ressource si nécessaire et rend un chemin local.
func localFile(for argument: String, userAgent: String?) async throws -> (url: URL, isTemporary: Bool) {
    if !argument.lowercased().hasPrefix("http") {
        let url = URL(fileURLWithPath: argument)
        guard FileManager.default.fileExists(atPath: url.path) else {
            fail("fichier introuvable : \(argument)")
        }
        return (url, false)
    }
    guard let remote = URL(string: argument) else { fail("URL invalide : \(argument)") }

    var request = URLRequest(url: remote)
    if let userAgent { request.setValue(userAgent, forHTTPHeaderField: "User-Agent") }

    print("Téléchargement de \(remote.host ?? "")…")
    let started = Date()
    let (data, response) = try await URLSession.shared.data(for: request)
    if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
        fail("le serveur a répondu \(http.statusCode)")
    }
    let destination = FileManager.default.temporaryDirectory
        .appendingPathComponent("uhf-probe-\(UUID().uuidString)")
    try data.write(to: destination)
    let mb = Double(data.count) / 1_048_576
    print("  \(String(format: "%.1f", mb)) Mo en \(duration(since: started))")
    return (destination, true)
}

// MARK: - Commandes

func probeM3U(_ path: String, limit: Int, userAgent: String?) async throws {
    let (url, isTemporary) = try await localFile(for: path, userAgent: userAgent)
    defer { if isTemporary { try? FileManager.default.removeItem(at: url) } }

    var channels: [ParsedChannel] = []
    let started = Date()
    let result = try M3UParser.parse(fileAt: url) { channels.append($0) }
    let elapsed = duration(since: started)

    print("\n── Playlist ────────────────────────────────")
    print("Chaînes            : \(result.count)  (analysées en \(elapsed))")
    print("Lignes ignorées    : \(result.skipped.count)")
    for epg in result.header.epgURLs { print("EPG déclaré        : \(epg.absoluteString)") }

    let withTvgID = channels.count { $0.tvgID != nil }
    let withLogo = channels.count { $0.logoURL != nil }
    let withCatchup = channels.count(where: \.supportsCatchup)
    let adult = channels.count(where: \.isLikelyAdult)
    let hls = channels.count { $0.url.pathExtension.lowercased() == "m3u8" }

    print("\n── Qualité des métadonnées ─────────────────")
    print("tvg-id présent     : \(withTvgID) (\(percent(ratio(withTvgID, channels.count))))")
    print("Logo présent       : \(withLogo) (\(percent(ratio(withLogo, channels.count))))")
    print("Replay annoncé     : \(withCatchup) (\(percent(ratio(withCatchup, channels.count))))")
    print("Catégorie adulte   : \(adult)")

    print("\n── Moteur de lecture ───────────────────────")
    print("Flux HLS (.m3u8)   : \(hls) → AVPlayer, PiP/AirPlay/HDR disponibles")
    print("Autres (.ts, …)    : \(channels.count - hls) → VLCKit requis")
    if hls == 0 && !channels.isEmpty {
        print("  ⚠︎  Aucun flux HLS : demander la sortie m3u8 au fournisseur si possible.")
    }

    let groups = Dictionary(grouping: channels, by: { $0.groupTitle ?? "(sans groupe)" })
    print("\n── Groupes (\(groups.count)) ─────────────────────────────")
    for (name, list) in groups.sorted(by: { $0.value.count > $1.value.count }).prefix(limit) {
        print(String(format: "  %6d  %@", list.count, name))
    }

    if !result.skipped.isEmpty {
        print("\n── Lignes ignorées ─────────────────────────")
        for entry in result.skipped.prefix(limit) {
            print("  ligne \(entry.line) : \(entry.reason)")
        }
    }

    print("\n── Échantillon ─────────────────────────────")
    for channel in channels.prefix(limit) {
        print("  \(channel.name)")
        print("    tvg-id \(channel.tvgID ?? "—")   clé \(channel.stableKey(playlistID: "probe"))")
        print("    \(channel.url.absoluteString)")
        if !channel.httpHeaders.isEmpty { print("    en-têtes \(channel.httpHeaders)") }
    }
}

func probeXtream(_ raw: String, limit: Int, userAgent: String?) async throws {
    guard let credentials = XtreamClient.Credentials(pastedURL: raw) else {
        fail("URL Xtream non reconnue. Attendu : http://serveur:port/get.php?username=…&password=…")
    }
    let client = XtreamClient(credentials: credentials, userAgent: userAgent)
    print("Serveur : \(credentials.baseURL.absoluteString)")

    let account = try await client.account()
    print("\n── Compte ──────────────────────────────────")
    print("Utilisateur        : \(account.username)")
    print("Statut             : \(account.status ?? "—")\(account.isTrial ? " (essai)" : "")")
    if let expiry = account.expiresAt {
        print("Expiration         : \(expiry.formatted(date: .abbreviated, time: .shortened))")
    } else {
        print("Expiration         : illimitée")
    }
    print("Connexions         : \(account.activeConnections ?? 0) / \(account.maxConnections.map(String.init) ?? "—")")
    print("Formats proposés   : \(account.allowedOutputFormats.map(\.rawValue).joined(separator: ", "))")
    print("Format retenu      : \(account.preferredLiveFormat.rawValue)"
          + (account.preferredLiveFormat == .m3u8
             ? "  → AVPlayer, PiP/AirPlay/HDR disponibles"
             : "  → VLCKit requis, pas de PiP ni d'AirPlay"))

    let started = Date()
    async let categoriesTask = client.liveCategories()
    async let channelsTask = client.liveChannels(format: account.preferredLiveFormat)
    let (categories, channels) = try await (categoriesTask, channelsTask)

    print("\n── Catalogue live ──────────────────────────")
    print("Catégories         : \(categories.count)")
    print("Chaînes            : \(channels.count)  (récupérées en \(duration(since: started)))")
    print("Avec replay        : \(channels.count(where: \.supportsCatchup))")
    print("Avec tvg-id        : \(channels.count { $0.tvgID != nil })")

    for (movies, series) in [try await (client.movies(), client.series())] {
        print("\n── VOD ─────────────────────────────────────")
        print("Films              : \(movies.count)")
        print("Séries             : \(series.count)")
        if let sample = movies.first(where: { $0.year != nil }) {
            print("Exemple            : \(sample.title) (\(sample.year!)) — .\(sample.containerExtension)")
        }
    }

    print("\n── Échantillon ─────────────────────────────")
    for channel in channels.prefix(limit) {
        print("  \(channel.name)  [\(channel.tvgID ?? "sans tvg-id")]")
        print("    \(channel.url.absoluteString)")
    }
    print("\nEPG complet : \(client.epgURL.absoluteString)")
}

func probeEPG(_ path: String, limit: Int, userAgent: String?) async throws {
    let (url, isTemporary) = try await localFile(for: path, userAgent: userAgent)
    defer { if isTemporary { try? FileManager.default.removeItem(at: url) } }

    if Gunzip.isGzip(fileAt: url) { print("Archive gzip détectée, décompression en flux.") }

    var channels: [EPGChannel] = []
    var earliest: Date?
    var latest: Date?
    var titles = 0
    var withDescription = 0

    let parser = XMLTVParser(
        options: .init(preferredLanguages: ["fr", "en"]),
        onChannel: { channels.append($0) },
        onProgramme: { programme in
            titles += 1
            if programme.desc != nil { withDescription += 1 }
            if earliest == nil || programme.start < earliest! { earliest = programme.start }
            if latest == nil || programme.stop > latest! { latest = programme.stop }
        })

    let started = Date()
    let summary = try parser.parse(fileAt: url)
    let elapsed = Date().timeIntervalSince(started)

    print("\n── Guide ───────────────────────────────────")
    print("Chaînes            : \(summary.channelCount)")
    print("Programmes         : \(summary.programmeCount)")
    print("Écartés            : \(summary.skippedCount)")
    print("Avec description   : \(withDescription) (\(percent(ratio(withDescription, titles))))")
    print("Durée de l'analyse : \(String(format: "%.2f s", elapsed))")
    if let earliest, let latest {
        print("Couverture         : \(earliest.formatted(date: .abbreviated, time: .shortened))"
              + " → \(latest.formatted(date: .abbreviated, time: .shortened))")
        let days = latest.timeIntervalSince(earliest) / 86400
        print("                     soit \(String(format: "%.1f", days)) jours")
    }

    print("\n── Échantillon ─────────────────────────────")
    for channel in channels.prefix(limit) {
        print("  \(channel.xmltvID)  →  \(channel.displayNames.joined(separator: " / "))")
    }
}

func probeMatch(_ playlistPath: String, _ epgPath: String, limit: Int, userAgent: String?) async throws {
    let (playlistURL, playlistTemporary) = try await localFile(for: playlistPath, userAgent: userAgent)
    defer { if playlistTemporary { try? FileManager.default.removeItem(at: playlistURL) } }
    let (epgURL, epgTemporary) = try await localFile(for: epgPath, userAgent: userAgent)
    defer { if epgTemporary { try? FileManager.default.removeItem(at: epgURL) } }

    var channels: [ParsedChannel] = []
    _ = try M3UParser.parse(fileAt: playlistURL) { channels.append($0) }

    var epgChannels: [EPGChannel] = []
    let parser = XMLTVParser(onChannel: { epgChannels.append($0) }, onProgramme: { _ in })
    _ = try parser.parse(fileAt: epgURL)

    let report = EPGMatcher(epgChannels: epgChannels).match(channels: channels)

    print("\n── Appariement chaînes ↔ guide ─────────────")
    print("Chaînes playlist   : \(channels.count)")
    print("Chaînes guide      : \(epgChannels.count)")
    print("Appariées          : \(report.matchedCount) (\(percent(report.rate)))")
    for confidence in EPGMatcher.Confidence.allCases.sorted(by: >) {
        let count = report.countsByConfidence[confidence] ?? 0
        guard count > 0 else { continue }
        let label = switch confidence {
        case .exactID: "  tvg-id exact     "
        case .normalizedID: "  tvg-id normalisé "
        case .name: "  par le nom       "
        case .weak: "  approximatif     "
        }
        print("\(label): \(count)\(confidence.isTrustworthy ? "" : "  ← à faire confirmer")")
    }

    if !report.unmatched.isEmpty {
        print("\n── Sans correspondance (\(report.unmatched.count)) ───────────")
        for name in report.unmatched.prefix(limit) { print("  \(name)") }
        if report.unmatched.count > limit {
            print("  … et \(report.unmatched.count - limit) autres")
        }
    }
    if report.rate < 0.8 {
        print("\n⚠︎  Taux faible : prévoir l'écran de correspondance manuelle (PLAN.md §8.2).")
    }
}

func ratio(_ part: Int, _ total: Int) -> Double {
    total == 0 ? 0 : Double(part) / Double(total)
}

// MARK: - Point d'entrée

var arguments = Array(CommandLine.arguments.dropFirst())
var limit = 10
var userAgent: String?

var index = 0
var positional: [String] = []
while index < arguments.count {
    switch arguments[index] {
    case "--limit":
        index += 1
        limit = Int(arguments[safe: index] ?? "") ?? 10
    case "--user-agent":
        index += 1
        userAgent = arguments[safe: index]
    case "-h", "--help":
        print(usage)
        exit(0)
    default:
        positional.append(arguments[index])
    }
    index += 1
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

guard let command = positional.first else {
    print(usage)
    exit(1)
}

do {
    switch command {
    case "m3u":
        guard let path = positional[safe: 1] else { fail("chemin ou URL manquant") }
        try await probeM3U(path, limit: limit, userAgent: userAgent)
    case "xtream":
        guard let path = positional[safe: 1] else { fail("URL manquante") }
        try await probeXtream(path, limit: limit, userAgent: userAgent)
    case "epg":
        guard let path = positional[safe: 1] else { fail("chemin ou URL manquant") }
        try await probeEPG(path, limit: limit, userAgent: userAgent)
    case "match":
        guard let playlist = positional[safe: 1], let epg = positional[safe: 2] else {
            fail("usage : uhf-probe match <m3u> <epg>")
        }
        try await probeMatch(playlist, epg, limit: limit, userAgent: userAgent)
    default:
        print(usage)
        exit(1)
    }
} catch let error as LocalizedError {
    fail(error.errorDescription ?? String(describing: error))
} catch {
    fail(String(describing: error))
}
