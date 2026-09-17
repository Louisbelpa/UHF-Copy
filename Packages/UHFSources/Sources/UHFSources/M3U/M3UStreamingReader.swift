import Foundation
import UHFCore

extension M3UParser {

    /// Parse un fichier M3U en mémoire constante, en remontant les chaînes au fil de l'eau.
    ///
    /// Le bloc `onChannel` est l'endroit où brancher l'insertion par lots en base :
    /// accumuler 5 000 chaînes puis écrire en une transaction, plutôt que de construire
    /// un tableau de 150 000 éléments.
    ///
    /// - Returns: l'en-tête de la playlist et le nombre de chaînes émises.
    @discardableResult
    public static func parse(
        fileAt url: URL,
        isCancelled: () -> Bool = { false },
        onChannel: (ParsedChannel) throws -> Void
    ) throws -> (header: Header, count: Int, skipped: [(line: Int, reason: String)]) {
        let reader = try LineReader(url: url)
        var parser = M3UParser()
        var count = 0

        while let line = try reader.nextLine() {
            if isCancelled() { break }
            if let channel = parser.consume(line: line) {
                try onChannel(channel)
                count += 1
            }
        }
        return (parser.header, count, parser.skipped)
    }
}
