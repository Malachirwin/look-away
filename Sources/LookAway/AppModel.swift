import AppKit
import LookAwayCore
import Observation

/// Glue between the scheduler and the UI. Owns the popup panel and exposes
/// observable display state for the menu and the break view.
@MainActor
@Observable
final class AppModel {
    enum BreakPhase { case counting, done }

    private(set) var iconName = "eye"
    private(set) var remainingSeconds = 0
    private(set) var breakPhase: BreakPhase = .counting
    private(set) var launchAtLoginEnabled = false
    private(set) var launchAtLoginError: String?

    /// Mirrors the scheduler's schedule so SwiftUI sees edits immediately.
    private(set) var schedule: Schedule

    let config: Config
    private let scheduler: BreakScheduler
    private let clock: Timekeeper
    private let scheduleStore: ScheduleStoring
    private var panel: BreakPanelController?
    private var doneHide: ScheduledTask?

    init(config: Config = .standard, scheduleStore: ScheduleStoring = UserDefaultsScheduleStore()) {
        self.config = config
        self.scheduleStore = scheduleStore
        let clock = SystemTimekeeper()
        self.clock = clock
        let schedule = scheduleStore.load()
        self.schedule = schedule
        scheduler = BreakScheduler(config: config, schedule: schedule, clock: clock)
        scheduler.onEvent = { [unowned self] event in self.handle(event) }
    }

    func start() {
        scheduler.start()
    }

    // MARK: User actions

    func snooze() { scheduler.snooze() }
    func decline() { scheduler.decline() }
    func breakNow() { scheduler.breakNow() }
    func togglePause() { isPaused ? scheduler.resume() : scheduler.pause() }
    func systemDidSuspend() { scheduler.systemDidSuspend() }
    func systemDidResume() { scheduler.systemDidResume() }
    func clockDidChange() { scheduler.clockDidChange() }

    /// Single write path for schedule edits: persist, then apply. The
    /// scheduler's `scheduleChanged` event refreshes the display.
    func updateSchedule(_ schedule: Schedule) {
        guard schedule != self.schedule else { return }
        self.schedule = schedule
        scheduleStore.save(schedule)
        scheduler.apply(schedule: schedule)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLogin.set(enabled)
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
        }
        refreshLaunchAtLogin()
    }

    func refreshLaunchAtLogin() {
        launchAtLoginEnabled = LaunchAtLogin.isEnabled
    }

    // MARK: Scheduler events

    private func handle(_ event: BreakScheduler.Event) {
        switch event {
        case .breakStarted:
            cancelDoneHide()
            breakPhase = .counting
            remainingSeconds = config.breakSeconds
            showPanel()
        case .countdownTicked(let remaining):
            remainingSeconds = remaining
        case .breakCompleted:
            breakPhase = .done
            Sound.playChime()
            doneHide = clock.schedule(after: 1.2) { [weak self] in self?.panel?.hide() }
        case .breakDismissed:
            cancelDoneHide()
            panel?.hide()
        case .scheduleChanged:
            break
        }
        refreshIcon()
    }

    private func showPanel() {
        if panel == nil {
            panel = BreakPanelController(content: BreakView(model: self))
        }
        panel?.show()
    }

    private func cancelDoneHide() {
        doneHide?.cancel()
        doneHide = nil
    }

    // MARK: Display state

    var isPaused: Bool {
        if case .paused = scheduler.state { return true }
        return false
    }

    var isBreaking: Bool {
        if case .breaking = scheduler.state { return true }
        return false
    }

    /// Computed on demand so a menu can poll it every second while open.
    var statusText: String {
        switch scheduler.state {
        case .stopped:
            return "Starting…"
        case .idle(let fireAt):
            return "Next break in \(Self.format(fireAt.timeIntervalSince(clock.now())))"
        case .breaking:
            return "Break in progress"
        case .snoozed(let until):
            return "Delayed — back in \(Self.format(until.timeIntervalSince(clock.now())))"
        case .paused(let byUser):
            return byUser ? "Paused" : "Paused (screen locked)"
        case .offSchedule(let until):
            // `until` is only nil when no day is switched on.
            guard let until else { return "No days scheduled" }
            return "Outside schedule — back \(Self.formatOpening(until, from: clock.now()))"
        }
    }

    private func refreshIcon() {
        let icon: String
        switch scheduler.state {
        case .breaking: icon = "eye.slash"
        case .paused: icon = "pause.circle"
        case .offSchedule: icon = "moon.zzz"
        case .stopped, .idle, .snoozed: icon = "eye"
        }
        if icon != iconName { iconName = icon }
    }

    /// "at 9:00 AM" for later today, "Mon at 9:00 AM" within the week, and
    /// "next Mon at 9:00 AM" when the opening is a full week away, so a
    /// Monday-only schedule read on Monday evening does not look like today.
    private static func formatOpening(_ date: Date, from now: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return "at \(time)" }
        let weekday = date.formatted(.dateTime.weekday(.abbreviated))
        let daysAway = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)
        ).day ?? 0
        return daysAway >= 7 ? "next \(weekday) at \(time)" : "\(weekday) at \(time)"
    }

    private static func format(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval.rounded(.up)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
