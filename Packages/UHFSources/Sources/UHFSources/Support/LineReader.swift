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
    private var buffer = [UInt8]()
    /// Position de lecture dans `buffer`.
    ///
    /// Consommer une ligne par `removeFirst` décalerait tout le tampon à chaque appel,
    /// soit un `memmove` de plusieurs dizaines de kilo-octets par ligne — de loin le
    /// premier poste de coût à l'import d'une grosse playlist. On avance donc un index,
    /// et on ne compacte le tampon que lorsque la partie consommée devient majoritaire.
    private var cursor = 0
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
                guard cursor < buffer.count else { return nil }
                let rest = decode(buffer[cursor...])
                cursor = buffer.count
                return rest
            }
            try fill()
        }
    }

    private func fill() throws {
        compactIfNeeded()

        let read = stream.read(&chunk, maxLength: chunk.count)
        if read < 0 {
            throw Failure.readFailed(stream.streamError?.localizedDescription ?? "erreur inconnue")
        }
        if read == 0 {
            exhausted = true
            return
        }
        buffer.append(contentsOf: chunk[0..<read])

        if !didStripBOM, buffer.count - cursor >= 3 {
            didStripBOM = true
            if buffer[cursor] == 0xEF, buffer[cursor + 1] == 0xBB, buffer[cursor + 2] == 0xBF {
                cursor += 3
            }
        }
    }

    private func compactIfNeeded() {
        guard cursor > 0, cursor * 2 >= buffer.count else { return }
        buffer.removeFirst(cursor)
        cursor = 0
    }

    private func takeBufferedLine() -> String? {
        guard let newline = buffer[cursor...].firstIndex(of: 0x0A) else {
            // Un `\r` seul (fins de ligne Mac historiques) ne clôt une ligne que si on
            // est certain qu'aucun `\n` ne le suit, donc seulement en fin de flux.
            guard exhausted, let cr = buffer[cursor...].firstIndex(of: 0x0D) else { return nil }
            let line = decode(buffer[cursor..<cr])
            cursor = cr + 1
            return line
        }
        var end = newline
        if end > cursor, buffer[end - 1] == 0x0D { end -= 1 }
        let line = decode(buffer[cursor..<end])
        cursor = newline + 1
        return line
    }

    private func decode(_ bytes: ArraySlice<UInt8>) -> String {
        let data = Data(bytes)
        // Les playlists mal encodées (latin-1) ne doivent pas faire échouer l'import :
        // on dégrade au lieu de jeter la ligne.
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? ""
    }
}
