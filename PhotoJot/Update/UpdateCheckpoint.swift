import Foundation

nonisolated enum UpdateCheckpoint {
    static let listingInterval = 256

    // 保存transactionの外側だけで呼ぶ。yield後にも確認し、次の通信・保存へ進ませない。
    static func yield() async throws {
        try Task.checkCancellation()
        await Task.yield()
        try Task.checkCancellation()
    }
}
