//  AudioBufferOps.swift
//  音のスレッドで使う並べ替えと書き出し。**生のポインタだけを取る。**
//
//  AudioBufferList も AVAudio* も取らないので、作り物の配列で試せる
//  （AudioBufferOpsTests）。AudioIO の render と ETAUExternalBridge の Adapter が呼ぶ。
//
//  **確保も待ちも ObjC もしない。** 渡される閉包は非エスケープなので積み上げで済む。
//  並べ方の約束: プレーナは「チャンネルごとの行」で、行の幅は明示したもの
//  （既定は frames）。EffeTune のカーネルは offset = channel * frame_count で読む。

import Foundation

enum ETAudioBufferOps {

    // MARK: - 見る

    /// 最大の絶対値。NaN は拾わない（`abs(NaN) > peak` が偽になる）。
    /// PowerGate は NaN を無音として扱うので、ここも同じ向きに倒す。
    static func peak(_ samples: UnsafePointer<Float>, count: Int) -> Float {
        guard count > 0 else { return 0 }
        var peak: Float = 0
        for i in 0..<count {
            let a = abs(samples[i])
            if a > peak { peak = a }
        }
        return peak
    }

    /// `stride` 個おきに `count` 個を見たときの最大の絶対値。インターリーブの 1 チャンネルぶん
    /// （L なら先頭から、R なら 1 つずらして stride 2）。NaN は拾わない（上と同じ）。
    static func peak(_ samples: UnsafePointer<Float>, count: Int, stride: Int) -> Float {
        guard count > 0, stride > 0 else { return 0 }
        var peak: Float = 0
        for i in 0..<count {
            let a = abs(samples[i * stride])
            if a > peak { peak = a }
        }
        return peak
    }

    // MARK: - 入口

    /// リンクのインターリーブ（L,R,L,R…）を、`channels` 行のプレーナへ広げる。
    /// 1 行目が L、2 行目が R。3 行目以降は 0 で埋める（前のブロックの残りを出さない）。
    /// 入力は常に 2ch なので、`interleaved` は `frames * 2` だけ読む。
    static func spreadStereo(_ interleaved: UnsafePointer<Float>, frames: Int,
                             into planar: UnsafeMutablePointer<Float>, channels: Int) {
        guard frames > 0, channels > 0 else { return }
        planar.update(repeating: 0, count: frames * channels)
        if channels >= 2 {
            for i in 0..<frames {
                planar[i]          = interleaved[i * 2]
                planar[frames + i] = interleaved[i * 2 + 1]
            }
        } else {
            for i in 0..<frames { planar[i] = interleaved[i * 2] }
        }
    }

    // MARK: - 出口

    /// プレーナ（行の幅 = frames）を出力のバッファ群へ書く。
    ///
    /// - Parameters:
    ///   - frames: 有効なフレーム数（容量で切った n）。
    ///   - channels: プレーナの行数。
    ///   - frameCount: 出力が求めたフレーム数。frames を超えた分は 0 で埋める。
    ///   - bufferCount: バッファの数。
    ///   - channelPeaks: 渡せば、チャンネルごとに書いた値のピークを入れる（`channels` 個。
    ///     口が足りず書かなかった行は 0）。OUT のメーターがこれを読む。
    ///   - buffer: k 番目のバッファの (先頭, 1 バッファに入っている本数)。
    ///     本数が 2 以上ならインターリーブ（frame * lanes + lane）。0 は 1 として扱う。
    /// - Returns: 書いた値のピーク（NaN は拾わない）。
    ///
    /// バッファは前から順にチャンネルを受け持つ。行の数より口が多ければ残りは 0、
    /// 口が少なければ余った行は書かない（ミキサーが受け持つ）。
    /// **先頭が nil のバッファは飛ばし、チャンネルも消費しない。**
    static func writeOutput(planar: UnsafePointer<Float>, frames: Int, channels: Int,
                            frameCount: Int, bufferCount: Int,
                            channelPeaks: UnsafeMutablePointer<Float>? = nil,
                            buffer: (Int) -> (data: UnsafeMutablePointer<Float>?, lanes: Int)) -> Float {
        if let channelPeaks, channels > 0 { channelPeaks.update(repeating: 0, count: channels) }
        guard frameCount > 0, bufferCount > 0 else { return 0 }
        var peak: Float = 0
        var sourceChannel = 0
        for k in 0..<bufferCount {
            let slot = buffer(k)
            guard let data = slot.data else { continue }
            let lanes = max(1, slot.lanes)
            for i in 0..<frameCount {
                for lane in 0..<lanes {
                    let value: Float
                    if i < frames, sourceChannel + lane < channels {
                        value = planar[(sourceChannel + lane) * frames + i]
                        let a = abs(value)
                        peak = max(peak, a)
                        if let channelPeaks, a > channelPeaks[sourceChannel + lane] {
                            channelPeaks[sourceChannel + lane] = a
                        }
                    } else {
                        value = 0
                    }
                    data[i * lanes + lane] = value
                }
            }
            sourceChannel += lanes
        }
        return peak
    }

