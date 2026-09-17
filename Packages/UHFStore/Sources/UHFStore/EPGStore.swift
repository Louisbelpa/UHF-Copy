import Foundation
import GRDB
import UHFCore

/// Écriture et lecture du guide des programmes.
///
/// La table `programmes` est de loin la plus volumineuse de la base — plusieurs
/// millions de lignes pour un XMLTV complet. Tout ici est dimensionné pour ça :
/// import par lots, remplacement par marqueur de passe plutôt que par purge
/// préalable, et requêtes toujours bornées par une plage horaire.
public struct EPGStore: Sendable {

    private let database: UHFDatabase

    public init(_ database: UHFDatabase) {
        self.database = database
    }

    // MARK: - Import

    /// Ouvre une session d'import branchable directement sur ``XMLTVParser`` :
    ///
    /// ```swift
    /// let session = try store.beginImport(playlistID: playlist.id)
    /// let parser = XMLTVParser(
    ///     onChannel:   { try? session.append(channel: $0) },
    ///     onProgramme: { try? session.append(programme: $0) })
    /// try parser.parse(fileAt: url)
    /// let report = try session.finish()
    /// ```
    public func beginImport(playlistID: String,
                            batchSize: Int = 5_000) throws -> ImportSession {
        ImportSession(database: database, playlistID: playlistID, batchSize: batchSize,
                      previousTotal: try programmeCount(playlistID: playlistID))
    }

    public final class ImportSession {
        private let database: UHFDatabase
        private let playlistID: String
        private let batchSize: Int
        private let token = UUID().uuidString
        private let startedAt = Date()

        /// Correspondance `xmltvId` → `rowid`, tenue en mémoire pour éviter une
        /// requête par programme. Quelques milliers d'entrées au plus : négligeable
        /// face aux millions de programmes qui la traversent.
        private var channelRowIDs: [String: Int64] = [:]
        private var pendingChannels: [EPGChannel] = []
        private var pendingProgrammes: [EPGProgramme] = []
        private var report = MergeReport()
        private var orphaned = 0

        init(database: UHFDatabase, playlistID: String, batchSize: Int, previousTotal: Int) {
            self.database = database
            self.playlistID = playlistID
            self.batchSize = batchSize
            self.report = MergeReport(previousTotal: previousTotal)
            pendingProgrammes.reserveCapacity(batchSize)
        }

        public func append(channel: EPGChannel) throws {
            pendingChannels.append(channel)
            if pendingChannels.count >= 500 { try flushChannels() }
        }

        public func append(programme: EPGProgramme) throws {
            pendingProgrammes.append(programme)
            if pendingProgrammes.count >= batchSize { try flushProgrammes() }
        }

        @discardableResult
        public func finish() throws -> MergeReport {
            try flushChannels()
            try flushProgrammes()

            try database.writer.write { db in
                // Le guide précédent n'est remplacé qu'ici : jusqu'à cette ligne,
                // l'utilisateur continuait de voir l'ancien.
                try db.execute(sql: """
                    DELETE FROM programmes
                    WHERE syncToken <> ?
                      AND epgChannelId IN (SELECT id FROM epgChannels WHERE playlistId = ?)
                    """, arguments: [token, playlistID])
                report.removed = db.changesCount
            }
            report.duration = Date().timeIntervalSince(startedAt)
            return report
        }

        /// Programmes rattachés à une chaîne absente du bloc `<channel>` du fichier.
        /// Fréquent, et sans gravité : ils sont ignorés.
        public var orphanedProgrammes: Int { orphaned }

        private func flushChannels() throws {
            guard !pendingChannels.isEmpty else { return }
            let batch = pendingChannels
            pendingChannels.removeAll(keepingCapacity: true)

            try database.writer.write { db in
                let statement = try db.makeStatement(sql: """
                    INSERT INTO epgChannels (playlistId, xmltvId, displayName, iconURL)
                    VALUES (?,?,?,?)
                    ON CONFLICT(playlistId, xmltvId) DO UPDATE SET
                        displayName = excluded.displayName, iconURL = excluded.iconURL
                    """)
                for channel in batch {
                    statement.setUncheckedArguments([
                        playlistID, channel.xmltvID,
                        channel.displayNames.first, channel.iconURL?.absoluteString,
                    ])
                    try statement.execute()
                }

                for channel in batch where channelRowIDs[channel.xmltvID] == nil {
                    channelRowIDs[channel.xmltvID] = try Int64.fetchOne(db, sql: """
                        SELECT id FROM epgChannels WHERE playlistId = ? AND xmltvId = ?
                        """, arguments: [playlistID, channel.xmltvID])
                }
            }
        }

