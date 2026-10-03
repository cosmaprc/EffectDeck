//  RhythmAnalyzerTests.swift
//  Rhythm Analyzer（2.12.0）の枠の読み・履歴・Min / Max BPM の規則（DSP/RhythmAnalyzerModel.swift）。
//  **実機もエンジンも要らない。**期待値は rhythm_analyzer.js の式から手で出したもの。

import XCTest

final class RhythmAnalyzerTests: XCTestCase {

    typealias R = ETRhythm

    // MARK: Min / Max BPM

    func testBPMRangeRule() {
        typealias N = ETRhythmBPMRange
        // 既定。Max だけを範囲の中の値へ（Min の 1.25 倍以上）。
        XCTAssertEqual(N.normalize(previousMin: 40, previousMax: 240, requestedMin: nil, requestedMax: 100).max, 100)
        XCTAssertEqual(N.normalize(previousMin: 40, previousMax: 240, requestedMin: nil, requestedMax: 100).min, 40)
        // Max だけを Min の 1.25 倍より下へ入れると、Min が下がる（floor(mx / 1.25)）。
        let lowered = N.normalize(previousMin: 100, previousMax: 200, requestedMin: nil, requestedMax: 60)
        XCTAssertEqual(lowered.min, 48)
        XCTAssertEqual(lowered.max, 60)
        // 範囲の下限（50）まで。Min 40 なら 50 ≥ 50 で通る。
        let floorMax = N.normalize(previousMin: 40, previousMax: 240, requestedMin: nil, requestedMax: 50)
        XCTAssertEqual(floorMax.min, 40)
        XCTAssertEqual(floorMax.max, 50)
        // Min だけを上げて Max が足りなくなると、Max が上がる（ceil(mn * 1.25)）。
        let raised = N.normalize(previousMin: 100, previousMax: 200, requestedMin: 190, requestedMax: nil)
        XCTAssertEqual(raised.min, 190)
        XCTAssertEqual(raised.max, 238)
        // 同時に来たときは Min を優先して Max が寄る。
        let both = N.normalize(previousMin: 40, previousMax: 240, requestedMin: 100, requestedMax: 50)
        XCTAssertEqual(both.min, 100)
        XCTAssertEqual(both.max, 125)
        // 範囲の外は端へ。範囲の外の Max は Min を下げない（打った先頭の字 '1' が送られても）。
        let typed = N.normalize(previousMin: 100, previousMax: 200, requestedMin: nil, requestedMax: 1)
        XCTAssertEqual(typed.min, 100, "範囲の外の Max は Min を下げない")
        XCTAssertEqual(typed.max, 125)
        XCTAssertEqual(N.normalize(previousMin: 40, previousMax: 240, requestedMin: 500, requestedMax: nil).min, 192)
        XCTAssertEqual(N.normalize(previousMin: 40, previousMax: 240, requestedMin: 500, requestedMax: nil).max, 240)
        // 数でないものは前の値のまま。
        let kept = N.normalize(previousMin: 60, previousMax: 180, requestedMin: .nan, requestedMax: .infinity)
        XCTAssertEqual(kept.min, 60)
        XCTAssertEqual(kept.max, 180)
        // どの入力でも規則を守る。
        for mn in stride(from: 40.0, through: 192, by: 13) {
            for mx in stride(from: 50.0, through: 240, by: 17) {
                for request in [(mn, nil), (nil, mx), (mn, mx)] as [(Double?, Double?)] {
                    let r = N.normalize(previousMin: 40, previousMax: 240, requestedMin: request.0,
                                        requestedMax: request.1)
                    XCTAssertGreaterThanOrEqual(r.max, r.min * 1.25 - 1e-9)
                    XCTAssertGreaterThanOrEqual(r.min, 40, "\(r)")
                    XCTAssertLessThanOrEqual(r.min, 192, "\(r)")
                    XCTAssertLessThanOrEqual(r.max, 240 + 1e-9, "\(r)")
                }
            }
        }
    }

    func testSpanSnapsToTheNearestAllowedValue() {
        XCTAssertEqual(R.spans, [4, 6, 8, 12, 16])
        XCTAssertEqual(R.nearestSpan(8), 8)
        XCTAssertEqual(R.nearestSpan(7), 6, "6 と 8 の間は近い方。同じ距離なら小さい方")
        XCTAssertEqual(R.nearestSpan(5), 4)
        XCTAssertEqual(R.nearestSpan(10), 8)
        XCTAssertEqual(R.nearestSpan(11), 12)
        XCTAssertEqual(R.nearestSpan(100), 16)
        XCTAssertEqual(R.nearestSpan(-3), 4)
        XCTAssertEqual(R.nearestSpan(.nan), 8)
    }

