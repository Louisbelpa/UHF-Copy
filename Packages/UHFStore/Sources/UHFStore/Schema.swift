import Foundation
import GRDB

/// Schéma de la base et migrations.
///
/// Trois principes gouvernent ce schéma, et expliquent à eux seuls la plupart de ses
/// choix :
///
/// 1. **Les données utilisateur ne référencent jamais un identifiant de fournisseur.**
///    Favoris, historique, renommages et rappels sont indexés par ``StableKey`` ou par
///    un couple métier, jamais par `rowid` ni par `stream_id`. Une resynchronisation
///    peut donc tout réécrire sans rien perdre.
/// 2. **Le catalogue est jetable.** Chaînes, programmes et VOD se reconstruisent
///    intégralement depuis la source. Seules les tables utilisateur sont précieuses —
///    ce sont elles, et elles seules, qui remontent dans la synchronisation iCloud.
/// 3. **Les tables volumineuses sont taillées pour SQLite, pas pour l'élégance.**
///    Dates en `REAL`, index composites explicites, FTS5 externe : une playlist de
///    150 000 chaînes et un EPG de plusieurs millions de lignes ne pardonnent pas.
public enum Schema {

    public static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        #if DEBUG
        // En développement, une migration modifiée repart de zéro plutôt que de
        // laisser traîner une base à moitié dans l'ancien schéma.
        migrator.eraseDatabaseOnSchemaChange = true
        #endif

        migrator.registerMigration("v1") { db in
            try createSources(db)
            try createCatalogue(db)
            try createEPG(db)
            try createUserData(db)
        }

