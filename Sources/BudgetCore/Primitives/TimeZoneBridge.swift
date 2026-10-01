import Foundation

/// Converts between instants (`Date`) and `LocalDate`s in one fixed time zone.
/// The app always uses the time zone from settings (Australia/Melbourne by default),
/// never the Mac's current zone, so travelling doesn't move transactions between days.
public struct TimeZoneBridge: Sendable {
    public let timeZone: TimeZone

    public static let defaultIdentifier = "Australia/Melbourne"

    public init(identifier: String = TimeZoneBridge.defaultIdentifier) {
        timeZone = TimeZone(identifier: identifier)
            ?? TimeZone(identifier: TimeZoneBridge.defaultIdentifier)
            ?? TimeZone(secondsFromGMT: 10 * 3600)!
    }

    public init(timeZone: TimeZone) {
        self.timeZone = timeZone
    }

    /// The local calendar date of an instant.
    public func localDate(for instant: Date) -> LocalDate {
        let offset = Double(timeZone.secondsFromGMT(for: instant))
        let localSeconds = instant.timeIntervalSince1970 + offset
        return LocalDate(dayNumber: Int32((localSeconds / 86_400).rounded(.down)))
    }

    /// The instant a local date begins (local midnight).
    public func startOfDay(_ date: LocalDate) -> Date {
        let midnightUTC = Double(date.dayNumber) * 86_400
        // Two refinement passes settle the offset even next to a DST change.
        var guess = Date(timeIntervalSince1970: midnightUTC - Double(timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: midnightUTC))))
        guess = Date(timeIntervalSince1970: midnightUTC - Double(timeZone.secondsFromGMT(for: guess)))
        return guess
    }

    public func today(now: Date = Date()) -> LocalDate {
        localDate(for: now)
    }

    /// UTC offset in seconds at the start of the given local date.
    public func offsetSeconds(at date: LocalDate) -> Int {
        timeZone.secondsFromGMT(for: startOfDay(date))
    }

    /// RFC 3339 timestamp for the start of a local date, e.g. "2026-10-01T00:00:00+10:00".
    public func rfc3339StartOfDay(_ date: LocalDate) -> String {
        let instant = startOfDay(date)
        return RFC3339.format(instant, offsetSeconds: timeZone.secondsFromGMT(for: instant))
    }
}

/// Minimal RFC 3339 / ISO 8601 parser and formatter (no formatter objects, so it is
/// Sendable and behaves the same on macOS and Linux).
public enum RFC3339 {
    /// Parses "2024-08-03T04:00:00+10:00", "2024-08-02T18:00:00Z", with optional fractional seconds.
    public static func parse(_ text: String) -> Date? {
        let bytes = Array(text.utf8)
        var index = 0

        func digits(_ count: Int) -> Int? {
            guard index + count <= bytes.count else { return nil }
            var value = 0
            for _ in 0..<count {
                let b = bytes[index]
                guard b >= 48 && b <= 57 else { return nil }
                value = value * 10 + Int(b - 48)
                index += 1
            }
            return value
        }

        func expect(_ chars: [UInt8]) -> Bool {
            guard index < bytes.count, chars.contains(bytes[index]) else { return false }
            index += 1
            return true
        }

        guard let year = digits(4), expect([45]), let month = digits(2), expect([45]), let day = digits(2),
              expect([84, 116, 32]), // T t space
              let hour = digits(2), expect([58]), let minute = digits(2), expect([58]), let second = digits(2),
              let date = LocalDate(year: year, month: month, day: day),
              hour < 24, minute < 60, second <= 60 else {
            return nil
        }

        var fraction = 0.0
        if index < bytes.count && (bytes[index] == 46 || bytes[index] == 44) { // . or ,
            index += 1
            var scale = 0.1
            var sawDigit = false
            while index < bytes.count, bytes[index] >= 48 && bytes[index] <= 57 {
                fraction += Double(bytes[index] - 48) * scale
                scale /= 10
                index += 1
                sawDigit = true
            }
            guard sawDigit else { return nil }
        }

        guard index < bytes.count else { return nil }
        var offset = 0
        switch bytes[index] {
        case 90, 122: // Z z
            index += 1
        case 43, 45: // + -
            let sign = bytes[index] == 45 ? -1 : 1
            index += 1
            guard let oh = digits(2) else { return nil }
            if index < bytes.count && bytes[index] == 58 { index += 1 }
            guard let om = digits(2) else { return nil }
            offset = sign * (oh * 3600 + om * 60)
        default:
            return nil
        }
        guard index == bytes.count else { return nil }

        let seconds = Double(date.dayNumber) * 86_400 + Double(hour * 3600 + minute * 60 + second) + fraction - Double(offset)
        return Date(timeIntervalSince1970: seconds)
    }

    /// Formats an instant at a fixed UTC offset, to whole seconds: "2026-10-01T00:00:00+10:00".
    public static func format(_ instant: Date, offsetSeconds: Int) -> String {
        let local = Int((instant.timeIntervalSince1970 + Double(offsetSeconds)).rounded(.down))
        let days = IntMath.floorDiv(local, 86_400)
        let secondsOfDay = local - days * 86_400
        let date = LocalDate(dayNumber: Int32(days))
        let h = secondsOfDay / 3600, m = (secondsOfDay % 3600) / 60, s = secondsOfDay % 60
        let sign = offsetSeconds < 0 ? "-" : "+"
        let absOffset = abs(offsetSeconds)
        return "\(date.isoString)T\(two(h)):\(two(m)):\(two(s))\(sign)\(two(absOffset / 3600)):\(two((absOffset % 3600) / 60))"
    }

    private static func two(_ value: Int) -> String { value < 10 ? "0\(value)" : "\(value)" }
}