    // MARK: - Audio Unit との受け渡し

    /// プレーナ（行の幅 = frames）を、行の幅が `stride` のプレーナと、
    /// インターリーブ（frame * channels + channel）の両方へ写す。
    /// AU がどちらの形で入力を引いても渡せるようにするため（ETAUExternalBridge）。
    static func stage(_ planar: UnsafePointer<Float>, frames: Int, channels: Int,
                      planarOut: UnsafeMutablePointer<Float>, stride: Int,
                      interleavedOut: UnsafeMutablePointer<Float>) {
        guard frames > 0, channels > 0 else { return }
        for frame in 0..<frames {
            for channel in 0..<channels {
                let value = planar[channel * frames + frame]
                planarOut[channel * stride + frame] = value
                interleavedOut[frame * channels + channel] = value
            }
        }
    }

    /// インターリーブ（frame * channels + channel）をプレーナ（行の幅 = frames）へ戻す。
    static func deinterleave(_ interleaved: UnsafePointer<Float>, frames: Int, channels: Int,
                             into planar: UnsafeMutablePointer<Float>) {
        guard frames > 0, channels > 0 else { return }
        for frame in 0..<frames {
            for channel in 0..<channels {
                planar[channel * frames + frame] = interleaved[frame * channels + channel]
            }
        }
    }

    // MARK: - 負荷

    /// 1 ブロックの負荷（使った時間 / 使える時間）を 1 次の平滑で溜める。係数 0.1。
    /// 使える時間が 0 のブロックで割り算が飛ばないよう、下を 1ns で押さえる。
    static func smoothedLoad(_ previous: Double, spent: Double, budget: Double) -> Double {
        previous + (spent / max(budget, 1e-9) - previous) * 0.1
    }
}

/// 鎖の外に出す IN / OUT のメーターの値。**音のスレッドが 1 ブロックごとに進め、画面は読むだけ。**
///
/// 画面が読むのは TimelineView の 30Hz で、ブロックは 5〜20ms ごとに来る。その瞬間のピークだけを
/// 置くと、読む間に来たブロックの山とクリップを取りこぼす。だから山はここで持って落とし
/// （Level Meter と同じ 20 dB/秒。LevelMeterView.fallRate / level_meter.js:16）、
/// 0 dBFS に届いたブロックは数で残す（読む側は数が増えたかで赤にする）。
/// 確保も待ちもしない（pow を 1 回呼ぶだけ）。
struct ETPeakMeter: Equatable {
    /// 線形の振幅。上がるときはそのブロックの山へ跳び、下がるときは 20 dB/秒で落ちる。
    private(set) var peak: Float = 0
    /// 山が 1.0（0 dBFS）以上だったブロックの数。回り込む（&+=）。
    private(set) var clips: UInt32 = 0

