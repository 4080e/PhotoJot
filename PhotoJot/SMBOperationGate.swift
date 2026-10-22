import Foundation

// Coordinator内のフォルダ一覧／ファイル処理をFIFOで譲るための排他枠。
// 実行中の処理は所有者がcleanup後にreleaseする。待機のcancelだけで枠を解放しない。
actor SMBOperationGate {
    #if DEBUG
    private var diagnosticOwner: UUID?
    #endif
    private var occupied = false
    private var waiting: [(UUID, CheckedContinuation<Void, Error>)] = []
    func acquire(operation: UUID? = nil) async throws {
        let id = UUID()
        #if DEBUG
        SMBDiagnostics.shared.begin("gate parent=\(operation.map { String($0.uuidString.prefix(8)) } ?? "-")", id: id, parent: operation)
        SMBDiagnostics.shared.event("acquire waiting", id: id)
        #endif
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else {
                    #if DEBUG
                    SMBDiagnostics.shared.end(id, outcome: "gate cancelled")
                    #endif
                    continuation.resume(throwing: CancellationError()); return
                }
                if !occupied {
                    occupied = true
                    #if DEBUG
                    diagnosticOwner = id
                    SMBDiagnostics.shared.event("acquired", id: id)
                    #endif
                    continuation.resume()
                }
                else { waiting.append((id, continuation)) }
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    private func cancel(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.0 == id }) else { return }
        #if DEBUG
        SMBDiagnostics.shared.end(id, outcome: "gate waiting cancelled")
        #endif
        waiting.remove(at: index).1.resume(throwing: CancellationError())
    }
    func release() {
        #if DEBUG
        if let id = diagnosticOwner { SMBDiagnostics.shared.end(id, outcome: "released") }
        diagnosticOwner = waiting.first?.0
        if let id = diagnosticOwner { SMBDiagnostics.shared.event("acquired", id: id) }
        #endif
        if waiting.isEmpty { occupied = false }
        else { waiting.removeFirst().1.resume() }
    }
    #if DEBUG
    var waitingCount: Int { waiting.count }
    #endif
}
