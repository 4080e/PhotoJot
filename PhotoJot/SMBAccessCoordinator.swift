import Foundation
import Network
import SMBClient

// 接続確認と走査は排他的に実行し、成功・失敗ともにセッションを切断する。
actor SMBAccessCoordinator {
    private var isChecking = false

    func checkConnection(settings: SMBConnectionSettings, password: String) async throws -> Int {
        guard !isChecking else { throw AccessError(message: "接続確認は実行中です。") }
        guard (1...65535).contains(settings.port) else {
            throw AccessError(message: "ポート番号は1〜65535で指定してください。")
        }
        isChecking = true
        defer { isChecking = false }
        let client = SMBClient(host: settings.host, port: settings.port)
        defer { client.session.disconnect() }
        var stage = "接続"
        do {
            try Task.checkCancellation()
            try await client.session.connect()
            stage = "認証"
            try Task.checkCancellation()
            try await client.login(username: settings.username, password: password,
                                   domain: settings.domain.isEmpty ? nil : settings.domain)
            stage = "共有への接続"
            try Task.checkCancellation()
            try await client.connectShare(settings.share)
            stage = "ルートフォルダの一覧取得"
            try Task.checkCancellation()
            // shareを付加しない。空文字は共有直下を表す。
            let entries = try await client.listDirectory(path: settings.rootPath)
            try Task.checkCancellation()
            return entries.filter { $0.name != "." && $0.name != ".." }.count
        } catch is CancellationError {
            throw AccessError(message: "接続確認を中止しました。")
        } catch {
            throw Self.failure(error, stage: stage)
        }
    }

    func scan(settings: SMBConnectionSettings, password: String,
              consume: @Sendable ([ScannedMedia], ScanProgress) async throws -> Void) async throws -> ScanProgress {
        guard !isChecking, (1...65535).contains(settings.port) else {
            throw AccessError(message: "SMB処理を開始できません。接続確認の終了を待ってください。")
        }
        isChecking = true
        defer { isChecking = false }
        let client = SMBClient(host: settings.host, port: settings.port)
        defer { client.session.disconnect() }
        var stage = "接続"
        do {
            try Task.checkCancellation()
            try await client.session.connect()
            stage = "認証"
            try Task.checkCancellation()
            try await client.login(username: settings.username, password: password,
                                   domain: settings.domain.isEmpty ? nil : settings.domain)
            stage = "共有への接続"
            try Task.checkCancellation()
            try await client.connectShare(settings.share)
        } catch is CancellationError { throw CancellationError() }
        catch { throw Self.failure(error, stage: stage) }

        var pending = [settings.rootPath]
        var batch: [ScannedMedia] = []
        var progress = ScanProgress()
        while let directory = pending.popLast() {
            try Task.checkCancellation()
            let entries: [File]
            do { entries = try await client.listDirectory(path: directory) }
            catch { throw Self.failure(error, stage: "フォルダの一覧取得") }
            progress.folders += 1
            for entry in entries where entry.name != "." && entry.name != ".." {
                try Task.checkCancellation()
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
                            try await consume(batch, progress)
                            batch.removeAll(keepingCapacity: true)
                        }
                    }
                }
            }
            // 対象メディアのないフォルダでも進捗とキャンセルを反映する。
            try await consume([], progress)
        }
        try Task.checkCancellation()
        if !batch.isEmpty { try await consume(batch, progress) }
        return progress
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