    static let fallDBPerSecond: Double = 20
    /// ここまで落ちたら 0 にする（-100 dB。目盛りの下端 -96 dB の外）。
    static let floor: Float = 1e-5
    /// 山の上限（+24 dB）。inf が来ても落ちなくならないように。
    static let ceiling: Float = 16

    mutating func feed(blockPeak: Float, frames: Int, sampleRate: Double) {
        let p = blockPeak.isNaN ? 0 : min(max(blockPeak, 0), Self.ceiling)
        // ちょうど 1.0 も数える（LevelMeterView は > 1 だが、ここは 0 dBFS に届いたら赤）。
        if p >= 1 { clips &+= 1 }
        let seconds = sampleRate > 0 ? Double(max(frames, 0)) / sampleRate : 0
        let fallen = peak * Float(pow(10, -Self.fallDBPerSecond * seconds / 20))
        peak = max(p, fallen <= Self.floor ? 0 : fallen)
    }
}

/// IN / OUT のメーターのピークの線（と読み値）。1 秒保持して 20 dB/秒で落ちる（MeterView と同じ数）。
///
/// **値は時刻だけで決まる。**MeterView の保持は段の値が変わったときだけ進むので、
/// 無音で棒が下端に張り付くと段が変わらなくなり、線が下端の 20 dB 上（-76 dB）で止まっていた。
/// ここは最後に掴んだ山と時刻だけを持ち、線の位置は読むたびに時刻から出す。
/// 画面は TimelineView の拍の時刻で value(at:) を呼ぶだけでよい。
struct ETPeakHold: Equatable {
    var holdTime: Double = 1.0
    /// dB/秒。
    var fallRate: Double = 20
    /// 目盛りの下端。ここより下は出さない。
    var floorDB: Double = -96

    /// 最後に掴んだ山（dB）と、その時刻。まだ何も掴んでいなければ nil。
    private(set) var peakDB: Double?
    private(set) var capturedAt: Date?

    init(holdTime: Double = 1.0, fallRate: Double = 20, floorDB: Double = -96) {
        self.holdTime = holdTime
        self.fallRate = fallRate
        self.floorDB = floorDB
    }

    /// `now` の線の位置。保持のあいだは掴んだ山、過ぎたら落ちて下端で止まる。
    func value(at now: Date) -> Double {
        guard let peakDB, let capturedAt else { return floorDB }
        let falling = max(0, now.timeIntervalSince(capturedAt) - holdTime)
        return max(floorDB, peakDB - fallRate * falling)
    }

    /// 新しい山。いまの線以上なら掴み直す（保持をそこから数え直す）。下なら何もしない。
    mutating func feed(_ db: Double, at now: Date) {
        // NaN・inf は捨てる（ETPeakMeter が上限 +24 dB で止めているので、来るのは壊れた値だけ）。
        guard db.isFinite, db > floorDB, db >= value(at: now) else { return }
        peakDB = db
        capturedAt = now
    }
}

/// IN / OUT のメーターをチャンネルごとに持つ（ETPeakMeter を本数ぶん）。IN は L / R の 2 本、
/// OUT は端末へ渡している本数（AudioIO の RenderState.channels。ふつうは 2、多チャンネルの IF なら最大 16）。
///
/// **音のスレッドが書くので配列を使わない。**上限の 16 本（ETAudioSessionRules.maxChannels、DSP の上限）
/// ぶんを値の中に固定で並べ、確保も参照の数え上げもしない。メインは丸ごと写して読む
/// （ETPeakMeter を読んでいたのと同じ形。本と本が別のブロックのものになることはあるが、出すだけなので構わない）。
struct ETChannelPeakMeters: Equatable {
    /// 持てる本数の上限。並べ場（Storage）の数と同じにしておく（AudioBufferOpsTests）。
    static let maxChannels = 16

    private typealias Storage = (ETPeakMeter, ETPeakMeter, ETPeakMeter, ETPeakMeter,
                                 ETPeakMeter, ETPeakMeter, ETPeakMeter, ETPeakMeter,
                                 ETPeakMeter, ETPeakMeter, ETPeakMeter, ETPeakMeter,
                                 ETPeakMeter, ETPeakMeter, ETPeakMeter, ETPeakMeter)

