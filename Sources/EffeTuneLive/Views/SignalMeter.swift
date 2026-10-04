//  SignalMeter.swift
//  鎖の外に固定で出す 2 本のメーター。IN は鎖の頭（入ってきた音、鎖の前）、OUT は出力補正の行
//  （鎖と補正を通って端末へ渡す音。補正の入切にかかわらず出す）。
//  見た目は Level Meter のカードと同じ MeterView（-96〜0 dB、落下 20 dB/秒、ピーク保持 1 秒）。
//  1 本だけ（全チャンネルの山）。0 dBFS に届いたら LevelMeterView.overloadTime のあいだ赤。
//
//  **AudioIO は観測しない。**TimelineView の拍（30Hz）ごとに AudioIO.inputMeter / outputMeter
//  （@Published でない）を読むだけ。作り直されるのはこの View だけで、鎖の画面は動かない。
//  鳴っていないとき（active が偽）は拍を止めて 0 を出す。
import SwiftUI

struct ETSignalMeter: View {
    enum Point { case input, output }
    let point: Point
    /// 鳴っているか。PipelineView が io.running から写した @State をそのまま渡す。
    let active: Bool

    /// 赤を出し続ける終わりの時刻。
    @State private var redUntil: Date?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !active)) { context in
            let meter = active ? read() : ETPeakMeter()
            let red = redUntil.map { context.date < $0 } ?? false
            MeterView(channels: [ETMeterChannel(
                          id: 0, label: point == .input ? "IN" : "OUT",
                          levelDB: ETdB.fromAmplitude(meter.peak, floor: LevelMeterView.floorDB),
                          clipped: red)],
                      range: LevelMeterView.floorDB...0,
                      ticks: LevelMeterView.ticks,
                      holdsPeak: true,
                      holdTime: LevelMeterView.holdTime,
                      fallRate: LevelMeterView.fallRate,
                      rowHeight: 13,
                      showsReadout: true,
                      labelWidth: 26)
                .tint(red ? Color.red : nil)
                // クリップの数が増えたら赤にする。止まっている間の 0 への戻りでは点けない。
                .onChange(of: meter.clips) { old, new in
                    if active, new != old {
                        redUntil = context.date.addingTimeInterval(LevelMeterView.overloadTime)
                    }
                }
        }
        .onChange(of: active) { _, on in if !on { redUntil = nil } }
        .accessibilityIdentifier(point == .input ? "inputMeter" : "outputMeter")
    }

    private func read() -> ETPeakMeter {
        point == .input ? AudioIO.shared.inputMeter : AudioIO.shared.outputMeter
    }
}
