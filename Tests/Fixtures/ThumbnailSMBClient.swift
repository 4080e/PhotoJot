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
    private var loginFailure: UInt32?
    private var ignoreDisconnectedResult = false
    public func failLogin(_ status: UInt32) { loginFailure = status }
    public func takeLoginFailure() -> UInt32? { defer { loginFailure = nil }; return loginFailure }
    public func allowLateResult(_ allowed: Bool) { ignoreDisconnectedResult = allowed }
    public func lateResultAllowed() -> Bool { ignoreDisconnectedResult }
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
public final class TestDisconnectCounter: @unchecked Sendable {
    public static let shared = TestDisconnectCounter()
    private let lock = NSLock()
    private var count = 0
    public func increment() { lock.lock(); count += 1; lock.unlock() }
    public func snapshot() -> Int { lock.lock(); defer { lock.unlock() }; return count }
}
public final class TestSMBConnections: @unchecked Sendable {
    public static let shared = TestSMBConnections()
    private let lock = NSLock()
    private var callbacks: [UUID: (Error) -> Void] = [:]
    private var ids: [UUID] = []
    private var stopped: Set<UUID> = []
    public func register(_ id: UUID) { lock.lock(); ids.append(id); lock.unlock() }
    public func set(_ id: UUID, _ callback: @escaping (Error) -> Void) { lock.lock(); callbacks[id] = callback; lock.unlock() }
    public func allIDs() -> [UUID] { lock.lock(); defer { lock.unlock() }; return ids }
    public func notify(_ id: UUID, error: Error = ConnectionError.disconnected) {
        lock.lock(); let callback = callbacks[id]; lock.unlock(); callback?(error)
    }
    public func stop(_ id: UUID) { lock.lock(); stopped.insert(id); lock.unlock() }
    public func isStopped(_ id: UUID) -> Bool { lock.lock(); defer { lock.unlock() }; return stopped.contains(id) }
}
public final class Session: @unchecked Sendable {
    public let id = UUID()
    public init() { TestSMBConnections.shared.register(id) }
    public func check() throws { if TestSMBConnections.shared.isStopped(id) { throw ConnectionError.disconnected } }
    public func connect() async throws { await TestSMBServer.shared.call("connect"); try check() }
    public func disconnect() { TestDisconnectCounter.shared.increment(); TestSMBConnections.shared.stop(id) }
}
public final class SMBClient: @unchecked Sendable {
    public var onDisconnected: (Error) -> Void = { _ in } { didSet { TestSMBConnections.shared.set(session.id, onDisconnected) } }
    public let session = Session()
    public init(host: String, port: Int) { }
    public func login(username: String, password: String, domain: String?) async throws {
        if let code = await TestSMBServer.shared.takeLoginFailure() { throw ErrorResponse(status: code) }
    }
    public func connectShare(_ share: String) async throws { }
    public func listDirectory(path: String) async throws -> [File] {
        try session.check()
        await TestSMBServer.shared.call("list:\(path)")
        if !(await TestSMBServer.shared.lateResultAllowed()) { try session.check() }
        return path == "scan" ? [File(name: "child", isDirectory: true)] : []
    }
    public func fileReader(path: String) -> FileReader { FileReader(path: path, session: session) }
}
public final class FileReader: @unchecked Sendable {
    let path: String
    let session: Session
    init(path: String, session: Session) { self.path = path; self.session = session }
    public var fileSize: UInt64 {
        get async throws { try session.check(); await TestSMBServer.shared.call("open:\(path)"); try session.check(); return await TestSMBServer.shared.size() }
    }
    public func read(offset: UInt64, length: UInt32) async throws -> Data {
        try session.check()
        await TestSMBServer.shared.call("read:\(path)")
        try session.check()
        return await TestSMBServer.shared.bytes(offset, length)
    }
    public func close() async throws {
        try session.check()
        await TestSMBServer.shared.call("close:\(path)")
        try session.check()
        if await TestSMBServer.shared.takeCloseFailure() { throw CocoaError(.fileReadUnknown) }
    }
}
public struct ErrorResponse: Error { public struct Header: Sendable { public var status: UInt32 }; public var header: Header; public init(status: UInt32) { header = Header(status: status) } }
public enum NTStatus { case logonFailure, accessDenied, other
    public init(_ code: UInt32) { self = code == 0xC000006D ? .logonFailure : code == 0xC0000022 ? .accessDenied : .other }
}

public enum ConnectionError: Error { case disconnected }
