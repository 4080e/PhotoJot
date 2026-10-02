import Foundation

actor RangeCancellationHarness {
    var cursor: RangeThumbnailCursor
    var ledger = RangeThumbnailLedger()
    var responds = 0
    var readStarted = false
    var started: CheckedContinuation<Void, Never>?
    var release: CheckedContinuation<Void, Never>?
    init() throws { cursor = try .init(size: 3_000_000, requested: 0, current: 0, length: 3_000_000, allToEnd: false) }
    func run() async throws {
        while let (offset,count) = cursor.next() {
            try ledger.begin(count)
            readStarted = true; started?.resume()
            await withCheckedContinuation { release = $0 }
            try ledger.record(offset: offset, count: count)
            if try cursor.accept(count) { responds += 1 }
        }
    }
    func wait() async { if !readStarted { await withCheckedContinuation { started = $0 } } }
    func cancelAndReturn() { cursor.cancelled = true; release?.resume() }
    func result() -> (Int, UInt64, Int) { (ledger.calls, ledger.bytes, responds) }
}
@main struct RangeThumbnailChecks {
    static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ text: String) { checks += 1; precondition(value, text) }
        func cursor(_ size: UInt64 = 100, _ requested: Int64 = 10, _ current: Int64 = 0, _ length: Int = 20, _ all: Bool = false) throws -> RangeThumbnailCursor {
            try .init(size: size, requested: requested, current: current, length: length, allToEnd: all)
        }
        var c = try cursor()
        check(c.position == 10 && c.end == 30, "initial current 0")
        c = try cursor(100,10,15,20); check(c.position == 15 && c.end == 30, "resumed current")
        check(c.next()?.1 == 15, "remaining length")
        check(try c.accept(15), "respond permitted")
        check(c.next() == nil, "completed")
        c = try cursor(100,90,0,30); check(c.end == 100 && c.next()?.1 == 10, "clamp EOF")
        c = try cursor(100,100,0,20); check(c.next() == nil, "at EOF")
        c = try cursor(100,10,10,0); check(c.next() == nil, "zero length")
        c = try cursor(100,10,40,0,true); check(c.position == 40 && c.end == 100, "all ignores length")
        c = try cursor(100,10,0,Int.max,true); check(c.end == 100, "all ignores huge positive length")
        for (size,requested,current,length,all) in [(100,Int64(-1),Int64(0),10,false),(100,0,-1,10,false),(100,0,0,-1,false),
            (100,101,0,1,false),(100,10,5,20,false),(100,10,31,20,false),(100,10,101,0,true),
            (Int64.max,Int64.max-1,0,10,false)] {
            do { _ = try cursor(UInt64(size),requested,current,length,all); check(false,"invalid range") } catch { check(true,"invalid range") }
        }
        do { _ = try cursor(UInt64.max); check(false,"size overflow") } catch { check(true,"size overflow") }
        c = try cursor(3_000_000,0,0,3_000_000)
        var chunks: [Int] = []
        while let (_,count) = c.next() { chunks.append(count); _ = try c.accept(count) }
        check(chunks == [1_048_576,1_048_576,902_848], "1 MiB chunks")
        c = try cursor(); c.cancelled = true
        check(c.next() == nil, "cancel prevents new read")
        check(try !c.accept(10), "cancel prevents respond")
        var ledger = RangeThumbnailLedger(limit:100)
        try ledger.begin(20); try ledger.record(offset:10,count:20)
        try ledger.begin(20); try ledger.record(offset:20,count:20)
        check(ledger.bytes == 40 && ledger.calls == 2, "actual sum")
        check(ledger.uniqueBytes == 30 && ledger.duplicateBytes == 10, "overlap")
        try ledger.begin(10); try ledger.record(offset:0,count:10)
        try ledger.begin(10); try ledger.record(offset:50,count:10)
        check(ledger.intervals == [0..<40,50..<60], "sorted intervals")
        try ledger.begin(30); try ledger.record(offset:35,count:30)
        check(ledger.intervals == [0..<65] && ledger.bytes == 90 && ledger.duplicateBytes == 25, "bridge intervals")
        do { try ledger.begin(11); check(false,"cap") } catch { check(ledger.calls == 5,"no read beyond cap") }
        try ledger.begin(10); try ledger.record(offset:0,count:10)
        do { try ledger.begin(1); check(false,"at cap") } catch { check(ledger.bytes == 100,"cap exact") }
        check(ledger.isLimitReached, "exact cap is failure, not success")
        for count in [0,-1,1_048_577] { do { var l = RangeThumbnailLedger(); try l.begin(count); check(false,"chunk cap") } catch { check(true,"chunk cap") } }
        do { var l = RangeThumbnailLedger(); try l.record(offset:UInt64.max,count:2); check(false,"range overflow") } catch { check(true,"range overflow") }
        // 集合oracleと比較し、包含・隣接・前後の重複計算を確認。
        var l = RangeThumbnailLedger(); var oracle = Set<UInt64>()
        for i in 0..<100 {
            let start = UInt64((i * 37) % 191), length = (i * 11) % 30 + 1
            try l.begin(length); try l.record(offset:start,count:length)
            for offset in start..<(start + UInt64(length)) { oracle.insert(offset) }
            check(l.uniqueBytes == UInt64(oracle.count), "union oracle")
        }
        let harness = try RangeCancellationHarness()
        let task = Task { try await harness.run() }
        await harness.wait(); await harness.cancelAndReturn(); try await task.value
        let result = await harness.result()
        check(result.0 == 1 && result.1 == 1_048_576 && result.2 == 0, "inflight cancelled: count bytes, no respond, no next read")
        print("Range thumbnail: \(checks) checks passed")
    }
}
