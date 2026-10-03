import Foundation
import Network
import SMBClient

// 全SMB処理は同じ接続とFIFO枠を利用する。scanはフォルダ、metadataはファイルで譲る。
actor SMBAccessCoordinator {
    private let gate = SMBOperationGate()
    private var viewerReaders: [UUID: (FileReader, UInt64)] = [:]
    private var client: SMBClient?
    private var connectedSettings: SMBConnectionSettings?
    private var connectedPassword: String?
    #if DEBUG
    var waitingOperationCount: Int { get async { await gate.waitingCount } }
    #endif

    private func disconnect() {
        viewerReaders.removeAll()
        client?.session.disconnect(); client = nil
        connectedSettings = nil; connectedPassword = nil
    }

    func disconnectWhenAvailable() async {
        // cleanupは呼び出し元Taskのcancelにも関係なく最後まで待つ。
        let cleanup = Task {
            do { try await gate.acquire() } catch { return }
            disconnect()
            await gate.release()
        }
        await cleanup.value
    }

    private func withClient<T: Sendable>(settings: SMBConnectionSettings, password: String,
                                        operation: (SMBClient) async throws -> T) async throws -> T {
        try await gate.acquire()
        do {
            try Task.checkCancellation()
            if connectedSettings != settings || connectedPassword != password { disconnect() }
            if client == nil {
                guard (1...65535).contains(settings.port) else { throw IndexFailure.invalidState }
                let next = SMBClient(host: settings.host, port: settings.port)
                client = next
                try await next.session.connect(); try Task.checkCancellation()
                try await next.login(username: settings.username, password: password,
                                     domain: settings.domain.isEmpty ? nil : settings.domain)
                try Task.checkCancellation()
                try await next.connectShare(settings.share); try Task.checkCancellation()
                connectedSettings = settings; connectedPassword = password
            }
            let value = try await operation(client!)
            try Task.checkCancellation()
            await gate.release()
            return value
        } catch {
            disconnect()
            await gate.release()
            try Task.checkCancellation()
            throw error
        }
    }

    func checkConnection(settings: SMBConnectionSettings, password: String) async throws -> Int {
        do {
            return try await withClient(settings: settings, password: password) { client in
                // 接続確認後は認証情報を含むsessionを保持しない。
                defer { disconnect() }
                let entries = try await client.listDirectory(path: settings.rootPath)
                return entries.filter { $0.name != "." && $0.name != ".." }.count
            }
        } catch is CancellationError { throw CancellationError() }
        catch { throw Self.failure(error, stage: "接続確認") }
    }

    func thumbnail(target: MediaThumbnailTarget, password: String) async throws -> Data {
        try await withClient(settings: target.settings, password: password) { client in
            guard target.fileSize > 0, !target.path.hasPrefix("/"),
                  !target.path.replacingOccurrences(of: "\\", with: "/").split(separator: "/").contains("..") else {
                throw IndexFailure.invalidState
            }
            let reader = client.fileReader(path: target.path)
            do {
                let size = try await reader.fileSize
                try Task.checkCancellation()
                guard size == UInt64(target.fileSize) else { throw IndexFailure.invalidState }
                let source = SMBThumbnailReader(reader: reader)
                let data: Data
                if VideoThumbnailPolicy.supports(target.fileExtension) {
                    // reader/sessionを共有するため、全rangeのdrainまで同じSMB枠を保持。
                    data = try await VideoThumbnailGenerator.generate(format: target.fileExtension, size: size) {
                        try await source.read(offset: $0, count: $1)
                    }
                } else {
                    data = try await PhotoThumbnailGenerator.generate(format: target.fileExtension, size: size) {
                        try await source.read(offset: $0, count: $1)
                    }
                }
                try await reader.close()
                try Task.checkCancellation()
                return data
            } catch {
                try? await reader.close()
                try Task.checkCancellation()
                throw error
            }
        }
    }

    // Viewerはreaderを保持するが、各readの間ではSMB枠を譲る。
    // disconnect時に全handleを失効させ、別接続で古いreaderを使わない。
    func openViewer(target: MediaThumbnailTarget, password: String) async throws -> UUID {
        try await withClient(settings: target.settings, password: password) { client in
            let path = target.path.replacingOccurrences(of: "\\", with: "/")
            guard target.fileSize > 0, !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { throw IndexFailure.invalidState }
            let file = client.fileReader(path: target.path)
            do {
                let size = try await file.fileSize
                try Task.checkCancellation()
                guard size == UInt64(target.fileSize) else { throw IndexFailure.invalidState }
                let id = UUID()
                viewerReaders[id] = (file, size)
                return id
            } catch { try? await file.close(); throw error }
        }
    }

    func readViewer(_ id: UUID, offset: UInt64, count: Int) async throws -> Data {
        try await gate.acquire()
        do {
            try Task.checkCancellation()
            guard let (reader, size) = viewerReaders[id], count > 0, count <= 1_048_576,
                  offset <= size, UInt64(count) <= size - offset else { throw IndexFailure.invalidState }
            let data = try await reader.read(offset: offset, length: UInt32(count))
            try Task.checkCancellation()
            guard data.count == count else { throw IndexFailure.invalidState }
            await gate.release()
            return data
        } catch {
            // 失効handleは現在の別接続を切断しない。
            if viewerReaders[id] != nil { disconnect() }
            await gate.release()
            try Task.checkCancellation()
            throw error
        }
    }

    func closeViewer(_ id: UUID) async {
        let cleanup = Task {
            do { try await gate.acquire() } catch { return }
            if let (reader, _) = viewerReaders.removeValue(forKey: id) {
                do { try await reader.close() } catch { disconnect() }
            }
            await gate.release()
        }
        await cleanup.value
    }

    func scan(settings: SMBConnectionSettings, password: String,
              consume: @Sendable ([ScannedMedia], ScanProgress) async throws -> Void) async throws -> ScanProgress {
        var pending = [settings.rootPath]
        var batch: [ScannedMedia] = []
        var progress = ScanProgress()
        while let directory = pending.popLast() {
            try await UpdateCheckpoint.yield()
            let entries: [File]
            // SMBClient 0.3.1の一覧取得はTaskキャンセル非対応。応答後に必ず確認する。
            do {
                entries = try await withClient(settings: settings, password: password) {
                    try await $0.listDirectory(path: directory)
                }
            }
            catch is CancellationError { throw CancellationError() }
            catch {
                try Task.checkCancellation()
                throw Self.failure(error, stage: "フォルダの一覧取得")
            }
            try Task.checkCancellation()
            progress.folders += 1
            for (index, entry) in entries.enumerated() {
                // 対象外ファイル・directory・dot entryも件数に含める。
                if index % UpdateCheckpoint.listingInterval == 0 { try await UpdateCheckpoint.yield() }
                try Task.checkCancellation()
                if entry.name == "." || entry.name == ".." { continue }
                let path = directory.isEmpty ? entry.name : directory + "/" + entry.name
                if entry.isDirectory {
                    pending.append(path)
                } else {
                    progress.files += 1
                    if ScannedMedia.isSupported(entry.name) {
                        guard let size = Int64(exactly: entry.size) else { throw IndexFailure.invalidState }
                        progress.media += 1
                        batch.append(ScannedMedia(path: path, size: size,
                                                  creation: entry.creationTime, modified: entry.lastWriteTime))
                        if batch.count == MediaRepository.batchSize {
                            try await UpdateCheckpoint.yield()
                            try await consume(batch, progress)
                            batch.removeAll(keepingCapacity: true)
                            try await UpdateCheckpoint.yield()
                        }
                    }
                }
            }
            // 対象メディアのないフォルダでも進捗とキャンセルを反映する。
            try await UpdateCheckpoint.yield()
            try await consume([], progress)
        }
        try await UpdateCheckpoint.yield()
        if !batch.isEmpty { try await consume(batch, progress) }
        try await UpdateCheckpoint.yield()
        return progress
    }

    // 保存バッチは維持し、readerをcloseしたファイル境界でSMB枠を譲る。
    func completeMetadata(settings: SMBConnectionSettings, password: String,
                          next: @Sendable () async throws -> [MetadataTarget],
                          save: @Sendable ([MetadataUpdate]) async throws -> Void) async throws {
        while true {
            try await UpdateCheckpoint.yield()
            let targets = try await next()
            try Task.checkCancellation()
            if targets.isEmpty { return }
            var updates: [MetadataUpdate] = []
            for target in targets {
                try await UpdateCheckpoint.yield()
                let outcome: MetadataOutcome
                do {
                    outcome = try await withClient(settings: settings, password: password) {
                        let result = try await self.readMetadata(client: $0, target: target)
                        // read/close失敗を結果として返す場合も、不完全なsessionを次へ残さない。
                        if result.requiresRetry { disconnect() }
                        return result
                    }
                } catch is CancellationError { throw CancellationError() }
                catch {
                    try Task.checkCancellation()
                    throw Self.failure(error, stage: "撮影日時の取得")
                }
                try await UpdateCheckpoint.yield()
                updates.append(MetadataUpdate(target: target, outcome: outcome))
                if outcome.requiresRetry {
                    try await UpdateCheckpoint.yield()
                    try await save(updates)
                    try await UpdateCheckpoint.yield()
                    throw MetadataServiceError.interruptedRead
                }
            }
            try await UpdateCheckpoint.yield()
            try await save(updates)
            try await UpdateCheckpoint.yield()
        }
    }

    private func readMetadata(client: SMBClient, target: MetadataTarget) async throws -> MetadataOutcome {
        guard let format = MediaDateFormat(name: target.file.path), target.file.size >= 0 else { throw IndexFailure.invalidState }
        // indexはshare基準。rootを再付加したりpathの表現を変えたりしない。
        let file = client.fileReader(path: target.file.path)
        var outcome: MetadataOutcome
        do {
            let size = try await file.fileSize
            try Task.checkCancellation()
            if size != UInt64(target.file.size) {
                outcome = MetadataCore.outcome(format: format,
                    evidence: .init(diagnostics: [.init(kind: .temporary, message: "index取得後にサイズが変化。再走査が必要")]),
                    creation: nil, modified: nil)
            } else {
                let input = SMBMetadataSource(reader: file, size: size, isJPEG: format == .jpeg)
                outcome = try await MetadataCore.parse(format: format, source: input,
                                                       creation: target.file.creation, modified: target.file.modified)
            }
        } catch is CancellationError {
            try? await file.close()
            throw CancellationError()
        } catch {
            if Task.isCancelled { try? await file.close(); throw CancellationError() }
            outcome = MetadataCore.outcome(format: format,
                evidence: .init(diagnostics: [.init(kind: .smb, message: "SMB open/read失敗")]), creation: nil, modified: nil)
        }
        do { try await file.close() }
        catch is CancellationError { throw CancellationError() }
        catch {
            outcome = MetadataCore.outcome(format: format,
                evidence: .init(diagnostics: [.init(kind: .cleanup, message: "SMB close失敗")]), creation: nil, modified: nil)
        }
        try Task.checkCancellation()
        return outcome
    }

    private nonisolated static func failure(_ error: Error, stage: String) -> AccessError {
        if let response = error as? ErrorResponse {
            let code = response.header.status
            let status = String(format: "0x%08X", code)
            switch NTStatus(code) {
            case .logonFailure:
                return AccessError(message: "認証に失敗しました。ユーザー名・パスワードを確認してください。（SMB \(status)）")
            case .accessDenied:
                return AccessError(message: "\(stage)でサーバーからアクセスを拒否されました。（SMB \(status)）")
            default:
                return AccessError(message: "\(stage)に失敗しました。（SMB \(status)）")
            }
        }
        if let network = error as? NWError {
            if case .posix(let code) = network, code == .EACCES || code == .EPERM {
                return AccessError(message: "\(stage)中の通信がOSの権限制限で拒否されました。（POSIX \(code.rawValue)）\n設定アプリでPhotoJotのローカルネットワーク許可を確認してください。このエラーだけでは、どの権限制限が原因かは判別できません。")
            }
            let detail: String
            switch network {
            case .posix(let code): detail = "POSIX \(code.rawValue)"
            case .dns(let code): detail = "DNS \(code)"
            case .tls(let code): detail = "TLS \(code)"
            default: detail = "Networkエラー"
            }
            return AccessError(message: "\(stage)中に通信に失敗しました。（\(detail)）\n接続先とWi-Fi、設定アプリのPhotoJotのローカルネットワーク許可を確認してください。このエラーだけでは許可拒否かどうかは判別できません。")
        }
        // 生のエラー本文には接続情報が含まれ得るため表示しない。
        return AccessError(message: "\(stage)に失敗しました。接続が切れたか、処理を完了できませんでした。原因は判別できません。")
    }

    private struct AccessError: LocalizedError {
        let message: String
        nonisolated var errorDescription: String? { message }
        nonisolated init(message: String) { self.message = message }
    }
}

// Coordinatorの排他枠内でのみ作成し、生成器の逐次readだけへ渡す。
// FileReaderを他のTaskへ共有せず、generatorが戻ってからcloseする。
nonisolated private final class SMBThumbnailReader: @unchecked Sendable {
    let reader: FileReader
    init(reader: FileReader) { self.reader = reader }
    func read(offset: UInt64, count: Int) async throws -> Data {
        try await reader.read(offset: offset, length: UInt32(count))
    }
}
