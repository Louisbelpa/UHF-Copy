import Foundation

/// Analyse des dates XMLTV, écrite à la main.
///
/// Format nominal : `YYYYMMDDHHMMSS +0100`. Dans la nature on rencontre aussi
/// `YYYYMMDDHHMM`, `YYYYMMDDHHMMSS` sans décalage, ou un `Z` final.
///
/// - Important: un `DateFormatter` coûte ici environ 10 µs par appel, soit près de
///   40 secondes pour les deux millions de bornes d'un XMLTV de 200 Mo. Ce parseur
///   entier est deux ordres de grandeur plus rapide, et c'est ce qui rend l'objectif
///   « 200 Mo en moins de 60 s » atteignable.
public enum XMLTVDate {

    public static func parse(_ string: String) -> Date? {
        let scalars = Array(string.utf8)
        var digits: [Int] = []
        digits.reserveCapacity(14)

        var index = 0
        while index < scalars.count, digits.count < 14 {
            let byte = scalars[index]
            guard byte >= 48, byte <= 57 else { break }
            digits.append(Int(byte - 48))
            index += 1
        }
        guard digits.count >= 8 else { return nil }

        func number(_ start: Int, _ length: Int) -> Int {
            guard start + length <= digits.count else { return 0 }
            return digits[start..<(start + length)].reduce(0) { $0 * 10 + $1 }
        }

        var components = DateComponents()
        components.year = number(0, 4)
        components.month = number(4, 2)
        components.day = number(6, 2)
        components.hour = digits.count >= 10 ? number(8, 2) : 0
        components.minute = digits.count >= 12 ? number(10, 2) : 0
        components.second = digits.count >= 14 ? number(12, 2) : 0

        // Décalage horaire : « +0100 », « -0530 », « Z », ou absent.
        var offsetSeconds = 0
        while index < scalars.count, scalars[index] == 0x20 { index += 1 }   // espaces
        if index < scalars.count {
            let sign = scalars[index]
            if sign == 0x2B || sign == 0x2D {                                // '+' ou '-'
                index += 1
                var offsetDigits: [Int] = []
                while index < scalars.count, offsetDigits.count < 4,
                      scalars[index] >= 48, scalars[index] <= 57 {
                    offsetDigits.append(Int(scalars[index] - 48))
                    index += 1
                }
                guard offsetDigits.count >= 2 else { return nil }
                let hours = offsetDigits[0] * 10 + offsetDigits[1]
                let minutes = offsetDigits.count >= 4 ? offsetDigits[2] * 10 + offsetDigits[3] : 0
                offsetSeconds = (hours * 3600 + minutes * 60) * (sign == 0x2D ? -1 : 1)
            }
            // « Z » ou rien : on reste en UTC, hypothèse par défaut de la spécification.
        }

        components.timeZone = TimeZone(secondsFromGMT: offsetSeconds)
        return Self.utcCalendar.date(from: components)
    }

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
}
