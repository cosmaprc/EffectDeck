//  AudioBufferOpsTests.swift
//  音のスレッドの並べ替えと書き出し（ETAudioBufferOps）。
//
//  壊れると: 多チャンネルの IF で音が別のスピーカーへ行く、片側が無音になる、
//  前のブロックの残りが鳴る。作り物の配列で、AVAudioSourceNode が渡してくる形
//  （インターリーブの 1 本・チャンネルごとの複数本・本数の過不足・容量超え）を並べる。

import XCTest

final class AudioBufferOpsTests: XCTestCase {

    /// 出力のバッファを作り物で持つ。lanes は 1 バッファに入る本数。
    private final class FakeOutput {
        var storage: [[Float]]
        let lanes: [Int]
        var present: [Bool]
        init(lanes: [Int], frames: Int, fill: Float = -9) {
            self.lanes = lanes
            storage = lanes.map { [Float](repeating: fill, count: max(1, $0) * frames) }
            present = lanes.map { _ in true }
        }
        /// writeOutput に渡す。配列の先頭を返す（テストの間だけ有効）。
        func write(planar: [Float], frames: Int, channels: Int, frameCount: Int) -> Float {
            var pointers: [UnsafeMutablePointer<Float>] = []
            for k in storage.indices {
                let p = UnsafeMutablePointer<Float>.allocate(capacity: storage[k].count)
                p.initialize(from: storage[k], count: storage[k].count)
                pointers.append(p)
            }
            defer {
                for (k, p) in pointers.enumerated() {
                    storage[k] = Array(UnsafeBufferPointer(start: p, count: storage[k].count))
                    p.deallocate()
                }
            }
            return planar.withUnsafeBufferPointer { pl in
                ETAudioBufferOps.writeOutput(planar: pl.baseAddress!, frames: frames, channels: channels,
                                             frameCount: frameCount, bufferCount: storage.count) { k in
                    (self.present[k] ? pointers[k] : nil, self.lanes[k])
                }
            }
        }
    }

    /// チャンネル c・フレーム i の値が一目で分かるプレーナ（c*100 + i + 1）。
    private func planar(channels: Int, frames: Int) -> [Float] {
        (0..<channels).flatMap { c in (0..<frames).map { i in Float(c * 100 + i + 1) } }
    }

    // MARK: - peak

    func testPeakIsLargestAbsoluteValue() {
        let s: [Float] = [0.1, -0.7, 0.3, 0.69]
        XCTAssertEqual(s.withUnsafeBufferPointer { ETAudioBufferOps.peak($0.baseAddress!, count: 4) }, 0.7)
    }

    /// NaN は拾わない（ゲートと同じく無音の側へ倒す）。
    func testPeakIgnoresNaN() {
        let s: [Float] = [.nan, 0.2, .nan, -0.1]
        XCTAssertEqual(s.withUnsafeBufferPointer { ETAudioBufferOps.peak($0.baseAddress!, count: 4) }, 0.2)
        let all: [Float] = [.nan, .nan]
        XCTAssertEqual(all.withUnsafeBufferPointer { ETAudioBufferOps.peak($0.baseAddress!, count: 2) }, 0)
    }

    func testPeakOfNothingIsZero() {
        let s: [Float] = [1]
        XCTAssertEqual(s.withUnsafeBufferPointer { ETAudioBufferOps.peak($0.baseAddress!, count: 0) }, 0)
        XCTAssertEqual(s.withUnsafeBufferPointer { ETAudioBufferOps.peak($0.baseAddress!, count: -3) }, 0)
    }

    /// 入力は 2ch なので n*2 を見る。R だけに音があっても拾う。
    func testPeakSeesTheRightChannel() {
        var s = [Float](repeating: 0, count: 8)
        s[7] = -0.5
        XCTAssertEqual(s.withUnsafeBufferPointer { ETAudioBufferOps.peak($0.baseAddress!, count: 8) }, 0.5)
    }

    // MARK: - spreadStereo

    func testSpreadStereoToTwoChannels() {
        let inter: [Float] = [1, -1, 2, -2, 3, -3]
        var p = [Float](repeating: 99, count: 6)
        inter.withUnsafeBufferPointer { i in
            p.withUnsafeMutableBufferPointer { ETAudioBufferOps.spreadStereo(i.baseAddress!, frames: 3,
                                                                             into: $0.baseAddress!, channels: 2) }
        }
        XCTAssertEqual(p, [1, 2, 3, -1, -2, -3])
    }

