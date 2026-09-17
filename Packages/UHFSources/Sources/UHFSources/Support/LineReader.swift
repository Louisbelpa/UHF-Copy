import Foundation

/// Lecture de lignes sur un flux, en mémoire constante.
///
/// `String(contentsOf:)` puis `split` coûte deux à trois fois la taille du fichier en
/// RAM — inacceptable pour un M3U de 60 Mo sur un iPhone, et fatal pour un XMLTV.
/// Gère le BOM UTF-8, les fins de ligne `\n`, `\r\n` et `\r`.
public final class LineReader {

    public enum Failure: Error, LocalizedError {
        case cannotOpen(URL)
        case readFailed(String)

        public var errorDescription: String? {
            switch self {
            case .cannotOpen(let url): "Fichier illisible : \(url.lastPathComponent)"
            case .readFailed(let message): "Lecture interrompue : \(message)"
            }
        }
    }

    private let stream: InputStream
    private var buffer = Data()
    private var chunk = [UInt8](repeating: 0, count: 64 * 1024)
    private var exhausted = false
    private var didStripBOM = false

    public init(stream: InputStream) {
        self.stream = stream
        stream.open()
    }

    public convenience init(url: URL) throws {
        guard let stream = InputStream(url: url) else { throw Failure.cannotOpen(url) }
        self.init(stream: stream)
    }

    deinit { stream.close() }

    /// Prochaine ligne, sans son séparateur. `nil` en fin de flux.
    public func nextLine() throws -> String? {
        while true {
            if let line = takeBufferedLine() { return line }
            guard !exhausted else {
                guard !buffer.isEmpty else { return nil }
                let rest = buffer
                buffer.removeAll(keepingCapacity: false)
                return decode(rest)
            }
            try fill()
        }
    }

    private func fill() throws {
        let read = stream.read(&chunk, maxLength: chunk.count)
        if read < 0 {
            throw Failure.readFailed(stream.streamError?.localizedDescription ?? "erreur inconnue")
        }
        if read == 0 {
            exhausted = true
            return
        }
        buffer.append(contentsOf: chunk[0..<read])

        if !didStripBOM, buffer.count >= 3 {
            didStripBOM = true
            if buffer[buffer.startIndex] == 0xEF,
               buffer[buffer.index(buffer.startIndex, offsetBy: 1)] == 0xBB,
               buffer[buffer.index(buffer.startIndex, offsetBy: 2)] == 0xBF {
                buffer.removeFirst(3)
            }
        }
    }

    private func takeBufferedLine() -> String? {
        guard let newline = buffer.firstIndex(of: 0x0A) else {
            // Un `\r` seul (fins de ligne Mac historiques) ne clôt une ligne que si on
            // est certain qu'aucun `\n` ne le suit, donc seulement en fin de flux.
            guard exhausted, let cr = buffer.firstIndex(of: 0x0D) else { return nil }
            let line = buffer[buffer.startIndex..<cr]
            buffer.removeSubrange(buffer.startIndex...cr)
            return decode(line)
        }
        var end = newline
        if end > buffer.startIndex, buffer[buffer.index(before: end)] == 0x0D {
            end = buffer.index(before: end)
        }
        let line = buffer[buffer.startIndex..<end]
        buffer.removeSubrange(buffer.startIndex...newline)
        return decode(line)
    }

    private func decode<C: DataProtocol>(_ bytes: C) -> String {
        let data = Data(bytes)
        // Les playlists mal encodées (latin-1) ne doivent pas faire échouer l'import :
        // on dégrade au lieu de jeter la ligne.
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
    }
}
