import SwiftUI
import AVKit
import Observation

@MainActor @Observable final class MediaViewerController {
    private(set) var activeItem: TimelineItem?
    let photo = PhotoResolution()
    var image: CGImage? { photo.image }
    private(set) var previewKey: ThumbnailKey?
    private(set) var previewImage: CGImage?
    @ObservationIgnored private var previewWork: Task<Void, Never>?
    @ObservationIgnored private var previewEpoch = UUID()
    private(set) var player: AVPlayer?
    private(set) var videoQuarterTurns = 0
    private(set) var isRotatingVideo = false
    var videoRotationError: String?
    @ObservationIgnored private var videoRotationWork: Task<Void, Never>?
    private(set) var message: String?
    private(set) var isLoading = false
    private(set) var isClosing = false
    @ObservationIgnored private let resolve: @Sendable (UUID, UUID) async throws -> MediaThumbnailTarget?
    @ObservationIgnored private let open: (MediaThumbnailTarget) async throws -> MediaViewerStream
    @ObservationIgnored private var stream: MediaViewerStream?
    @ObservationIgnored private var playback: MediaPlaybackResource?
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var cleanup: Task<Void, Never>?
    @ObservationIgnored private var observation: NSKeyValueObservation?
    @ObservationIgnored private var presentation: (item: TimelineItem, viewport: FullPhotoViewport)?
    @ObservationIgnored private var pendingSelection: (item: TimelineItem, viewport: FullPhotoViewport)?
    var rotationError: String?
    @ObservationIgnored private let loadRotation: @Sendable (UUID, UUID) async throws -> Int
    @ObservationIgnored private let saveRotation: @Sendable (Int, UUID, UUID) async throws -> Void
    @ObservationIgnored private var rotationSave: Task<Void, Never>?
    private var resumeAfterBackground = false
    // 復帰予約中は中断メッセージではなく、通常の読み込み表示を使う。
    var showsLoading: Bool { resumeAfterBackground || isLoading || pendingSelection != nil }
    private var awaitingAutoplay = false
    private var background = false
    private var editing = false

    init(resolve: @escaping @Sendable (UUID, UUID) async throws -> MediaThumbnailTarget?,
         loadRotation: @escaping @Sendable (UUID, UUID) async throws -> Int = { _, _ in 0 },
         saveRotation: @escaping @Sendable (Int, UUID, UUID) async throws -> Void = { _, _, _ in },
         open: @escaping (MediaThumbnailTarget) async throws -> MediaViewerStream) {
        self.resolve = resolve; self.open = open
        self.loadRotation = loadRotation; self.saveRotation = saveRotation
    }

    func rotatePhotoRight() {
        guard let item = activeItem, item.mediaType == "photo",
              image != nil, !showsLoading, !isClosing else { return }
        photo.zoom.rotateRight()
        enqueueRotationSave(photo.zoom.quarterTurns, for: item)
    }

    private func enqueueRotationSave(_ value: Int, for item: TimelineItem) {
        let previous = rotationSave
        rotationSave = Task {
            await previous?.value
            do { try await saveRotation(value, item.id, item.libraryID) }
            catch { rotationError = "回転角度を保存できませんでした。もう一度お試しください。" }
        }
    }

    func rotateVideoRight() {
        guard let media = activeItem, media.mediaType == "video", !showsLoading, !isClosing, !isRotatingVideo,
              let item = player?.currentItem, item.status == .readyToPlay else { return }
        let next = (videoQuarterTurns + 1) % 4
        isRotatingVideo = true
        videoRotationWork = Task {
            defer { isRotatingVideo = false }
            do {
                let composition = next == 0 ? nil : try await Self.videoComposition(asset: item.asset, quarterTurns: next)
                try Task.checkCancellation()
                guard player?.currentItem === item, !isClosing else { return }
                // Keep the item, timeline, rate and audio unchanged. Replace the
                // composition instance so paused frames can also be refreshed.
                item.videoComposition = composition
                videoQuarterTurns = next
                enqueueRotationSave(next, for: media)
            } catch is CancellationError {
            } catch {
                if !isClosing { videoRotationError = "この動画を回転できませんでした。" }
            }
        }
    }

