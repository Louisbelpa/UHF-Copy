import Foundation
import GRDB
import UHFCore

/// Écriture et lecture du catalogue de chaînes.
public struct ChannelStore: Sendable {

    private let database: UHFDatabase

    public init(_ database: UHFDatabase) {
        self.database = database
    }

    // MARK: - Import

    /// Ouvre une session d'import qui absorbe les chaînes au fil de l'eau.
    ///
    /// À brancher directement sur le parseur :
    ///
    /// ```swift
    /// let session = store.beginImport(playlistID: playlist.id)
    /// try M3UParser.parse(fileAt: url) { try session.append($0) }
    /// let report = try session.finish()
    /// ```
    ///
    /// La mémoire reste constante de bout en bout, quelle que soit la taille de la
    /// playlist.
    public func beginImport(playlistID: String, batchSize: Int = 5_000) throws -> ImportSession {
        ImportSession(database: database,
                      playlistID: playlistID,
                      batchSize: batchSize,
                      previousTotal: try count(playlistID: playlistID))
    }

    /// Variante « tout en mémoire », pour les petits lots et les tests.
    @discardableResult
    public func merge(_ channels: [ParsedChannel], playlistID: String) throws -> MergeReport {
        let session = try beginImport(playlistID: playlistID)
        for channel in channels { try session.append(channel) }
        return try session.finish()
    }

    /// Session d'import à état, qui écrit par lots et conclut par la purge des
    /// chaînes disparues de la source.
    public final class ImportSession {
        private let database: UHFDatabase
        private let playlistID: String
        private let batchSize: Int
        /// Marqueur de cette passe : toute ligne qui ne le porte pas à la fin a
        /// disparu de la source.
        private let token = UUID().uuidString
        private let startedAt = Date()

        private var buffer: [ParsedChannel] = []
        private var report: MergeReport

        init(database: UHFDatabase, playlistID: String, batchSize: Int, previousTotal: Int) {
            self.database = database
            self.playlistID = playlistID
            self.batchSize = batchSize
            self.report = MergeReport(previousTotal: previousTotal)
            buffer.reserveCapacity(batchSize)
        }

        public func append(_ channel: ParsedChannel) throws {
            buffer.append(channel)
            if buffer.count >= batchSize { try flush() }
        }

        /// Conclut l'import : purge les chaînes absentes de cette passe et rend le bilan.
        @discardableResult
        public func finish() throws -> MergeReport {
            try flush()

            try database.writer.write { db in
                try db.execute(sql: """
                    DELETE FROM channels WHERE playlistId = ? AND syncToken <> ?
                    """, arguments: [playlistID, token])
                report.removed = db.changesCount

                try db.execute(sql: "UPDATE playlists SET lastSyncAt = ? WHERE id = ?",
                               arguments: [Date().timeIntervalSince1970, playlistID])
            }
            report.duration = Date().timeIntervalSince(startedAt)
            return report
        }

        private func flush() throws {
            guard !buffer.isEmpty else { return }
            let batch = buffer
            buffer.removeAll(keepingCapacity: true)

            // Une transaction par lot, et non une seule pour tout l'import : le
            // journal WAL ne gonfle pas, et une interruption ne perd que le dernier lot.
            try database.writer.write { db in
                let before = try Int.fetchOne(
                    db, sql: "SELECT count(*) FROM channels WHERE playlistId = ?",
                    arguments: [playlistID]) ?? 0

                // Une seule requête préparée, réutilisée pour tout le lot : le coût de
                // compilation SQL est payé une fois au lieu de cinq mille.
                let statement = try db.makeStatement(sql: Self.upsertSQL)
                for channel in batch {
                    statement.setUncheckedArguments(try Self.arguments(for: channel,
                                                                       playlistID: playlistID,
                                                                       token: token))
                    try statement.execute()
                }

                let after = try Int.fetchOne(
                    db, sql: "SELECT count(*) FROM channels WHERE playlistId = ?",
                    arguments: [playlistID]) ?? 0

                let added = after - before
                report.added += added
                report.updated += batch.count - added
            }
        }

        /// `ON CONFLICT` plutôt que `INSERT OR REPLACE` : remplacer supprimerait puis
        /// réinsérerait la ligne, ce qui ferait tourner son `rowid` et obligerait
        /// l'index plein texte à se reconstruire à chaque rafraîchissement.
        private static let upsertSQL = """
            INSERT INTO channels
                (playlistId, key, name, url, streamId, logoURL, groupTitle, tvgId,
                 tvgShift, catchupMode, catchupDays, catchupSource, httpHeaders,
                 sortIndex, isAdult, syncToken)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(playlistId, key) DO UPDATE SET
                name = excluded.name,
                url = excluded.url,
                streamId = excluded.streamId,
                logoURL = excluded.logoURL,
                groupTitle = excluded.groupTitle,
                tvgId = excluded.tvgId,
                tvgShift = excluded.tvgShift,
                catchupMode = excluded.catchupMode,
                catchupDays = excluded.catchupDays,
                catchupSource = excluded.catchupSource,
                httpHeaders = excluded.httpHeaders,
                sortIndex = excluded.sortIndex,
                isAdult = excluded.isAdult,
                syncToken = excluded.syncToken
            """

