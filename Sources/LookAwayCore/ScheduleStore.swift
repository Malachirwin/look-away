import Foundation
import os

/// Where the user's schedule lives between launches. A protocol so the
/// scheduler's callers can be tested without touching real preferences.
@MainActor
public protocol ScheduleStoring: AnyObject {
    func load() -> Schedule
    func save(_ schedule: Schedule)
}

/// Stores the schedule as JSON under a single preferences key.
///
/// Decoding is all-or-nothing: if `Schedule` ever gains a field, give it a
/// default through `decodeIfPresent` in a custom `init(from:)`, or every
/// existing user silently drops back to `.standard` with the schedule off.
@MainActor
public final class UserDefaultsScheduleStore: ScheduleStoring {
    private static let logger = Logger(subsystem: "com.connortorrell.LookAway", category: "schedule")
    private let key = "schedule"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> Schedule {
        guard let data = defaults.data(forKey: key) else { return .standard }
        do {
            return try JSONDecoder().decode(Schedule.self, from: data)
        } catch {
            Self.logger.error("Stored schedule is unreadable, using the default: \(String(describing: error), privacy: .public)")
            return .standard
        }
    }

    public func save(_ schedule: Schedule) {
        do {
            defaults.set(try JSONEncoder().encode(schedule), forKey: key)
        } catch {
            Self.logger.error("Schedule could not be saved: \(String(describing: error), privacy: .public)")
        }
    }
}
