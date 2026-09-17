import Foundation
import GRDB
import UHFCore

/// Films et séries.
///
/// Même principe de resynchronisation que pour les chaînes : marqueur de passe puis
/// purge, avec des clés stables dérivées du titre — un film réimporté sous un autre
/// `stream_id` doit retrouver sa position de lecture.
public struct VODStore: Sendable {

    private let database: UHFDatabase

    public init(_ database: UHFDatabase) {
        self.database = database
    }

    // MARK: - Films

    @discardableResult
    public func merge(movies: [ParsedMovie], playlistID: String, batchSize: Int = 2_000) throws -> MergeReport {
        let token = UUID().uuidString
        let startedAt = Date()
        var report = MergeReport(previousTotal: try movieCount(playlistID: playlistID))

        for batch in movies.chunked(into: batchSize) {
            try database.writer.write { db in
                let before = try Int.fetchOne(
                    db, sql: "SELECT count(*) FROM movies WHERE playlistId = ?",
                    arguments: [playlistID]) ?? 0

                let statement = try db.makeStatement(sql: """
                    INSERT INTO movies
                        (playlistId, key, streamId, title, year, posterURL, rating,
                         plot, containerExtension, categoryId, syncToken)
                    VALUES (?,?,?,?,?,?,?,?,?,?,?)
                    ON CONFLICT(playlistId, key) DO UPDATE SET
                        streamId = excluded.streamId,
                        title = excluded.title,
                        year = excluded.year,
                        posterURL = excluded.posterURL,
                        rating = excluded.rating,
                        plot = excluded.plot,
                        containerExtension = excluded.containerExtension,
                        categoryId = excluded.categoryId,
                        syncToken = excluded.syncToken
                    """)
                for movie in batch {
                    let key = StableKey.movie(playlistID: playlistID, title: movie.title, year: movie.year)
                    statement.setUncheckedArguments([
                        playlistID, key.rawValue, movie.streamID, movie.title, movie.year,
                        movie.posterURL?.absoluteString, movie.rating, movie.plot,
                        movie.containerExtension, movie.categoryID, token,
                    ])
                    try statement.execute()
                }

                let after = try Int.fetchOne(
                    db, sql: "SELECT count(*) FROM movies WHERE playlistId = ?",
                    arguments: [playlistID]) ?? 0
                report.added += after - before
                report.updated += batch.count - (after - before)
            }
        }

        try database.writer.write { db in
            try db.execute(sql: "DELETE FROM movies WHERE playlistId = ? AND syncToken <> ?",
                           arguments: [playlistID, token])
            report.removed = db.changesCount
        }
        report.duration = Date().timeIntervalSince(startedAt)
        return report
    }

    public func movies(playlistID: String,
                       categoryID: String? = nil,
                       limit: Int = 200,
                       offset: Int = 0) throws -> [MovieRecord] {
        try database.reader.read { db in
            var request = MovieRecord.filter(Column("playlistId") == playlistID)
            if let categoryID { request = request.filter(Column("categoryId") == categoryID) }
            return try request.order(Column("title")).limit(limit, offset: offset).fetchAll(db)
        }
    }

    public func movieCount(playlistID: String) throws -> Int {
        try database.reader.read { db in
            try MovieRecord.filter(Column("playlistId") == playlistID).fetchCount(db)
        }
    }

    // MARK: - Séries

    @discardableResult
    public func merge(series: [ParsedSeries], playlistID: String) throws -> MergeReport {
        let token = UUID().uuidString
        let startedAt = Date()
        var report = MergeReport(previousTotal: try seriesCount(playlistID: playlistID))

        try database.writer.write { db in
            let before = try Int.fetchOne(
                db, sql: "SELECT count(*) FROM series WHERE playlistId = ?",
                arguments: [playlistID]) ?? 0

            let statement = try db.makeStatement(sql: """
                INSERT INTO series (playlistId, key, seriesId, title, posterURL, plot, categoryId, syncToken)
                VALUES (?,?,?,?,?,?,?,?)
                ON CONFLICT(playlistId, key) DO UPDATE SET
                    seriesId = excluded.seriesId,
                    title = excluded.title,
                    posterURL = excluded.posterURL,
                    plot = excluded.plot,
                    categoryId = excluded.categoryId,
                    syncToken = excluded.syncToken
                """)
            for item in series {
                let key = StableKey.series(playlistID: playlistID, title: item.title)
                statement.setUncheckedArguments([
                    playlistID, key.rawValue, item.seriesID, item.title,
                    item.posterURL?.absoluteString, item.plot, item.categoryID, token,
                ])
                try statement.execute()
            }

            let after = try Int.fetchOne(
                db, sql: "SELECT count(*) FROM series WHERE playlistId = ?",
                arguments: [playlistID]) ?? 0
            report.added = after - before
            report.updated = series.count - report.added

            try db.execute(sql: "DELETE FROM series WHERE playlistId = ? AND syncToken <> ?",
                           arguments: [playlistID, token])
            report.removed = db.changesCount
        }
        report.duration = Date().timeIntervalSince(startedAt)
        return report
    }

    /// Remplace les épisodes d'une série. Les épisodes n'ont pas de marqueur de passe :
    /// ils sont peu nombreux et toujours récupérés d'un bloc.
    public func replaceEpisodes(_ episodes: [ParsedEpisode], seriesKey: StableKey) throws {
        try database.writer.write { db in
            guard let series = try SeriesRecord.filter(Column("key") == seriesKey.rawValue).fetchOne(db),
                  let rowID = series.id else { return }

            try db.execute(sql: "DELETE FROM episodes WHERE seriesRowId = ?", arguments: [rowID])
            for episode in episodes {
                var record = EpisodeRecord(parsed: episode, seriesRowID: rowID, seriesKey: seriesKey)
                try record.insert(db)
            }
        }
    }

    public func series(playlistID: String, categoryID: String? = nil) throws -> [SeriesRecord] {
        try database.reader.read { db in
            var request = SeriesRecord.filter(Column("playlistId") == playlistID)
            if let categoryID { request = request.filter(Column("categoryId") == categoryID) }
            return try request.order(Column("title")).fetchAll(db)
        }
    }

    public func seriesCount(playlistID: String) throws -> Int {
        try database.reader.read { db in
            try SeriesRecord.filter(Column("playlistId") == playlistID).fetchCount(db)
        }
    }

    public func episodes(seriesKey: StableKey) throws -> [EpisodeRecord] {
        try database.reader.read { db in
            try EpisodeRecord.fetchAll(db, sql: """
                SELECT episodes.* FROM episodes
                JOIN series ON series.id = episodes.seriesRowId
                WHERE series.key = ?
                ORDER BY episodes.season, episodes.number
                """, arguments: [seriesKey.rawValue])
        }
    }

    /// Prochain épisode à regarder : le premier non terminé, ou le suivant du dernier vu.
    public func nextEpisode(seriesKey: StableKey) throws -> EpisodeRecord? {
        let all = try episodes(seriesKey: seriesKey)
        guard !all.isEmpty else { return nil }

        return try database.reader.read { db in
            for episode in all {
                let progress = try WatchProgressRecord.fetchOne(db, key: episode.key)
                if progress == nil || !progress!.isFinished { return episode }
            }
            return nil   // série entièrement vue
        }
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