    private static func videoComposition(asset: AVAsset, quarterTurns: Int) async throws -> AVVideoComposition {
        let tracks = try await asset.loadTracks(withMediaType: .video)
        // Do not guess the layout of multi-track movies.
        guard tracks.count == 1, let track = tracks.first else { throw ViewerFailure.unavailable }
        let size = try await track.load(.naturalSize)
        let preferred = try await track.load(.preferredTransform)
        let duration = try await asset.load(.duration)
        guard size.width > 0, size.height > 0, duration.isNumeric, duration > .zero else {
            throw ViewerFailure.unavailable
        }
        let base: AVVideoComposition = try await withCheckedThrowingContinuation { continuation in
            AVVideoComposition.videoComposition(withPropertiesOf: asset) { composition, error in
                if let composition { continuation.resume(returning: composition) }
                else { continuation.resume(throwing: error ?? ViewerFailure.unavailable) }
            }
        }
        try Task.checkCancellation()
        guard let composition = base.mutableCopy() as? AVMutableVideoComposition else { throw ViewerFailure.unavailable }
        let rotation = CGAffineTransform(rotationAngle: CGFloat(quarterTurns) * .pi / 2)
        let transform = preferred.concatenating(rotation)
        let bounds = CGRect(origin: .zero, size: size).applying(transform).standardized
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else {
            throw ViewerFailure.unavailable
        }
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(transform.concatenating(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY)), at: .zero)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        instruction.layerInstructions = [layer]
        composition.instructions = [instruction]
        // Round away tiny floating-point errors from quarter-turn transforms.
        composition.renderSize = CGSize(width: bounds.width.rounded(), height: bounds.height.rounded())
        return composition
    }

    // ページ確定時だけ呼ぶ。旧処理の終了中は最新の要求1件へ集約する。
    func select(item: TimelineItem, viewport: FullPhotoViewport, force: Bool = false) {
        guard viewport.valid, !editing else { return }
        if !force, activeItem == item, pendingSelection == nil, work != nil || message != nil { return }
        if !force, pendingSelection?.item == item { return }
        cancelAutomaticResume()
        pendingSelection = (item, viewport)
        activeItem = nil
        _ = requestStop(message: nil)
    }

    private func startPendingSelection() {
        guard !background, !editing, !isClosing, work == nil, let next = pendingSelection else { return }
        pendingSelection = nil
        start(item: next.item, viewport: next.viewport)
    }

    func start(item: TimelineItem, viewport: FullPhotoViewport) {
        guard work == nil, !isClosing, viewport.valid else { return }
        guard !background, !editing else {
            message = "現在メディアを読み込めません。接続設定を閉じ、再読み込みしてください。"
            return
        }
        activeItem = item
        presentation = (item, viewport)
        player = nil; message = nil; isLoading = true
        work = Task {
            do {
                guard let target = try await resolve(item.id, item.libraryID), target.key.generation == item.generation else { throw ViewerFailure.changed }
                try Task.checkCancellation()
                let opened = try await open(target)
                stream = opened
                try Task.checkCancellation()
                // 各rangeの前後でも現在generationを確認。旧handleと新内容を混ぜない。
                let resolve = resolve
                let read: @Sendable (UInt64, Int) async throws -> Data = { offset, count in
                    guard try await resolve(item.id, item.libraryID)?.key == target.key else { throw ViewerFailure.changed }
                    let data = try await opened.read(offset, count)
                    guard try await resolve(item.id, item.libraryID)?.key == target.key else { throw ViewerFailure.changed }
                    return data
                }
                if VideoThumbnailPolicy.supports(target.fileExtension) {
                    let resource = try MediaPlaybackResource(format: target.fileExtension, size: UInt64(target.fileSize), read: read)
                    playback = resource
                    guard try await resource.asset.load(.isPlayable) else { throw ViewerFailure.unavailable }
                    try Task.checkCancellation()
                    guard try await resolve(item.id, item.libraryID)?.key == target.key else { throw ViewerFailure.changed }
                    let rotation = try await loadRotation(item.id, item.libraryID)
                    var composition: AVVideoComposition?
                    var appliedRotation = 0
                    if rotation != 0 {
                        do {
                            composition = try await Self.videoComposition(asset: resource.asset, quarterTurns: rotation)
                            appliedRotation = rotation
                        } catch is CancellationError { throw CancellationError() }
                        catch {
                            if !isClosing { videoRotationError = "この動画を回転できませんでした。" }
                        }
                    }
                    try Task.checkCancellation()
                    guard try await resolve(item.id, item.libraryID)?.key == target.key else { throw ViewerFailure.changed }
                    videoQuarterTurns = appliedRotation
                    installPlayer(resource.asset, composition: composition)

                } else {
                    let rotation = try await loadRotation(item.id, item.libraryID)
                    try Task.checkCancellation()
                    let load = Task.detached { try await PhotoViewerImage.load(size: UInt64(target.fileSize), viewport: viewport, read: read) }
                    let decoded = try await withTaskCancellationHandler { try await load.value } onCancel: { load.cancel() }
                    try Task.checkCancellation()
                    guard try await resolve(item.id, item.libraryID)?.key == target.key else { throw ViewerFailure.changed }
                    await opened.close(); stream = nil
                    try Task.checkCancellation()
                    guard try await resolve(item.id, item.libraryID)?.key == target.key else { throw ViewerFailure.changed }
                    try Task.checkCancellation()
                    photo.install(decoded, isCurrent: { try await resolve(item.id, item.libraryID)?.key == target.key })
                    photo.zoom.restoreRotation(rotation)
                }
                isLoading = false
            } catch {
                if !isClosing { cancelAutomaticResume() }
                await releaseResources()
                if !isClosing {
                    message = error is ViewerFailure ? "ファイルが変更されたか、表示できませんでした。timelineを更新して再度開いてください。" : "メディアを取得できませんでした。接続先を確認してください。"
                    isLoading = false
                }
            }
        }
    }

    private func installPlayer(_ asset: AVURLAsset, composition: AVVideoComposition?) {
        let playerItem = AVPlayerItem(asset: asset)
        // Apply before exposing the player or starting autoplay to avoid an unrotated first frame.
        playerItem.videoComposition = composition
        player = AVPlayer(playerItem: playerItem)
        awaitingAutoplay = true
        observation = playerItem.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self, self.player?.currentItem === item,
                      !self.isClosing, !self.background, !self.editing else { return }
                if item.status == .readyToPlay, self.awaitingAutoplay {
                    self.awaitingAutoplay = false
                    self.player?.play()
                } else if item.status == .failed {
                    await self.stop(message: "動画を再生できませんでした。接続先またはファイルを確認してください。")
                }
            }
        }
    }

    // Keep only the current page's lightweight cache image, independently of media cleanup.
    func preparePreview(for item: TimelineItem, thumbnails: ThumbnailSession) {
        clearPreview()
        guard !editing, presentation?.item == item || pendingSelection?.item == item else { return }
        let key = ThumbnailSession.placeholderKey(for: item)
        let epoch = previewEpoch
        previewKey = key
        previewImage = thumbnails.cachedImage(for: key)
        previewWork = Task {
            do {
                let image = try await thumbnails.cachedImageOnly(for: key)
                try Task.checkCancellation()
                guard previewEpoch == epoch else { return }
                previewImage = image
            } catch is CancellationError {
                // Background media cancellation must not remove an accepted preview.
            } catch {
                // A cache read failure leaves an already accepted lightweight image usable.
            }
        }
    }
    private func clearPreview() {
        previewEpoch = UUID(); previewWork?.cancel(); previewWork = nil
        previewKey = nil; previewImage = nil
    }

    // 明示的な終了・手動再試行・設定変更は自動再開予約も破棄する。
    func cancelAutomaticResume() {
        clearPreview()
        pendingSelection = nil
        presentation = nil
        resumeAfterBackground = false
    }

    func stop(message: String? = nil) async {
        cancelAutomaticResume()
        await requestStop(message: message).value
    }

    // 停止要求を同期的に登録。全waiterが状態の解放まで待ってから戻る。
    private func requestStop(message: String?) -> Task<Void, Never> {
        if let cleanup { return cleanup }
        isClosing = true
        videoRotationWork?.cancel()
        videoQuarterTurns = 0
        videoRotationError = nil
        work?.cancel(); playback?.cancel(); photo.cancel()
        player?.pause(); player?.replaceCurrentItem(with: nil)
        let task = Task {
            await work?.value
            await videoRotationWork?.value
            videoRotationWork = nil
            await rotationSave?.value
            rotationSave = nil
            await releaseResources()
            work = nil; isLoading = false
            self.message = message
            cleanup = nil; isClosing = false
            startPendingSelection()
            resumeIfNeeded()
        }
        cleanup = task
        return task
    }
    private func releaseResources() async {
        await photo.clear()
        awaitingAutoplay = false
        observation?.invalidate(); observation = nil
        player?.pause(); player?.replaceCurrentItem(with: nil); player = nil
        let oldPlayback = playback, oldStream = stream
        playback = nil; stream = nil
        await oldPlayback?.stop()
        await oldStream?.close()
    }
    private func resumeIfNeeded() {
        guard resumeAfterBackground, !background, !editing, !isClosing,
              work == nil, let presentation else { return }
        resumeAfterBackground = false
        start(item: presentation.item, viewport: presentation.viewport)
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        if phase == .background {
            background = true
            // 実エラーや未表示状態は自動再試行の対象にしない。
            if presentation != nil, message == nil, !isClosing {
                resumeAfterBackground = true
                _ = requestStop(message: "閲覧を中断しました。再読み込みできます。")
            }
        } else if phase == .active {
            background = false
            startPendingSelection()
            resumeIfNeeded()
        }
    }
    func setEditing(_ value: Bool) {
        editing = value
        if value {
            cancelAutomaticResume()
            _ = requestStop(message: "接続設定の変更により閲覧を中断しました。")
        }
    }
}
