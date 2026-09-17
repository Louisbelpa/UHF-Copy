import Foundation

/// Décodage tolérant des réponses Xtream.
///
/// Les panneaux Xtream n'ont pas de schéma stable : selon la version et la charge,
/// un même champ arrive en nombre (`"stream_id": 1234`) ou en chaîne
/// (`"stream_id": "1234"`), un booléen vaut `1`, `"1"` ou `true`, et une note vide
/// vaut `""`, `0` ou `null`. Un `Codable` strict échoue sur la moitié des serveurs
/// du marché — d'où ces accesseurs, systématiquement préférés aux `decode(_:forKey:)`.
extension KeyedDecodingContainer {

    func lenientString(_ key: Key) -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return value.isEmpty ? nil : value
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return String(value) }
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return String(value) }
        return nil
    }

    func lenientInt(_ key: Key) -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return Int(value) }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            return Int(trimmed) ?? Double(trimmed).map(Int.init)
        }
        return nil
    }

    func lenientDouble(_ key: Key) -> Double? {
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return Double(value) }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            // Certains panneaux renvoient la note avec une virgule décimale.
            return Double(value.replacingOccurrences(of: ",", with: ".")
                .trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    func lenientBool(_ key: Key) -> Bool? {
        if let value = try? decodeIfPresent(Bool.self, forKey: key) { return value }
        if let value = lenientInt(key) { return value != 0 }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return ["1", "true", "yes", "on"].contains(value.lowercased())
        }
        return nil
    }

    func lenientURL(_ key: Key) -> URL? {
        guard let raw = lenientString(key)?.trimmingCharacters(in: .whitespaces),
              !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    /// Date exprimée en secondes depuis epoch, en nombre ou en chaîne.
    func lenientEpochDate(_ key: Key) -> Date? {
        guard let seconds = lenientDouble(key), seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// Certains champs (titre et description d'EPG) arrivent encodés en base64 —
    /// mais pas sur tous les serveurs. On décode quand c'est possible, sinon on garde
    /// la valeur brute.
    func lenientMaybeBase64String(_ key: Key) -> String? {
        guard let raw = lenientString(key) else { return nil }
        guard let data = Data(base64Encoded: raw, options: [.ignoreUnknownCharacters]),
              let decoded = String(data: data, encoding: .utf8),
              !decoded.isEmpty,
              // Un texte court peut être accidentellement du base64 valide ; on ne
              // retient le décodage que s'il produit quelque chose de lisible.
              decoded.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) || $0 == "\n" })
        else { return raw }
        return decoded
    }
}

/// Extrait une année d'un titre de film : "Inception (2010)" ou "Inception 2010".
func extractYear(from title: String) -> (cleanTitle: String, year: Int?) {
    let pattern = #"\s*[\(\[]?((19|20)\d{2})[\)\]]?\s*$"#
    guard let range = title.range(of: pattern, options: .regularExpression) else {
        return (title, nil)
    }
    let yearText = title[range].trimmingCharacters(in: CharacterSet(charactersIn: " ()[]"))
    guard let year = Int(yearText) else { return (title, nil) }
    return (String(title[title.startIndex..<range.lowerBound]).trimmingCharacters(in: .whitespaces), year)
}
