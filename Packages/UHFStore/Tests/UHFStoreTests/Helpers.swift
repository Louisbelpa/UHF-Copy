import Foundation
import UHFCore
@testable import UHFStore

enum Fixture {

    static func database() throws -> UHFDatabase {
        try UHFDatabase.inMemory()
    }

    @discardableResult
    static func playlist(in database: UHFDatabase,
                         id: String = "p1",
                         name: String = "Ma playlist") throws -> PlaylistRecord {
        let record = PlaylistRecord(id: id, name: name, kind: .m3u,
                                    url: URL(string: "http://srv/get.php")!)
        try database.writer.write { try record.insert($0) }
        return record
    }

    static func channel(_ name: String,
                        tvgID: String? = nil,
                        streamID: String? = nil,
                        group: String? = "Généralistes",
                        url: String? = nil,
                        sortIndex: Int = 0) -> ParsedChannel {
        ParsedChannel(
            name: name,
            url: URL(string: url ?? "http://srv/live/u/p/\(streamID ?? "1").ts")!,
            streamID: streamID,
            groupTitle: group,
            tvgID: tvgID,
            sortIndex: sortIndex)
    }
}
