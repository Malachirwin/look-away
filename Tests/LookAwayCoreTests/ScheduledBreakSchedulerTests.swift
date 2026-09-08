import Foundation
import Testing
@testable import LookAwayCore

/// The scheduler's behaviour once a schedule is switched on. The fake clock
/// starts at Monday, 1 Jan 2001, 00:00 UTC.
@MainActor
struct ScheduledBreakSchedulerTests {
    let config = Config(workInterval: 100, breakSeconds: 5, snoozeInterval: 10)
    let clock = FakeTimekeeper()

    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func date(day: Int = 0, hour: Int = 0, minute: Int = 0, second: Int = 0) -> Date {
        Date(timeIntervalSinceReferenceDate: TimeInterval((((day * 24 + hour) * 60 + minute) * 60) + second))
    }

    private var workweek: Schedule {
        Schedule(isEnabled: true, activeDays: [.monday, .tuesday, .wednesday, .thursday, .friday])
    }

    private func makeScheduler(_ schedule: Schedule) -> BreakScheduler {
        BreakScheduler(config: config, schedule: schedule, clock: clock, calendar: calendar)
    }

    @Test func startingBeforeTheWindowHoldsUntilItOpens() {
        let scheduler = makeScheduler(workweek)
        scheduler.start()
        #expect(scheduler.state == .offSchedule(until: date(hour: 9)))

        clock.advance(by: 9 * 3600)
        #expect(scheduler.state == .idle(fireAt: date(hour: 9, second: 100)))
    }

    @Test func breaksFireNormallyInsideTheWindow() {
        let scheduler = makeScheduler(workweek)
        clock.advance(by: 10 * 3600) // Monday 10am
        scheduler.start()
        #expect(scheduler.state == .idle(fireAt: date(hour: 10, second: 100)))
        clock.advance(by: 100)
        #expect(scheduler.state == .breaking(remaining: 5))
    }

    @Test func aBreakArmedBeforeClosingTimeDefersToTheNextOpening() {
        let scheduler = makeScheduler(workweek)
        clock.advance(by: 17 * 3600 - 50) // Monday, 50s before 5pm
        scheduler.start()
        #expect(scheduler.state == .idle(fireAt: date(hour: 17, second: 50)))

        clock.advance(by: 100) // window closed on the way there
        #expect(scheduler.state == .offSchedule(until: date(day: 1, hour: 9)))
    }

    @Test func holdingRearmsWhenTheWindowOpens() {
        let scheduler = makeScheduler(workweek)
        clock.advance(by: 20 * 3600) // Monday 8pm
        scheduler.start()
        #expect(scheduler.state == .offSchedule(until: date(day: 1, hour: 9)))

        clock.advance(by: 13 * 3600) // Tuesday 9am
        #expect(scheduler.state == .idle(fireAt: date(day: 1, hour: 9, second: 100)))
    }

    @Test func noActiveDaysHoldsIndefinitely() {
        let scheduler = makeScheduler(Schedule(isEnabled: true, activeDays: []))
        scheduler.start()
        #expect(scheduler.state == .offSchedule(until: nil))
        clock.advance(by: 30 * 24 * 3600)
        #expect(scheduler.state == .offSchedule(until: nil))
    }

    @Test func takeABreakNowStillWorksOutsideTheWindow() {
        let scheduler = makeScheduler(workweek)
        clock.advance(by: 20 * 3600)
        scheduler.start()
        scheduler.breakNow()
        #expect(scheduler.state == .breaking(remaining: 5))

        clock.advance(by: 5) // back on hold once it finishes
        #expect(scheduler.state == .offSchedule(until: date(day: 1, hour: 9)))
    }

    @Test func snoozeLandingOutsideTheWindowDefers() {
        let scheduler = makeScheduler(workweek)
        clock.advance(by: 17 * 3600 - 5) // Monday, 5s before close
        scheduler.start()
        scheduler.breakNow()
        scheduler.snooze() // returns 10s later, past 5pm
        clock.advance(by: 10)
        #expect(scheduler.state == .offSchedule(until: date(day: 1, hour: 9)))
    }

    @Test func editingTheScheduleReEvaluatesImmediately() {
        let scheduler = makeScheduler(workweek)
        clock.advance(by: 20 * 3600) // Monday 8pm, on hold
        scheduler.start()
        #expect(scheduler.state == .offSchedule(until: date(day: 1, hour: 9)))

        var evening = workweek
        evening.hours = TimeWindow(start: TimeOfDay(hour: 18, minute: 0), end: TimeOfDay(hour: 23, minute: 0))
        scheduler.apply(schedule: evening)
        #expect(scheduler.state == .idle(fireAt: date(hour: 20, second: 100)))
    }

    @Test func turningTheScheduleOnMidIntervalCanPutTheAppOnHold() {
        let scheduler = makeScheduler(Schedule(isEnabled: false))
        clock.advance(by: 20 * 3600)
        scheduler.start()
        #expect(scheduler.state == .idle(fireAt: date(hour: 20, second: 100)))

        scheduler.apply(schedule: workweek)
        #expect(scheduler.state == .offSchedule(until: date(day: 1, hour: 9)))
    }

    @Test func editingDoesNotInterruptABreakInProgress() {
        let scheduler = makeScheduler(workweek)
        clock.advance(by: 10 * 3600)
        scheduler.start()
        clock.advance(by: 100)
        #expect(scheduler.state == .breaking(remaining: 5))

        scheduler.apply(schedule: Schedule(isEnabled: true, activeDays: []))
        #expect(scheduler.state == .breaking(remaining: 5))
        clock.advance(by: 5)
        #expect(scheduler.state == .offSchedule(until: nil))
    }

    @Test func aUserPauseSurvivesAScheduleEdit() {
        let scheduler = makeScheduler(workweek)
        clock.advance(by: 10 * 3600)
        scheduler.start()
        scheduler.pause()
        scheduler.apply(schedule: workweek)
        #expect(scheduler.state == .paused(byUser: true))
    }

    @Test func resumingOutsideTheWindowGoesBackOnHold() {
        let scheduler = makeScheduler(workweek)
        clock.advance(by: 10 * 3600)
        scheduler.start()
        scheduler.pause()
        clock.advance(by: 10 * 3600) // now 8pm
        scheduler.resume()
        #expect(scheduler.state == .offSchedule(until: date(day: 1, hour: 9)))
    }

    @Test func perDayOverrideChangesWhenTheDayOpens() {
        var schedule = workweek
        schedule.setOverride(
            TimeWindow(start: TimeOfDay(hour: 6, minute: 0), end: TimeOfDay(hour: 12, minute: 0)),
            for: .monday
        )
        let scheduler = makeScheduler(schedule)
        scheduler.start()
        #expect(scheduler.state == .offSchedule(until: date(hour: 6)))
    }
}
