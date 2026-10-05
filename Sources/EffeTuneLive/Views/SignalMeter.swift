//  SignalMeter.swift
//  鎖の外に固定で出す 2 つのメーター。IN は鎖の頭（入ってきた音、鎖の前）、OUT は出力補正の行
//  （鎖と補正を通って端末へ渡す音。補正の入切にかかわらず出す）。
//  数字は Level Meter と同じ（-96〜0 dB、落下 20 dB/秒、ピーク保持 1 秒）。
//  棒はチャンネルごと。IN はリンクの L / R、OUT は端末へ渡している本数（ふつうは L / R、
//  多チャンネルの IF なら 1〜N。段の名前は Level Meter と同じ LevelMeterView.label）。
//  どれかのチャンネルが 0 dBFS に届いたら LevelMeterView.overloadTime のあいだ赤（届いた段には印も）。
//
//  **MeterView（GraphCanvas）は使わない。**あちらは上の読み値の行・下の目盛りの字・段ごとの
//  隙間で、L / R だけでもカードが 110pt ほどになり、メーターだけの行が鎖より場所を取っていた。
//  鎖の頭と出力補正の行に常に居るものなので、目盛りの字は捨てて、1 段を
//  「段の名前・細い棒・その段の dB」の 1 行にする。どちらのメーターかは左の札（IN / OUT）。
//  色は MeterView と同じ塗り（ETGraphShading の溝・棒・ピークの線、赤は .tint）。
//
//  ピークの保持はここでする（MeterView の holdsPeak は使わない）。MeterView の保持は段の値が
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
            ETCompactMeter(channels: channels, badge: point == .input ? "IN" : "OUT")
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

/// IN / OUT の詰めたメーター。左に札、右に段を縦に並べる（段 = 名前・棒・dB）。
/// L / R なら 1 段 13pt で、札を含めて 30pt に収まる。多チャンネルは段を細くする。
private struct ETCompactMeter: View {
    let channels: [ETMeterChannel]
    let badge: String

    /// 多チャンネル（OUT が 3 本以上）か。16 本まで来るので、段の高さと字を下げる。
    private var dense: Bool { channels.count > 2 }
    private var rowHeight: CGFloat { dense ? 11 : 13 }
    private var barHeight: CGFloat { dense ? 3 : 5 }
    private var readoutSize: CGFloat { dense ? 9 : ETGraphMetrics.readoutSize }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            // GraphCanvas の札と同じ形。IN と OUT で幅を揃え、2 つのカードの棒の頭を揃える。
            Text(badge)
                .font(.system(size: 10, weight: .heavy))
                .tracking(0.5)
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .frame(minWidth: 38)
                .background(.tint, in: .capsule)
                .fixedSize()

            VStack(spacing: 2) {
                // **身元は段の番号。**値が 30Hz で変わっても段は挿し直さない。
                ForEach(channels) { channel in
                    HStack(spacing: 6) {
                        Text(channel.label)
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 14, alignment: .trailing)
                        ETCompactMeterBar(channel: channel)
                            .frame(height: barHeight)
                        // 字の数を下端（-96.0 dB）に揃える。桁が落ちても幅が変わらず、棒の長さが動かない
                        // （MeterView の readout と同じ理由）。
                        Text(Self.padded(channel.peakDB))
                            .font(.system(size: readoutSize, weight: .medium, design: .monospaced))
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .frame(height: rowHeight)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private static func padded(_ db: Double) -> String {
        let width = ETFormat.db(LevelMeterView.floorDB, decimals: 1).count
        let text = ETFormat.db(ETdB.finite(db, floor: LevelMeterView.floorDB), decimals: 1)
        return String(repeating: " ", count: max(0, width - text.count)) + text
    }
}

/// 1 段の棒。溝・棒・ピークの線・振り切れた印は MeterView と同じ塗りで描く。
private struct ETCompactMeterBar: View {
    let channel: ETMeterChannel

    var body: some View {
        Canvas { context, size in
            let floor = LevelMeterView.floorDB
            /// dB を横の位置へ。下端 0、0 dBFS が右端。
            func x(_ db: Double) -> CGFloat {
                let clamped = min(max(ETdB.finite(db, floor: floor), floor), 0)
                return CGFloat((clamped - floor) / -floor) * size.width
            }
            let radius = min(2, size.height / 2)
            let track = CGRect(origin: .zero, size: size)
            context.fill(Path(roundedRect: track, cornerRadius: radius), with: ETGraphShading.grid)

            let width = x(channel.levelDB)
            if width > 0.5 {
                let bar = CGRect(x: 0, y: 0, width: width, height: size.height)
                context.fill(Path(roundedRect: bar, cornerRadius: radius), with: ETGraphShading.curve)
            }

            // ピークの線。端に寄っても線の太さぶんは溝の中に残す。
            if ETdB.finite(channel.peakDB, floor: floor) > floor + 0.01 {
                let px = min(max(x(channel.peakDB), 1), size.width - 1)
                var line = Path()
                line.move(to: CGPoint(x: px, y: 0))
                line.addLine(to: CGPoint(x: px, y: size.height))
                context.stroke(line, with: ETGraphShading.axis, lineWidth: 2)
            }

            if channel.clipped {
                let mark = CGRect(x: size.width - 4, y: 0, width: 4, height: size.height)
                context.fill(Path(mark), with: ETGraphShading.curve)
            }
        }
    }
}
