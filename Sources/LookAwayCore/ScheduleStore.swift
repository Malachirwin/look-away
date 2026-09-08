import Foundation

/// Where the user's schedule lives between launches. A protocol so the
/// scheduler's callers can be tested without touching real preferences.
@MainActor
public protocol ScheduleStoring: AnyObject {
    func load() -> Schedule
    func save(_ schedule: Schedule)
}

/// Stores the schedule as JSON under a single preferences key.
@MainActor
public final class UserDefaultsScheduleStore: ScheduleStoring {
    private let key = "schedule"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> Schedule {
        guard let data = defaults.data(forKey: key),
              let schedule = try? JSONDecoder().decode(Schedule.self, from: data)
        else { return .standard }
        return schedule
    }

    public func save(_ schedule: Schedule) {
        guard let data = try? JSONEncoder().encode(schedule) else { return }
        defaults.set(data, forKey: key)
    }
}