    func testSmallHelpers() {
        XCTAssertEqual(R.bpmPosition(30), 0, accuracy: 1e-12)
        XCTAssertEqual(R.bpmPosition(120), 0.5, accuracy: 1e-12)
        XCTAssertEqual(R.bpmPosition(480), 1, accuracy: 1e-12)
        XCTAssertEqual(R.bpmPosition(10), 0)
        XCTAssertEqual(R.bpmPosition(2000), 1)
        // 0 に丸まる値は +0。
        XCTAssertEqual(R.signed(0.4, digits: 0), "+0")
        XCTAssertEqual(R.signed(-0.4, digits: 0), "+0")
        XCTAssertEqual(R.signed(-3, digits: 0), "−3")
        XCTAssertEqual(R.signed(12.34, digits: 1), "+12.3")
        XCTAssertEqual(R.median([3, 1, 2]), 2)
        XCTAssertEqual(R.median([4, 1, 2, 3]), 2.5)
        // 32 ビットの回り込み。
        XCTAssertTrue(R.isNewerCounter(1, than: 0))
        XCTAssertTrue(R.isNewerCounter(0, than: 0xFFFF_FFFF))
        XCTAssertFalse(R.isNewerCounter(5, than: 5))
        XCTAssertFalse(R.isNewerCounter(0, than: 1))
    }

    // MARK: 枠を作る

    private struct EventSpec {
        var frame: UInt32
        var fraction: Float = 0
        var epoch: UInt32 = 1
        var beatIndex: Int32
        var beatFraction: Float = 0
        var period: Float = 0.5
        var strength: Float = 0.8
        var band: UInt8 = 1
        var flags: UInt8 = 0
    }

    private struct Fields {
        var rate: Float = 48000
        var generation: UInt32 = 1
        var hop: UInt32 = 480
        var frameCount: UInt32 = 1000
        var time: Float = 2
        var latency: Float = 0.02
        var dropped: UInt32 = 0
        var locked = true
        var epoch: UInt32 = 1
        var confidence: Float = 0.6
        var period: Float = 0.5
        var nextFrame: UInt32 = 1050
        var nextFraction: Float = 0.25
        var nextIndex: UInt32 = 3
        var comb: Float = 120
        var tempogram = [Float](repeating: 0.25, count: 192)
        var events: [EventSpec] = []
    }

    private func frame(_ f: Fields, length: Int = 1344, sequence: UInt32 = 1) -> ETFrame {
        var p = [UInt8](repeating: 0, count: 1344)
        func put(_ bytes: [UInt8], _ offset: Int) { TelemetryBytes.put(bytes, at: offset, into: &p) }
        put(TelemetryBytes.f32(f.rate), 0)
        put(TelemetryBytes.u32(f.generation), 4)
        put(TelemetryBytes.u32(f.hop), 8)
        put(TelemetryBytes.u32(f.frameCount), 12)
        put(TelemetryBytes.f32(f.time), 16)
        put(TelemetryBytes.f32(f.latency), 20)
        put(TelemetryBytes.u32(f.dropped), 24)
        put(TelemetryBytes.u32(UInt32(f.events.count)), 28)
        put(TelemetryBytes.u32(f.locked ? 1 : 0), 32)
        put(TelemetryBytes.u32(f.epoch), 36)
        put(TelemetryBytes.f32(f.confidence), 40)
        put(TelemetryBytes.f32(f.locked ? f.period : 0), 44)
        put(TelemetryBytes.u32(f.locked ? f.nextFrame : 0), 48)
        put(TelemetryBytes.f32(f.locked ? f.nextFraction : 0), 52)
        put(TelemetryBytes.u32(f.locked ? f.nextIndex : 0), 56)
        put(TelemetryBytes.f32(f.comb), 60)
        for (i, v) in f.tempogram.enumerated() { put(TelemetryBytes.f32(v), 64 + 4 * i) }
        for (k, e) in f.events.enumerated() {
            let base = 832 + 32 * k
            put(TelemetryBytes.u32(e.frame), base)
            put(TelemetryBytes.f32(e.fraction), base + 4)
            put(TelemetryBytes.u32(e.epoch), base + 8)
            put(TelemetryBytes.i32(e.beatIndex), base + 12)
            put(TelemetryBytes.f32(e.beatFraction), base + 16)
            put(TelemetryBytes.f32(e.period), base + 20)
            put(TelemetryBytes.f32(e.strength), base + 24)
            put([e.band], base + 28)
            put([e.flags], base + 29)
        }
        return TelemetryBytes.frame(.rhythmAnalyzer, sequence: sequence, payload: Array(p.prefix(length)))
    }

