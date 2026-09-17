import Foundation
import GRDB
import UHFCore

/// Données propres à l'utilisateur : favoris, dossiers, renommages, progression,
/// rappels, moteur de lecture appris.
///
/// C'est la seule partie de la base qui ne se reconstruit pas. Tout y est indexé par
/// ``StableKey``, jamais par un identifiant de fournisseur : c'est ce qui permet de
/// réécrire entièrement le catalogue sans rien perdre — et c'est exactement ce qui
/// devra remonter dans la synchronisation iCloud.
public struct LibraryStore: Sendable {

    private let database: UHFDatabase

    public init(_ database: UHFDatabase) {
        self.database = database
    }

    // MARK: - Favoris

    public func setFavorite(_ isFavorite: Bool,
                            key: StableKey,
                            kind: FavoriteKind,
                            folderId: String? = nil) throws {
        try database.writer.write { db in
            if isFavorite {
                let nextIndex = try Int.fetchOne(db, sql: """
                    SELECT coalesce(max(sortIndex), -1) + 1 FROM favorites
                    WHERE coalesce(folderId, '') = ?
                    """, arguments: [folderId ?? ""]) ?? 0

                try FavoriteRecord(targetKey: key, kind: kind,
                                   folderId: folderId, sortIndex: nextIndex).upsert(db)
            } else {
                _ = try FavoriteRecord.deleteOne(db, key: key.rawValue)
            }
        }
    }

    public func isFavorite(_ key: StableKey) throws -> Bool {
        try database.reader.read { db in
            try FavoriteRecord.filter(Column("targetKey") == key.rawValue).fetchCount(db) > 0
        }
    }

    /// Chaînes favorites, dans l'ordre choisi par l'utilisateur.
    ///
    /// Un favori dont la chaîne a disparu du catalogue n'est **pas** supprimé : le
    /// fournisseur peut la remettre au rafraîchissement suivant, et effacer le favori
    /// au premier import incomplet serait la meilleure façon de perdre la confiance
    /// de l'utilisateur. La jointure l'écarte simplement de l'affichage.
    public func favoriteChannels(folderId: String? = nil) throws -> [ChannelRecord] {
        try database.reader.read { db in
            var sql = """
                SELECT channels.* FROM channels
                JOIN favorites ON favorites.targetKey = channels.key
                WHERE favorites.targetKind = 'channel'
                """
            var arguments: StatementArguments = []
            if let folderId {
                sql += " AND favorites.folderId = ?"
                arguments += [folderId]
            } else {
                sql += " AND favorites.folderId IS NULL"
            }
            sql += " ORDER BY favorites.sortIndex"
            return try ChannelRecord.fetchAll(db, sql: sql, arguments: arguments)
        }
    }

    public func favoriteCount() throws -> Int {
        try database.reader.read { try FavoriteRecord.fetchCount($0) }
    }

    /// Réordonne les favoris d'un dossier selon la liste fournie.
    public func reorderFavorites(_ keys: [StableKey], folderId: String? = nil) throws {
        try database.writer.write { db in
            for (index, key) in keys.enumerated() {
                try db.execute(sql: """
                    UPDATE favorites SET sortIndex = ?, folderId = ? WHERE targetKey = ?
                    """, arguments: [index, folderId, key.rawValue])
            }
        }
    }

    // MARK: - Dossiers

    public func createFolder(name: String, pinHash: String? = nil) throws -> FolderRecord {
        try database.writer.write { db in
            let nextIndex = try Int.fetchOne(
                db, sql: "SELECT coalesce(max(sortIndex), -1) + 1 FROM folders") ?? 0
            let folder = FolderRecord(name: name, pinHash: pinHash, sortIndex: nextIndex)
            try folder.insert(db)
            return folder
        }
    }

    public func folders() throws -> [FolderRecord] {
        try database.reader.read { db in
            try FolderRecord.order(Column("sortIndex")).fetchAll(db)
        }
    }

    public func deleteFolder(id: String) throws {
        // Les favoris du dossier sont conservés et remontent à la racine : supprimer
        // un dossier ne doit pas supprimer son contenu.
        try database.writer.write { db in
            _ = try FolderRecord.deleteOne(db, key: id)
        }
    }

    // MARK: - Personnalisation des chaînes

    public func setOverride(_ override: ChannelOverrideRecord) throws {
        try database.writer.write { db in
            if override.isEmpty {
                _ = try ChannelOverrideRecord.deleteOne(db, key: override.channelKey)
            } else {
                try override.upsert(db)
            }
        }
    }

    public func override(for key: StableKey) throws -> ChannelOverrideRecord? {
        try database.reader.read { db in
            try ChannelOverrideRecord.fetchOne(db, key: key.rawValue)
        }
    }

    public func overrides(for keys: [StableKey]) throws -> [String: ChannelOverrideRecord] {
        try database.reader.read { db in
            let records = try ChannelOverrideRecord
                .filter(keys.map(\.rawValue).contains(Column("channelKey")))
                .fetchAll(db)
            return Dictionary(uniqueKeysWithValues: records.map { ($0.channelKey, $0) })
        }
    }

