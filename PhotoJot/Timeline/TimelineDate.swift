import Foundation

nonisolated enum TimelinePolicy {
    // metadata parserとは独立。保存済みの値からローカルで再構築できる。
    static let version = 1
    static let pageSize = 200
    static let buildBatchSize = 500
}

nonisolated enum TimelineDateKind: String, CaseIterable, Sendable {
    case internalMetadata, containerDate, confirmedFallback, provisional, unknown
}

// 表示groupは暦日のみ。記録offsetはTimelineDateと元metadataに保持する。
nonisolated struct TimelineGroupKey: Hashable, Sendable {
    let day: String
}

nonisolated struct TimelineDate: Sendable, Equatable {
    let calendarDateTime: String?
    let recordedOffset: String?
    let kind: TimelineDateKind
    let source: String?
    let quality: String?
    var groupKey: TimelineGroupKey? {
        calendarDateTime.map { TimelineGroupKey(day: String($0.prefix(10))) }
    }

    func sortKey(id: UUID) -> String {
        // !は数字より前。小数の末尾0を除くことで.1と.100は同順位、.1001は.1より新しい。
        // UUIDまで含めて一意にし、known/unknownを同じkeyset queryで取得する。
        (calendarDateTime.map { "1" + $0 } ?? "0") + "!" + id.uuidString
    }
}

nonisolated enum TimelineDates {
    private static let localExpression = try? NSRegularExpression(pattern:
        #"^([0-9]{4})[-:]([0-9]{2})[-:]([0-9]{2})[T ]([0-9]{2}):([0-9]{2}):([0-9]{2})(?:\.([0-9]{1,256}))?(Z|[+-][0-9]{2}:[0-9]{2})?$"#)
    static func hasCurrentMetadata(_ entry: MediaEntry) -> Bool {
        entry.metadataCompletedAt != nil && entry.metadataGeneration == entry.generation
            && entry.metadataVersion == MetadataPolicy.version
    }

    static func resolve(_ entry: MediaEntry) -> TimelineDate {
        func value(_ date: String?, _ kind: TimelineDateKind, offset: String? = nil,
                   source: String? = nil, quality: String? = nil) -> TimelineDate {
            TimelineDate(calendarDateTime: date, recordedOffset: date == nil ? nil : offset,
                         kind: date == nil ? .unknown : kind, source: source, quality: quality)
        }
        guard hasCurrentMetadata(entry) else {
            for (date, source, quality) in [
                (entry.smbCreationTime, DisplayDateSource.smbCreationTime, DisplayDateQuality.fileSystemCreationTime),
                (entry.smbLastWriteTime, .smbLastWriteTime, .fileSystemModificationTime)
            ] {
                if let date = DisplayDateResolver.validSMBDate(date) {
                    return value(utcCalendar(date), .provisional, source: source.rawValue, quality: quality.rawValue)
                }
            }
            return value(nil, .unknown)
        }
        let source = entry.dateSource.flatMap(DisplayDateSource.init(rawValue:))
        switch source {
        case .jpegExifDateTimeOriginal, .heicExifDateTimeOriginal, .quickTimeCreationDate:
            // resolvedInstantを端末timezoneへ変換しない。元文字列の暦日時を優先する。
            let raw = entry.originalDateValue ?? entry.resolvedFloatingDate
            guard let raw, let parsed = localCalendar(raw, separateOffset: entry.utcOffset, subsecond: entry.subsecond) else {
                return value(nil, .unknown, source: entry.dateSource, quality: entry.dateQuality)
            }
            return value(parsed.date, .internalMetadata, offset: parsed.offset, source: entry.dateSource, quality: entry.dateQuality)
        case .movieHeaderCreationTime:
            return value(entry.resolvedInstant.flatMap(utcCalendar), .containerDate,
                         source: entry.dateSource, quality: entry.dateQuality)
        case .smbCreationTime, .smbLastWriteTime:
            return value(entry.resolvedInstant.flatMap(utcCalendar), .confirmedFallback,
                         source: entry.dateSource, quality: entry.dateQuality)
        case nil:
            return value(nil, .unknown, source: entry.dateSource, quality: entry.dateQuality)
        }
    }

    static func apply(to entry: MediaEntry) {
        entry.timelineSortKey = resolve(entry).sortKey(id: entry.id)
        entry.timelineKeyVersion = TimelinePolicy.version
    }

    private static var calendar: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(secondsFromGMT: 0)!
        return result
    }

    private static func normalizedFraction(_ value: String) -> String {
        var result = value
        while result.last == "0" { result.removeLast() }
        return result
    }

    private static func offset(_ value: String?) -> String? {
        guard let value else { return nil }
        if value == "Z" { return "+00:00" }
        guard value.range(of: #"^[+-][0-9]{2}:[0-9]{2}$"#, options: .regularExpression) != nil,
              let hours = Int(value.dropFirst().prefix(2)), hours <= 23,
              let minutes = Int(value.suffix(2)), minutes <= 59 else { return nil }
        // -00:00も元表現を維持する。timezone名や撮影地を推定しない。
        return value
    }

    static func localCalendar(_ raw: String, separateOffset: String?, subsecond: String?) -> (date: String, offset: String?)? {
        guard raw.utf8.count <= 512 else { return nil }
        guard let regex = localExpression,
              let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)) else { return nil }
        func part(_ index: Int) -> String? {
            Range(match.range(at: index), in: raw).map { String(raw[$0]) }
        }
        let values = (1...6).compactMap { part($0).flatMap(Int.init) }
        guard values.count == 6, values[0] >= 1 else { return nil }
        let components = DateComponents(year: values[0], month: values[1], day: values[2],
                                        hour: values[3], minute: values[4], second: values[5])
        let cal = calendar
        guard let date = cal.date(from: components) else { return nil }
        let actual = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard [actual.year, actual.month, actual.day, actual.hour, actual.minute, actual.second].compactMap({ $0 }) == values else { return nil }
        let embedded = part(8)
        if let embedded, offset(embedded) == nil { return nil }
        if let separateOffset, offset(separateOffset) == nil { return nil }
        if let embedded, let separateOffset, offset(embedded) != offset(separateOffset) { return nil }
        let fraction = subsecond ?? part(7) ?? ""
        guard fraction.utf8.count <= 256, fraction.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        let base = String(format: "%04d-%02d-%02dT%02d:%02d:%02d", values[0], values[1], values[2], values[3], values[4], values[5])
        let normalized = normalizedFraction(fraction)
        return (base + (normalized.isEmpty ? "" : "." + normalized), offset(embedded ?? separateOffset))
    }

    // SMB Date / mvhdは撮影地を持たない。UTCの暦日時を使うがrecordedOffsetは付与しない。
    private static func utcCalendar(_ date: Date) -> String? {
        guard date.timeIntervalSince1970.isFinite else { return nil }
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date)
        guard let year = c.year, (1...9999).contains(year), let month = c.month, let day = c.day,
              let hour = c.hour, let minute = c.minute, let second = c.second else { return nil }
        let base = String(format: "%04d-%02d-%02dT%02d:%02d:%02d", year, month, day, hour, minute, second)
        let fraction = normalizedFraction(String(format: "%09d", c.nanosecond ?? 0))
        return base + (fraction.isEmpty ? "" : "." + fraction)
    }
}