    // MARK: 枠の読み

    func testParsesAFrameWithOneEvent() throws {
        var f = Fields()
        f.events = [EventSpec(frame: 990, fraction: 0.5, epoch: 4, beatIndex: 7, beatFraction: 0.25,
                              period: 0.5, strength: 0.6, band: 2)]
        let s = try XCTUnwrap(ETRhythmSnapshot.parse(frame(f, sequence: 8)))
        XCTAssertEqual(s.sampleRate, 48000)
        XCTAssertEqual(s.generation, 1)
        XCTAssertEqual(s.hop, 480)
        XCTAssertEqual(s.hopSeconds, 0.01, accuracy: 1e-12)
        XCTAssertEqual(s.frameCount, 1000)
        XCTAssertTrue(s.locked)
        XCTAssertEqual(s.lockEpoch, 1)
        XCTAssertEqual(s.periodSeconds, 0.5)
        XCTAssertEqual(s.nextBeatFrame, 1050)
        XCTAssertEqual(s.nextBeatFraction, 0.25)
        XCTAssertEqual(s.nextBeatIndex, 3)
        XCTAssertEqual(s.combBestBpm, 120)
        XCTAssertEqual(s.tempogram.count, 192)
        XCTAssertEqual(s.sequence, 8)
        let e = try XCTUnwrap(s.events.first)
        XCTAssertEqual(s.events.count, 1)
        XCTAssertTrue(e.locked)
        XCTAssertEqual(e.time, 990.5 * 0.01, accuracy: 1e-9, "(frame + fraction) × hopSeconds")
        XCTAssertEqual(e.epoch, 4)
        XCTAssertEqual(e.position, 7.25, accuracy: 1e-9)
        XCTAssertEqual(e.band, 2)
        XCTAssertEqual(e.strength, 0.6, accuracy: 1e-6)
    }

    func testUnlockedFrameAndEvents() throws {
        var f = Fields()
        f.locked = false
        f.events = [EventSpec(frame: 10, beatIndex: 0, period: 0, flags: 1)]
        let s = try XCTUnwrap(ETRhythmSnapshot.parse(frame(f)))
        XCTAssertFalse(s.locked)
        XCTAssertFalse(s.events[0].locked)
        // 拍に乗っていない onset は period 0 が許される。乗っているのに 0 は落とす。
        f.events = [EventSpec(frame: 10, beatIndex: 0, period: 0, flags: 0)]
        XCTAssertNil(ETRhythmSnapshot.parse(frame(f)))
    }

    func testRejectsMalformedFrames() {
        XCTAssertNil(ETRhythmSnapshot.parse(nil))
        XCTAssertNil(ETRhythmSnapshot.parse(frame(Fields(), length: 1343)))
        func mutate(_ change: (inout Fields) -> Void) -> ETRhythmSnapshot? {
            var f = Fields()
            change(&f)
            return ETRhythmSnapshot.parse(frame(f))
        }
        XCTAssertNotNil(mutate { _ in })
        XCTAssertNil(mutate { $0.generation = 0 })
        XCTAssertNil(mutate { $0.hop = 0 })
        XCTAssertNil(mutate { $0.rate = 0 })
        XCTAssertNil(mutate { $0.rate = .nan })
        XCTAssertNil(mutate { $0.time = -1 })
        XCTAssertNil(mutate { $0.confidence = -0.1 })
        XCTAssertNil(mutate { $0.period = 0 }, "拍に乗っているのに周期が 0")
        XCTAssertNil(mutate { $0.nextFraction = 1 })
        XCTAssertNil(mutate { $0.comb = -1 })
        XCTAssertNil(mutate { $0.tempogram[5] = 1.5 })
        XCTAssertNil(mutate { $0.tempogram[5] = -0.1 })
        XCTAssertNil(mutate { $0.tempogram[5] = .nan })
        XCTAssertNil(mutate { $0.events = [EventSpec(frame: 1, beatIndex: 0, band: 3)] })
        XCTAssertNil(mutate { $0.events = [EventSpec(frame: 1, beatIndex: 0, strength: 0)] })
        XCTAssertNil(mutate { $0.events = [EventSpec(frame: 1, fraction: 1, beatIndex: 0)] })
        XCTAssertNil(mutate { $0.events = [EventSpec(frame: 1, beatIndex: 0, flags: 2)] })
        XCTAssertNil(ETRhythmSnapshot.parse(TelemetryBytes.frame(.rhythmAnalyzer, version: 2,
                                                                 payload: [UInt8](repeating: 0, count: 1344))))
        XCTAssertNil(ETRhythmSnapshot.parse(TelemetryBytes.frame(.level, payload: [UInt8](repeating: 0, count: 1344))))
    }

