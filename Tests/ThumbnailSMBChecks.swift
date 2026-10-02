import Foundation
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
        let target = PhotoThumbnailTarget(key: key, path: "photo.jpg", fileSize: Int64(data.length), fileExtension: "jpg", settings: settings)
        let metadata = MetadataFixture(.init(id: UUID(), libraryID: key.libraryID, generation: UUID(),
            file: .init(path: "metadata.jpg", size: Int64(data.length), creation: .distantPast, modified: .distantPast)))
        await server.configure(data as Data, blocked: ["list:scan", "read:photo.jpg", "close:photo.jpg"])
        let scan = Task { try await access.scan(settings: settings, password: "secret", consume: { _,_ in }) }
        await wait { await server.waiting("list:scan") }
        let photo = Task { try await access.photoThumbnail(target: target, password: "secret") }
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
        let result = try await access.photoThumbnail(target: target, password: "secret")
        check(CGImageSourceCreateWithData(result as CFData, nil) != nil)
        await access.disconnectWhenAvailable()

        // Cancellation of a queued operation never releases the active owner's slot.
        await server.configure(data as Data, blocked: ["read:photo.jpg"])
        let active = Task { try await access.photoThumbnail(target: target, password: "secret") }
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
        _ = try await access.photoThumbnail(target: target, password: "secret")
        check(await server.events.filter { $0 == "connect" }.count == 2)
        await access.disconnectWhenAvailable()
        print("PASS: real coordinator with test SMB API: scan/thumbnail/metadata FIFO, close-before-handoff, connection check contention, cancelled queued scan, retry, no concurrent SMB calls")
    }
}
