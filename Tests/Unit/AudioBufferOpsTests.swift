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
        func write(planar: [Float], frames: Int, channels: Int, frameCount: Int,
                   channelPeaks: UnsafeMutablePointer<Float>? = nil) -> Float {
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
                                             frameCount: frameCount, bufferCount: storage.count,
                                             channelPeaks: channelPeaks) { k in
                    (self.present[k] ? pointers[k] : nil, self.lanes[k])
                }
            }
        }

        /// チャンネルごとのピークも受け取る。受け皿は前の値（-9）で汚しておき、全部書き直されるかを見る。
        func writePeaks(planar: [Float], frames: Int, channels: Int,
                        frameCount: Int) -> (peak: Float, channels: [Float]) {
            var peaks = [Float](repeating: -9, count: channels)
            let peak = peaks.withUnsafeMutableBufferPointer { cp in
                write(planar: planar, frames: frames, channels: channels, frameCount: frameCount,
                      channelPeaks: cp.baseAddress!)
            }
            return (peak, peaks)
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

    /// インターリーブの 1 チャンネルぶん（stride 2）。L は先頭から、R は 1 つずらして。
    func testStridedPeakReadsOneChannel() {
        let s: [Float] = [0.1, -0.9, -0.5, 0.2, .nan, 0.3]
        s.withUnsafeBufferPointer { b in
            let l = ETAudioBufferOps.peak(b.baseAddress!, count: 3, stride: 2)
            let r = ETAudioBufferOps.peak(b.baseAddress! + 1, count: 3, stride: 2)
            XCTAssertEqual(l, 0.5)
            XCTAssertEqual(r, 0.9)
            // L と R の大きいほうは、全体の山と同じ（ゲートに渡す値は変わらない）。
            XCTAssertEqual(max(l, r), ETAudioBufferOps.peak(b.baseAddress!, count: 6))
            XCTAssertEqual(ETAudioBufferOps.peak(b.baseAddress!, count: 0, stride: 2), 0)
            XCTAssertEqual(ETAudioBufferOps.peak(b.baseAddress!, count: 3, stride: 0), 0)
        }
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

    /// チャンネルごとのピーク（OUT のメーター）。本ごとに別に取り、全体のピークは今までどおり。
    func testWriteOutputChannelPeaks() {
        let out = FakeOutput(lanes: [1, 1], frames: 3)
        var pl = planar(channels: 2, frames: 3)
        pl[1] = -150   // L の負の値は絶対値で数える
        let r = out.writePeaks(planar: pl, frames: 3, channels: 2, frameCount: 3)
        XCTAssertEqual(r.channels, [150, 103])
        XCTAssertEqual(r.peak, 150)
    }

    /// インターリーブの口と混在の口でも、本ごとに正しい行のピークになる。
    func testWriteOutputChannelPeaksMixedLanes() {
        let out = FakeOutput(lanes: [2, 1, 1], frames: 2)
        let r = out.writePeaks(planar: planar(channels: 4, frames: 2), frames: 2, channels: 4, frameCount: 2)
        XCTAssertEqual(r.channels, [2, 102, 202, 302])
    }

    /// 口が足りず書かなかった行は 0（前の値を残さない）。
    func testWriteOutputChannelPeaksUnwrittenRowsAreZero() {
        let out = FakeOutput(lanes: [1, 1], frames: 2)
        let r = out.writePeaks(planar: planar(channels: 4, frames: 2), frames: 2, channels: 4, frameCount: 2)
        XCTAssertEqual(r.channels, [2, 102, 0, 0])
        XCTAssertEqual(r.peak, 102)
    }

    /// 先頭が nil の口は飛ばしてチャンネルを消費しないので、L は次の口へ行き、R は書かれない。
    func testWriteOutputChannelPeaksSkipNilBuffer() {
        let out = FakeOutput(lanes: [1, 1], frames: 2)
        out.present[0] = false
        let r = out.writePeaks(planar: planar(channels: 2, frames: 2), frames: 2, channels: 2, frameCount: 2)
        XCTAssertEqual(r.channels, [2, 0])
    }

    /// 出力が 0 フレームでも受け皿は 0 にする。NaN は拾わない。
    func testWriteOutputChannelPeaksDegenerate() {
        let empty = FakeOutput(lanes: [1, 1], frames: 1)
        XCTAssertEqual(empty.writePeaks(planar: planar(channels: 2, frames: 1), frames: 1, channels: 2,
                                        frameCount: 0).channels, [0, 0])
        let out = FakeOutput(lanes: [1, 1], frames: 2)
        let r = out.writePeaks(planar: [.nan, 0.5, 0.25, .nan], frames: 2, channels: 2, frameCount: 2)
        XCTAssertEqual(r.channels, [0.5, 0.25])
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

    // MARK: - ETChannelPeakMeters

    /// 並べ場の数が上限と食い違っていない（食い違うと範囲の外を読み書きする）。上限は DSP と同じ 16。
    func testChannelMetersStorageMatchesMaximum() {
        XCTAssertEqual(ETChannelPeakMeters.storageCapacity, ETChannelPeakMeters.maxChannels)
        XCTAssertEqual(ETChannelPeakMeters.maxChannels, ETAudioSessionRules.maxChannels)
    }

    /// 本数は 0〜16 に収める。作った直後は全部 0。
    func testChannelMetersCountIsClamped() {
        XCTAssertEqual(ETChannelPeakMeters(channels: 2).count, 2)
        XCTAssertEqual(ETChannelPeakMeters(channels: 40).count, 16)
        XCTAssertEqual(ETChannelPeakMeters(channels: -1).count, 0)
        XCTAssertEqual(ETChannelPeakMeters(channels: 6).peaks, [Float](repeating: 0, count: 6))
        XCTAssertEqual(ETChannelPeakMeters(channels: 6).clipCounts, [UInt32](repeating: 0, count: 6))
    }

    /// L と R は別々に上がり、別々に数える。
    func testChannelMetersAreIndependent() {
        var m = ETChannelPeakMeters(channels: 2)
        m.feed(channel: 0, blockPeak: 0.5, frames: 480, sampleRate: 48000)
        m.feed(channel: 1, blockPeak: 1.0, frames: 480, sampleRate: 48000)
        XCTAssertEqual(m.peaks, [0.5, 1.0])
        XCTAssertEqual(m.clipCounts, [0, 1])
        XCTAssertEqual(m[1].clips, 1)
        // 範囲の外は 0 のまま、入れても捨てる。
        XCTAssertEqual(m[2], ETPeakMeter())
        XCTAssertEqual(m[-1], ETPeakMeter())
        m.feed(channel: 2, blockPeak: 1.0, frames: 480, sampleRate: 48000)
        m.feed(channel: -1, blockPeak: 1.0, frames: 480, sampleRate: 48000)
        XCTAssertEqual(m.peaks, [0.5, 1.0])
        XCTAssertEqual(m.clipCounts, [0, 1])
    }

    /// 16 本の端まで、それぞれの位置に入る（並べ場のずらし方を確かめる）。
    func testChannelMetersAllSixteenSlots() {
        var m = ETChannelPeakMeters(channels: 16)
        for ch in 0..<16 {
            m.feed(channel: ch, blockPeak: Float(ch + 1) / 32, frames: 480, sampleRate: 48000)
        }
        XCTAssertEqual(m.peaks, (0..<16).map { Float($0 + 1) / 32 })
        m.feed(channel: 15, blockPeak: 2, frames: 480, sampleRate: 48000)
        XCTAssertEqual(m.clipCounts, [UInt32](repeating: 0, count: 15) + [1])
    }

    /// まとめて入れる形（writeOutput の受け皿から）。本数が合わなければ短いほうまで。
    func testChannelMetersFeedFromBuffer() {
        var m = ETChannelPeakMeters(channels: 3)
        let peaks: [Float] = [0.25, 1.0, 0.5, 0.75]
        peaks.withUnsafeBufferPointer {
            m.feed(blockPeaks: $0.baseAddress!, channels: 4, frames: 480, sampleRate: 48000)
        }
        XCTAssertEqual(m.peaks, [0.25, 1.0, 0.5])
        XCTAssertEqual(m.clipCounts, [0, 1, 0])
        var short = ETChannelPeakMeters(channels: 3)
        peaks.withUnsafeBufferPointer {
            short.feed(blockPeaks: $0.baseAddress!, channels: 1, frames: 480, sampleRate: 48000)
        }
        XCTAssertEqual(short.peaks, [0.25, 0, 0])
    }

    /// 出力が全部 0 のブロック: どの本も 20 dB/秒で落ちる。
    func testChannelMetersFallTogether() {
        var m = ETChannelPeakMeters(channels: 2)
        m.feed(channel: 0, blockPeak: 1.0, frames: 480, sampleRate: 48000)
        m.feed(channel: 1, blockPeak: 0.5, frames: 480, sampleRate: 48000)
        m.fall(frames: 4800, sampleRate: 48000)
        let factor = Float(pow(10, -2.0 / 20))
        XCTAssertEqual(m.peaks[0], factor, accuracy: 1e-4)
        XCTAssertEqual(m.peaks[1], 0.5 * factor, accuracy: 1e-4)
        XCTAssertEqual(m.clipCounts, [1, 0])
        var empty = ETChannelPeakMeters(channels: 0)
        empty.fall(frames: 480, sampleRate: 48000)
        XCTAssertEqual(empty.peaks, [])
    }

    /// 等しさは本数と各本の値で決まる。
    func testChannelMetersEquality() {
        var a = ETChannelPeakMeters(channels: 2)
        var b = ETChannelPeakMeters(channels: 2)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, ETChannelPeakMeters(channels: 3))
        a.feed(channel: 1, blockPeak: 0.5, frames: 480, sampleRate: 48000)
        XCTAssertNotEqual(a, b)
        b.feed(channel: 1, blockPeak: 0.5, frames: 480, sampleRate: 48000)
        XCTAssertEqual(a, b)
    }

    /// 赤にする本: 数が変わって 0 でないもの。0 への戻り（止めて作り直した）や本数が増えたぶんの 0 では点けない。
    func testNewlyClippedChannels() {
        XCTAssertEqual(ETChannelPeakMeters.newlyClipped(from: [0, 0], to: [0, 1]), [1])
        XCTAssertEqual(ETChannelPeakMeters.newlyClipped(from: [2, 1], to: [3, 1]), [0])
        XCTAssertEqual(ETChannelPeakMeters.newlyClipped(from: [2, 1], to: [2, 1]), [])
        XCTAssertEqual(ETChannelPeakMeters.newlyClipped(from: [5, 3], to: [0, 0, 0, 0, 0, 0]), [])
        XCTAssertEqual(ETChannelPeakMeters.newlyClipped(from: [5, 3], to: [0, 1, 0, 0, 0, 2]), [1, 5])
        XCTAssertEqual(ETChannelPeakMeters.newlyClipped(from: [], to: [0, 0]), [])
        XCTAssertEqual(ETChannelPeakMeters.newlyClipped(from: [4, 4], to: []), [])
    }
}
