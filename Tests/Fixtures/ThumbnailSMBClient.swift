// Test-only SMBClient module. API calls deliberately ignore Task cancellation,
// matching the cancellation constraint of SMBClient 0.3.1.
import Foundation
public actor TestSMBServer {
    public static let shared = TestSMBServer()
    public var events: [String] = []
    private var blocked: Set<String> = []
    private var gates: [String: CheckedContinuation<Void, Never>] = [:]
    private var contents = Data()
    private var failNextClose = false
    private var inFlight = 0
    public private(set) var maximumInFlight = 0
    public func configure(_ data: Data, blocked: Set<String>) {
        precondition(inFlight == 0)
        contents = data; self.blocked = blocked; events = []; maximumInFlight = 0
    }
    public func call(_ event: String) async {
        inFlight += 1; maximumInFlight = max(maximumInFlight, inFlight)
        events.append(event)
        if blocked.contains(event) { await withCheckedContinuation { gates[event] = $0 } }
        inFlight -= 1
    }
    public func failCloseOnce() { failNextClose = true }
    public func takeCloseFailure() -> Bool { defer { failNextClose = false }; return failNextClose }
    public func waiting(_ event: String) -> Bool { gates[event] != nil }
    public func release(_ event: String) { blocked.remove(event); gates.removeValue(forKey: event)?.resume() }
    public func size() -> UInt64 { UInt64(contents.count) }
    public func bytes(_ offset: UInt64, _ count: UInt32) -> Data {
        contents.subdata(in: Int(offset)..<min(contents.count, Int(offset) + Int(count)))
    }
}
public struct File: Sendable {
    public let name: String
    public let isDirectory: Bool
    public var size: UInt64 { 1 }
    public var creationTime: Date { .distantPast }
    public var lastWriteTime: Date { .distantPast }
}
public final class Session: @unchecked Sendable {
    public func connect() async throws { await TestSMBServer.shared.call("connect") }
    public func disconnect() { }
}
public final class SMBClient: @unchecked Sendable {
    public let session = Session()
    public init(host: String, port: Int) { }
    public func login(username: String, password: String, domain: String?) async throws { }
    public func connectShare(_ share: String) async throws { }
    public func listDirectory(path: String) async throws -> [File] {
        await TestSMBServer.shared.call("list:\(path)")
        return path == "scan" ? [File(name: "child", isDirectory: true)] : []
    }
    public func fileReader(path: String) -> FileReader { FileReader(path: path) }
}
public final class FileReader: @unchecked Sendable {
    let path: String
    init(path: String) { self.path = path }
    public var fileSize: UInt64 {
        get async throws { await TestSMBServer.shared.call("open:\(path)"); return await TestSMBServer.shared.size() }
    }
    public func read(offset: UInt64, length: UInt32) async throws -> Data {
        await TestSMBServer.shared.call("read:\(path)")
        return await TestSMBServer.shared.bytes(offset, length)
    }
    public func close() async throws {
        await TestSMBServer.shared.call("close:\(path)")
        if await TestSMBServer.shared.takeCloseFailure() { throw CocoaError(.fileReadUnknown) }
    }
}
public struct ErrorResponse: Error { public struct Header: Sendable { public var status: UInt32 }; public var header: Header }
public enum NTStatus { case logonFailure, accessDenied, other
    public init(_ code: UInt32) { self = .other }
}
