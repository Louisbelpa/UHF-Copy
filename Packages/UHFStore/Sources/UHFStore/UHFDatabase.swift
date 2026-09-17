import Foundation
import GRDB

/// Point d'accès unique à la base.
///
/// Un `DatabasePool` et non une `DatabaseQueue` : les lectures se font en parallèle
/// des écritures grâce au mode WAL, si bien que la liste des chaînes reste fluide
/// pendant qu'un import de 150 000 lignes tourne en arrière-plan. C'est la différence
/// entre une app qui se fige à chaque rafraîchissement et une qui ne bronche pas.
public final class UHFDatabase: Sendable {

    public let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) throws {
        self.writer = writer
        try Schema.migrator.migrate(writer)
    }

    /// Base sur disque, configurée pour un usage mobile.
    public static func onDisk(at url: URL) throws -> UHFDatabase {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        // Le catalogue se reconstruit depuis la source : perdre les toutes dernières
        // écritures sur coupure de courant est sans conséquence, et `NORMAL` évite un
        // fsync par transaction — décisif quand on en enchaîne trente par import.
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
            try db.execute(sql: "PRAGMA temp_store = MEMORY")
            try db.execute(sql: "PRAGMA cache_size = -20000")   // ~20 Mo
        }
        configuration.busyMode = .timeout(5)

        return try UHFDatabase(writer: try DatabasePool(path: url.path, configuration: configuration))
    }

    /// Base en mémoire, pour les tests et les aperçus SwiftUI.
    public static func inMemory() throws -> UHFDatabase {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        return try UHFDatabase(writer: try DatabaseQueue(configuration: configuration))
    }

    public var reader: any DatabaseReader { writer }

    /// Emplacement recommandé : `Application Support`, hors de `Documents` — la base
    /// est un cache reconstructible, elle n'a rien à faire dans les sauvegardes iCloud
    /// ni dans l'app Fichiers.
    public static func defaultURL() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        return support.appendingPathComponent("UHF/library.sqlite")
    }

    /// Récupère l'espace laissé par les purges d'EPG.
    public func vacuum() throws {
        try writer.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM")
        }
    }

    public func erase() throws {
        try writer.erase()
        try Schema.migrator.migrate(writer)
    }
}

/// Bilan d'une resynchronisation.
public struct MergeReport: Sendable, Equatable {
    public var added = 0
    public var updated = 0
    public var removed = 0
    /// Nombre d'éléments présents avant cet import.
    public var previousTotal = 0
    public var duration: TimeInterval = 0

    public var total: Int { added + updated }
    public var isEmpty: Bool { added == 0 && updated == 0 && removed == 0 }

    /// Un resync qui supprime l'essentiel du catalogue est presque toujours le signe
    /// d'une source qui a mal répondu, pas d'un fournisseur qui a vidé son offre.
    /// L'appelant doit pouvoir refuser d'appliquer un tel résultat.
    ///
    /// - Note: `previousTotal` est porté par le bilan, et non demandé à l'appelant :
    ///   il n'est lisible de façon fiable qu'avant la première écriture, et c'est à
    ///   la session d'import de le savoir, pas à celui qui l'utilise.
    public var looksSuspicious: Bool {
        previousTotal > 100 && total < previousTotal / 2
    }
}
