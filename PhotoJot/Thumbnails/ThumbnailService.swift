import Foundation

actor ThumbnailService {
    // generatorの返却値は完成したJPEGデータ。cacheも同じ形式で保存・返却する。
    typealias Generator = @Sendable (ThumbnailKey) async throws -> Data
    enum GenerationError: Error { case notConfigured }

    private final class Job {
        let key: ThumbnailKey
        let id = UUID()
        var users: [UUID: CheckedContinuation<Data, Error>] = [:]
        init(key: ThumbnailKey) { self.key = key }
    }
    private let cache: ThumbnailCache
    private let generate: Generator
    private var jobs: [ThumbnailKey: Job] = [:]
    private var queue: [Job] = []
    private var active: Job?
    private var worker: Task<Void, Never>?

    // generatorは成功・失敗・中断ともreader等のcleanupを終えてからreturn/throwする契約。
    init(cache: ThumbnailCache, generate: @escaping Generator) {
        self.cache = cache; self.generate = generate
    }

    func thumbnail(for key: ThumbnailKey) async throws -> Data {
        try Task.checkCancellation()
        // 各readはcache専用queueへ渡す。生成枠の空きを待たない。
        if let data = await cache.load(key) {
            try Task.checkCancellation()
            return data
        }
        try Task.checkCancellation()
        let user = UUID()
        let data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                let job: Job
                if let existing = jobs[key] { job = existing }
                else {
                    job = Job(key: key); jobs[key] = job; queue.append(job)
                }
                job.users[user] = continuation
                startNext()
            }
        } onCancel: {
            Task { await self.cancel(user: user, key: key) }
        }
        try Task.checkCancellation()
        return data
    }

    #if DEBUG
    // 要求の登録完了を決定的に検証するための読み取り専用診断。
    func requestCount(for key: ThumbnailKey) -> Int { jobs[key]?.users.count ?? 0 }
    #endif

    private func cancel(user: UUID, key: ThumbnailKey) {
        guard let job = jobs[key], let continuation = job.users.removeValue(forKey: user) else { return }
        continuation.resume(throwing: CancellationError())
        guard job.users.isEmpty else { return }
        jobs.removeValue(forKey: key)
        if active?.id == job.id {
            worker?.cancel()
            // activeはfinishedまで保持。同じkeyの新要求も次のjobとして待機する。
        } else { queue.removeAll { $0.id == job.id } }
    }

    private func startNext() {
        guard active == nil, !queue.isEmpty else { return }
        let job = queue.removeFirst()
        active = job
        let key = job.key, id = job.id, cache = cache, generate = generate
        worker = Task.detached {
            let result: Result<Data, Error>
            do {
                try Task.checkCancellation()
                // 最初のmissと登録の間に別要求がcacheを完成させた場合も再生成しない。
                if let cached = await cache.load(key) {
                    try Task.checkCancellation()
                    result = .success(cached)
                } else {
                    try Task.checkCancellation()
                    let data = try await generate(key)
                    try Task.checkCancellation()
                    try await cache.save(data, for: key)
                    try Task.checkCancellation()
                    result = .success(data)
                }
            } catch { result = .failure(error) }
            await self.finished(id: id, result: result)
        }
    }

    private func finished(id: UUID, result: Result<Data, Error>) {
        guard let job = active, job.id == id else { return }
        if jobs[job.key]?.id == id { jobs.removeValue(forKey: job.key) }
        for continuation in job.users.values { continuation.resume(with: result) }
        active = nil; worker = nil
        startNext()
    }
}