        return migrator
    }

    // MARK: - Sources

    private static func createSources(_ db: Database) throws {
        try db.create(table: "playlists") { table in
            table.primaryKey("id", .text)
            table.column("name", .text).notNull()
            table.column("kind", .text).notNull()
            table.column("url", .text).notNull()
            // Référence Keychain. Les identifiants eux-mêmes ne sont jamais en base :
            // un fichier SQLite finit dans les sauvegardes et les journaux de crash.
            table.column("credentialsRef", .text)
            table.column("epgURL", .text)
            table.column("userAgent", .text)
            table.column("referer", .text)
            table.column("lastSyncAt", .double)
            table.column("refreshInterval", .double).notNull().defaults(to: 86_400)
            table.column("sortIndex", .integer).notNull().defaults(to: 0)
            table.column("isEnabled", .boolean).notNull().defaults(to: true)
        }
    }

    // MARK: - Catalogue

    private static func createCatalogue(_ db: Database) throws {
        try db.create(table: "channels") { table in
            table.autoIncrementedPrimaryKey("id")
            table.column("playlistId", .text).notNull()
                .references("playlists", onDelete: .cascade)
            /// ``StableKey`` : l'identité durable de la chaîne.
            table.column("key", .text).notNull()
            table.column("name", .text).notNull()
            table.column("url", .text).notNull()
            table.column("streamId", .text)
            table.column("logoURL", .text)
            table.column("groupTitle", .text)
            table.column("tvgId", .text)
            table.column("tvgShift", .double).notNull().defaults(to: 0)
            table.column("catchupMode", .text)
            table.column("catchupDays", .integer)
            table.column("catchupSource", .text)
            table.column("httpHeaders", .text)
            table.column("sortIndex", .integer).notNull().defaults(to: 0)
            table.column("isAdult", .boolean).notNull().defaults(to: false)
            /// Marqueur de passe de synchronisation : voir ``ChannelStore/merge(_:playlistID:)``.
            table.column("syncToken", .text).notNull().defaults(to: "")

            table.uniqueKey(["playlistId", "key"])
        }
        try db.create(index: "channels_playlist_sort", on: "channels",
                      columns: ["playlistId", "sortIndex"])
        try db.create(index: "channels_group", on: "channels",
                      columns: ["playlistId", "groupTitle"])
        try db.create(index: "channels_tvgId", on: "channels", columns: ["tvgId"])

        // Index plein texte à contenu externe : l'index ne duplique pas le texte, et
        // GRDB installe les déclencheurs qui le tiennent à jour sur INSERT/UPDATE/DELETE.
        // C'est ce qui permet une recherche en quelques millisecondes sur 150 000 chaînes.
        try db.create(virtualTable: "channelsFts", using: FTS5()) { table in
            table.synchronize(withTable: "channels")
            table.column("name")
            table.column("groupTitle")
            // unicode61 retire les diacritiques : « tele » trouve « Télé ».
            table.tokenizer = .unicode61()
        }

        try db.create(table: "movies") { table in
            table.autoIncrementedPrimaryKey("id")
            table.column("playlistId", .text).notNull()
                .references("playlists", onDelete: .cascade)
            table.column("key", .text).notNull()
            table.column("streamId", .text).notNull()
            table.column("title", .text).notNull()
            table.column("year", .integer)
            table.column("posterURL", .text)
            table.column("rating", .double)
            table.column("plot", .text)
            table.column("containerExtension", .text).notNull().defaults(to: "mp4")
            table.column("categoryId", .text)
            table.column("syncToken", .text).notNull().defaults(to: "")
            table.uniqueKey(["playlistId", "key"])
        }
        try db.create(index: "movies_playlist_title", on: "movies",
                      columns: ["playlistId", "title"])

        try db.create(table: "series") { table in
            table.autoIncrementedPrimaryKey("id")
            table.column("playlistId", .text).notNull()
                .references("playlists", onDelete: .cascade)
            table.column("key", .text).notNull()
            table.column("seriesId", .text).notNull()
            table.column("title", .text).notNull()
            table.column("posterURL", .text)
            table.column("plot", .text)
            table.column("categoryId", .text)
            table.column("syncToken", .text).notNull().defaults(to: "")
            table.uniqueKey(["playlistId", "key"])
        }

        try db.create(table: "episodes") { table in
            table.autoIncrementedPrimaryKey("id")
            table.column("seriesRowId", .integer).notNull()
                .references("series", onDelete: .cascade)
            table.column("key", .text).notNull()
            table.column("episodeId", .text).notNull()
            table.column("season", .integer).notNull()
            table.column("number", .integer).notNull()
            table.column("title", .text).notNull()
            table.column("containerExtension", .text).notNull().defaults(to: "mp4")
            table.column("plot", .text)
            table.column("durationSeconds", .integer)
            table.uniqueKey(["seriesRowId", "key"])
        }
        try db.create(index: "episodes_order", on: "episodes",
                      columns: ["seriesRowId", "season", "number"])
    }

    // MARK: - EPG

    private static func createEPG(_ db: Database) throws {
        try db.create(table: "epgChannels") { table in
            table.autoIncrementedPrimaryKey("id")
            table.column("playlistId", .text).notNull()
                .references("playlists", onDelete: .cascade)
            table.column("xmltvId", .text).notNull()
            table.column("displayName", .text)
            table.column("iconURL", .text)
            table.uniqueKey(["playlistId", "xmltvId"])
        }

        try db.create(table: "programmes") { table in
            table.autoIncrementedPrimaryKey("id")
            table.column("epgChannelId", .integer).notNull()
                .references("epgChannels", onDelete: .cascade)
            // Dates en REAL : sur plusieurs millions de lignes, le format texte ISO
            // par défaut de GRDB coûterait une centaine de méga-octets de plus et
            // ralentirait chaque comparaison de plage.
            table.column("startAt", .double).notNull()
            table.column("endAt", .double).notNull()
            table.column("title", .text).notNull()
            table.column("subtitle", .text)
            table.column("summary", .text)
            table.column("categories", .text)
            table.column("iconURL", .text)
            table.column("episodeNumber", .text)
            // Marqueur de passe d'import : le guide précédent reste consultable
            // pendant qu'on écrit le nouveau, et n'est remplacé qu'à la toute fin.
            table.column("syncToken", .text).notNull().defaults(to: "")
        }
        // L'index qui porte toute la grille EPG : « les programmes de cette chaîne,
        // dans cette tranche horaire ».
        try db.create(index: "programmes_channel_start", on: "programmes",
                      columns: ["epgChannelId", "startAt"])
        // Purge des programmes périmés.
        try db.create(index: "programmes_end", on: "programmes", columns: ["endAt"])

        /// Rattachement d'une chaîne à une entrée du guide.
        ///
        /// Table à part, et non colonne de `channels`, pour deux raisons : la
        /// correspondance peut être corrigée à la main par l'utilisateur et doit alors
        /// survivre à la resynchronisation du catalogue, et elle porte un niveau de
        /// confiance dont l'interface se sert pour proposer une vérification.
        try db.create(table: "channelEPGLinks") { table in
            table.column("playlistId", .text).notNull()
                .references("playlists", onDelete: .cascade)
            table.column("channelKey", .text).notNull()
            table.column("xmltvId", .text).notNull()
            table.column("confidence", .integer).notNull()
            table.column("isManual", .boolean).notNull().defaults(to: false)
            table.primaryKey(["playlistId", "channelKey"])
        }
    }

    // MARK: - Données utilisateur

    private static func createUserData(_ db: Database) throws {
        try db.create(table: "folders") { table in
            table.primaryKey("id", .text)
            table.column("name", .text).notNull()
            // Empreinte du code, jamais le code lui-même.
            table.column("pinHash", .text)
            table.column("sortIndex", .integer).notNull().defaults(to: 0)
        }

        try db.create(table: "favorites") { table in
            // Indexé par StableKey : c'est ce qui fait qu'un favori survit à un
            // changement de stream_id côté fournisseur.
            table.column("targetKey", .text).notNull()
            table.column("targetKind", .text).notNull()
            table.column("folderId", .text).references("folders", onDelete: .setNull)
            table.column("sortIndex", .integer).notNull().defaults(to: 0)
            table.column("addedAt", .double).notNull()
            table.primaryKey(["targetKey"])
        }
        try db.create(index: "favorites_folder", on: "favorites",
                      columns: ["folderId", "sortIndex"])

        try db.create(table: "channelOverrides") { table in
            table.primaryKey("channelKey", .text)
            table.column("customName", .text)
            table.column("customLogoURL", .text)
            table.column("isHidden", .boolean).notNull().defaults(to: false)
            table.column("customSortIndex", .integer)
        }

        try db.create(table: "watchProgress") { table in
            table.primaryKey("targetKey", .text)
            table.column("positionSeconds", .double).notNull()
            table.column("durationSeconds", .double).notNull()
            table.column("updatedAt", .double).notNull()
        }
        try db.create(index: "watchProgress_updated", on: "watchProgress",
                      columns: ["updatedAt"])

        try db.create(table: "reminders") { table in
            table.primaryKey("id", .text)
            // Rattaché au couple (chaîne du guide, heure de début) plutôt qu'à la
            // ligne `programmes`, qui est intégralement réécrite à chaque import EPG.
            table.column("xmltvId", .text).notNull()
            table.column("programmeStartAt", .double).notNull()
            table.column("title", .text).notNull()
            table.column("fireAt", .double).notNull()
            table.column("notificationId", .text)
            table.uniqueKey(["xmltvId", "programmeStartAt"])
        }
        try db.create(index: "reminders_fire", on: "reminders", columns: ["fireAt"])

        /// Moteur de lecture retenu pour une chaîne, appris à l'usage.
        try db.create(table: "playbackDecisions") { table in
            table.primaryKey("targetKey", .text)
            table.column("engine", .text).notNull()
            table.column("decidedAt", .double).notNull()
        }
    }
}