    /// 3 行目以降は 0。前のブロックの残り（99）を出さない。
    func testSpreadStereoZeroesExtraChannels() {
        let inter: [Float] = [1, -1, 2, -2]
        var p = [Float](repeating: 99, count: 2 * 6)
        inter.withUnsafeBufferPointer { i in
            p.withUnsafeMutableBufferPointer { ETAudioBufferOps.spreadStereo(i.baseAddress!, frames: 2,
                                                                             into: $0.baseAddress!, channels: 6) }
        }
        XCTAssertEqual(Array(p[0..<4]), [1, 2, -1, -2])
        XCTAssertEqual(Array(p[4...]), [Float](repeating: 0, count: 8))
    }

    /// 書くのは frames * channels まで。その先（容量の残り）には触らない。
    func testSpreadStereoWritesOnlyTheBlock() {
        let inter: [Float] = [1, -1]
        var p = [Float](repeating: 99, count: 8)
        inter.withUnsafeBufferPointer { i in
            p.withUnsafeMutableBufferPointer { ETAudioBufferOps.spreadStereo(i.baseAddress!, frames: 1,
                                                                             into: $0.baseAddress!, channels: 2) }
        }
        XCTAssertEqual(p, [1, -1, 99, 99, 99, 99, 99, 99])
    }

    // MARK: - writeOutput

    /// チャンネルごとの 1 本ずつ（AVAudioSourceNode の標準の形）。
    func testNonInterleavedBuffers() {
        let out = FakeOutput(lanes: [1, 1], frames: 3)
        let peak = out.write(planar: planar(channels: 2, frames: 3), frames: 3, channels: 2, frameCount: 3)
        XCTAssertEqual(out.storage[0], [1, 2, 3])
        XCTAssertEqual(out.storage[1], [101, 102, 103])
        XCTAssertEqual(peak, 103)
    }

    /// 1 本にインターリーブで 2 レーン。
    func testInterleavedLanes() {
        let out = FakeOutput(lanes: [2], frames: 3)
        _ = out.write(planar: planar(channels: 2, frames: 3), frames: 3, channels: 2, frameCount: 3)
        XCTAssertEqual(out.storage[0], [1, 101, 2, 102, 3, 103])
    }

    /// 混在: 2 レーンの 1 本 + 1 レーンの 2 本 = 4ch。前から順に受け持つ。
    func testMixedLaneLayout() {
        let out = FakeOutput(lanes: [2, 1, 1], frames: 2)
        _ = out.write(planar: planar(channels: 4, frames: 2), frames: 2, channels: 4, frameCount: 2)
        XCTAssertEqual(out.storage[0], [1, 101, 2, 102])
        XCTAssertEqual(out.storage[1], [201, 202])
        XCTAssertEqual(out.storage[2], [301, 302])
    }

    /// 口が少ない（4ch を 2 本へ）: 3・4 本目は書かず、ピークにも入れない。
    func testFewerBuffersThanChannels() {
        let out = FakeOutput(lanes: [1, 1], frames: 2)
        let peak = out.write(planar: planar(channels: 4, frames: 2), frames: 2, channels: 4, frameCount: 2)
        XCTAssertEqual(out.storage[0], [1, 2])
        XCTAssertEqual(out.storage[1], [101, 102])
        XCTAssertEqual(peak, 102, "書いていない 3・4 本目（最大 302）はメーターに入れない")
    }

    /// 口が多い（2ch を 4 本へ）: 残りは 0 で埋める（前の中身を鳴らさない）。
    func testMoreBuffersThanChannels() {
        let out = FakeOutput(lanes: [1, 1, 1, 1], frames: 2)
        _ = out.write(planar: planar(channels: 2, frames: 2), frames: 2, channels: 2, frameCount: 2)
        XCTAssertEqual(out.storage[2], [0, 0])
        XCTAssertEqual(out.storage[3], [0, 0])
    }

    /// インターリーブの 1 本がプレーナより広い（2ch を 4 レーンへ）: 余ったレーンは 0。
    func testInterleavedWiderThanChannels() {
        let out = FakeOutput(lanes: [4], frames: 2)
        _ = out.write(planar: planar(channels: 2, frames: 2), frames: 2, channels: 2, frameCount: 2)
        XCTAssertEqual(out.storage[0], [1, 101, 0, 0, 2, 102, 0, 0])
    }