    // MARK: 履歴

    /// 0.1 秒（10 ホップ）ごとの枠。拍は 0.5 秒（50 ホップ）おきで、拍 n は 50n ホップ。
    /// `events` は拍の頭の onset を持つ拍の番号。
    private func gridFrame(_ k: Int, generation: UInt32 = 1, onsetsOn beats: [Int] = [],
                           midBeats: [Int] = []) -> ETFrame {
        var f = Fields()
        f.generation = generation
        f.frameCount = UInt32(10 * k)
        f.time = Float(Double(k) * 0.1)
        let next = Int(f.frameCount) / 50 + 1
        f.nextIndex = UInt32(next)
        f.nextFrame = UInt32(50 * next)
        f.nextFraction = 0
        var events = beats.map { EventSpec(frame: UInt32(50 * $0), beatIndex: Int32($0)) }
        // 拍の途中（0.52 拍）の onset は +10ms 遅れ。
        events += midBeats.map {
            EventSpec(frame: UInt32(50 * $0 + 26), beatIndex: Int32($0), beatFraction: 0.52)
        }
        f.events = events
        return frame(f, sequence: UInt32(k))
    }

    private func feed(_ state: ETRhythmState, frames range: ClosedRange<Int>, generation: UInt32 = 1,
                      onsets: [Int: [Int]] = [:], mids: [Int: [Int]] = [:]) {
        for k in range {
            state.ingest(gridFrame(k, generation: generation, onsetsOn: onsets[k] ?? [],
                                   midBeats: mids[k] ?? []), now: Double(k) * 0.1)
        }
    }

    func testTempogramColumnsAdvanceWithAnalysedTime() {
        let state = ETRhythmState()
        XCTAssertEqual(state.tempogramHead, 159)
        state.ingest(gridFrame(1), now: 0)
        XCTAssertEqual(state.tempogramHead, 0, "最初の枠は 1 列進める")
        XCTAssertEqual(state.tempogramAdopted[0], 120, "採用したテンポ = 60 / 周期")
        XCTAssertEqual(state.tempogramConfidence[0], 0.6, accuracy: 1e-6)
        state.ingest(gridFrame(2), now: 0.1)
        XCTAssertEqual(state.tempogramHead, 0, "0.1 秒 < 1 列（0.125 秒）: 同じ列を書き直す")
        XCTAssertEqual(state.columnPhase, 0.8, accuracy: 1e-12)
        state.ingest(gridFrame(3), now: 0.2)
        XCTAssertEqual(state.tempogramHead, 1)
        XCTAssertEqual(state.columnPhase, 0.6, accuracy: 1e-12)
        XCTAssertEqual(state.tempogramScroll(now: 0.2), 0.6, accuracy: 1e-12)
        // 枠が止まっても、壁時計で 2 列までしか進めない。
        XCTAssertEqual(state.tempogramScroll(now: 100), 0.6 + 2, accuracy: 1e-12)
    }

    func testBeatClockFollowsTheLockedGrid() throws {
        let state = ETRhythmState()
        feed(state, frames: 1...60)
        let segment = try XCTUnwrap(state.openSegment)
        XCTAssertEqual(state.segments.count, 1)
        XCTAssertEqual(segment.epoch, 1)
        // 最初の枠で時計は 0、拍の位置は 0.2。以後は同じ傾きで進む（0.1 秒 = 0.2 拍）。
        XCTAssertEqual(segment.offset, -0.2, accuracy: 1e-9)
        XCTAssertEqual(state.beatClock, 0.2 * 59, accuracy: 1e-6)
        XCTAssertEqual(state.heldPeriod, 0.5)
        XCTAssertEqual(state.snapshot?.frameCount, 600)
        // 時計の履歴からの補間。
        XCTAssertEqual(state.clockAt(3.0), 0.2 * 29, accuracy: 1e-6, "k = 30 の時刻 3.0 秒")
        XCTAssertEqual(state.clockAt(3.05), 0.2 * 29 + 0.1, accuracy: 1e-6)
    }

