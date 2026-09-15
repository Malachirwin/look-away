import Foundation
import Testing
@testable import LookAwayCore

/// Serialized because every test shares one preferences suite, wiped in `init`.
@Suite(.serialized)
@MainActor
struct ScheduleStoreTests {
    private static let suiteName = "com.connortorrell.LookAway.tests"

    let defaults: UserDefaults
    let store: UserDefaultsScheduleStore

    init() {
        defaults = UserDefaults(suiteName: Self.suiteName)!
        defaults.removePersistentDomain(forName: Self.suiteName)
        store = UserDefaultsScheduleStore(defaults: defaults)
    }

    @Test func loadsTheDefaultWhenNothingIsStored() {
        #expect(store.load() == .standard)
    }

    @Test func roundTripsASavedSchedule() {
        var schedule = Schedule(isEnabled: true, activeDays: [.monday, .saturday])
        schedule.addOverride(for: .saturday)
        store.save(schedule)
        #expect(store.load() == schedule)
    }

    @Test func fallsBackToTheDefaultWhenTheStoredDataIsUnreadable() {
        defaults.set(Data("not json".utf8), forKey: "schedule")
        #expect(store.load() == .standard)
    }
}
