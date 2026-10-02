import Foundation
import Observation
import SwiftUI
import CoreGraphics

// AppのscenePhaseと既存の設定操作から通知する小さな表示session。
// 通信の順序・要求集約はService/Coordinatorが所有する。
@MainActor @Observable final class ThumbnailSession {
    private(set) var revision = 0
    private var background = false
    private var editing = false
    private var checking = false
    var canGenerate: Bool { !background && !editing && !checking }
    @ObservationIgnored private let memory = ThumbnailMemoryCache()
    @ObservationIgnored private let cache: ThumbnailCache
    @ObservationIgnored private let resolve: @Sendable (UUID, UUID) async throws -> PhotoThumbnailTarget?
    @ObservationIgnored private let generator: ThumbnailService.Generator
    @ObservationIgnored private let disconnect: @Sendable () async -> Void
    @ObservationIgnored private var transition: Task<Void, Never>?
    @ObservationIgnored private lazy var service = ThumbnailService(cache: cache) { [weak self] key in
        guard let self, await self.canGenerate else { throw CancellationError() }
        let generate = self.generator
        return try await generate(key)
    }

    init(cache: ThumbnailCache, resolve: @escaping @Sendable (UUID, UUID) async throws -> PhotoThumbnailTarget?,
         generate: @escaping ThumbnailService.Generator, disconnect: @escaping @Sendable () async -> Void) {
        self.cache = cache; self.resolve = resolve; self.generator = generate; self.disconnect = disconnect
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        if phase == .background { background = true; reconcile() }
        else if phase == .active { background = false; reconcile() }
    }
    func setEditing(_ value: Bool) { editing = value; reconcile() }
    func beginConnectionCheck() async {
        checking = true; reconcile()
        await transition?.value
    }
    func endConnectionCheck() { checking = false; reconcile() }
    private func reconcile() {
        let allowed = canGenerate, service = service, previous = transition, disconnect = disconnect
        transition = Task {
            await previous?.value
            if allowed {
                await service.resumeGeneration()
                if canGenerate { revision += 1 }
            } else {
                await service.suspendAndWait()
                await disconnect()
            }
        }
    }

    // 既存更新の区切りで可視セルだけ再確認する。timeline自体はreloadしない。
    func revalidateVisibleItems() { revision += 1 }

    struct Result: Sendable {
        let key: ThumbnailKey
        let data: Data
    }
    func isCurrent(_ key: ThumbnailKey) async throws -> Bool {
        try await resolve(key.mediaEntryID, key.libraryID)?.key == key
    }
    // 採用済みキーの再描画は同期lookupだけ。NSCacheが退避した場合はtaskで再取得する。
    func cachedImage(for key: ThumbnailKey) -> CGImage? { memory.image(for: key) }

    func imageKey(id: UUID, libraryID: UUID) async throws -> ThumbnailKey? {
        guard let target = try await resolve(id, libraryID) else { return nil }
        try Task.checkCancellation()
        _ = try await memory.image(for: target.key) {
            try await self.service.thumbnail(for: target.key, allowGeneration: self.canGenerate)
        }
        try Task.checkCancellation()
        guard try await isCurrent(target.key) else { return nil }
        try Task.checkCancellation()
        return target.key
    }

    func imageData(id: UUID, libraryID: UUID) async throws -> Result? {
        guard let target = try await resolve(id, libraryID) else { return nil }
        try Task.checkCancellation()
        let data = try await service.thumbnail(for: target.key, allowGeneration: canGenerate)
        try Task.checkCancellation()
        guard let current = try await resolve(id, libraryID), current.key == target.key else { return nil }
        try Task.checkCancellation()
        return Result(key: target.key, data: data)
    }
}
