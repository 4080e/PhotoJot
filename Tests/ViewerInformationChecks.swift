import Foundation

@main struct ViewerInformationChecks {
    static func main() {
        let value = MediaViewerInformation(calendarDateTime: "2024-01-31T14:32:18.999", relativePath: "Photos/2024/01/旅行/IMG_1234.HEIC")
        precondition(value.dateText == "2024年1月31日 14:32:18")
        precondition(value.folder == "Photos/2024/01/旅行" && value.filename == "IMG_1234.HEIC")
        let root = MediaViewerInformation(calendarDateTime: nil, relativePath: "movie.MOV")
        precondition(root.dateText == "日時不明" && root.folder == "共有ルート" && root.filename == "movie.MOV")
        let backslash = MediaViewerInformation(calendarDateTime: "2023-12-31T23:59:59", relativePath: "2023\\旅行\\a%20b.JPG")
        precondition(backslash.folder == "2023/旅行" && backslash.filename == "a%20b.JPG")
        precondition(backslash.dateText == "2023年12月31日 23:59:59")
        let path = String(repeating: "長いフォルダ/", count: 50)
        let name = String(repeating: "長い名前", count: 50) + ".HEIC"
        let long = MediaViewerInformation(calendarDateTime: nil, relativePath: path + name)
        precondition(long.folder == String(path.dropLast()) && long.filename == name)
        print("PASS: stored calendar date to seconds, unknown date, share-relative folder, original filename, root/backslash/unicode/long paths; no repository or network dependencies")
    }
}
