import Foundation
import Network
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
import SMBClient

actor MetadataFixture {
    var target: MetadataTarget?
    var saved = 0
    init(_ target: MetadataTarget) { self.target = target }
    func next() -> [MetadataTarget] { defer { target = nil }; return target.map { [$0] } ?? [] }
    func save(_ values: [MetadataUpdate]) { saved += values.count }
}

@main struct ThumbnailSMBChecks {
    static func check(_ value: Bool, line: UInt = #line) { precondition(value, "line \(line)") }
    static func wait(_ condition: () async -> Bool) async {
        let limit = Date().addingTimeInterval(10)
        while !(await condition()) { check(Date() < limit); await Task.yield() }
    }
    static func main() async throws {
        let context = CGContext(data: nil, width: 600, height: 400, bitsPerComponent: 8, bytesPerRow: 2400,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        check(CGImageDestinationFinalize(destination))
        let server = TestSMBServer.shared
        let access = SMBAccessCoordinator()
        var settings = SMBConnectionSettings(); settings.host = "test"; settings.share = "photos"; settings.rootPath = "scan"
        let key = ThumbnailKey(libraryID: UUID(), mediaEntryID: UUID(), generation: UUID(), specificationVersion: PhotoThumbnailPolicy.version, pixelSize: 300)
        let target = MediaThumbnailTarget(key: key, path: "photo.jpg", fileSize: Int64(data.length), fileExtension: "jpg", settings: settings)
        let metadata = MetadataFixture(.init(id: UUID(), libraryID: key.libraryID, generation: UUID(),
            file: .init(path: "metadata.jpg", size: Int64(data.length), creation: .distantPast, modified: .distantPast)))
        await server.configure(data as Data, blocked: ["list:scan", "read:photo.jpg", "close:photo.jpg"])
        let scan = Task { try await access.scan(settings: settings, password: "secret", consume: { _,_ in }) }
        await wait { await server.waiting("list:scan") }
        let photo = Task { try await access.thumbnail(target: target, password: "secret") }
        await wait { await access.waitingOperationCount == 1 }
        let parse = Task { try await access.completeMetadata(settings: settings, password: "secret",
            next: { await metadata.next() }, save: { await metadata.save($0) }) }
        await wait { await access.waitingOperationCount == 2 }
        await server.release("list:scan")
        await wait { await server.waiting("read:photo.jpg") }
        await wait { await access.waitingOperationCount == 2 }
        // Queued metadata and the scan's next folder cannot use the shared session until close finishes.
        photo.cancel()
        await server.release("read:photo.jpg")
        await wait { await server.waiting("close:photo.jpg") }
        check(await access.waitingOperationCount == 2)
        // Snapshot stays readable while SMB close holds the gate, without releasing it.
        let diagnosticSnapshot = SMBDiagnostics.shared.snapshot()
        check(diagnosticSnapshot.active.contains { $0.kind.hasPrefix("file close") })
        check(diagnosticSnapshot.active.contains { $0.kind.hasPrefix("gate") && $0.stage == "acquired" })
        check(diagnosticSnapshot.active.contains { $0.kind.hasPrefix("gate") && $0.stage == "acquire waiting" })
        let diagnosticText = diagnosticSnapshot.recent.joined() + diagnosticSnapshot.active.map(\.kind).joined()
        check(!diagnosticText.contains("secret") && !diagnosticText.contains("photo.jpg") && !diagnosticText.contains("metadata.jpg"))
        check(!(await server.events.contains("open:metadata.jpg")))
        check(!(await server.events.contains("list:scan/child")))
        let connection = Task { try await access.checkConnection(settings: settings, password: "new") }
        await wait { await access.waitingOperationCount == 3 }
        await server.release("close:photo.jpg")
        do { _ = try await photo.value; preconditionFailure("cancel must propagate") } catch is CancellationError { }
        _ = try await scan.value; try await parse.value; _ = try await connection.value
        check(await metadata.saved == 1)
        let events = await server.events
        check(events.firstIndex(of: "open:photo.jpg")! < events.firstIndex(of: "open:metadata.jpg")!)
        check(events.firstIndex(of: "open:metadata.jpg")! < events.firstIndex(of: "list:scan/child")!)
        check(await server.maximumInFlight == 1)
        // Foreground retry can generate after cancellation cleanup and connection check.
        let result = try await access.thumbnail(target: target, password: "secret")
        check(CGImageSourceCreateWithData(result as CFData, nil) != nil)
        await access.disconnectWhenAvailable()

        // Cancellation of a queued operation never releases the active owner's slot.
        await server.configure(data as Data, blocked: ["read:photo.jpg"])
        let active = Task { try await access.thumbnail(target: target, password: "secret") }
        await wait { await server.waiting("read:photo.jpg") }
        let cancelledScan = Task { try await access.scan(settings: settings, password: "secret", consume: { _,_ in }) }
        await wait { await access.waitingOperationCount == 1 }
        cancelledScan.cancel()
        do { _ = try await cancelledScan.value; preconditionFailure("queued cancel") } catch is CancellationError { }
        check(await access.waitingOperationCount == 0)
        check(!(await server.events.contains("list:scan")))
        await server.release("read:photo.jpg"); _ = try await active.value
        check(await server.maximumInFlight == 1)
        await access.disconnectWhenAvailable()
        // Metadata close失敗は未完了として保存し、そのsessionを再利用しない。
        await server.configure(data as Data, blocked: [])
        await server.failCloseOnce()
        let retryMetadata = MetadataFixture(.init(id: UUID(), libraryID: key.libraryID, generation: UUID(),
            file: .init(path: "retry.jpg", size: Int64(data.length), creation: .distantPast, modified: .distantPast)))
        do {
            try await access.completeMetadata(settings: settings, password: "secret",
                next: { await retryMetadata.next() }, save: { await retryMetadata.save($0) })
            preconditionFailure("close failure")
        } catch MetadataServiceError.interruptedRead { }
        check(await retryMetadata.saved == 1)
        _ = try await access.thumbnail(target: target, password: "secret")
        check(await server.events.filter { $0 == "connect" }.count == 2)
        await access.disconnectWhenAvailable()
        // 本物のAVAsset loaderからmock SMB APIへrange要求を送り、closeまで枠を保持。
        let movie = try await VideoThumbnailFixture.make()
        let videoKey = ThumbnailKey(libraryID: key.libraryID, mediaEntryID: UUID(), generation: UUID(),
            specificationVersion: VideoThumbnailPolicy.version, pixelSize: 300)
        let videoTarget = MediaThumbnailTarget(key: videoKey, path: "video.mov", fileSize: Int64(movie.count), fileExtension: "mov", settings: settings)
        await server.configure(movie, blocked: ["read:video.mov", "close:video.mov"])
        let video = Task { try await access.thumbnail(target: videoTarget, password: "secret") }
        await wait { await server.waiting("read:video.mov") }
        let afterVideo = Task { try await access.scan(settings: settings, password: "secret", consume: { _,_ in }) }
        await wait { await access.waitingOperationCount == 1 }
        video.cancel()
        check(!(await server.events.contains("list:scan")))
        await server.release("read:video.mov")
        await wait { await server.waiting("close:video.mov") }
        check(await access.waitingOperationCount == 1)
        await server.release("close:video.mov")
        do { _ = try await video.value; preconditionFailure("video cancel") } catch is CancellationError { }
        _ = try await afterVideo.value
        check(await server.maximumInFlight == 1)
        check(await server.events.filter { $0 == "read:video.mov" }.count == 1)
        let poster = try await access.thumbnail(target: videoTarget, password: "secret")
        check(CGImageSourceCreateWithData(poster as CFData, nil) != nil)
        await access.disconnectWhenAvailable()
        // Viewer readerはopenしたままでも、各range間でscan/thumbnailが進める。
        let viewerTarget = MediaThumbnailTarget(key: videoKey, path: "viewer.mov", fileSize: Int64(movie.count), fileExtension: "mov", settings: settings)
        await server.configure(movie, blocked: ["read:viewer.mov"])
        let handle = try await access.openViewer(target: viewerTarget, password: "secret")
        let range = Task { try await access.readViewer(handle, offset: 0, count: 32) }
        await wait { await server.waiting("read:viewer.mov") }
        let concurrentScan = Task { try await access.scan(settings: settings, password: "secret", consume: { _,_ in }) }
        await wait { await access.waitingOperationCount == 1 }
        let concurrentThumbnail = Task { try await access.thumbnail(target: videoTarget, password: "secret") }
        await wait { await access.waitingOperationCount == 2 }
        await server.release("read:viewer.mov")
        check(try await range.value == movie.prefix(32))
        _ = try await concurrentScan.value; _ = try await concurrentThumbnail.value
        check(!(await server.events.contains("close:viewer.mov")))
        check(try await access.readViewer(handle, offset: 32, count: 32) == movie.subdata(in: 32..<64))
        await access.closeViewer(handle); await access.closeViewer(handle)
        check(await server.events.filter { $0 == "close:viewer.mov" }.count == 1)
        check(await server.maximumInFlight == 1)
        let expired = try await access.openViewer(target: viewerTarget, password: "secret")
        await access.disconnectWhenAvailable()
        do { _ = try await access.readViewer(expired, offset: 0, count: 32); preconditionFailure("expired handle") } catch { }
        await access.closeViewer(expired)
        check(SMBDiagnostics.shared.snapshot().active.isEmpty)
        // Notification aborts outside the gate. A non-returning transport still owns the gate.
        await server.configure(data as Data, blocked: ["list:scan"])
        let interruptedScan = Task { try await access.scan(settings: settings, password: "secret", consume: { _, _ in }) }
        await wait { await server.waiting("list:scan") }
        let connections = TestSMBConnections.shared
        let oldID = connections.allIDs().last!
        let connectionCount = connections.allIDs().count
        let disconnectCount = TestDisconnectCounter.shared.snapshot()
        connections.notify(oldID)
        await wait { connections.isStopped(oldID) }
        check(SMBRecoveryStatus.shared.snapshot() != nil)
        let recoveryCheck = Task { try await access.checkConnection(settings: settings, password: "secret") }
        await wait { await access.waitingOperationCount == 1 }
        check(connections.allIDs().count == connectionCount)
        check(await server.waiting("list:scan"))
        connections.notify(oldID) // duplicate notification cannot keep aborting the connection
        await server.release("list:scan")
        do { _ = try await interruptedScan.value; preconditionFailure("discard interrupted scan") } catch is SMBRecoveryError { }
        _ = try await recoveryCheck.value
        check(SMBRecoveryStatus.shared.snapshot() == nil)
        check(connections.allIDs().count == connectionCount + 1)
        check(TestDisconnectCounter.shared.snapshot() >= disconnectCount + 1)
        // Late notification and an expired reader cannot affect the next generation.
        let fresh = try await access.openViewer(target: target, password: "secret")
        let freshID = connections.allIDs().last!
        connections.notify(oldID)
        _ = try await access.readViewer(fresh, offset: 0, count: 16)
        check(!connections.isStopped(freshID))
        await access.closeViewer(expired)
        check(!connections.isStopped(freshID))
        // Video range read interruption drains before new generation; old handles fail safely.
        await server.configure(data as Data, blocked: ["read:photo.jpg"])
        let interruptedRead = Task { try await access.readViewer(fresh, offset: 0, count: 16) }
        await wait { await server.waiting("read:photo.jpg") }
        connections.notify(freshID)
        await wait { connections.isStopped(freshID) }
        let readConnectionCount = connections.allIDs().count
        let nextOpen = Task { try await access.openViewer(target: target, password: "secret") }
        await wait { await access.waitingOperationCount == 1 }
        check(connections.allIDs().count == readConnectionCount)
        await server.release("read:photo.jpg")
        do { _ = try await interruptedRead.value; preconditionFailure("interrupted read") } catch is SMBRecoveryError { }
        let nextHandle = try await nextOpen.value
        await access.closeViewer(fresh)
        check(try await access.readViewer(nextHandle, offset: 0, count: 16) == (data as Data).prefix(16))
        await access.closeViewer(nextHandle)
        await access.disconnectWhenAvailable()
        // Cancellation beats retry classification after the old operation really finishes.
        await server.configure(data as Data, blocked: ["list:scan"])
        let cancelledRecovery = Task { try await access.scan(settings: settings, password: "secret", consume: { _, _ in }) }
        await wait { await server.waiting("list:scan") }
        let cancelledID = connections.allIDs().last!
        connections.notify(cancelledID)
        await wait { connections.isStopped(cancelledID) }
        cancelledRecovery.cancel()
        await server.release("list:scan")
        do { _ = try await cancelledRecovery.value; preconditionFailure("cancellation must win") } catch is CancellationError { }
        check(SMBRecoveryStatus.shared.snapshot() == nil)
        // Authentication and share permission failures never become automatic retry markers.
        for code: UInt32 in [0xC000006D, 0xC0000022] {
            await server.configure(data as Data, blocked: [])
            await server.failLogin(code)
            do {
                _ = try await access.scan(settings: settings, password: "secret", consume: { _, _ in })
                preconditionFailure("expected permission failure")
            } catch is SMBRecoveryError { preconditionFailure("permission must not retry") }
            catch { }
        }
        // A late successful response after an EPERM notification must also remain non-retryable.
        await server.configure(data as Data, blocked: ["list:scan"])
        await server.allowLateResult(true)
        let deniedScan = Task { try await access.scan(settings: settings, password: "secret", consume: { _, _ in }) }
        await wait { await server.waiting("list:scan") }
        let deniedID = connections.allIDs().last!
        connections.notify(deniedID, error: NWError.posix(.EPERM))
        await wait { connections.isStopped(deniedID) }
        await server.release("list:scan")
        do { _ = try await deniedScan.value; preconditionFailure("denied late result") }
        catch is SMBRecoveryError { preconditionFailure("permission notification must not retry") }
        catch { }
        await server.allowLateResult(false)
        check(SMBRecoveryStatus.shared.snapshot() == nil)
        // Manual switch rejects queued old settings and never force-releases the gate.
        let routeAccess = SMBAccessCoordinator()
        var routeSettings = settings
        routeSettings.libraryID = UUID(); routeSettings.routeVersion = UUID()
        await routeAccess.configureRoute(routeSettings.routeVersion)
        await server.configure(data as Data, blocked: ["list:scan"])
        let routeScan = Task { try await routeAccess.scan(settings: routeSettings, password: "secret", consume: { _, _ in }) }
        await wait { await server.waiting("list:scan") }
        let routeOldID = connections.allIDs().last!
        let queuedOld = Task { try await routeAccess.checkConnection(settings: routeSettings, password: "secret") }
        await wait { await routeAccess.waitingOperationCount == 1 }
        await routeAccess.pauseRouteRequests()
        await routeAccess.abortRoute()
        check(connections.isStopped(routeOldID))
        let routeCount = connections.allIDs().count
        let routeDrain = Task { await routeAccess.disconnectWhenAvailable() }
        await wait { await routeAccess.waitingOperationCount >= 2 }
        check(connections.allIDs().count == routeCount)
        await server.release("list:scan")
        do { _ = try await routeScan.value; preconditionFailure("manual abort must fail old scan") }
        catch is SMBRecoveryError { preconditionFailure("manual abort must not auto retry") }
        catch { }
        do { _ = try await queuedOld.value; preconditionFailure("stale queued settings") }
        catch is CancellationError { }
        await routeDrain.value
        var newRoute = routeSettings; newRoute.host = "100.92.22.5"; newRoute.routeVersion = UUID()
        try await routeAccess.establishRoute(settings: newRoute, password: "secret")
        await routeAccess.resumeRouteRequests(version: newRoute.routeVersion)
        let newRouteID = connections.allIDs().last!
        connections.notify(routeOldID)
        do { _ = try await routeAccess.checkConnection(settings: routeSettings, password: "secret"); preconditionFailure("late old settings") }
        catch is CancellationError { }
        check(!connections.isStopped(newRouteID))
        let routeTarget = MediaThumbnailTarget(key: target.key, path: target.path, fileSize: target.fileSize,
            fileExtension: target.fileExtension, settings: newRoute)
        let routeHandle = try await routeAccess.openViewer(target: routeTarget, password: "secret")
        await server.configure(data as Data, blocked: ["read:photo.jpg"])
        let routeRead = Task { try await routeAccess.readViewer(routeHandle, offset: 0, count: 16) }
        await wait { await server.waiting("read:photo.jpg") }
        await routeAccess.abortRoute()
        let videoDrain = Task { await routeAccess.disconnectWhenAvailable() }
        await wait { await routeAccess.waitingOperationCount == 1 }
        await server.release("read:photo.jpg")
        do { _ = try await routeRead.value; preconditionFailure("old range read") } catch { }
        await videoDrain.value
        try await routeAccess.establishRoute(settings: routeSettings, password: "secret")
        await routeAccess.resumeRouteRequests(version: routeSettings.routeVersion)
        do { _ = try await routeAccess.readViewer(routeHandle, offset: 0, count: 16); preconditionFailure("old stream") } catch { }
        await routeAccess.closeViewer(routeHandle)
        await routeAccess.disconnectWhenAvailable()
        print("PASS: manual route abort/drain, stale gate waiters and late notifications, no new connection before drain, old video reader rejected")
        // Probe deadline aborts only the independent probe, at each transport stage.
        let retained = SMBAccessCoordinator()
        await server.configure(data as Data, blocked: [])
        let retainedHandle = try await retained.openViewer(target: target, password: "secret")
        let retainedID = connections.allIDs().last!
        for stage in ["connect", "login", "list:scan"] {
            await retained.pauseRouteRequests()
            await server.configure(data as Data, blocked: [stage])
            let operationID = UUID(), probe = SMBAccessCoordinator(probeOperationID: UUID())
            // An operation ID from another transaction cannot start or stop this coordinator.
            do { try await probe.checkProbe(operationID: operationID, settings: settings, password: "secret"); preconditionFailure("wrong operation") }
            catch is CancellationError { }
            let actualProbe = SMBAccessCoordinator(probeOperationID: operationID)
            let pending = Task { try await actualProbe.checkProbe(operationID: operationID, settings: settings, password: "secret") }
            await wait { await server.waiting(stage) }
            let probeID = connections.allIDs().last!, countBeforeAbort = connections.allIDs().count
            await actualProbe.expireProbe(operationID: UUID())
            check(!connections.isStopped(probeID))
            await actualProbe.expireProbe(operationID: operationID)
            check(connections.isStopped(probeID) && !connections.isStopped(retainedID))
            do { _ = try await retained.readViewer(retainedHandle, offset: 0, count: 16); preconditionFailure("paused old requests") }
            catch is CancellationError { }
            let draining = Task { await actualProbe.finishProbe(operationID: operationID) }
            await wait { await actualProbe.waitingOperationCount == 1 }
            check(connections.allIDs().count == countBeforeAbort)
            if stage == "list:scan" { await server.allowLateResult(true) }
            await server.release(stage)
            do { try await pending.value; preconditionFailure("expired probe success") } catch { }
            await draining.value
            await server.allowLateResult(false)
            do { try await actualProbe.checkProbe(operationID: operationID, settings: settings, password: "secret"); preconditionFailure("reuse expired probe") }
            catch is CancellationError { }
            await retained.resumeRouteRequests(version: nil)
            check(try await retained.readViewer(retainedHandle, offset: 0, count: 16) == (data as Data).prefix(16))
            check(!connections.isStopped(retainedID))
        }
        let beforeStartID = UUID(), beforeStartProbe = SMBAccessCoordinator(probeOperationID: UUID())
        await beforeStartProbe.expireProbe(operationID: beforeStartID) // unrelated ID is a no-op
        let expiredBeforeID = UUID(), expiredBefore = SMBAccessCoordinator(probeOperationID: expiredBeforeID)
        let beforeCount = connections.allIDs().count
        await expiredBefore.expireProbe(operationID: expiredBeforeID)
        do { try await expiredBefore.checkProbe(operationID: expiredBeforeID, settings: settings, password: "secret"); preconditionFailure("connect after early expiry") }
        catch is CancellationError { }
        await expiredBefore.finishProbe(operationID: expiredBeforeID)
        check(connections.allIDs().count == beforeCount)
        await retained.closeViewer(retainedHandle); await retained.disconnectWhenAvailable()
        print("PASS: probe expiry during connect/login/list, operation isolation, real gate drain, no post-expiry connection, old reader remains usable")
        print("PASS: authentication/access denial and permission notification with late success are not retried")
        print("PASS: recovery abort bypasses gate, stalled transport blocks new connections, delayed notifications, stale handles, range read, cancellation")
        print("PASS: real coordinator with test SMB API: scan/thumbnail/metadata FIFO, close-before-handoff, connection check contention, cancelled queued scan, retry, no concurrent SMB calls")
    }
}
