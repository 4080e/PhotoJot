#if DEBUG
import Foundation
import os

// Bounded, process-local diagnostics. Never stores paths, credentials or error descriptions.
// Its lock protects only memory; no SMB work, await or logging runs under the lock.
nonisolated final class SMBDiagnostics: @unchecked Sendable {
    static let shared = SMBDiagnostics()
    struct Entry: Sendable {
        let id: UUID
        let kind: String
        let parent: UUID?
        let start: TimeInterval
        var stage: String
    }
    private let lock = NSLock()
    private var active: [UUID: Entry] = [:]
    private var recent: [String] = []
    private let logger = Logger(subsystem: "PhotoJot", category: "SMBDiagnostics")
    @TaskLocal static var operation: UUID?

    @discardableResult func begin(_ kind: String, id: UUID = UUID(), parent: UUID? = nil) -> UUID {
        lock.lock()
        active[id] = Entry(id: id, kind: kind, parent: parent, start: ProcessInfo.processInfo.systemUptime, stage: "begin")
        lock.unlock()
        event("begin \(kind)", id: id)
        return id
    }
    func event(_ stage: String, id: UUID? = SMBDiagnostics.operation) {
        let label = id.map { String($0.uuidString.prefix(8)) } ?? "-"
        lock.lock()
        var elapsed: TimeInterval = 0
        if let id, var entry = active[id] {
            elapsed = ProcessInfo.processInfo.systemUptime - entry.start
            entry.stage = stage; active[id] = entry
        }
        let line = String(format: "[%@] +%.2fs %@", label, elapsed, stage)
        recent.append(line)
        if recent.count > 80 { recent.removeFirst(recent.count - 80) }
        lock.unlock()
        logger.debug("\(line, privacy: .public)")
    }
    func end(_ id: UUID, outcome: String = "end") {
        event(outcome, id: id)
        lock.lock()
        active.removeValue(forKey: id)
        lock.unlock()
    }
    func snapshot() -> (active: [Entry], recent: [String]) {
        lock.lock(); defer { lock.unlock() }
        return (active.values.sorted { $0.start < $1.start }, recent)
    }
    static func measure<T>(_ kind: String, _ body: () async throws -> T) async rethrows -> T {
        let parent = operation.map { String($0.uuidString.prefix(8)) } ?? "-"
        let id = shared.begin("\(kind) parent=\(parent)", parent: operation)
        do {
            let value = try await body()
            shared.end(id)
            return value
        } catch {
            shared.end(id, outcome: error is CancellationError ? "cancelled" : "error")
            throw error
        }
    }
}
#endif
