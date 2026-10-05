//  SignalMeter.swift
//  鎖の外に固定で出す 2 つのメーター。IN は鎖の頭（入ってきた音、鎖の前）、OUT は出力補正の行
//  （鎖と補正を通って端末へ渡す音。補正の入切にかかわらず出す）。
//  見た目は Level Meter のカードと同じ MeterView（-96〜0 dB、落下 20 dB/秒、ピーク保持 1 秒）。
//  棒はチャンネルごと。IN はリンクの L / R、OUT は端末へ渡している本数（ふつうは L / R、
//  多チャンネルの IF なら 1〜N。段の名前は Level Meter と同じ LevelMeterView.label）。
//  上の読み値は "IN" / "OUT" の 1 つだけで、いちばん大きいチャンネルの値。
//  どれかのチャンネルが 0 dBFS に届いたら LevelMeterView.overloadTime のあいだ赤（届いた段には印も）。
//
//  ピークの保持は MeterView に任せない（holdsPeak: false）。MeterView の保持は段の値が
//  変わったときだけ進むので、無音で棒が下端に張り付くと線が -76 dB で止まり、止めたときは
//  最後の山のまま残っていた。ここは ETPeakHold を拍の時刻で読み、止めたら捨てる。
//
//  **AudioIO は観測しない。**TimelineView の拍（30Hz）ごとに AudioIO.inputMeter / outputMeter
//  （@Published でない）を読むだけ。作り直されるのはこの View だけで、鎖の画面は動かない。
//  鳴っていないとき（active が偽）は拍を止めて、0 の L / R を出す。
import SwiftUI

struct ETSignalMeter: View {
    enum Point { case input, output }
    let point: Point
    /// 鳴っているか。PipelineView が io.running から写した @State をそのまま渡す。
    let active: Bool

    /// 赤を出し続ける終わりの時刻。チャンネルごと。
    @State private var clipUntil: [Int: Date] = [:]
    /// ピークの線と読み値。チャンネルごと（本数が変わったら作り直す）。
    @State private var holds: [ETPeakHold] = []

    private static var emptyHold: ETPeakHold {
        ETPeakHold(holdTime: LevelMeterView.holdTime, fallRate: LevelMeterView.fallRate,
                   floorDB: LevelMeterView.floorDB)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !active)) { context in
            let meters = active ? read() : ETChannelPeakMeters(channels: 2)
            let levels = meters.peaks.map { ETdB.fromAmplitude($0, floor: LevelMeterView.floorDB) }
            let channels = channelRows(levels, at: context.date)
            MeterView(channels: channels,
                      range: LevelMeterView.floorDB...0,
                      ticks: LevelMeterView.ticks,
                      holdsPeak: false,
                      rowHeight: levels.count > 2 ? 9 : 13,
                      showsReadout: true,
                      readoutLabel: point == .input ? "IN" : "OUT")
                .tint(channels.contains(where: { $0.clipped }) ? Color.red : nil)
                // クリップの数が増えた段を赤にする。止まっている間の 0 への戻りでは点けない。
                .onChange(of: meters.clipCounts) { old, new in
                    guard active else { return }
                    for ch in ETChannelPeakMeters.newlyClipped(from: old, to: new) {
                        clipUntil[ch] = context.date.addingTimeInterval(LevelMeterView.overloadTime)
                    }
                }
                .onChange(of: levels, initial: true) { _, new in
                    if active { feedHolds(new, at: context.date) }
                }
        }
        .onChange(of: active) { _, on in
            if !on {
                clipUntil = [:]
                holds = []
            }
        }
        .accessibilityIdentifier(point == .input ? "inputMeter" : "outputMeter")
    }

    /// 段を並べる。棒はその拍の値、線は保持（掴む前の拍でも棒より下にならないよう、いまの値とも比べる）。
    /// 止まっていれば線は下端で、赤も出さない。
    private func channelRows(_ levels: [Double], at now: Date) -> [ETMeterChannel] {
        levels.indices.map { ch in
            let held = holds.indices.contains(ch) ? holds[ch].value(at: now) : LevelMeterView.floorDB
            let clipped = active && (clipUntil[ch].map { now < $0 } ?? false)
            return ETMeterChannel(id: ch,
                                  label: LevelMeterView.label(ch, of: levels.count),
                                  levelDB: levels[ch],
                                  peakDB: active ? max(levels[ch], held) : LevelMeterView.floorDB,
                                  clipped: clipped)
        }
    }

    /// 段ごとの保持へ新しい値を入れる。本数が変わったら（出力先を替えて作り直したとき）空から始める。
    private func feedHolds(_ levels: [Double], at now: Date) {
        var next = holds.count == levels.count
            ? holds : Array(repeating: Self.emptyHold, count: levels.count)
        for ch in levels.indices { next[ch].feed(levels[ch], at: now) }
        holds = next
    }

    private func read() -> ETChannelPeakMeters {
        point == .input ? AudioIO.shared.inputMeter : AudioIO.shared.outputMeter
    }
}
