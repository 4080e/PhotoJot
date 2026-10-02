import Foundation

// Coordinator内のフォルダ一覧／ファイル処理をFIFOで譲るための排他枠。
// 実行中の処理は所有者がcleanup後にreleaseする。待機のcancelだけで枠を解放しない。
actor SMBOperationGate {
    private var occupied = false
    private var waiting: [(UUID, CheckedContinuation<Void, Error>)] = []
    func acquire() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                if !occupied { occupied = true; continuation.resume() }
                else { waiting.append((id, continuation)) }
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    private func cancel(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.0 == id }) else { return }
        waiting.remove(at: index).1.resume(throwing: CancellationError())
    }
    func release() {
        if waiting.isEmpty { occupied = false }
        else { waiting.removeFirst().1.resume() }
    }
    #if DEBUG
    var waitingCount: Int { waiting.count }
    #endif
}