    /// 出力が容量より多いフレームを求めた（frameCount > n）: n より先は 0。
    /// 容量ぶんのプレーナしか無いので、その先を読まないことも兼ねる。
    func testMoreFramesThanCapacity() {
        let out = FakeOutput(lanes: [1, 1], frames: 5)
        let peak = out.write(planar: planar(channels: 2, frames: 3), frames: 3, channels: 2, frameCount: 5)
        XCTAssertEqual(out.storage[0], [1, 2, 3, 0, 0])
        XCTAssertEqual(out.storage[1], [101, 102, 103, 0, 0])
        XCTAssertEqual(peak, 103)
    }

    /// レーン数 0 は 1 として扱う。
    func testZeroLanesTreatedAsOne() {
        let out = FakeOutput(lanes: [0, 0], frames: 2)
        _ = out.write(planar: planar(channels: 2, frames: 2), frames: 2, channels: 2, frameCount: 2)
        XCTAssertEqual(out.storage[0], [1, 2])
        XCTAssertEqual(out.storage[1], [101, 102])
    }

    /// 先頭が nil のバッファは飛ばし、チャンネルも消費しない（次の口が同じ行を受け持つ）。
    func testNilBufferIsSkippedWithoutConsumingAChannel() {
        let out = FakeOutput(lanes: [1, 1, 1], frames: 2)
        out.present[0] = false
        _ = out.write(planar: planar(channels: 2, frames: 2), frames: 2, channels: 2, frameCount: 2)
        XCTAssertEqual(out.storage[0], [-9, -9], "nil の口には書かない")
        XCTAssertEqual(out.storage[1], [1, 2])
        XCTAssertEqual(out.storage[2], [101, 102])
    }

    /// ピークは絶対値。NaN は拾わない（値はそのまま出す）。
    func testPeakOfOutputUsesAbsoluteValueAndIgnoresNaN() {
        let out = FakeOutput(lanes: [1, 1], frames: 2)
        let p: [Float] = [-0.9, .nan, 0.5, 0.1]
        let peak = out.write(planar: p, frames: 2, channels: 2, frameCount: 2)
        XCTAssertEqual(peak, 0.9)
        XCTAssertTrue(out.storage[0][1].isNaN)
    }

    func testNothingToWrite() {
        let out = FakeOutput(lanes: [1], frames: 2)
        XCTAssertEqual(out.write(planar: [1, 2], frames: 2, channels: 1, frameCount: 0), 0)
        XCTAssertEqual(out.storage[0], [-9, -9])
        let none = FakeOutput(lanes: [], frames: 2)
        XCTAssertEqual(none.write(planar: [1, 2], frames: 2, channels: 1, frameCount: 2), 0)
    }

    // MARK: - Audio Unit との受け渡し

    /// 行の幅が違うプレーナ（stride = maxFrames）とインターリーブの両方へ写す。
    /// 取り違えると、ブロックが maxFrames より短いときだけ 2 本目以降がずれる。
    func testStageUsesStrideForPlanarOut() {
        let src = planar(channels: 3, frames: 2)          // 1,2 | 101,102 | 201,202
        var pl = [Float](repeating: -1, count: 3 * 4)       // stride 4
        var inter = [Float](repeating: -1, count: 3 * 2)
        src.withUnsafeBufferPointer { s in
            pl.withUnsafeMutableBufferPointer { p in
                inter.withUnsafeMutableBufferPointer { i in
                    ETAudioBufferOps.stage(s.baseAddress!, frames: 2, channels: 3,
                                           planarOut: p.baseAddress!, stride: 4,
                                           interleavedOut: i.baseAddress!)
                }
            }
        }
        XCTAssertEqual(pl, [1, 2, -1, -1, 101, 102, -1, -1, 201, 202, -1, -1])
        XCTAssertEqual(inter, [1, 101, 201, 2, 102, 202])
    }

