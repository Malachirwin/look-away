import Foundation
import Testing
@testable import LookAwayCore

/// Reference date 0 is Monday, 1 Jan 2001, 00:00 UTC; every date below is an
/// offset in seconds from that midnight, read in a fixed UTC calendar.
struct ScheduleTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func date(day: Int = 0, hour: Int = 0, minute: Int = 0) -> Date {
        Date(timeIntervalSinceReferenceDate: TimeInterval(((day * 24 + hour) * 60 + minute) * 60))
    }

    private var workweek: Schedule {
        Schedule(isEnabled: true, activeDays: [.monday, .tuesday, .wednesday, .thursday, .friday])
    }

    // MARK: Opt-in

    @Test func disabledScheduleAllowsEverything() {
        let schedule = Schedule(isEnabled: false, activeDays: [])
        #expect(schedule.allows(date(day: 5, hour: 3), calendar: calendar))
        #expect(schedule.nextOpening(after: date(), calendar: calendar) == nil)
    }

    @Test func standardScheduleIsOffAndWeekdaysNineToFive() {
        #expect(Schedule.standard.isEnabled == false)
        #expect(Schedule.standard.activeDays == [.monday, .tuesday, .wednesday, .thursday, .friday])
        #expect(Schedule.standard.hours == .workday)
    }

    // MARK: Windows

    @Test func allowsOnlyInsideTheWindowOnActiveDays() {
        let schedule = workweek
        #expect(!schedule.allows(date(hour: 8, minute: 59), calendar: calendar))
        #expect(schedule.allows(date(hour: 9), calendar: calendar))
        #expect(schedule.allows(date(hour: 16, minute: 59), calendar: calendar))
        #expect(!schedule.allows(date(hour: 17), calendar: calendar))
    }

    @Test func inactiveDaysNeverAllow() {
        // Day 5 is Saturday.
        #expect(!workweek.allows(date(day: 5, hour: 12), calendar: calendar))
    }

    @Test func overnightWindowCarriesIntoTheNextMorning() {
        let schedule = Schedule(
            isEnabled: true,
            activeDays: [.monday],
            hours: TimeWindow(start: TimeOfDay(hour: 22, minute: 0), end: TimeOfDay(hour: 2, minute: 0))
        )
        #expect(schedule.allows(date(hour: 23), calendar: calendar))
        #expect(schedule.allows(date(day: 1, hour: 1), calendar: calendar))   // Tuesday 1am
        #expect(!schedule.allows(date(day: 1, hour: 2), calendar: calendar))
        #expect(!schedule.allows(date(hour: 21), calendar: calendar))
    }

    // MARK: Next opening

    @Test func nextOpeningIsLaterToday() {
        #expect(workweek.nextOpening(after: date(hour: 7), calendar: calendar) == date(hour: 9))
    }

    @Test func nextOpeningSkipsInactiveDays() {
        // Friday 6pm rolls to Monday 9am.
        #expect(workweek.nextOpening(after: date(day: 4, hour: 18), calendar: calendar) == date(day: 7, hour: 9))
    }

    @Test func nextOpeningRespectsAPerDayOverride() {
        var schedule = workweek
        schedule.setOverride(
            TimeWindow(start: TimeOfDay(hour: 6, minute: 30), end: TimeOfDay(hour: 12, minute: 0)),
            for: .tuesday
        )
        #expect(schedule.nextOpening(after: date(hour: 18), calendar: calendar) == date(day: 1, hour: 6, minute: 30))
    }

    @Test func nextOpeningIsNilWithNoActiveDays() {
        let schedule = Schedule(isEnabled: true, activeDays: [])
        #expect(schedule.nextOpening(after: date(), calendar: calendar) == nil)
        #expect(!schedule.allows(date(hour: 12), calendar: calendar))
    }

    @Test func currentWindowEndIsTheClosingTime() {
        #expect(workweek.currentWindowEnd(at: date(hour: 10), calendar: calendar) == date(hour: 17))
        #expect(workweek.currentWindowEnd(at: date(hour: 20), calendar: calendar) == nil)
    }

    // MARK: Overrides

    @Test func overrideReplacesTheSharedHoursForThatDayOnly() {
        var schedule = workweek
        schedule.setOverride(
            TimeWindow(start: TimeOfDay(hour: 12, minute: 0), end: TimeOfDay(hour: 15, minute: 0)),
            for: .monday
        )
        #expect(!schedule.allows(date(hour: 9), calendar: calendar))          // Monday
        #expect(schedule.allows(date(hour: 13), calendar: calendar))
        #expect(schedule.allows(date(day: 1, hour: 9), calendar: calendar))   // Tuesday, untouched
    }

    @Test func addOverrideSeedsFromTheSharedHours() {
        var schedule = workweek
        schedule.addOverride(for: .monday)
        #expect(schedule.overrides[.monday] == .workday)
        #expect(schedule.hasOverride(.monday))
    }

    @Test func overridesAreIgnoredForInactiveDays() {
        var schedule = workweek
        schedule.addOverride(for: .sunday)
        schedule.setOverride(.workday, for: .sunday)
        #expect(!schedule.hasOverride(.sunday))
        #expect(schedule.hours(for: .sunday) == nil)
    }

    @Test func switchingADayOffDropsItsOverride() {
        var schedule = workweek
        schedule.addOverride(for: .monday)
        schedule.setActive(false, for: .monday)
        #expect(!schedule.isActive(.monday))
        #expect(!schedule.hasOverride(.monday))
    }

    @Test func toggleFlipsADay() {
        var schedule = workweek
        schedule.toggleActive(.saturday)
        #expect(schedule.isActive(.saturday))
        schedule.toggleActive(.saturday)
        #expect(!schedule.isActive(.saturday))
    }

    // MARK: Persistence

    @Test func roundTripsThroughJSON() throws {
        var schedule = workweek
        schedule.addOverride(for: .friday)
        schedule.setOverride(TimeWindow(start: TimeOfDay(hour: 8, minute: 15), end: TimeOfDay(hour: 13, minute: 45)), for: .friday)

        let data = try JSONEncoder().encode(schedule)
        #expect(try JSONDecoder().decode(Schedule.self, from: data) == schedule)
    }

    @Test func weekIsSundayFirstWithTheRightInitials() {
        #expect(Weekday.week.map(\.initial) == ["S", "M", "T", "W", "T", "F", "S"])
    }
}