        private func flushProgrammes() throws {
            guard !pendingProgrammes.isEmpty else { return }
            // Les `<channel>` précèdent les `<programme>` dans un XMLTV conforme, mais
            // on vide la file des chaînes d'abord au cas où ce ne serait pas le cas.
            try flushChannels()

            let batch = pendingProgrammes
            pendingProgrammes.removeAll(keepingCapacity: true)

            try database.writer.write { db in
                let statement = try db.makeStatement(sql: """
                    INSERT INTO programmes
                        (epgChannelId, startAt, endAt, title, subtitle, summary,
                         categories, iconURL, episodeNumber, syncToken)
                    VALUES (?,?,?,?,?,?,?,?,?,?)
                    """)
                for programme in batch {
                    guard let rowID = channelRowIDs[programme.channelID] else {
                        orphaned += 1
                        continue
                    }
                    let categories = programme.categories.isEmpty
                        ? nil
                        : String(data: try JSONEncoder().encode(programme.categories), encoding: .utf8)

                    statement.setUncheckedArguments([
                        rowID,
                        programme.start.timeIntervalSince1970,
                        programme.stop.timeIntervalSince1970,
                        programme.title,
                        programme.subtitle,
                        programme.desc,
                        categories,
                        programme.iconURL?.absoluteString,
                        programme.episodeNumber,
                        token,
                    ])
                    try statement.execute()
                    report.added += 1
                }
            }
        }
    }

    // MARK: - Rattachement des chaînes au guide

    /// Enregistre les correspondances calculées par `EPGMatcher`.
    ///
    /// Les correspondances corrigées à la main par l'utilisateur ne sont **jamais**
    /// écrasées : c'est tout l'intérêt de l'écran de correction, et l'y voir revenir
    /// à chaque rafraîchissement serait le meilleur moyen de le rendre inutile.
    public func saveLinks(_ links: [(channelKey: StableKey, xmltvID: String, confidence: Int)],
                          playlistID: String) throws {
        try database.writer.write { db in
            let statement = try db.makeStatement(sql: """
                INSERT INTO channelEPGLinks (playlistId, channelKey, xmltvId, confidence, isManual)
                VALUES (?,?,?,?,0)
                ON CONFLICT(playlistId, channelKey) DO UPDATE SET
                    xmltvId = excluded.xmltvId,
                    confidence = excluded.confidence
                WHERE isManual = 0
                """)
            for link in links {
                statement.setUncheckedArguments([
                    playlistID, link.channelKey.rawValue, link.xmltvID, link.confidence,
                ])
                try statement.execute()
            }
        }
    }

    /// Correspondance choisie manuellement par l'utilisateur.
    public func setManualLink(channelKey: StableKey, xmltvID: String, playlistID: String) throws {
        try database.writer.write { db in
            try ChannelEPGLinkRecord(playlistId: playlistID,
                                     channelKey: channelKey.rawValue,
                                     xmltvId: xmltvID,
                                     confidence: 3,
                                     isManual: true).upsert(db)
        }
    }

    public func link(for channelKey: StableKey, playlistID: String) throws -> ChannelEPGLinkRecord? {
        try database.reader.read { db in
            try ChannelEPGLinkRecord.filter(
                Column("playlistId") == playlistID && Column("channelKey") == channelKey.rawValue
            ).fetchOne(db)
        }
    }

    // MARK: - Lecture

    public struct NowNext: Sendable, Equatable {
        public var current: ProgrammeRecord?
        public var next: ProgrammeRecord?
    }