    // MARK: - Progression de lecture

    public func recordProgress(key: StableKey, position: TimeInterval, duration: TimeInterval) throws {
        // Les toutes premières secondes ne valent pas une reprise : elles pollueraient
        // « continuer à regarder » au moindre zapping.
        guard position > 30, duration > 0 else { return }
        try database.writer.write { db in
            try WatchProgressRecord(targetKey: key, positionSeconds: position,
                                    durationSeconds: duration).upsert(db)
        }
    }

    public func progress(for key: StableKey) throws -> WatchProgressRecord? {
        try database.reader.read { db in
            try WatchProgressRecord.fetchOne(db, key: key.rawValue)
        }
    }

    public func clearProgress(key: StableKey) throws {
        try database.writer.write { db in
            _ = try WatchProgressRecord.deleteOne(db, key: key.rawValue)
        }
    }

    /// Contenus commencés et non terminés, du plus récent au plus ancien.
    public func continueWatching(limit: Int = 20) throws -> [WatchProgressRecord] {
        try database.reader.read { db in
            try WatchProgressRecord
                .filter(sql: "positionSeconds / durationSeconds < 0.95")
                .order(Column("updatedAt").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    // MARK: - Rappels

    public func addReminder(_ reminder: ReminderRecord) throws {
        try database.writer.write { db in try reminder.upsert(db) }
    }

    public func removeReminder(xmltvId: String, programmeStart: Date) throws {
        try database.writer.write { db in
            try db.execute(sql: """
                DELETE FROM reminders WHERE xmltvId = ? AND programmeStartAt = ?
                """, arguments: [xmltvId, programmeStart.timeIntervalSince1970])
        }
    }

    public func reminder(xmltvId: String, programmeStart: Date) throws -> ReminderRecord? {
        try database.reader.read { db in
            try ReminderRecord.filter(
                Column("xmltvId") == xmltvId
                && Column("programmeStartAt") == programmeStart.timeIntervalSince1970
            ).fetchOne(db)
        }
    }

    /// Rappels encore à venir. Les rappels échus sont retirés au passage : sans cela
    /// la table grossirait indéfiniment.
    public func pendingReminders(now: Date = Date()) throws -> [ReminderRecord] {
        try database.writer.write { db in
            try db.execute(sql: "DELETE FROM reminders WHERE fireAt < ?",
                           arguments: [now.addingTimeInterval(-3600).timeIntervalSince1970])
            return try ReminderRecord
                .filter(Column("fireAt") >= now.timeIntervalSince1970)
                .order(Column("fireAt"))
                .fetchAll(db)
        }
    }

    // MARK: - Moteur de lecture appris

    public func rememberEngine(_ engine: String, for key: StableKey) throws {
        try database.writer.write { db in
            try PlaybackDecisionRecord(targetKey: key, engine: engine).upsert(db)
        }
    }

    public func engine(for key: StableKey) throws -> String? {
        try database.reader.read { db in
            try PlaybackDecisionRecord.fetchOne(db, key: key.rawValue)?.engine
        }
    }

    public func allEngineDecisions() throws -> [StableKey: String] {
        try database.reader.read { db in
            let records = try PlaybackDecisionRecord.fetchAll(db)
            return Dictionary(uniqueKeysWithValues:
                records.map { (StableKey(rawValue: $0.targetKey), $0.engine) })
        }
    }

    // MARK: - Sauvegarde

    /// Ce qui doit remonter dans iCloud : tout sauf le catalogue, qui se reconstruit.
    public struct UserDataSnapshot: Codable, Sendable, Equatable {
        public var folders: [FolderRecord]
        public var favorites: [FavoriteRecord]
        public var overrides: [ChannelOverrideRecord]
        public var progress: [WatchProgressRecord]
        public var reminders: [ReminderRecord]
    }

    public func exportUserData() throws -> UserDataSnapshot {
        try database.reader.read { db in
            UserDataSnapshot(
                folders: try FolderRecord.fetchAll(db),
                favorites: try FavoriteRecord.fetchAll(db),
                overrides: try ChannelOverrideRecord.fetchAll(db),
                progress: try WatchProgressRecord.fetchAll(db),
                reminders: try ReminderRecord.fetchAll(db))
        }
    }

    /// Fusionne un instantané venu d'un autre appareil.
    ///
    /// La règle de résolution est « le plus récent gagne » sur la progression, et
    /// « l'union » sur les favoris : entre perdre un favori et en garder un de trop,
    /// le choix est vite fait.
    public func importUserData(_ snapshot: UserDataSnapshot) throws {
        try database.writer.write { db in
            for folder in snapshot.folders { try folder.upsert(db) }
            for favorite in snapshot.favorites { try favorite.upsert(db) }
            for override in snapshot.overrides { try override.upsert(db) }
            for reminder in snapshot.reminders { try reminder.upsert(db) }

            for incoming in snapshot.progress {
                let existing = try WatchProgressRecord.fetchOne(db, key: incoming.targetKey)
                if existing == nil || existing!.updatedAt < incoming.updatedAt {
                    try incoming.upsert(db)
                }
            }
        }
    }
}