    func testUnlockedFramesRunTheClockOnAtTheHeldPeriod() {
        let state = ETRhythmState()
        feed(state, frames: 1...5)
        let before = state.beatClock
        var f = Fields()
        f.locked = false
        f.frameCount = 60
        f.time = 0.6
        state.ingest(frame(f), now: 0.6)
        // dt = 10 ホップ × 0.01 秒、周期 0.5 → 0.2 拍。
        XCTAssertEqual(state.beatClock, before + 0.2, accuracy: 1e-9)
        XCTAssertNil(state.openSegment)
        XCTAssertEqual(state.ledLevel, 0)
    }

    func testOnsetsAreStoredAndPlacedOnTheBeatClock() throws {
        let state = ETRhythmState()
        // 拍 n の onset は拍 n の時刻（frame 50n）の後に届く（5n フレーム目）。
        var onsets: [Int: [Int]] = [:]
        for n in 1...12 { onsets[5 * n] = [n] }
        feed(state, frames: 1...60, onsets: onsets)
        XCTAssertEqual(state.eventSerial, 12)
        var us: [Double] = []
        state.forEachEvent(from: -100, to: 100) { _ in us.append(0) }
        XCTAssertEqual(us.count, 12)
        let lens = try XCTUnwrap(state.lensSummary())
        // 拍の頭だけ。帯域 1（Mid）のスロット 0 に 12 個、揺れは 0。
        XCTAssertEqual(lens.rows.count, 1)
        XCTAssertEqual(lens.rows[0].band, 1)
        XCTAssertEqual(lens.rows[0].slot, 0)
        XCTAssertEqual(lens.rows[0].count, 12)
        XCTAssertEqual(lens.rows[0].mean, 0, accuracy: 1e-5)
        XCTAssertEqual(lens.rows[0].sd, 0, accuracy: 1e-5)
        XCTAssertEqual(lens.jitter, 0, accuracy: 1e-5)
        XCTAssertTrue(lens.swing.isNaN, "0.4〜0.8 拍の onset が無い")
    }

    func testSwingAndSlotsFromMidBeatOnsets() throws {
        let state = ETRhythmState()
        var onsets: [Int: [Int]] = [:]
        var mids: [Int: [Int]] = [:]
        for n in 1...12 {
            onsets[5 * n] = [n]
            // 拍 n の 0.52 拍目は frame 50n + 26。それを越える 10 フレームごとの枠（5n + 3 枠目）で届く。
            mids[5 * n + 3, default: []].append(n)
        }
        feed(state, frames: 1...66, onsets: onsets, mids: mids)
        XCTAssertEqual(state.eventSerial, 24)
        let lens = try XCTUnwrap(state.lensSummary())
        XCTAssertEqual(Set(lens.rows.map(\.slot)), [0, 3], "拍の頭と 8 分の裏（straight の 3 番）")
        XCTAssertEqual(lens.swing, 0.52 / 0.48, accuracy: 1e-3, "中央値 0.52 → 0.52 : 0.48")
        let mid = try XCTUnwrap(lens.rows.first { $0.slot == 3 })
        XCTAssertEqual(mid.count, 12)
        // 先頭の拍の onset は、同じ帯域の 1 Span か 2 Span 前が無いので新規ではない。
        XCTAssertFalse(lens.rows.isEmpty)
    }

    func testPointsForLaneViewsAreOldestFirstAndInsideTheWindow() {
        let state = ETRhythmState()
        var onsets: [Int: [Int]] = [:]
        for n in 1...12 { onsets[5 * n] = [n] }
        feed(state, frames: 1...60, onsets: onsets)
        let view = ETRhythmState.LaneView(left: 0, top: 0, width: 400, height: 90,
                                          uRight: state.beatClock, span: 4, echo: false)
        let points = state.points(for: view)
        XCTAssertGreaterThanOrEqual(points.count, 4)
        XCTAssertEqual(points.map(\.x), points.map(\.x).sorted(), "古い順")
        // 帯域 1（Mid）の行の中心（上から 2 行目の中央）。揺れ 0 ms。
        for p in points where p.timed {
            XCTAssertEqual(p.y, 90.0 / 3 * 1.5, accuracy: 1e-3)
            XCTAssertGreaterThanOrEqual(p.radius, 0.025 * 30)
        }
        // Echo は帯域ごとの行の高さ（中央の行は 0.5 の位置）。
        let echo = ETRhythmState.LaneView(left: 0, top: 0, width: 400, height: 22,
                                          uRight: state.beatClock, span: 4, echo: true)
        for p in state.points(for: echo) { XCTAssertEqual(p.y, 11, accuracy: 1e-9) }
    }

