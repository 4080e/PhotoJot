import Foundation

// TimelineItemの表示・ソートに使用済みの暦日時と、共有ルート相対パスだけを整形する。
nonisolated struct MediaViewerInformation {
    let dateText: String
    let folder: String
    let filename: String

    init(calendarDateTime: String?, relativePath: String) {
        if let value = calendarDateTime, value.count >= 19,
           let year = Int(value.prefix(4)),
           let month = Int(value.dropFirst(5).prefix(2)),
           let day = Int(value.dropFirst(8).prefix(2)) {
            // 元の暦日時をそのまま表示。timezone変換や小数秒の丸めはしない。
            dateText = "\(year)年\(month)月\(day)日 \(value.dropFirst(11).prefix(8))"
        } else {
            dateText = "日時不明"
        }
        let parts = relativePath.replacingOccurrences(of: "\\", with: "/").split(separator: "/", omittingEmptySubsequences: false)
        filename = parts.last.map(String.init) ?? ""
        let parent = parts.dropLast().joined(separator: "/")
        folder = parent.isEmpty ? "共有ルート" : parent
    }
}
