import Foundation
import AVFoundation

// 全可変状態とAVFoundation requestへの操作はqueueに限定。
// SMB await中もqueueをブロックしない。readerは同時に1 readだけ。
nonisolated final class RangeThumbnailLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "PhotoJot.range-thumbnail.loader")
    private let size: UInt64
    private let requestLimit: Int
    private let recordTransfers: Bool
    private let type: String
    private let read: @Sendable (UInt64, Int) async throws -> Data
    private var state = RangeThumbnailSnapshot()
    private struct Pending {
        let request: AVAssetResourceLoadingRequest
        let log: Int
        var cursor: RangeThumbnailCursor
    }
    private var pending: [ObjectIdentifier: Pending] = [:]
    private var order: [ObjectIdentifier] = []
    private var inFlight = false
    private var stopped = false
    private var waiters: [CheckedContinuation<RangeThumbnailSnapshot, Never>] = []
    init(size: UInt64, type: String, limit: UInt64 = 256 * 1_048_576, requestLimit: Int = 4096, callLimit: Int = 65_536, recordTransfers: Bool = false, read: @escaping @Sendable (UInt64, Int) async throws -> Data) {
        self.size = size; self.type = type; self.read = read
        self.requestLimit = requestLimit; self.recordTransfers = recordTransfers
        state.ledger = RangeThumbnailLedger(limit: limit, callLimit: callLimit)
    }
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        dispatchPrecondition(condition: .onQueue(queue))
        state.loading += 1
        guard !stopped, state.loading <= requestLimit else {
            if !stopped { fail(RangeThumbnailError.invalid("loading request数制限超過")) }
            request.finishLoading(with: RangeThumbnailError.invalid(state.error ?? "生成終了")); return true
        }
        if let info = request.contentInformationRequest {
            state.content += 1
            info.contentLength = Int64(size); info.contentType = type; info.isByteRangeAccessSupported = true
        }
        guard let data = request.dataRequest else { request.finishLoading(); return true }
        state.data += 1
        if data.requestsAllDataToEndOfResource { state.allToEnd += 1 }
        let index = state.logs.count
        state.logs.append(.init(id: state.loading, requested: data.requestedOffset, current: data.currentOffset,
            length: data.requestedLength, allToEnd: data.requestsAllDataToEndOfResource))
        do {
            let cursor = try RangeThumbnailCursor(size: size, requested: data.requestedOffset, current: data.currentOffset,
                length: data.requestedLength, allToEnd: data.requestsAllDataToEndOfResource)
            let id = ObjectIdentifier(request)
            pending[id] = Pending(request: request, log: index, cursor: cursor); order.append(id)
            pump()
        } catch {
            state.logs[index].status = "error: \(error)"; request.finishLoading(with: error)
        }
        return true
    }
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel request: AVAssetResourceLoadingRequest) {
        dispatchPrecondition(condition: .onQueue(queue))
        state.cancelCallbacks += 1
        cancel(ObjectIdentifier(request), finish: false)
        pump()
    }
    private func cancel(_ id: ObjectIdentifier, finish: Bool) {
        guard var value = pending[id], !value.cursor.cancelled else { return }
        value.cursor.cancelled = true; pending[id] = value
        state.cancellations += 1; state.logs[value.log].status = "cancel"
        if finish && !value.request.isCancelled && !value.request.isFinished { value.request.finishLoading(with: CancellationError()) }
    }
    private func fail(_ error: Error) {
        state.error = String(describing: error); stopped = true
        for (_, item) in pending {
            if !item.cursor.cancelled {
                state.logs[item.log].status = "error: \(error)"
                if !item.request.isCancelled && !item.request.isFinished { item.request.finishLoading(with: error) }
            }
        }
        pending.removeAll(); order.removeAll()
        drain()
    }
    private func pump() {
        guard !inFlight else { return }
        while let id = order.first {
            guard let item = pending[id] else { order.removeFirst(); continue }
            if item.cursor.cancelled || item.request.isCancelled {
                cancel(id, finish: false); pending.removeValue(forKey: id); order.removeFirst(); continue
            }
            guard !stopped else { return }
            guard let (offset, count) = item.cursor.next() else {
                state.logs[item.log].status = "完了"; item.request.finishLoading()
                pending.removeValue(forKey: id); order.removeFirst(); continue
            }
            do { try state.ledger.begin(count) } catch { fail(error); return }
            state.logs[item.log].status = "read中"
            inFlight = true
            let read = read
            Task.detached {
                let start = ProcessInfo.processInfo.systemUptime
                let result: Result<Data, Error>
                do { result = .success(try await read(offset, count)) } catch { result = .failure(error) }
                let elapsed = ProcessInfo.processInfo.systemUptime - start
                self.queue.async { self.received(result, id: id, log: item.log, offset: offset, count: count, elapsed: elapsed) }
            }
            return
        }
        drain()
    }
    private func received(_ result: Result<Data, Error>, id: ObjectIdentifier, log: Int, offset: UInt64, count: Int, elapsed: Double) {
        inFlight = false; state.ledger.wait += elapsed
        do {
            let data = try result.get()
            try state.ledger.record(offset: offset, count: data.count)
            state.logs[log].bytes += UInt64(data.count)
            if recordTransfers { state.transfers.append(.init(offset: offset, bytes: data.count)) }
            if state.ledger.isLimitReached { fail(RangeThumbnailError.invalid("取得上限到達")); return }
            // didCancel/stop後の返却も集計するが、respondと次readは行わない。
            if var item = pending[id], !stopped {
                if item.request.isCancelled { cancel(id, finish: false) }
                else if !item.cursor.cancelled {
                    guard data.count == count else { throw RangeThumbnailError.invalid("SMB short/oversized read") }
                    if try item.cursor.accept(data.count) {
                        pending[id] = item
                        item.request.dataRequest?.respond(with: data)
                        // 大きなto-EOF要求で他の管理情報要求を塞がない。readは常に1本。
                        if let index = order.firstIndex(of: id) { order.remove(at: index); order.append(id) }
                    }
                }
            }
        } catch {
            if !stopped, pending[id]?.cursor.cancelled == false { fail(error) }
        }
        pump(); drain()
    }
    // read発行数は発行時、bytes/read待ちは返却時に計上。in-flight中も取得可能。
    func snapshot() async -> RangeThumbnailSnapshot {
        await withCheckedContinuation { continuation in
            queue.async {
                self.state.capturedAt = ProcessInfo.processInfo.systemUptime
                continuation.resume(returning: self.state)
            }
        }
    }
    func cancelAll() {
        queue.async {
            self.stopped = true
            for id in self.order { self.cancel(id, finish: true) }
            self.pump(); self.drain()
        }
    }
    func finish() async -> RangeThumbnailSnapshot {
        await withCheckedContinuation { continuation in
            queue.async {
                self.waiters.append(continuation); self.stopped = true
                for id in self.order { self.cancel(id, finish: true) }
                self.pump(); self.drain()
            }
        }
    }
    private func drain() {
        guard stopped, !inFlight else { return }
        pending.removeAll(); order.removeAll()
        state.capturedAt = ProcessInfo.processInfo.systemUptime
        let waiting = waiters; waiters.removeAll()
        for waiter in waiting { waiter.resume(returning: state) }
    }
}
