import Foundation

/// Découpage d'une ligne `#EXTINF` en attributs + libellé affiché.
///
/// La difficulté n'est pas la syntaxe nominale mais tout ce que produisent les
/// générateurs de playlists dans la nature : virgules dans les valeurs entre
/// guillemets, virgules dans le libellé, guillemets simples, valeurs non quotées,
/// attributs inconnus, ligne sans virgule du tout.
public enum M3UAttributes {

    /// Scinde le contenu d'un `#EXTINF:` à la **première virgule hors guillemets**.
    ///
    /// `-1 tvg-name="Foo, Bar" group-title="X",Ma chaîne, en direct`
    /// donne `(#"-1 tvg-name="Foo, Bar" group-title="X""#, "Ma chaîne, en direct")`.
    public static func splitAttributesAndTitle(_ body: String) -> (attributes: Substring, title: Substring?) {
        var quote: Character?
        var index = body.startIndex

        while index < body.endIndex {
            let ch = body[index]
            if let q = quote {
                if ch == q { quote = nil }
            } else if ch == "\"" || ch == "'" {
                quote = ch
            } else if ch == "," {
                let title = body[body.index(after: index)...]
                return (body[body.startIndex..<index], title)
            }
            index = body.index(after: index)
        }
        return (body[...], nil)
    }

    /// Extrait les paires `clé=valeur`. Les clés sont ramenées en minuscules ; les
    /// valeurs peuvent être entre guillemets doubles, simples, ou nues.
    public static func parse(_ attributes: Substring) -> [String: String] {
        var result: [String: String] = [:]
        var index = attributes.startIndex

        while index < attributes.endIndex {
            // Début de clé.
            guard let keyStart = attributes[index...].firstIndex(where: { !$0.isWhitespace }) else { break }
            guard let equals = attributes[keyStart...].firstIndex(of: "=") else { break }

            // La clé est la plus longue suite d'identifiants qui précède le `=`, et non
            // tout ce qui sépare le curseur du `=` : sans cela le jeton de durée en tête
            // de ligne ("-1 tvg-id=…") serait agglutiné à la première clé, qui serait
            // alors rejetée. Même raisonnement pour tout résidu non reconnu en amont.
            let key = String(attributes[keyStart..<equals]
                .reversed()
                .prefix(while: { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
                .reversed())
                .lowercased()

            var cursor = attributes.index(after: equals)
            guard cursor < attributes.endIndex else { break }

            var value = ""
            if attributes[cursor] == "\"" || attributes[cursor] == "'" {
                let quote = attributes[cursor]
                cursor = attributes.index(after: cursor)
                let valueStart = cursor
                while cursor < attributes.endIndex, attributes[cursor] != quote {
                    cursor = attributes.index(after: cursor)
                }
                value = String(attributes[valueStart..<cursor])
                if cursor < attributes.endIndex { cursor = attributes.index(after: cursor) }
            } else {
                let valueStart = cursor
                while cursor < attributes.endIndex, !attributes[cursor].isWhitespace {
                    cursor = attributes.index(after: cursor)
                }
                value = String(attributes[valueStart..<cursor])
            }

            if !key.isEmpty, key.first?.isLetter == true || key.first == "_" {
                result[key] = value
            }
            index = cursor
        }
        return result
    }

    /// Durée annoncée par `#EXTINF`, quand elle est exploitable (`-1` = flux continu).
    public static func duration(from attributes: Substring) -> TimeInterval? {
        let token = attributes.drop(while: { $0.isWhitespace })
            .prefix(while: { !$0.isWhitespace })
        guard let value = Double(token), value > 0 else { return nil }
        return value
    }
}