        private static func arguments(for channel: ParsedChannel,
                                      playlistID: String,
                                      token: String) throws -> StatementArguments {
            let headers: String?
            if channel.httpHeaders.isEmpty {
                headers = nil
            } else {
                headers = String(data: try JSONEncoder().encode(channel.httpHeaders), encoding: .utf8)
            }
            return [
                playlistID,
                channel.stableKey(playlistID: playlistID).rawValue,
                channel.name,
                channel.url.absoluteString,
                channel.streamID,
                channel.logoURL?.absoluteString,
                channel.groupTitle,
                channel.tvgID,
                channel.tvgShift,
                channel.catchup?.rawValue,
                channel.catchupDays,
                channel.catchupSource,
                headers,
                channel.sortIndex,
                channel.isLikelyAdult,
                token,
            ]
        }
    }

    // MARK: - Lecture

    public struct ChannelGroup: Sendable, Equatable, Identifiable {
        public var name: String
        public var count: Int
        public var id: String { name }
    }

    /// Groupes d'une playlist, du plus fourni au moins fourni.
    public func groups(playlistID: String, includeAdult: Bool = false) throws -> [ChannelGroup] {
        try database.reader.read { db in
            try Row.fetchAll(db, sql: """
                SELECT coalesce(groupTitle, '') AS name, count(*) AS count
                FROM channels
                WHERE playlistId = ? \(includeAdult ? "" : "AND isAdult = 0")
                  AND key NOT IN (SELECT channelKey FROM channelOverrides WHERE isHidden = 1)
                GROUP BY groupTitle
                ORDER BY count DESC, name
                """, arguments: [playlistID])
                .map { ChannelGroup(name: $0["name"], count: $0["count"]) }
        }
    }

    public func channels(playlistID: String,
                         group: String? = nil,
                         includeAdult: Bool = false,
                         limit: Int = 500,
                         offset: Int = 0) throws -> [ChannelRecord] {
        try database.reader.read { db in
            var sql = """
                SELECT channels.* FROM channels
                WHERE playlistId = ?
                  AND key NOT IN (SELECT channelKey FROM channelOverrides WHERE isHidden = 1)
                """
            var arguments: StatementArguments = [playlistID]
            if let group {
                sql += " AND coalesce(groupTitle, '') = ?"
                arguments += [group]
            }
            if !includeAdult { sql += " AND isAdult = 0" }
            sql += " ORDER BY sortIndex, name LIMIT ? OFFSET ?"
            arguments += [limit, offset]

            return try ChannelRecord.fetchAll(db, sql: sql, arguments: arguments)
        }
    }

    public func channel(key: StableKey) throws -> ChannelRecord? {
        try database.reader.read { db in
            try ChannelRecord.filter(Column("key") == key.rawValue).fetchOne(db)
        }
    }

    public func count(playlistID: String) throws -> Int {
        try database.reader.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM channels WHERE playlistId = ?",
                             arguments: [playlistID]) ?? 0
        }
    }

    /// Recherche plein texte, sur toutes les playlists à la fois.
    ///
    /// La saisie de l'utilisateur est convertie en motif FTS5 par GRDB : sans cela,
    /// un simple « Canal+ » serait interprété comme un opérateur et ferait échouer la
    /// requête. Chaque mot est traité comme un préfixe, pour que les résultats
    /// s'affinent à la frappe.
    public func search(_ text: String,
                       playlistID: String? = nil,
                       includeAdult: Bool = false,
                       limit: Int = 100) throws -> [ChannelRecord] {
        guard let pattern = FTS5Pattern(matchingAllPrefixesIn: text) else { return [] }

        return try database.reader.read { db in
            var sql = """
                SELECT channels.* FROM channels
                JOIN channelsFts ON channelsFts.rowid = channels.id
                WHERE channelsFts MATCH ?
                  AND channels.key NOT IN (SELECT channelKey FROM channelOverrides WHERE isHidden = 1)
                """
            var arguments: StatementArguments = [pattern]
            if let playlistID {
                sql += " AND channels.playlistId = ?"
                arguments += [playlistID]
            }
            if !includeAdult { sql += " AND channels.isAdult = 0" }
            // `rank` classe par pertinence FTS5 ; le tri d'origine départage.
            sql += " ORDER BY rank, channels.sortIndex LIMIT ?"
            arguments += [limit]

            return try ChannelRecord.fetchAll(db, sql: sql, arguments: arguments)
        }
    }
}
