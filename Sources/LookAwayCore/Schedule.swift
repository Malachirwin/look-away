import Foundation

/// A day of the week, numbered to match `Calendar`'s `weekday` component.
public enum Weekday: Int, CaseIterable, Codable, Sendable, Comparable {
    case sunday = 1, monday, tuesday, wednesday, thursday, friday, saturday

    /// Sunday-first order, matching how the settings panel lays out the week.
    public static let week: [Weekday] = allCases

    public init?(date: Date, calendar: Calendar) {
        self.init(rawValue: calendar.component(.weekday, from: date))
    }

    /// Single letter for the toggle circles: S M T W T F S.
    public var initial: String { String(name.prefix(1)) }

    public var name: String {
        switch self {
        case .sunday: return "Sunday"
        case .monday: return "Monday"
        case .tuesday: return "Tuesday"
        case .wednesday: return "Wednesday"
        case .thursday: return "Thursday"
        case .friday: return "Friday"
        case .saturday: return "Saturday"
        }
    }

    public static func < (lhs: Weekday, rhs: Weekday) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// A wall-clock time with no date attached.
public struct TimeOfDay: Codable, Equatable, Comparable, Sendable {
    public var hour: Int
    public var minute: Int

    public init(hour: Int, minute: Int) {
        self.hour = min(max(hour, 0), 23)
        self.minute = min(max(minute, 0), 59)
    }

    public init?(date: Date, calendar: Calendar) {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        guard let hour = parts.hour, let minute = parts.minute else { return nil }
        self.init(hour: hour, minute: minute)
    }

    /// Minutes since midnight. The comparison and arithmetic basis.
    public var minutesSinceMidnight: Int { hour * 60 + minute }

    /// This time of day on the calendar day containing `day`.
    public func date(on day: Date, calendar: Calendar) -> Date {
        calendar.startOfDay(for: day).addingTimeInterval(TimeInterval(minutesSinceMidnight) * 60)
    }

    public static func < (lhs: TimeOfDay, rhs: TimeOfDay) -> Bool {
        lhs.minutesSinceMidnight < rhs.minutesSinceMidnight
    }
}

/// The stretch of a day reminders are allowed to fire in. An `end` at or before
/// `start` reads as an overnight window that closes the following morning.
public struct TimeWindow: Codable, Equatable, Sendable {
    public var start: TimeOfDay
    public var end: TimeOfDay

    public init(start: TimeOfDay, end: TimeOfDay) {
        self.start = start
        self.end = end
    }

    /// A standard 9-to-5 workday.
    public static let workday = TimeWindow(
        start: TimeOfDay(hour: 9, minute: 0),
        end: TimeOfDay(hour: 17, minute: 0)
    )

    public var isOvernight: Bool { end <= start }

    /// The window anchored to the calendar day `day` falls on.
    public func range(startingOn day: Date, calendar: Calendar) -> Range<Date> {
        let opens = start.date(on: day, calendar: calendar)
        var closes = end.date(on: day, calendar: calendar)
        if closes <= opens {
            closes = calendar.date(byAdding: .day, value: 1, to: closes) ?? closes.addingTimeInterval(86_400)
        }
        return opens..<closes
    }
}

/// When reminders are allowed to fire. Opt-in: while `isEnabled` is false the
/// app reminds around the clock, exactly as it did before schedules existed.
///
/// `hours` is the one window that covers every active day — the 9-to-5 case —
/// and `overrides` holds the per-day exceptions layered on top of it.
public struct Schedule: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public var activeDays: Set<Weekday>
    public var hours: TimeWindow
    public var overrides: [Weekday: TimeWindow]

    public init(
        isEnabled: Bool = false,
        activeDays: Set<Weekday> = [.monday, .tuesday, .wednesday, .thursday, .friday],
        hours: TimeWindow = .workday,
        overrides: [Weekday: TimeWindow] = [:]
    ) {
        self.isEnabled = isEnabled
        self.activeDays = activeDays
        self.hours = hours
        self.overrides = overrides
    }

    /// Weekdays 9-to-5, switched off until the user opts in.
    public static let standard = Schedule()

    // MARK: - Reading

    public func isActive(_ day: Weekday) -> Bool { activeDays.contains(day) }

    public func hasOverride(_ day: Weekday) -> Bool { overrides[day] != nil }

    /// The window that applies to `day`, or nil when the day is switched off.
    public func hours(for day: Weekday) -> TimeWindow? {
        guard isActive(day) else { return nil }
        return overrides[day] ?? hours
    }

    /// Whether reminders may fire at `date`. Always true while opted out.
    public func allows(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard isEnabled else { return true }
        return window(containing: date, calendar: calendar) != nil
    }

    /// The next moment `allows` flips to true, or nil when it never will —
    /// either because no day is active or because the schedule is off.
    public func nextOpening(after date: Date, calendar: Calendar = .current) -> Date? {
        guard isEnabled, !activeDays.isEmpty else { return nil }
        let today = calendar.startOfDay(for: date)
        // A window can only open on one of the next seven calendar days.
        for offset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                  let weekday = Weekday(date: day, calendar: calendar),
                  let hours = hours(for: weekday)
            else { continue }
            let opens = hours.range(startingOn: day, calendar: calendar).lowerBound
            if opens > date { return opens }
        }
        return nil
    }

    /// When the window `date` sits inside closes, or nil if it is outside every
    /// window (or the schedule is off).
    public func currentWindowEnd(at date: Date, calendar: Calendar = .current) -> Date? {
        guard isEnabled else { return nil }
        return window(containing: date, calendar: calendar)?.upperBound
    }

    // MARK: - Editing

    public mutating func setActive(_ isActive: Bool, for day: Weekday) {
        if isActive {
            activeDays.insert(day)
        } else {
            activeDays.remove(day)
            overrides[day] = nil
        }
    }

    public mutating func toggleActive(_ day: Weekday) {
        setActive(!isActive(day), for: day)
    }

    /// Starts a per-day exception, seeded from the shared hours so the picker
    /// opens on the values the day already had.
    public mutating func addOverride(for day: Weekday) {
        guard isActive(day), overrides[day] == nil else { return }
        overrides[day] = hours
    }

    public mutating func removeOverride(for day: Weekday) {
        overrides[day] = nil
    }

    public mutating func setOverride(_ window: TimeWindow, for day: Weekday) {
        guard isActive(day) else { return }
        overrides[day] = window
    }

    // MARK: - Helpers

    /// A window today or yesterday (an overnight one) that `date` lands in.
    private func window(containing date: Date, calendar: Calendar) -> Range<Date>? {
        let today = calendar.startOfDay(for: date)
        for offset in [0, -1] {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                  let weekday = Weekday(date: day, calendar: calendar),
                  let hours = hours(for: weekday)
            else { continue }
            let range = hours.range(startingOn: day, calendar: calendar)
            if range.contains(date) { return range }
        }
        return nil
    }
}

/// Enum keys encode as JSON object keys rather than a flat pair array.
extension Weekday: CodingKeyRepresentable {
    public var codingKey: any CodingKey { StringCodingKey(String(rawValue)) }

    public init?<T: CodingKey>(codingKey: T) {
        guard let raw = Int(codingKey.stringValue) else { return nil }
        self.init(rawValue: raw)
    }

    private struct StringCodingKey: CodingKey {
        let stringValue: String
        var intValue: Int? { Int(stringValue) }
        init(_ value: String) { stringValue = value }
        init?(stringValue: String) { self.init(stringValue) }
        init?(intValue: Int) { self.init(String(intValue)) }
    }
}
