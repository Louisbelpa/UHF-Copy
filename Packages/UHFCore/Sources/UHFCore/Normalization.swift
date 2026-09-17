import Foundation

extension String {
    /// Normalisation agressive utilisée pour rapprocher deux libellés qui désignent la
    /// même chaîne alors qu'ils viennent de sources différentes.
    ///
    /// `"FR | TF1 HD ᴴᴰ"` et `"TF1"` donnent tous les deux `"tf1"`.
    ///
    /// Sert à deux endroits : le repli d'identité de ``StableKey`` quand la playlist n'a
    /// pas de `tvg-id` propre (le cas courant), et l'appariement chaîne ↔ EPG.
    public var normalizedForMatching: String {
        let posix = Locale(identifier: "en_US_POSIX")

        // Le repli de compatibilité (NFKD) ramène les décorations typographiques à leur
        // équivalent ASCII : "ᴴᴰ" devient "HD", que la règle « qualité » plus bas saura
        // retirer. Le faire ici plutôt que de filtrer sur `CharacterSet.alphanumerics`
        // préserve les alphabets non latins, très présents dans les playlists réelles.
        var s = folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
                        locale: posix)
        s = s.precomposedStringWithCompatibilityMapping
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: posix)

        // Préfixe pays, sous ses deux formes courantes :
        //  - encadré, le séparateur est alors facultatif : "|FR| ", "[FR] ", "(FR) "
        //  - nu, un séparateur est alors exigé : "FR: ", "FR - ", "FR | "
        // Sans l'exigence de séparateur dans le second cas, "M6 Music" perdrait son "M6".
        s = s.replacingOccurrences(of: #"^\s*[\[\|\(]\s*[a-z]{2,3}\s*[\]\|\)]\s*[:\-\|]?\s*"#,
                                   with: "",
                                   options: [.regularExpression])
        s = s.replacingOccurrences(of: #"^\s*[a-z]{2,3}\s*[:\-\|]\s*"#,
                                   with: "",
                                   options: [.regularExpression])

        // Marqueurs de qualité, où qu'ils soient dans le libellé.
        s = s.replacingOccurrences(
            of: #"(?<![a-z0-9])(u?hd|fhd|sd|hq|lq|4k|8k|1080p?|720p?|576p?|480p?|h\.?26[45]|hevc|raw|backup|multi|vip|plus\+)(?![a-z0-9])"#,
            with: " ",
            options: [.regularExpression])

        // Caractères décoratifs Unicode (ᴴᴰ, ᵁᴴᴰ, drapeaux, puces…).
        s = s.unicodeScalars.reduce(into: "") { acc, scalar in
            if CharacterSet.alphanumerics.contains(scalar) || CharacterSet.whitespaces.contains(scalar) {
                acc.unicodeScalars.append(scalar)
            } else {
                acc.append(" ")
            }
        }

        return s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Variante sans espaces, pour un appariement en dernier recours.
    public var compactedForMatching: String {
        normalizedForMatching.replacingOccurrences(of: " ", with: "")
    }
}