    func testDeinterleave() {
        let inter: [Float] = [1, 101, 201, 2, 102, 202]
        var p = [Float](repeating: -1, count: 6)
        inter.withUnsafeBufferPointer { i in
            p.withUnsafeMutableBufferPointer {
                ETAudioBufferOps.deinterleave(i.baseAddress!, frames: 2, channels: 3, into: $0.baseAddress!)
            }
        }
        XCTAssertEqual(p, planar(channels: 3, frames: 2))
    }

    /// stage → deinterleave で元に戻る（AU が素通しで返したとき）。
    func testStageThenDeinterleaveRoundTrips() {
        for (channels, frames) in [(1, 5), (2, 7), (6, 3), (16, 4)] {
            let src = planar(channels: channels, frames: frames)
            var pl = [Float](repeating: 0, count: channels * 8)
            var inter = [Float](repeating: 0, count: channels * frames)
            var back = [Float](repeating: 0, count: channels * frames)
            src.withUnsafeBufferPointer { s in
                pl.withUnsafeMutableBufferPointer { p in
                    inter.withUnsafeMutableBufferPointer { i in
                        ETAudioBufferOps.stage(s.baseAddress!, frames: frames, channels: channels,
                                               planarOut: p.baseAddress!, stride: 8,
                                               interleavedOut: i.baseAddress!)
                    }
                }
            }
            inter.withUnsafeBufferPointer { i in
                back.withUnsafeMutableBufferPointer {
                    ETAudioBufferOps.deinterleave(i.baseAddress!, frames: frames, channels: channels,
                                                  into: $0.baseAddress!)
                }
            }
            XCTAssertEqual(back, src, "\(channels)ch × \(frames)")
        }
    }

    // MARK: - 負荷

    func testSmoothedLoad() {
        // 1 ブロックで差の 10% だけ動く。
        XCTAssertEqual(ETAudioBufferOps.smoothedLoad(0, spent: 0.005, budget: 0.01), 0.05, accuracy: 1e-12)
        // 同じ負荷が続けば収束する。
        var load = 0.0
        for _ in 0..<200 { load = ETAudioBufferOps.smoothedLoad(load, spent: 0.003, budget: 0.01) }
        XCTAssertEqual(load, 0.3, accuracy: 1e-6)
    }

    /// 使える時間が 0 でも無限や NaN にならない（1ns で押さえる）。
    func testSmoothedLoadWithZeroBudgetIsFinite() {
        let load = ETAudioBufferOps.smoothedLoad(0, spent: 1e-6, budget: 0)
        XCTAssertTrue(load.isFinite)
        XCTAssertEqual(load, 100, accuracy: 1e-9)
    }

    // MARK: - ETPeakMeter

    private func fed(_ peaks: [(Float, Int)], sampleRate: Double = 48000) -> ETPeakMeter {
        var m = ETPeakMeter()
        for (p, frames) in peaks { m.feed(blockPeak: p, frames: frames, sampleRate: sampleRate) }
        return m
    }

    /// 上がるときはそのブロックの山へすぐ跳ぶ。
    func testPeakMeterRisesAtOnce() {
        let m = fed([(0.5, 480)])
        XCTAssertEqual(m.peak, 0.5)
        XCTAssertEqual(m.clips, 0)
    }

    /// 下がるときは 20 dB/秒。0.1 秒で -2 dB。
    func testPeakMeterFallsTwentyDBPerSecond() {
        let m = fed([(1.0, 480), (0, 4800)])
        XCTAssertEqual(m.clips, 1)
        XCTAssertEqual(m.peak, Float(pow(10, -2.0 / 20)), accuracy: 1e-4)
    }

    /// 落ちている途中でも高いブロックが来ればそちらへ。低いブロックは落ちた値を持ち上げない。
    func testPeakMeterHigherBlockWinsLowerDoesNotRaise() {
        let higher = fed([(0.5, 480), (0, 4800), (0.8, 480)])
        XCTAssertEqual(higher.peak, 0.8)
        let falling = fed([(1.0, 480), (0, 4800)])
        let lower = fed([(1.0, 480), (0, 4800), (0.1, 480)])
        XCTAssertLessThan(lower.peak, falling.peak)
        XCTAssertGreaterThan(lower.peak, 0.1)
    }

    /// ちょうど 1.0 は数え、その少し下は数えない。
    func testPeakMeterClipEdge() {
        XCTAssertEqual(fed([(1.0, 480)]).clips, 1)
        XCTAssertEqual(fed([(0.99999, 480)]).clips, 0)
        XCTAssertEqual(fed([(1.0, 480), (0.5, 480), (1.2, 480)]).clips, 2)
    }