    /// Programme en cours et suivant, pour un lot de chaînes.
    ///
    /// Requête unique pour toute la page visible, et non une par cellule : à raison
    /// d'une requête par ligne, une liste de 60 chaînes qui défile en génère des
    /// milliers par seconde.
    ///
    /// Le décalage `tvg-shift` de chaque chaîne est appliqué ici : certaines sources
    /// fournissent un guide calé sur un autre fuseau que le flux.
    public func nowNext(channelKeys: [StableKey],
                        playlistID: String,
                        at date: Date = Date()) throws -> [StableKey: NowNext] {
        guard !channelKeys.isEmpty else { return [:] }
        let now = date.timeIntervalSince1970
        // Fenêtre bornée : sans elle, une chaîne au guide fourni renverrait des
        // milliers de lignes pour n'en garder que deux.
        let horizon = now + 12 * 3600

        return try database.reader.read { db in
            let placeholders = databaseQuestionMarks(count: channelKeys.count)
            let rows = try Row.fetchAll(db, sql: """
                SELECT l.channelKey AS channelKey, c.tvgShift AS tvgShift, p.*
                FROM channelEPGLinks l
                JOIN channels c ON c.playlistId = l.playlistId AND c.key = l.channelKey
                JOIN epgChannels e ON e.playlistId = l.playlistId AND e.xmltvId = l.xmltvId
                JOIN programmes p ON p.epgChannelId = e.id
                WHERE l.playlistId = ?
                  AND l.channelKey IN (\(placeholders))
                  AND p.endAt + c.tvgShift > ?
                  AND p.startAt + c.tvgShift < ?
                ORDER BY l.channelKey, p.startAt
                """, arguments: StatementArguments([playlistID] + channelKeys.map(\.rawValue))
                    + [now, horizon])

            var result: [StableKey: NowNext] = [:]
            for row in rows {
                let key = StableKey(rawValue: row["channelKey"])
                let shift: Double = row["tvgShift"]
                var programme = try ProgrammeRecord(row: row)
                programme.startAt += shift
                programme.endAt += shift

                var entry = result[key] ?? NowNext()
                if programme.startAt <= now, programme.endAt > now {
                    entry.current = programme
                } else if programme.startAt > now, entry.next == nil {
                    entry.next = programme
                }
                result[key] = entry
            }
            return result
        }
    }

    /// Programmes d'une chaîne sur une plage donnée — la requête de la grille EPG.
    public func programmes(channelKey: StableKey,
                           playlistID: String,
                           from: Date,
                           to: Date) throws -> [ProgrammeRecord] {
        try database.reader.read { db in
            try ProgrammeRecord.fetchAll(db, sql: """
                SELECT p.* FROM programmes p
                JOIN epgChannels e ON e.id = p.epgChannelId
                JOIN channelEPGLinks l ON l.xmltvId = e.xmltvId AND l.playlistId = e.playlistId
                WHERE l.playlistId = ? AND l.channelKey = ?
                  AND p.endAt > ? AND p.startAt < ?
                ORDER BY p.startAt
                """, arguments: [playlistID, channelKey.rawValue,
                                 from.timeIntervalSince1970, to.timeIntervalSince1970])
        }
    }

    public func programmeCount(playlistID: String) throws -> Int {
        try database.reader.read { db in
            try Int.fetchOne(db, sql: """
                SELECT count(*) FROM programmes
                WHERE epgChannelId IN (SELECT id FROM epgChannels WHERE playlistId = ?)
                """, arguments: [playlistID]) ?? 0
        }
    }

    public func epgChannels(playlistID: String) throws -> [EPGChannel] {
        try database.reader.read { db in
            try EPGChannelRecord
                .filter(Column("playlistId") == playlistID)
                .order(Column("displayName"))
                .fetchAll(db)
                .map { EPGChannel(xmltvID: $0.xmltvId,
                                  displayNames: [$0.displayName].compactMap { $0 },
                                  iconURL: $0.iconURL.flatMap(URL.init(string:))) }
        }
    }

    // MARK: - Entretien

    /// Supprime les programmes terminés à la date indiquée, celle-ci comprise —
    /// un programme qui s'achève à l'instant de coupure est bien terminé.
    ///
    /// Sans cette purge, la base grossit indéfiniment : un XMLTV quotidien de 200 Mo
    /// ajoute autant de lignes chaque jour, et l'index de la grille devient plus lent
    /// que la lecture du fichier d'origine.
    @discardableResult
    public func purge(before date: Date) throws -> Int {
        try database.writer.write { db in
            try db.execute(sql: "DELETE FROM programmes WHERE endAt <= ?",
                           arguments: [date.timeIntervalSince1970])
            return db.changesCount
        }
    }

    /// Fenêtre de conservation recommandée : hier, et les sept prochains jours.
    public static func retentionWindow(from date: Date = Date()) -> ClosedRange<Date> {
        date.addingTimeInterval(-86_400)...date.addingTimeInterval(7 * 86_400)
    }
}

/// `?,?,?…` — construit à partir d'un décompte, jamais d'une saisie utilisateur.
private func databaseQuestionMarks(count: Int) -> String {
    Array(repeating: "?", count: count).joined(separator: ",")
}
