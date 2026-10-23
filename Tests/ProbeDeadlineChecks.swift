import Foundation

@MainActor private final class DeadlineFixture {
    let defaults = UserDefaults(suiteName: "PhotoJot.ProbeDeadline.\(UUID())")!
    let profile = LibraryConnectionProfile(libraryID: UUID(), homeHost: "192.168.10.18",
        common: SMBConnectionSettings(host: "192.168.10.18", username: "fixture", share: "photos"))
    var now: TimeInterval = 0
    var requestedSleep: TimeInterval?
    var timerGate: CheckedContinuation<Void, Never>?
    var ioGate: CheckedContinuation<Void, Never>?
    var cleanupGate: CheckedContinuation<Void, Never>?
    var holdCleanup = false
    var failIO = false
    var disconnects = 0
    var finishes = 0
    var oldAborts = 0
    var newConnections = 0
    var activated: SMBConnectionSettings?
    enum Failure: Error { case expected }
    lazy var update = LibraryUpdateController(connection: { fatalError("no automatic update") },
        scan: { _, _ in fatalError("no scan") }, metadata: { _, _ in })

    func makeProbe(_ operationID: UUID) -> ConnectionProbe {
        ConnectionProbe(check: { _, _ in
            // Deliberately ignores cancellation and can return success after disconnect.
            await withCheckedContinuation { self.ioGate = $0 }
            if self.failIO { throw Failure.expected }
        }, disconnect: { self.disconnects += 1 }, finish: {
            self.finishes += 1
            if self.holdCleanup { await withCheckedContinuation { self.cleanupGate = $0 } }
        })
    }
    func controller(realClock: Bool = false) -> ConnectionSettingsController {
        if realClock {
            return ConnectionSettingsController(defaults: defaults, update: update, profile: profile,
                makeProbe: makeProbe, abortOldRoute: { self.oldAborts += 1 },
                establishRoute: { _, _ in self.newConnections += 1 }, activateRoute: { self.activated = $0 },
                readPassword: { _ in "fixture-secret" }, savePassword: { _, _ in }, deletePassword: { _ in },
                check: { _, _ in fatalError("must use independent probe") })
        }
        return ConnectionSettingsController(defaults: defaults, update: update, profile: profile,
            makeProbe: makeProbe, probeNow: { self.now }, probeSleep: { seconds in
                self.requestedSleep = seconds
                // Intentionally non-cooperative: proves a delayed timer cannot abort success.
                await withCheckedContinuation { self.timerGate = $0 }
            }, abortOldRoute: { self.oldAborts += 1 },
            establishRoute: { _, _ in self.newConnections += 1 }, activateRoute: { self.activated = $0 },
            readPassword: { _ in "fixture-secret" }, savePassword: { _, _ in }, deletePassword: { _ in },
            check: { _, _ in fatalError("must use independent probe") })
    }
}

