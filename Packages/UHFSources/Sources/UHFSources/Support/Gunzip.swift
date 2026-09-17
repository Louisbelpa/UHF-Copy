import Foundation
import CZlib

/// Décompression gzip en flux, vers un fichier temporaire.
///
/// Un XMLTV fait couramment 50 à 500 Mo une fois décompressé : le décompresser en
/// mémoire pour le donner à `XMLParser` réserverait un pic de RAM qui ferait tuer
/// l'app par le système sur iPhone. On écrit donc sur disque au fil de l'eau, puis
/// on parse le fichier en flux — le disque est la ressource la moins chère des trois.
public enum Gunzip {

    public enum Failure: Error, LocalizedError {
        case cannotOpen(URL)
        case corrupted(Int32)

        public var errorDescription: String? {
            switch self {
            case .cannotOpen(let url): "Fichier illisible : \(url.lastPathComponent)"
            case .corrupted(let code): "Archive EPG illisible (zlib \(code))."
            }
        }
    }

    /// Un fichier gzip commence par la signature `1f 8b`.
    ///
    /// L'extension et le `Content-Type` ne sont pas fiables : beaucoup de panneaux
    /// servent `xmltv.php` en gzip sans l'annoncer, et d'autres nomment `.xml.gz`
    /// un fichier en clair.
    public static func isGzip(_ data: Data) -> Bool {
        data.count >= 2 && data[data.startIndex] == 0x1F
            && data[data.index(after: data.startIndex)] == 0x8B
    }

    public static func isGzip(fileAt url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 2)) ?? Data()
        return isGzip(head)
    }

    /// Décompresse `source` vers `destination`. Détecte automatiquement gzip et zlib.
    /// Si la source n'est pas compressée, elle est simplement copiée.
    public static func decompress(from source: URL,
                                  to destination: URL,
                                  isCancelled: () -> Bool = { false }) throws {
        guard isGzip(fileAt: source) else {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
            return
        }

        guard let input = InputStream(url: source) else { throw Failure.cannotOpen(source) }
        input.open()
        defer { input.close() }

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        guard let output = try? FileHandle(forWritingTo: destination) else {
            throw Failure.cannotOpen(destination)
        }
        defer { try? output.close() }

        var stream = z_stream()
        // 15 + 32 : fenêtre maximale, et détection automatique de l'en-tête gzip ou zlib.
        guard inflateInit2_(&stream, 15 + 32, ZLIB_VERSION,
                            Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw Failure.corrupted(Z_MEM_ERROR)
        }
        defer { inflateEnd(&stream) }

        var inBuffer = [UInt8](repeating: 0, count: 64 * 1024)
        var outBuffer = [UInt8](repeating: 0, count: 256 * 1024)

        while true {
            if isCancelled() { return }

            let read = input.read(&inBuffer, maxLength: inBuffer.count)
            if read < 0 { throw Failure.corrupted(Z_ERRNO) }
            if read == 0 { break }

            var status: Int32 = Z_OK
            try inBuffer.withUnsafeMutableBufferPointer { inPointer in
                stream.next_in = inPointer.baseAddress
                stream.avail_in = uInt(read)

                repeat {
                    let produced: Int = try outBuffer.withUnsafeMutableBufferPointer { outPointer in
                        stream.next_out = outPointer.baseAddress
                        stream.avail_out = uInt(outPointer.count)

                        status = inflate(&stream, Z_NO_FLUSH)
                        guard status == Z_OK || status == Z_STREAM_END || status == Z_BUF_ERROR else {
                            throw Failure.corrupted(status)
                        }
                        return outPointer.count - Int(stream.avail_out)
                    }
                    if produced > 0 {
                        output.write(Data(outBuffer[0..<produced]))
                    }
                } while stream.avail_in > 0 && status != Z_STREAM_END
            }
            if status == Z_STREAM_END { break }
        }
    }
}
