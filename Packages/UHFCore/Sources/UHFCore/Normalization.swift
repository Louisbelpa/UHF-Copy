import Foundation

extension String {
    /// Normalisation agressive utilisée pour rapprocher deux libellés qui désignent la
    /// même chaîne alors qu'ils viennent de sources différentes.
    ///
    /// `"FR | TF1 HD ᴴᴰ"` et `"TF1"` donnent tous les deux `"tf1"`.
    ///
    /// Sert à deux endroits : le repli d'identité de ``StableKey`` quand la playlist n'a
    /// pas de `tvg-id` propre (le cas courant), et l'appariement chaîne ↔ EPG.
    ///
    /// - Note: écrite sans expression régulière à dessein. Elle est appelée une fois par
    ///   chaîne à l'import, soit 150 000 fois sur une grosse playlist ; une
    ///   `NSRegularExpression` y coûtait à elle seule plusieurs secondes.
    public var normalizedForMatching: String {
        let posix = Locale(identifier: "en_US_POSIX")

        // Le repli de compatibilité (NFKD) ramène les décorations typographiques à leur
        // équivalent ASCII : "ᴴᴰ" devient "HD", que le filtrage de tokens plus bas saura
        // retirer. Le faire ici plutôt que de filtrer sur `CharacterSet.alphanumerics`
        // préserve les alphabets non latins, très présents dans les playlists réelles.
        let folded = precomposedStringWithCompatibilityMapping
            .folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
                     locale: posix)

        var tokens = Self.tokenize(Self.droppingCountryPrefix(folded))

        // "h.264" / "h 265" se retrouvent scindés par la tokenisation.
        var index = 0
        while index + 1 < tokens.count {
            if tokens[index] == "h", tokens[index + 1] == "264" || tokens[index + 1] == "265" {
                tokens.removeSubrange(index...(index + 1))
            } else {
                index += 1
            }
        }

        tokens.removeAll { Self.qualityTokens.contains($0) || Self.isResolutionToken($0) }
        return tokens.joined(separator: " ")
    }

    /// Variante sans espaces, pour un appariement en dernier recours.
    public var compactedForMatching: String {
        normalizedForMatching.replacingOccurrences(of: " ", with: "")
    }

    // MARK: - Détail

    /// Marqueurs de qualité et de provenance, retirés quelle que soit leur position.
    private static let qualityTokens: Set<String> = [
        "hd", "uhd", "fhd", "sd", "hq", "lq", "4k", "8k",
        "hevc", "h264", "h265", "raw", "backup", "multi", "vip",
    ]

    /// `1080p`, `720i`… Les formes nues (`1080`, `720`) sont **conservées** : sans cela,
    /// « Chaîne 720 » et « Chaîne 1080 » se normaliseraient à l'identique et
    /// partageraient la même ``StableKey``.
    private static func isResolutionToken(_ token: String) -> Bool {
        guard let last = token.last, last == "p" || last == "i" else { return false }
        return ["1080", "720", "576", "480", "2160"].contains(String(token.dropLast()))
    }

    /// Retire le préfixe pays, sous ses deux formes courantes :
    /// - encadré, le séparateur est alors facultatif : `"|FR| "`, `"[FR] "`, `"(FR) "` ;
    /// - nu, un séparateur est alors exigé : `"FR: "`, `"FR - "`, `"FR | "`.
    ///
    /// Sans l'exigence de séparateur dans le second cas, `"TF1"` perdrait son propre nom.
    private static func droppingCountryPrefix(_ string: String) -> Substring {
        var cursor = string.startIndex
        func skipSpaces() {
            while cursor < string.endIndex, string[cursor].isWhitespace {
                cursor = string.index(after: cursor)
            }
        }

        skipSpaces()
        var sawBracket = false
        if cursor < string.endIndex, "[|(".contains(string[cursor]) {
            sawBracket = true
            cursor = string.index(after: cursor)
            skipSpaces()
        }

        var letters = 0
        while cursor < string.endIndex, string[cursor].isLetter, letters < 3 {
            cursor = string.index(after: cursor)
            letters += 1
        }
        guard letters >= 2,
              cursor == string.endIndex || !string[cursor].isLetter && !string[cursor].isNumber
        else { return string[...] }

        skipSpaces()
        if cursor < string.endIndex, "]|)".contains(string[cursor]) {
            sawBracket = true
            cursor = string.index(after: cursor)
            skipSpaces()
        }

        var sawSeparator = false
        if cursor < string.endIndex, ":-|".contains(string[cursor]) {
            sawSeparator = true
            cursor = string.index(after: cursor)
            skipSpaces()
        }

        guard sawBracket || sawSeparator, cursor < string.endIndex else { return string[...] }
        return string[cursor...]
    }

    /// Découpe en jetons alphanumériques, tout le reste faisant office de séparateur.
    private static func tokenize(_ string: Substring) -> [String] {
        var tokens: [String] = []
        var current = ""
        for character in string {
            if character.isLetter || character.isNumber {
                current.append(character)
            } else if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }
}