@main struct ProbeDeadlineChecks {
    @MainActor static func wait(_ predicate: () -> Bool) async {
        let deadline = ProcessInfo.processInfo.systemUptime + 12
        while !predicate() {
            precondition(ProcessInfo.processInfo.systemUptime < deadline, "test wait expired")
            await Task.yield()
        }
    }
    @MainActor static func main() async throws {
        let f = DeadlineFixture(), controller = f.controller()
        f.holdCleanup = true
        let task = Task { await controller.switchEndpoint(useAway: true) }
        await wait { f.ioGate != nil && f.timerGate != nil }
        precondition(f.requestedSleep == 5)
        f.now = 5; f.timerGate?.resume(); f.timerGate = nil
        await wait { f.disconnects == 1 }
        precondition(!controller.useAway && controller.isSaving)
        precondition(controller.message == "接続確認がタイムアウトしました")
        precondition(controller.switchStatus == "接続確認を終了中…")
        precondition(controller.savedSettings == f.profile.settings && f.oldAborts == 0)
        let duplicate = await controller.switchEndpoint(useAway: true)
        precondition(!duplicate && f.newConnections == 0)
        precondition(f.defaults.data(forKey: LibraryConnectionProfile.storageKey) == nil)
        f.ioGate?.resume(); f.ioGate = nil
        await wait { f.cleanupGate != nil }
        precondition(controller.isSaving && f.newConnections == 0 && f.oldAborts == 0)
        f.cleanupGate?.resume(); f.cleanupGate = nil
        let expiredResult = await task.value
        precondition(!expiredResult && !controller.isSaving && !controller.useAway)
        precondition(f.activated == f.profile.settings && f.finishes == 1)
        precondition(controller.message == "接続確認がタイムアウトしました")

        let successFixture = DeadlineFixture(), success = successFixture.controller()
        successFixture.holdCleanup = true
        let successfulTask = Task { await success.switchEndpoint(useAway: true) }
        await wait { successFixture.ioGate != nil && successFixture.timerGate != nil }
        successFixture.now = 4.999
        successFixture.ioGate?.resume(); successFixture.ioGate = nil
        await wait { successFixture.cleanupGate != nil }
        successFixture.now = 6
        successFixture.timerGate?.resume(); successFixture.timerGate = nil
        for _ in 0..<100 { await Task.yield() }
        precondition(successFixture.disconnects == 0 && success.isSaving)
        successFixture.cleanupGate?.resume(); successFixture.cleanupGate = nil
        let successfulResult = await successfulTask.value
        precondition(successfulResult && success.useAway && successFixture.disconnects == 0)
        precondition(successFixture.newConnections == 1)

        let lateFixture = DeadlineFixture(), late = lateFixture.controller()
        let lateTask = Task { await late.switchEndpoint(useAway: true) }
        await wait { lateFixture.ioGate != nil && lateFixture.timerGate != nil }
        lateFixture.now = 5.01 // timer has not run yet; late success still must lose
        lateFixture.ioGate?.resume(); lateFixture.ioGate = nil
        let lateResult = await lateTask.value
        precondition(!lateResult && lateFixture.disconnects == 1 && lateFixture.newConnections == 0)
        lateFixture.timerGate?.resume(); lateFixture.timerGate = nil
        for _ in 0..<100 { await Task.yield() }
        precondition(lateFixture.disconnects == 1)

        let failureFixture = DeadlineFixture(), failure = failureFixture.controller()
        failureFixture.failIO = true
        let failedTask = Task { await failure.switchEndpoint(useAway: true) }
        await wait { failureFixture.ioGate != nil && failureFixture.timerGate != nil }
        failureFixture.now = 1
        failureFixture.ioGate?.resume(); failureFixture.ioGate = nil
        let failedResult = await failedTask.value
        precondition(!failedResult && failureFixture.disconnects == 0 && failureFixture.finishes == 1)
        failureFixture.now = 6; failureFixture.timerGate?.resume(); failureFixture.timerGate = nil
        for _ in 0..<100 { await Task.yield() }
        precondition(failureFixture.disconnects == 0)

        // Exercise the production five-second clock against unresponsive injected I/O.
        let realFixture = DeadlineFixture(), real = realFixture.controller(realClock: true)
        let start = ProcessInfo.processInfo.systemUptime
        let realTask = Task { await real.switchEndpoint(useAway: true) }
        await wait { realFixture.disconnects == 1 }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        precondition(elapsed >= 5 && elapsed < 10)
        precondition(!real.useAway && real.isSaving && realFixture.oldAborts == 0)
        realFixture.ioGate?.resume(); realFixture.ioGate = nil
        let realResult = await realTask.value
        precondition(!realResult && !real.isSaving && real.savedSettings?.libraryID == realFixture.profile.libraryID)
        print(String(format: "PASS: production deadline fired at %.3fs; toggle restored before I/O drain", elapsed))
        print("PASS: cleanup disables repeat toggle, late success rejected, pre-deadline success survives delayed timer, old route/UUID unchanged, early error cleanup")
    }
}