    // MARK: 世代の柵

    func testGenerationFence() throws {
        let state = ETRhythmState()
        feed(state, frames: 1...3, generation: 5)
        XCTAssertEqual(state.activeGeneration, 5)
        XCTAssertNotNil(state.snapshot)

        // 同じ世代の途中で、古い世代が混じっても捨てる。
        state.ingest(gridFrame(4, generation: 4), now: 0)
        XCTAssertEqual(state.activeGeneration, 5)
        XCTAssertEqual(state.snapshot?.frameCount, 30)

        // Reset: 解析を捨てる。前の世代の取り残しの枠は受けず、新しい世代から始める。
        state.beginEpoch()
        XCTAssertNil(state.activeGeneration)
        XCTAssertNil(state.snapshot)
        XCTAssertEqual(state.tempogramHead, 159)
        feed(state, frames: 4...5, generation: 5)
        XCTAssertNil(state.snapshot, "前の世代の枠は受けない")
        XCTAssertNil(state.activeGeneration)
        feed(state, frames: 6...7, generation: 6)
        XCTAssertEqual(state.activeGeneration, 6)
        XCTAssertEqual(state.snapshot?.frameCount, 70)
    }

    func testNewerGenerationRestartsTheHistory() {
        let state = ETRhythmState()
        feed(state, frames: 1...10, generation: 3)
        XCTAssertEqual(state.segments.count, 1)
        state.ingest(gridFrame(11, generation: 4), now: 0)
        XCTAssertEqual(state.activeGeneration, 4)
        XCTAssertEqual(state.eventSerial, 0)
        XCTAssertEqual(state.segments.count, 1, "新しい世代の最初の枠から作り直す")
        XCTAssertEqual(state.tempogramHead, 0)
    }

    func testSourceChangeAcceptsRestartedGenerations() {
        let state = ETRhythmState()
        feed(state, frames: 1...3, generation: 9)
        // エンジンを作り直すと世代が 1 から数え直しになる。
        feed(state, frames: 1...2, generation: 1)
        XCTAssertEqual(state.activeGeneration, 9, "出どころが替わったと知らなければ古い世代と見て捨てる")
        state.resetSource()
        feed(state, frames: 1...2, generation: 1)
        XCTAssertEqual(state.activeGeneration, 1)
        XCTAssertNotNil(state.snapshot)
    }

    func testBeatLedLightsOnPredictedBeatsAndFades() throws {
        let state = ETRhythmState()
        feed(state, frames: 1...4)
        // 拍 1 は 0.5 秒。0.4 秒の枠まではまだ点いていない（ledBeat は無い）。
        XCTAssertEqual(state.ledLevel, 0)
        feed(state, frames: 5...5)
        // 0.5 秒の枠で拍 1 を越える。ちょうど越えた直後は最大。
        XCTAssertGreaterThan(state.ledLevel, 0.99)
        feed(state, frames: 6...6)
        // 0.1 秒後は 0.09 秒の減衰を過ぎて消える。
        XCTAssertEqual(state.ledLevel, 0)
        XCTAssertNotNil(state.ledAgeMilliseconds(now: 0.6))
    }

    func testSegmentsAreCappedAtSixtyFour() {
        let state = ETRhythmState()
        for epoch in 1...70 {
            var f = Fields()
            f.epoch = UInt32(epoch)
            f.frameCount = UInt32(10 * epoch)
            f.nextFrame = f.frameCount + 20
            f.nextFraction = 0
            f.nextIndex = UInt32(epoch)
            state.ingest(frame(f, sequence: UInt32(epoch)), now: 0)
        }
        XCTAssertEqual(state.segments.count, 64)
        XCTAssertEqual(state.segmentOrder.count, 64)
        XCTAssertNil(state.segments[1], "古い方から捨てる")
        XCTAssertNotNil(state.segments[70])
    }
}
