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
    ///   - buffer: k 番目のバッファの (先頭, 1 バッファに入っている本数)。
    ///     本数が 2 以上ならインターリーブ（frame * lanes + lane）。0 は 1 として扱う。
    /// - Returns: 書いた値のピーク（NaN は拾わない）。
    ///
    /// バッファは前から順にチャンネルを受け持つ。行の数より口が多ければ残りは 0、
    /// 口が少なければ余った行は書かない（ミキサーが受け持つ）。
    /// **先頭が nil のバッファは飛ばし、チャンネルも消費しない。**
    static func writeOutput(planar: UnsafePointer<Float>, frames: Int, channels: Int,
                            frameCount: Int, bufferCount: Int,
                            buffer: (Int) -> (data: UnsafeMutablePointer<Float>?, lanes: Int)) -> Float {
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
                        peak = max(peak, abs(value))
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
