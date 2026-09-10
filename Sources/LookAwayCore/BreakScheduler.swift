import Foundation

/// The 20/20/20 state machine. Owns all timing; the UI only reacts to events
/// and reads `state` for display.
@MainActor
public final class BreakScheduler {
    public enum State: Equatable, Sendable {
        /// `start()` has not been called.
        case stopped
        /// Waiting for the next break.
        case idle(fireAt: Date)
        /// Popup is visible and counting down.
        case breaking(remaining: Int)
        /// Popup was delayed and will return at `until`.
        case snoozed(until: Date)
        /// Reminders are off. `byUser` distinguishes a menu pause from sleep/lock.
        case paused(byUser: Bool)
        /// The clock is outside the user's schedule. `until` is the next
        /// opening, or nil when no day is active.
        case offSchedule(until: Date?)
        /// A meeting is in progress, so the popup is held back — but the
        /// countdown carries on underneath it. `dueAt` is the moment the break
        /// is owed, and it can be in the past: a break that came due mid-call
        /// is taken as soon as the call ends, rather than starting the wait
        /// over and leaving you a full interval short of a rest you had earned.
        case inMeeting(dueAt: Date)
    }

    public enum Event: Equatable, Sendable {
        /// Show the popup with a fresh countdown.
        case breakStarted
        /// Countdown moved to `remaining` seconds.
        case countdownTicked(remaining: Int)
        /// Countdown reached zero.
        case breakCompleted
        /// Popup should hide without completing (declined, snoozed, or paused).
        case breakDismissed
        /// Timing changed with no popup side effect (re-armed, snoozed, paused, resumed).
        case scheduleChanged
    }

    public let config: Config
    public private(set) var state: State = .stopped
    public private(set) var schedule: Schedule
    public var onEvent: (@MainActor (Event) -> Void)?

    private let clock: Timekeeper
    private let calendar: Calendar
    private var pending: ScheduledTask?
    /// Set by `meetingDidStart()` / `meetingDidEnd()`. Consulted whenever the
    /// next wait is armed, so a meeting outlasts any single transition.
    private var isInMeeting = false

    public init(
        config: Config = .standard,
        schedule: Schedule = .standard,
        clock: Timekeeper,
        calendar: Calendar = .current
    ) {
        self.config = config
        self.schedule = schedule
        self.clock = clock
        self.calendar = calendar
    }

    // MARK: - Commands

    /// Begin the first work interval.
    public func start() {
        armWork()
    }

    /// Open a break immediately from any non-breaking state.
    public func breakNow() {
        if case .breaking = state { return }
        beginBreak()
    }

    /// Close the popup and start the next work interval.
    public func decline() {
        guard case .breaking = state else { return }
        emit(.breakDismissed)
        armWork()
    }

    /// Hide the popup and bring it back after the snooze interval.
    public func snooze() {
        guard case .breaking = state else { return }
        cancelPending()
        emit(.breakDismissed)
        let duration = config.snoozeInterval
        state = .snoozed(until: clock.now().addingTimeInterval(duration))
        pending = clock.schedule(after: duration) { [weak self] in self?.fireScheduledBreak() }
        emit(.scheduleChanged)
    }

    /// Adopt an edited schedule and re-evaluate the current wait. An in-progress
    /// break is left alone; the new schedule takes effect when it closes.
    public func apply(schedule: Schedule) {
        self.schedule = schedule
        switch state {
        case .stopped, .paused, .breaking, .inMeeting:
            break
        case .idle, .offSchedule:
            armWork()
        case .snoozed:
            if !schedule.allows(clock.now(), calendar: calendar) { enterOffSchedule() }
        }
    }

    /// A meeting started. Holds the popup back and closes one already up — the
    /// whole point is not to be interrupted on a call — while keeping the
    /// deadline the countdown was working towards, so time on the call still
    /// counts. A user pause outranks this and is left alone.
    public func meetingDidStart() {
        isInMeeting = true
        guard state != .stopped else { return }
        switch state {
        case .paused, .inMeeting:
            return
        // Outside the scheduled hours nothing is pending anyway, and that hold
        // already outlasts the call.
        case .offSchedule:
            return
        case .idle, .breaking, .snoozed, .stopped:
            break
        }
        let dueAt = currentDeadline()
        cancelPending()
        if case .breaking = state { emit(.breakDismissed) }
        state = .inMeeting(dueAt: dueAt)
        emit(.scheduleChanged)
    }

