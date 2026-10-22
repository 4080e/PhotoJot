import Foundation
import SwiftUI

nonisolated enum SMBRecoveryError: LocalizedError {
    case interrupted
    var errorDescription: String? { "接続が切れました。旧通信の終了後に再接続します。" }
}

// A read-only UI snapshot never waits for the SMB gate. No timeout releases resources.
nonisolated final class SMBRecoveryStatus: @unchecked Sendable {
    static let shared = SMBRecoveryStatus()
    struct Waiting: Sendable { let generation: UUID; let since: TimeInterval }
    private let lock = NSLock()
    private var waiting: Waiting?
    func began(_ generation: UUID) {
        lock.lock(); defer { lock.unlock() }
        if waiting?.generation != generation { waiting = Waiting(generation: generation, since: ProcessInfo.processInfo.systemUptime) }
    }
    func ended(_ generation: UUID) {
        lock.lock(); defer { lock.unlock() }
        if waiting?.generation == generation { waiting = nil }
    }
    func snapshot() -> Waiting? { lock.lock(); defer { lock.unlock() }; return waiting }
}

struct SMBRecoveryBanner: View {
    var body: some View {
        SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { _ in
            if let waiting = SMBRecoveryStatus.shared.snapshot() {
                let elapsed = ProcessInfo.processInfo.systemUptime - waiting.since
                VStack(alignment: .leading, spacing: 4) {
                    Text("切断した通信の終了を待っています（\(elapsed, specifier: "%.0f")秒）")
                    if elapsed >= 15 {
                        Text("安全のため新しい接続を開始していません。終了しない場合はアプリを再起動してください。")
                    }
                }.font(.footnote).frame(maxWidth: .infinity, alignment: .leading).padding().background(.bar)
            }
        }
    }
}
