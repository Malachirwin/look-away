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
        case .stopped, .paused, .breaking:
            break
        case .idle, .offSchedule:
            armWork()
        case .snoozed:
            if !schedule.allows(clock.now(), calendar: calendar) { enterOffSchedule() }
        }
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

    private func armWork() {
        cancelPending()
        guard schedule.allows(clock.now(), calendar: calendar) else {
            enterOffSchedule()
            return
        }
        state = .idle(fireAt: clock.now().addingTimeInterval(config.workInterval))
        pending = clock.schedule(after: config.workInterval) { [weak self] in self?.fireScheduledBreak() }
        emit(.scheduleChanged)
    }

    /// A timer-driven break. The window can close mid-interval, so the
    /// schedule is checked again on arrival. `breakNow()` bypasses this.
    private func fireScheduledBreak() {
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