    /// 並べ場に入る本数。maxChannels と食い違っていないかをテストで見る。
    static var storageCapacity: Int {
        MemoryLayout<Storage>.size / MemoryLayout<ETPeakMeter>.stride
    }

    /// 出している本数（0〜maxChannels）。
    let count: Int
    private var storage: Storage

    init(channels: Int) {
        count = min(max(channels, 0), Self.maxChannels)
        let m = ETPeakMeter()
        storage = (m, m, m, m, m, m, m, m, m, m, m, m, m, m, m, m)
    }

    /// `channel` 本目。範囲の外は 0 のまま（ETPeakMeter()）。
    subscript(channel: Int) -> ETPeakMeter {
        guard channel >= 0, channel < count else { return ETPeakMeter() }
        // 同じ型だけのタプルは要素の型で並んでいる。ずらして読むだけ。
        return withUnsafeBytes(of: storage) { raw in
            raw.load(fromByteOffset: channel * MemoryLayout<ETPeakMeter>.stride, as: ETPeakMeter.self)
        }
    }

    /// `channel` 本目に 1 ブロックの山を入れる（ETPeakMeter.feed）。範囲の外は捨てる。
    mutating func feed(channel: Int, blockPeak: Float, frames: Int, sampleRate: Double) {
        guard channel >= 0, channel < count else { return }
        withUnsafeMutableBytes(of: &storage) { raw in
            let meters = raw.baseAddress!.assumingMemoryBound(to: ETPeakMeter.self)
            meters[channel].feed(blockPeak: blockPeak, frames: frames, sampleRate: sampleRate)
        }
    }

    /// 先頭から `channels` 本ぶんの山を入れる（writeOutput の channelPeaks をそのまま渡す）。
    /// 本数が合わなければ短いほうまで。
    mutating func feed(blockPeaks: UnsafePointer<Float>, channels: Int, frames: Int, sampleRate: Double) {
        let n = min(max(channels, 0), count)
        guard n > 0 else { return }
        withUnsafeMutableBytes(of: &storage) { raw in
            let meters = raw.baseAddress!.assumingMemoryBound(to: ETPeakMeter.self)
            for ch in 0..<n {
                meters[ch].feed(blockPeak: blockPeaks[ch], frames: frames, sampleRate: sampleRate)
            }
        }
    }

    /// 全部の本に無音のブロックを入れる（出力が全部 0 のとき。同じ落ち方で下がる）。
    mutating func fall(frames: Int, sampleRate: Double) {
        guard count > 0 else { return }
        let n = count
        withUnsafeMutableBytes(of: &storage) { raw in
            let meters = raw.baseAddress!.assumingMemoryBound(to: ETPeakMeter.self)
            for ch in 0..<n {
                meters[ch].feed(blockPeak: 0, frames: frames, sampleRate: sampleRate)
            }
        }
    }

    // MARK: 読む（メインだけ。配列を作る）

    /// 本ごとの山（線形）。
    var peaks: [Float] { (0..<count).map { self[$0].peak } }
    /// 本ごとのクリップの数。
    var clipCounts: [UInt32] { (0..<count).map { self[$0].clips } }

    /// 前の拍から新しくクリップした本。数が変わって、しかも 0 でないもの
    /// （止めて作り直すと数は 0 から始まるので、0 への戻りでは赤にしない）。本数が変わったぶんは前を 0 とみなす。
    static func newlyClipped(from old: [UInt32], to new: [UInt32]) -> [Int] {
        new.indices.filter { ch in
            let before = old.indices.contains(ch) ? old[ch] : 0
            return new[ch] != before && new[ch] != 0
        }
    }

    static func == (a: Self, b: Self) -> Bool {
        a.count == b.count && (0..<a.count).allSatisfy { a[$0] == b[$0] }
    }
}