    /// inf は上限で止めてクリップに数える。そのあと落ちきって 0 に戻る（張り付かない）。
    func testPeakMeterInfinityIsCappedAndFalls() {
        var m = fed([(.infinity, 480)])
        XCTAssertEqual(m.peak, ETPeakMeter.ceiling)
        XCTAssertEqual(m.clips, 1)
        m.feed(blockPeak: 0, frames: 480000, sampleRate: 48000)
        XCTAssertTrue(m.peak.isFinite)
        XCTAssertEqual(m.peak, 0)
    }

    /// NaN は 0 として扱い、クリップにしない。
    func testPeakMeterNaNIsZero() {
        let m = fed([(.nan, 480)])
        XCTAssertEqual(m.peak, 0)
        XCTAssertEqual(m.clips, 0)
    }

    /// -100 dB（5 秒）まで落ちたらちょうど 0。
    func testPeakMeterFloorsToZero() {
        XCTAssertEqual(fed([(1.0, 480), (0, 240000)]).peak, 0)
    }

    /// フレーム数 0 やレート 0 では落ちない（割り算で飛ばない）。
    func testPeakMeterDegenerateInputDoesNotFall() {
        XCTAssertEqual(fed([(0.5, 480), (0, 0)]).peak, 0.5)
        XCTAssertEqual(fed([(0.5, 480), (0, 4800)], sampleRate: 0).peak, 0.5)
        XCTAssertEqual(fed([(0.5, -10)]).peak, 0.5)
    }

    // MARK: - ETPeakHold

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    /// 何も掴んでいなければ下端。
    func testPeakHoldStartsAtFloor() {
        XCTAssertEqual(ETPeakHold().value(at: t0), -96)
    }

    /// 1 秒は掴んだ山のまま、そのあと 20 dB/秒で落ちる。
    func testPeakHoldHoldsThenFalls() {
        var h = ETPeakHold()
        h.feed(-3, at: t0)
        XCTAssertEqual(h.value(at: t0.addingTimeInterval(0.9)), -3, accuracy: 1e-9)
        XCTAssertEqual(h.value(at: t0.addingTimeInterval(1.5)), -13, accuracy: 1e-9)
    }

    /// 無音で段の値が変わらなくなっても、時刻だけで下端まで落ちきる（-76 dB で止まらない）。
    func testPeakHoldReachesFloorWithoutNewInput() {
        var h = ETPeakHold()
        h.feed(-3, at: t0)
        // 山が下端に張り付いてから、同じ値が来続ける（掴み直さない）。
        h.feed(-96, at: t0.addingTimeInterval(4.0))
        h.feed(-96, at: t0.addingTimeInterval(4.1))
        // 保持 1 秒 + 93 dB / 20 dB/秒 = 5.65 秒で下端。
        XCTAssertEqual(h.value(at: t0.addingTimeInterval(4.1)), -65, accuracy: 1e-6)
        XCTAssertEqual(h.value(at: t0.addingTimeInterval(5.65)), -96, accuracy: 1e-6)
        XCTAssertEqual(h.value(at: t0.addingTimeInterval(60)), -96)
    }

    /// 線より下の山は掴み直さない。上（同じ値も）なら保持を数え直す。
    func testPeakHoldOnlyHigherOrEqualRecaptures() {
        var h = ETPeakHold()
        h.feed(-3, at: t0)
        h.feed(-20, at: t0.addingTimeInterval(0.5))
        XCTAssertEqual(h.value(at: t0.addingTimeInterval(1.5)), -13, accuracy: 1e-9)
        h.feed(-1, at: t0.addingTimeInterval(1.5))
        XCTAssertEqual(h.value(at: t0.addingTimeInterval(2.4)), -1, accuracy: 1e-9)
    }

    /// 0 dB を超える山はそのまま持つ（赤にするのは別）。NaN は捨てる。
    func testPeakHoldAboveZeroAndNaN() {
        var h = ETPeakHold()
        h.feed(.nan, at: t0)
        XCTAssertEqual(h.value(at: t0), -96)
        h.feed(6, at: t0)
        XCTAssertEqual(h.value(at: t0), 6)
    }
}
