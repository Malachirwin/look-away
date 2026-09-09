import Foundation
import Testing
@testable import LookAwayCore

/// How the scheduler behaves while a meeting is on.
@MainActor
struct MeetingBreakSchedulerTests {
    let config = Config(workInterval: 100, breakSeconds: 5, snoozeInterval: 10)
    let clock = FakeTimekeeper()

    private func makeScheduler(schedule: Schedule = .standard) -> BreakScheduler {
        BreakScheduler(config: config, schedule: schedule, clock: clock)
    }

    @Test func aMeetingHoldsTheNextBreak() {
        let scheduler = makeScheduler()
        scheduler.start()
        scheduler.meetingDidStart()
        #expect(scheduler.state == .inMeeting)

        // Well past when the break would have been due.
        clock.advance(by: 500)
        #expect(scheduler.state == .inMeeting)
    }

    @Test func theBreakComesAFullIntervalAfterTheMeetingEnds() {
        let scheduler = makeScheduler()
        scheduler.start()
        clock.advance(by: 90) // 10s short of a break
        scheduler.meetingDidStart()
        clock.advance(by: 500)

        scheduler.meetingDidEnd()
        #expect(scheduler.state == .idle(fireAt: clock.now().addingTimeInterval(100)))

        clock.advance(by: 100)
        #expect(scheduler.state == .breaking(remaining: 5))
    }

    /// A meeting starting mid-break closes the popup — being interrupted on a
    /// call is the whole thing the feature exists to stop.
    @Test func aMeetingStartingMidBreakDismissesThePopup() {
        let scheduler = makeScheduler()
        var events: [BreakScheduler.Event] = []
        scheduler.onEvent = { events.append($0) }
        scheduler.start()
        clock.advance(by: 100)
        #expect(scheduler.state == .breaking(remaining: 5))

        scheduler.meetingDidStart()
        #expect(scheduler.state == .inMeeting)
        #expect(events.contains(.breakDismissed))
    }

    /// A break armed before a call has to re-check on arrival, since the
    /// meeting starts while the timer is already running.
    @Test func aBreakArrivingDuringAMeetingIsHeld() {
        let scheduler = makeScheduler()
        scheduler.start()
        clock.advance(by: 50)
        scheduler.meetingDidStart()
        clock.advance(by: 100)
        #expect(scheduler.state == .inMeeting)
    }

    @Test func aMeetingDuringASnoozeHoldsTheDelayedBreak() {
        let scheduler = makeScheduler()
        scheduler.start()
        clock.advance(by: 100)
        scheduler.snooze()
        scheduler.meetingDidStart()
        clock.advance(by: 500)
        #expect(scheduler.state == .inMeeting)
    }

    /// The menu's pause is the user's own call and outranks detection.
    @Test func aUserPauseIsNotOverriddenByAMeeting() {
        let scheduler = makeScheduler()
        scheduler.start()
        scheduler.pause()
        scheduler.meetingDidStart()
        #expect(scheduler.state == .paused(byUser: true))
    }

    /// Resuming from the menu during a call should not fire a popup into it.
    @Test func resumingDuringAMeetingHoldsAgain() {
        let scheduler = makeScheduler()
        scheduler.start()
        scheduler.pause()
        scheduler.meetingDidStart()
        scheduler.resume()
        #expect(scheduler.state == .inMeeting)
    }

    /// "Take a Break Now" is an explicit request and still works.
    @Test func aBreakCanStillBeTakenByHandDuringAMeeting() {
        let scheduler = makeScheduler()
        scheduler.start()
        scheduler.meetingDidStart()
        scheduler.breakNow()
        #expect(scheduler.state == .breaking(remaining: 5))
    }

    /// Turning detection off has to release the hold, because the monitor will
    /// not report an end for a meeting it has stopped watching.
    @Test func switchingDetectionOffReleasesTheHold() {
        let scheduler = makeScheduler()
        scheduler.start()
        scheduler.meetingDidStart()
        scheduler.meetingDetectionDidStop()
        #expect(scheduler.state == .idle(fireAt: clock.now().addingTimeInterval(100)))
    }

    @Test func sleepingDuringAMeetingWakesToAFreshInterval() {
        let scheduler = makeScheduler()
        scheduler.start()
        scheduler.meetingDidStart()
        scheduler.systemDidSuspend()
        #expect(scheduler.state == .paused(byUser: false))

        // The call is over by the time the Mac comes back.
        scheduler.meetingDidEnd()
        scheduler.systemDidResume()
        #expect(scheduler.state == .idle(fireAt: clock.now().addingTimeInterval(100)))
    }

    /// A meeting that is still going when the Mac wakes keeps holding.
    @Test func wakingIntoAMeetingHoldsAgain() {
        let scheduler = makeScheduler()
        scheduler.start()
        scheduler.meetingDidStart()
        scheduler.systemDidSuspend()
        scheduler.systemDidResume()
        #expect(scheduler.state == .inMeeting)
    }

    /// The schedule still applies once the call ends.
    @Test func aMeetingEndingOutsideTheScheduleHoldsForTheSchedule() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let schedule = Schedule(
            isEnabled: true,
            activeDays: [.monday],
            hours: TimeWindow(start: TimeOfDay(hour: 9, minute: 0), end: TimeOfDay(hour: 17, minute: 0))
        )
        let scheduler = BreakScheduler(config: config, schedule: schedule, clock: clock, calendar: calendar)

        clock.advance(by: 10 * 3600) // Monday 10am, inside the window
        scheduler.start()
        scheduler.meetingDidStart()
        clock.advance(by: 8 * 3600) // now 6pm, window has closed
        scheduler.meetingDidEnd()

        // Monday is the only active day, so the window reopens a week later.
        #expect(scheduler.state == .offSchedule(until: Date(timeIntervalSinceReferenceDate: 7 * 86_400 + 9 * 3600)))
    }
}
