import Foundation
import Network
import SMBClient

// 全SMB処理は同じ接続とFIFO枠を利用する。scanはフォルダ、metadataはファイルで譲る。
actor SMBAccessCoordinator {
    private let gate = SMBOperationGate()
    private var viewerReaders: [UUID: (FileReader, UInt64, Generation)] = [:]
    private final class Generation {
        let id = UUID()
        let client: SMBClient
        var interrupted = false
        var retryAllowed = true
        init(_ client: SMBClient) { self.client = client }
    }
    private var generation: Generation?
    private var activeOwner: (operation: UUID, generation: UUID)?

    private let probeOperationID: UUID?
    private var probeGenerationID: UUID?
    private var probeStarted = false
    private var probeExpired = false
    #if DEBUG
    private var probeAbortDiagnostic: UUID?
    #endif

    init(probeOperationID: UUID? = nil) { self.probeOperationID = probeOperationID }

    func checkProbe(operationID: UUID, settings: SMBConnectionSettings, password: String) async throws {
        guard probeOperationID == operationID, !probeStarted, !probeExpired else { throw CancellationError() }
        probeStarted = true
        _ = try await checkConnection(settings: settings, password: password)
    }

    func expireProbe(operationID: UUID) {
        guard probeOperationID == operationID, !probeExpired else { return }
        probeExpired = true; routeChanging = true
        #if DEBUG
        probeAbortDiagnostic = SMBDiagnostics.shared.begin("probe disconnect drain", parent: operationID)
        SMBDiagnostics.shared.event("probe disconnect requested outside gate", id: operationID)
        #endif
        // Expiry before client creation also prevents a subsequent connect.
        guard let current = generation, current.id == probeGenerationID else { return }
        current.interrupted = true; current.retryAllowed = false
        #if DEBUG
        SMBDiagnostics.shared.event("probe expired; disconnect requested", id: current.id)
        #endif
        current.client.session.disconnect()
    }

    func finishProbe(operationID: UUID) async {
        guard probeOperationID == operationID else { return }
        await disconnectWhenAvailable()
        #if DEBUG
        if let id = probeAbortDiagnostic {
            SMBDiagnostics.shared.end(id, outcome: "probe I/O and gate cleanup finished")
            probeAbortDiagnostic = nil
        }
        SMBDiagnostics.shared.event("probe gate drained", id: operationID)
        #endif
    }

    // The callback carries only its generation ID. Never wait for the gate to abort I/O.
    private func connectionInterrupted(_ id: UUID, retryAllowed: Bool) {
        guard let current = generation, current.id == id, !current.interrupted else { return }
        current.interrupted = true
        current.retryAllowed = retryAllowed
        SMBRecoveryStatus.shared.began(id)
        #if DEBUG
        SMBDiagnostics.shared.event("waiting/failed: disconnect outside gate; waiting for operation drain", id: id)
        #endif
        current.client.session.disconnect()
        if activeOwner?.generation != id { disconnect() }
    }
    private var routeChanging = false
    private var routeVersion: UUID?

    func configureRoute(_ version: UUID?) { routeVersion = version }
    func pauseRouteRequests() { routeChanging = true }
    func resumeRouteRequests(version: UUID?) { routeVersion = version; routeChanging = false }

    // User switch: invalidate only this generation, without waiting on its operation gate.
    func abortRoute() {
        routeChanging = true
        if let current = generation {
            current.interrupted = true
            current.retryAllowed = false
            #if DEBUG
            SMBDiagnostics.shared.event("manual route switch: abort old generation outside gate", id: current.id)
            #endif
            current.client.session.disconnect()
        }
    }

    func establishRoute(settings: SMBConnectionSettings, password: String) async throws {
        guard routeChanging else { throw CancellationError() }
        try await withClient(settings: settings, password: password, switching: true) { client in
            _ = try await client.listDirectory(path: settings.rootPath)
        }
    }

    private var client: SMBClient?
    private var connectedSettings: SMBConnectionSettings?
    private var connectedPassword: String?
    #if DEBUG
    var waitingOperationCount: Int { get async { await gate.waitingCount } }
    #endif

    private func disconnect() {
        if let current = generation {
            #if DEBUG
            SMBDiagnostics.shared.end(current.id, outcome: "disconnect cleanup")
            #endif
            SMBRecoveryStatus.shared.ended(current.id)
        }
        generation = nil
        viewerReaders.removeAll()
        client?.session.disconnect(); client = nil
        connectedSettings = nil; connectedPassword = nil
    }

    func disconnectWhenAvailable() async {
        #if DEBUG
        let diagnostic = SMBDiagnostics.shared.begin("disconnect gate wait")
        defer { SMBDiagnostics.shared.end(diagnostic) }
        #endif
        // cleanupは呼び出し元Taskのcancelにも関係なく最後まで待つ。
        let expectedGeneration = generation?.id
        let cleanup = Task {
            do { try await gate.acquire() } catch { return }
            // A queued cleanup belongs to the generation that requested it.
            if generation?.id == expectedGeneration { disconnect() }
            await gate.release()
        }
        await cleanup.value
    }

    private func withClient<T: Sendable>(settings: SMBConnectionSettings, password: String,
                                        operationName: String = #function, switching: Bool = false, operation: (SMBClient) async throws -> T) async throws -> T {
        if !switching {
            guard !routeChanging, routeVersion == nil || settings.routeVersion == routeVersion else { throw CancellationError() }
        }
        #if DEBUG
        let diagnostic = SMBDiagnostics.shared.begin(operationName)
        defer { SMBDiagnostics.shared.end(diagnostic) }
        try await gate.acquire(operation: diagnostic)
        #else
        try await gate.acquire()
        #endif
        var used: Generation?
        let ownership = UUID()
        defer { if activeOwner?.operation == ownership { activeOwner = nil } }
        do {
            try Task.checkCancellation()
            if !switching {
                guard !routeChanging, routeVersion == nil || settings.routeVersion == routeVersion else { throw CancellationError() }
            }
            if generation?.interrupted == true { disconnect() }
            if connectedSettings != settings || connectedPassword != password { disconnect() }
            if client == nil {
                guard (1...65535).contains(settings.port) else { throw IndexFailure.invalidState }
                let next = SMBClient(host: settings.host, port: settings.port)
                let created = Generation(next)
                generation = created; used = created
                if probeOperationID != nil { probeGenerationID = created.id }
                activeOwner = (ownership, created.id)
                let connectionID = created.id
                next.onDisconnected = { [weak self] error in
                    let retryAllowed = !Self.isPermissionFailure(error)
                    Task { await self?.connectionInterrupted(connectionID, retryAllowed: retryAllowed) }
                }
                #if DEBUG
                SMBDiagnostics.shared.begin("connection", id: connectionID, parent: probeOperationID)
                if let probeOperationID {
                    SMBDiagnostics.shared.event("probe generation operation=\(probeOperationID.uuidString.prefix(8))", id: connectionID)
                }
                SMBDiagnostics.shared.event("connect waiting", id: connectionID)
                #endif
                client = next
                try await next.session.connect(); try Task.checkCancellation()
                guard !created.interrupted else { throw SMBRecoveryError.interrupted }
                #if DEBUG
                SMBDiagnostics.shared.event("connect returned; login waiting", id: connectionID)
                #endif
                try await next.login(username: settings.username, password: password,
                                     domain: settings.domain.isEmpty ? nil : settings.domain)
                try Task.checkCancellation()
                guard !created.interrupted else { throw SMBRecoveryError.interrupted }
                #if DEBUG
                SMBDiagnostics.shared.event("login returned; share waiting", id: connectionID)
                #endif
                try await next.connectShare(settings.share); try Task.checkCancellation()
                guard !created.interrupted else { throw SMBRecoveryError.interrupted }
                #if DEBUG
                SMBDiagnostics.shared.event("share connected", id: connectionID)
                #endif
                connectedSettings = settings; connectedPassword = password
            }
            used = generation
            if let used { activeOwner = (ownership, used.id) }
            guard let used, !used.interrupted else { throw SMBRecoveryError.interrupted }
            #if DEBUG
            let value = try await SMBDiagnostics.$operation.withValue(diagnostic) {
                try await SMBDiagnostics.measure("SMB body", { try await operation(client!) })
            }
            #else
            let value = try await operation(client!)
            #endif
            try Task.checkCancellation()
            guard !used.interrupted else { throw SMBRecoveryError.interrupted }
            await gate.release()
            return value
        } catch {
            #if DEBUG
            SMBDiagnostics.shared.event(error is CancellationError ? "cancelled" : "error", id: diagnostic)
            #endif
            let recoverable = (used?.interrupted == true ? used?.retryAllowed == true : Self.isTransportFailure(error)) && !Self.isPermissionFailure(error)
            // Only the owning generation may be cleared by this completion.
            if let used, generation?.id == used.id { disconnect() }
            await gate.release()
            try Task.checkCancellation()
            if recoverable { throw SMBRecoveryError.interrupted }
            // An interruption detected through a permission-denied notification must not
            // leak the retry marker emitted by the post-await generation check.
            if error is SMBRecoveryError { throw AccessError(message: "接続を継続できませんでした。権限と接続設定を確認してください。") }
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
        catch is SMBRecoveryError { throw SMBRecoveryError.interrupted }
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
                let size = try await reader.diagnosticFileSize
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
                try await closeIfUsable(reader, client: client)
                try Task.checkCancellation()
                return data
            } catch {
                try? await closeIfUsable(reader, client: client)
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
                let size = try await file.diagnosticFileSize
                try Task.checkCancellation()
                guard size == UInt64(target.fileSize) else { throw IndexFailure.invalidState }
                let id = UUID()
                guard let generation, !generation.interrupted else { throw SMBRecoveryError.interrupted }
                viewerReaders[id] = (file, size, generation)
                return id
            } catch { try? await closeIfUsable(file, client: client); throw error }
        }
    }

    func readViewer(_ id: UUID, offset: UInt64, count: Int) async throws -> Data {
        guard !routeChanging else { throw CancellationError() }
        #if DEBUG
        let diagnostic = SMBDiagnostics.shared.begin("viewer read")
        defer { SMBDiagnostics.shared.end(diagnostic) }
        #endif
        try await gate.acquire()
        guard !routeChanging else { await gate.release(); throw CancellationError() }
        let owner = viewerReaders[id]?.2
        let ownership = UUID()
        if let owner { activeOwner = (ownership, owner.id) }
        defer { if activeOwner?.operation == ownership { activeOwner = nil } }
        do {
            try Task.checkCancellation()
            guard let owner, generation?.id == owner.id, !owner.interrupted else { throw SMBRecoveryError.interrupted }
            guard let (reader, size, _) = viewerReaders[id], count > 0, count <= 1_048_576,
                  offset <= size, UInt64(count) <= size - offset else { throw IndexFailure.invalidState }
            let data = try await reader.diagnosticRead(offset: offset, length: UInt32(count))
            try Task.checkCancellation()
            guard !owner.interrupted else { throw SMBRecoveryError.interrupted }
            guard data.count == count else { throw IndexFailure.invalidState }
            await gate.release()
            return data
        } catch {
            // 失効handleは現在の別接続を切断しない。
            let recoverable = (owner?.interrupted == true ? owner?.retryAllowed == true : (error is SMBRecoveryError || Self.isTransportFailure(error))) && !Self.isPermissionFailure(error)
            if let owner, generation?.id == owner.id { disconnect() }
            await gate.release()
            try Task.checkCancellation()
            if recoverable { throw SMBRecoveryError.interrupted }
            // An interruption detected through a permission-denied notification must not
            // leak the retry marker emitted by the post-await generation check.
            if error is SMBRecoveryError { throw AccessError(message: "接続を継続できませんでした。権限と接続設定を確認してください。") }
            throw error
        }
    }

    func closeViewer(_ id: UUID) async {
        #if DEBUG
        let diagnostic = SMBDiagnostics.shared.begin("viewer close wait")
        defer { SMBDiagnostics.shared.end(diagnostic) }
        #endif
        let cleanup = Task {
            do { try await gate.acquire() } catch { return }
            let ownership = UUID()
            defer { if activeOwner?.operation == ownership { activeOwner = nil } }
            if let (reader, _, owner) = viewerReaders.removeValue(forKey: id), generation?.id == owner.id {
                activeOwner = (ownership, owner.id)
                if owner.interrupted { disconnect() }
                else {
                    do { try await reader.diagnosticClose() }
                    catch { if generation?.id == owner.id { disconnect() } }
                    if owner.interrupted, generation?.id == owner.id { disconnect() }
                }
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
            catch is SMBRecoveryError { throw SMBRecoveryError.interrupted }
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
                catch is SMBRecoveryError { throw SMBRecoveryError.interrupted }
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
            let size = try await file.diagnosticFileSize
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
            try? await closeIfUsable(file, client: client)
            throw CancellationError()
        } catch {
            if Self.isPermissionFailure(error) { throw error }
            if Task.isCancelled { try? await closeIfUsable(file, client: client); throw CancellationError() }
            outcome = MetadataCore.outcome(format: format,
                evidence: .init(diagnostics: [.init(kind: .smb, message: "SMB open/read失敗")]), creation: nil, modified: nil)
        }
        do { try await closeIfUsable(file, client: client) }
        catch is CancellationError { throw CancellationError() }
        catch is SMBRecoveryError { throw SMBRecoveryError.interrupted }
        catch {
            outcome = MetadataCore.outcome(format: format,
                evidence: .init(diagnostics: [.init(kind: .cleanup, message: "SMB close失敗")]), creation: nil, modified: nil)
        }
        try Task.checkCancellation()
        return outcome
    }

    private func closeIfUsable(_ reader: FileReader, client: SMBClient) async throws {
        guard let owner = generation, owner.client === client, !owner.interrupted else { return }
        try await reader.diagnosticClose()
    }

    private nonisolated static func isPermissionFailure(_ error: Error) -> Bool {
        if let response = error as? ErrorResponse {
            switch NTStatus(response.header.status) {
            case .logonFailure, .accessDenied: return true
            default: return false
            }
        }
        if let error = error as? NWError, case .posix(let code) = error {
            return code == .EACCES || code == .EPERM
        }
        return false
    }
    private nonisolated static func isTransportFailure(_ error: Error) -> Bool {
        guard !isPermissionFailure(error) else { return false }
        return error is NWError || error is ConnectionError
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
        try await reader.diagnosticRead(offset: offset, length: UInt32(count))
    }
}

// No task, timeout or cancellation handler is introduced by these adapters.
extension FileReader {
    nonisolated var diagnosticFileSize: UInt64 {
        get async throws {
            #if DEBUG
            return try await SMBDiagnostics.measure("file open/size") { try await self.fileSize }
            #else
            return try await fileSize
            #endif
        }
    }
    nonisolated func diagnosticRead(offset: UInt64, length: UInt32) async throws -> Data {
        #if DEBUG
        return try await SMBDiagnostics.measure("file read") { try await self.read(offset: offset, length: length) }
        #else
        return try await read(offset: offset, length: length)
        #endif
    }
    nonisolated func diagnosticClose() async throws {
        #if DEBUG
        try await SMBDiagnostics.measure("file close") { try await self.close() }
        #else
        try await close()
        #endif
    }
}