    /// When the break the current state was heading towards is owed.
    private func currentDeadline() -> Date {
        switch state {
        case .idle(let fireAt):
            return fireAt
        case .snoozed(let until):
            return until
        // A break cut short by the call was never taken, so it is owed the
        // moment the call ends.
        case .breaking:
            return clock.now()
        case .stopped, .paused, .offSchedule, .inMeeting:
            return clock.now().addingTimeInterval(config.workInterval)
        }
    }

    /// The meeting ended. The countdown ran through the call, so a break that
    /// came due during it is taken now; otherwise the remainder plays out.
    public func meetingDidEnd() {
        isInMeeting = false
        guard case .inMeeting(let dueAt) = state else { return }
        guard schedule.allows(clock.now(), calendar: calendar) else {
            enterOffSchedule()
            return
        }
        if dueAt <= clock.now() {
            beginBreak()
        } else {
            scheduleWork(dueAt: dueAt)
        }
    }

    /// Meeting detection was switched off, so drop any hold it was placing.
    public func meetingDetectionDidStop() {
        meetingDidEnd()
        isInMeeting = false
    }

    /// User turned reminders off from the menu.
    public func pause() {
        guard state != .stopped else { return }
        enterPause(byUser: true)
    }

    /// User turned reminders back on. Starts a fresh work interval.
    public func resume() {
        guard case .paused = state else { return }
        armWork()
    }

    /// System went to sleep or the screen locked. Does not override a user pause.
    public func systemDidSuspend() {
        guard state != .stopped else { return }
        if case .paused(byUser: true) = state { return }
        enterPause(byUser: false)
    }

    /// System woke or the screen unlocked. Only resumes a system-initiated pause.
    public func systemDidResume() {
        guard case .paused(byUser: false) = state else { return }
        armWork()
    }

    // MARK: - Transitions

    /// Start the wait over, a full interval from now.
    private func armWork() {
        scheduleWork(dueAt: clock.now().addingTimeInterval(config.workInterval))
    }

    /// Wait for the break owed at `dueAt`, which may be less than a full
    /// interval away when a countdown is being picked back up mid-flight.
    private func scheduleWork(dueAt: Date) {
        cancelPending()
        guard schedule.allows(clock.now(), calendar: calendar) else {
            enterOffSchedule()
            return
        }
        if isInMeeting {
            state = .inMeeting(dueAt: dueAt)
            emit(.scheduleChanged)
            return
        }
        state = .idle(fireAt: dueAt)
        let wait = max(0, dueAt.timeIntervalSince(clock.now()))
        pending = clock.schedule(after: wait) { [weak self] in self?.fireScheduledBreak() }
        emit(.scheduleChanged)
    }

    /// A timer-driven break. A meeting can start and the window can close
    /// mid-interval, so both are checked again on arrival. `breakNow()`
    /// bypasses this.
    private func fireScheduledBreak() {
        if isInMeeting {
            // Came due mid-call. Hold the popup, and mark it owed as of now so
            // it opens the moment the call ends.
            cancelPending()
            state = .inMeeting(dueAt: clock.now())
            emit(.scheduleChanged)
            return
        }
        guard schedule.allows(clock.now(), calendar: calendar) else {
            enterOffSchedule()
            return
        }
        beginBreak()
    }

    private func beginBreak() {
        cancelPending()
        state = .breaking(remaining: config.breakSeconds)
        emit(.breakStarted)
        scheduleTick()
    }

    private func scheduleTick() {
        pending = clock.schedule(after: 1) { [weak self] in self?.tick() }
    }

    private func tick() {
        guard case .breaking(let remaining) = state else { return }
        let next = remaining - 1
        if next <= 0 {
            state = .breaking(remaining: 0)
            emit(.countdownTicked(remaining: 0))
            emit(.breakCompleted)
            armWork()
        } else {
            state = .breaking(remaining: next)
            emit(.countdownTicked(remaining: next))
            scheduleTick()
        }
    }

    /// Hold until the schedule opens again. Re-arms itself at that moment.
    private func enterOffSchedule() {
        cancelPending()
        if case .breaking = state { emit(.breakDismissed) }
        let now = clock.now()
        let opensAt = schedule.nextOpening(after: now, calendar: calendar)
        state = .offSchedule(until: opensAt)
        if let opensAt {
            pending = clock.schedule(after: opensAt.timeIntervalSince(now)) { [weak self] in self?.armWork() }
        }
        emit(.scheduleChanged)
    }

    private func enterPause(byUser: Bool) {
        cancelPending()
        if case .breaking = state { emit(.breakDismissed) }
        state = .paused(byUser: byUser)
        emit(.scheduleChanged)
    }

    private func cancelPending() {
        pending?.cancel()
        pending = nil
    }

    private func emit(_ event: Event) {
        onEvent?(event)
    }
}
