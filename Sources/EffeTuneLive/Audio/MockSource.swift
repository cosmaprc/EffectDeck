//  MockSource.swift
//  撮影のときだけ流す、作り物の信号。
//
//  シミュレータには拡張が無いので音が来ない。そのままだと
//  「No audio yet」の画面しか撮れず、メーターも図も全部止まったものになる。
//  画面の半分が見られないので、-ETMock 1 のときだけここが音を作る。
//
//  作る音は「それらしく見える」ことだけを狙う。音楽である必要は無い。
//    - 低音（和音の根音）と、その倍音をいくつか
//    - 上を行き来する掃引。スペアナとスペクトログラムに斜めの筋が出る
//    - 薄い雑音。床が真っ平らにならないように
//    - ゆっくりした強弱。レベルメーターとコンプの GR が動く
//    - 左右で少しずらす。ステレオメーターが点にならない
//
//  実機では -ETMock が付かないので、この型は何もしない。

import Foundation

/// 撮影用の信号を作る。音のスレッドから呼ばれるので、確保も ObjC も使わない。
final class ETMockSource {

    /// 起動の引数で入っているか。
    static var enabled: Bool {
        UserDefaults.standard.bool(forKey: "ETMock")
    }

    /// 和音。A2 を根にした長三和音。倍音は 1/n で落とす。（周波数, 振幅）
    static let chord: [(frequency: Double, amplitude: Double)] = [
        (110.0, 0.50), (138.6, 0.32), (164.8, 0.26),
        (220.0, 0.18), (330.0, 0.10), (440.0, 0.06),
    ]

    /// 掃引。300Hz から 6kHz を 7 秒かけて往復する。
    static let sweepLow = 300.0, sweepHigh = 6000.0, sweepPeriod = 7.0

    /// 右を遅らせる秒数。
    static let rightDelay = 0.00035

    /// 位相を戻す周期（秒）。倍精度でも丸めが効いてくるので、十分長い周期で折り返す。
    ///
    /// **戻した先で全部の成分がちょうど元の位相に居る長さにする。** 7 秒（掃引の往復）、
    /// 3.1 秒（強弱）、それに 138.6Hz と 164.8Hz（どちらも 1/5Hz 刻みなので 5 秒）の
    /// 公倍数で 1085 秒。前は 217 秒（7 と 3.1 の公倍数）で、138.6Hz と 164.8Hz が
    /// 0.2 と 0.6 周期の半端で切れ、217 秒ごとに波形が跳んでいた。
    static let wrapSeconds = 1085.0

    private let sampleRate: Double
    /// 通した標本の数（wrapSeconds で戻る）。位相はここから出す。
    private(set) var phase: Double = 0
    /// 掃引の位相（周期の数、0..<1）。**周波数を積分して出す。**
    /// 周波数に t を掛けて sin に入れると、瞬時周波数が f0 + t·f0' になって秒を追うごとに
    /// 上へ散る（10 秒で数十 kHz、折り返して帯域全体に撒かれる）。
    private var sweepPhase: Double = 0

    init(sampleRate: Double) {
        self.sampleRate = sampleRate > 0 ? sampleRate : 48000
    }

    /// t 秒での掃引の周波数。下と上を指数で往復する。
    static func sweepFrequency(at t: Double) -> Double {
        let u = (t.truncatingRemainder(dividingBy: sweepPeriod)) / sweepPeriod
        let tri = u < 0.5 ? u * 2 : (1 - u) * 2
        return sweepLow * pow(sweepHigh / sweepLow, tri)
    }

    /// 1 標本。
    /// - Parameters:
    ///   - t: 秒。
    ///   - sweep: 掃引の位相（周期の数）。
    ///   - f0: いまの掃引の周波数（右の遅れを位相に直すのに使う）。
    static func frame(t: Double, sweep: Double, sweepFrequency f0: Double) -> (left: Float, right: Float) {
        let twoPi = 2.0 * Double.pi

        var v = 0.0
        for c in chord { v += c.amplitude * sin(twoPi * c.frequency * t) }
        v += 0.12 * sin(twoPi * sweep)
        // 薄い雑音。乱数は使わず、素数比の正弦を掛けて代わりにする。
        v += 0.02 * sin(twoPi * 7331.0 * t) * sin(twoPi * 1117.0 * t)

        // ゆっくりした強弱。0.35 〜 1.0 のあいだを 3.1 秒周期で。
        let env = 0.675 + 0.325 * sin(twoPi * t / 3.1)
        v *= env * 0.42

        // 左右をずらす。右は少し遅らせて、少し小さくする。
        let tR = t - rightDelay
        var vR = 0.0
        for c in chord { vR += c.amplitude * sin(twoPi * c.frequency * tR) }
        vR += 0.12 * sin(twoPi * (sweep - f0 * rightDelay))
        vR *= env * 0.42 * 0.88

        return (Float(max(-1, min(1, v))), Float(max(-1, min(1, vR))))
    }

    /// インターリーブ（L,R,L,R…）で frames ぶん書く。
    func fill(_ out: UnsafeMutablePointer<Float>, frames: Int) {
        let sr = sampleRate
        for i in 0..<max(0, frames) {
            let t = (phase + Double(i)) / sr
            let f0 = Self.sweepFrequency(at: t)
            let s = Self.frame(t: t, sweep: sweepPhase, sweepFrequency: f0)
            out[i * 2]     = s.left
            out[i * 2 + 1] = s.right
            sweepPhase += f0 / sr
            sweepPhase -= sweepPhase.rounded(.down)
        }
        phase += Double(max(0, frames))
        let wrap = sr * Self.wrapSeconds
        if phase >= wrap { phase -= wrap }
    }
}
