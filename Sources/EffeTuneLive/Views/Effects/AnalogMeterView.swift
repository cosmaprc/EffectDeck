//  AnalogMeterView.swift
//  Analog Meter（AnalogMeterPlugin）。VU・PPM・RMS・ピーク・ラウドネスを針の計器で見せる。
//  2.12.0 で増えたもの。上流は plugins/analyzer/analog_meter.js。
//
//  値の計算は DSP/AnalogMeterModel.swift（目盛りの写し方・枠の読み・ピークホールド）。
//  ここは並べて描くだけ。
//
//  上流との違い:
//    - 行（Mode / Integration / Attack / Release / Reference / Range / PPM Scale / Peak Hold /
//      Needle / Target / Scale）は上流と同じ順で、いまのモードで効かない行は出さない
//      （analog_meter.js:415-421 の syncControlStates）。図は行の上に置く（このアプリの他の図と同じ）。
//    - 針の並びは 1 行 4 つまで、狭いとき（iPhone）は 2 つまで（同 :19-20、:366-377）。
//    - Reset（Loudness のときだけ）は et_instance_reset で、Integrated / LRA / 最大 True Peak の
//      測定を最初からにする（上流は resetPluginState、同 :268-272）。値は変えない。
//
//  Integrated などを止めても残す（上流は temporalCapability = 'stateless'、同 :246-249）点は
//  このアプリでは同じにならない。停止（AudioIO.stop）は et_engine_reset で全部の段を戻す。
//  docs/notes/effetune-2.12.0.md に書いてある。

import SwiftUI

struct AnalogMeterView: View {

    let index: Int
    let node: EffeTuneDSP.Node
    @ObservedObject var dsp: EffeTuneDSP

    @Environment(\.etGraphOnly) private var graphOnly

    // 表示だけの設定。畳むと View ごと消えるので鎖に持たせる（DisplayParams の "AnalogMeterPlugin"）。
    @State private var reference: Double = -14
    @State private var range: Double = 40
    @State private var ppmScale: Double = 0
    @State private var peakHold: Double = 1
    @State private var needle: Double = 0
    @State private var target: Double = -23
    @State private var loudnessScale: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AnalogMeterFigure(index: index, tapId: node.tapId, settings: settings, dsp: dsp)
            if !graphOnly {
                rows
            }
        }
        .etSaved($reference, key: "rl", index: index, dsp: dsp)
        .etSaved($range, key: "rg", index: index, dsp: dsp)
        .etSaved($ppmScale, key: "sc", index: index, dsp: dsp)
        .etSaved($peakHold, key: "ph", index: index, dsp: dsp)
        .etSaved($needle, key: "ln", index: index, dsp: dsp)
        .etSaved($target, key: "tg", index: index, dsp: dsp)
        .etSaved($loudnessScale, key: "ls", index: index, dsp: dsp)
    }

    // MARK: 行

    /// 上流と同じ並び（analog_meter.js:432-451）。効かない行は出さない。
    @ViewBuilder private var rows: some View {
        let s = settings
        if let mode = param("md") {
            ParameterRow(param: mode, nodeIndex: index, values: node.values, dsp: dsp)
        }
        dspRow("it", s)
        dspRow("at", s)
        dspRow("rt", s)
        if ETAnalogMeter.isActive("rl", settings: s) {
            ETDisplayNumberRow(title: "Reference", unit: "dBFS", value: $reference,
                               range: -30...0, step: 1, isInteger: true)
        }
        if ETAnalogMeter.isActive("rg", settings: s) {
            ETDisplayNumberRow(title: "Range", unit: "dB", value: $range,
                               range: 20...60, step: 1, isInteger: true)
        }
        if ETAnalogMeter.isActive("sc", settings: s) {
            ETDisplayChoiceRow(title: "PPM Scale",
                               options: ETAnalogMeter.ppmScales.enumerated().map { (value: $0.offset, label: $0.element) },
                               selection: choice($ppmScale))
        }
        if ETAnalogMeter.isActive("ph", settings: s) {
            ETDisplayNumberRow(title: "Peak Hold", unit: "s", value: $peakHold,
                               range: 0...10, step: 0.1)
        }
        if ETAnalogMeter.isActive("ln", settings: s) {
            ETDisplayChoiceRow(title: "Needle",
                               options: [(value: 0, label: "Momentary"), (value: 1, label: "Short-term")],
                               selection: choice($needle))
        }
        if ETAnalogMeter.isActive("tg", settings: s) {
            ETDisplayNumberRow(title: "Target", unit: "LUFS", value: $target,
                               range: -36 ... -10, step: 1, isInteger: true)
        }
        if ETAnalogMeter.isActive("ls", settings: s) {
            ETDisplayChoiceRow(title: "Scale",
                               options: [(value: 0, label: "EBU +9"), (value: 1, label: "EBU +18")],
                               selection: choice($loudnessScale))
        }
    }

    @ViewBuilder
    private func dspRow(_ key: String, _ settings: ETAnalogMeter.Settings) -> some View {
        if ETAnalogMeter.isActive(key, settings: settings), let p = param(key) {
            ParameterRow(param: p, nodeIndex: index, values: node.values, dsp: dsp)
        }
    }

    private func param(_ key: String) -> ETParam? {
        node.spec.params.first { $0.key == key }
    }

    /// 0/1/2 の選択を Double の持ち物へ戻す。
    private func choice(_ source: Binding<Double>) -> Binding<Int> {
        Binding(get: { Self.integer(source.wrappedValue) },
                set: { source.wrappedValue = Double($0) })
    }

    /// 打ち込みや取り込みで NaN・巨大な値が来ても Int(_:) で落とさない。
    static func integer(_ v: Double) -> Int {
        v.isFinite ? Int(min(max(v, -1e6), 1e6).rounded()) : 0
    }

    // MARK: 設定

    /// 上流の setParameters と同じ寄せ方で、いまの設定を作る（analog_meter.js:326-336）。
    private var settings: ETAnalogMeter.Settings {
        var s = ETAnalogMeter.Settings()
        if let p = param("md"), node.values.indices.contains(p.offset) {
            let m = Self.integer(Double(node.values[p.offset]))
            s.mode = ETAnalogMeter.modes.indices.contains(m) ? m : 0
        }
        s.reference = ETAnalogMeter.Settings.clamped(reference, -30, 0, previous: s.reference)
        s.range = ETAnalogMeter.Settings.clamped(range, 20, 60, previous: s.range)
        s.peakHold = ETAnalogMeter.Settings.clamped(peakHold, 0, 10, previous: s.peakHold)
        s.target = ETAnalogMeter.Settings.clamped(target, -36, -10, previous: s.target)
        let sc = Self.integer(ppmScale)
        s.ppmScale = ETAnalogMeter.ppmScales.indices.contains(sc) ? sc : 0
        s.needle = Self.integer(needle) == 1 ? 1 : 0
        s.loudnessScale = Self.integer(loudnessScale) == 1 ? 1 : 0
        return s
    }
}

// MARK: - 図

/// 針の計器を並べた面。テレメトリを観測するのはこの中だけ（つまみの行を 30Hz で作り直さない）。
private struct AnalogMeterFigure: View {

    let index: Int
    let tapId: UInt32
    let settings: ETAnalogMeter.Settings
    @ObservedObject var dsp: EffeTuneDSP

    @ETTelemetryFeed private var telemetry
    @Environment(\.etGraphOnly) private var graphOnly

    @State private var holds: [ETAnalogMeter.Hold] = []
    /// 最後に読めた枠のチャンネル数。枠が途切れても並びを変えない（analog_meter.js:350-358）。
    @State private var channelCount = 2
    @State private var width: CGFloat = 320

    /// 針の幅（上流の ANALOG_METER_ARC_DEGREES）。
    private static let arc = ETAnalogMeter.arcDegrees * Double.pi / 180
    private static let danger = Color(red: 0.725, green: 0.11, blue: 0.11)
    /// 針が狭いとき 2 列にする幅（pt）。上流は CSS の mobile 幅。
    private static let narrowWidth: CGFloat = 520

    /// 前のモードの枠は捨てる（applyReading、analog_meter.js:350）。
    private var reading: ETAnalogMeter.Reading? {
        guard let r = ETAnalogMeter.parse(telemetry.frame(tap: tapId, type: .analogMeter)),
              r.mode == settings.mode else { return nil }
        return r
    }

    private var grid: ETAnalogMeter.Grid {
        let cells = ETAnalogMeter.cellCount(mode: settings.mode, channelCount: channelCount)
        return ETAnalogMeter.grid(cells: cells,
                                  maxColumns: width < Self.narrowWidth ? ETAnalogMeter.mobileColumns
                                                                       : ETAnalogMeter.maxColumns)
    }

    var body: some View {
        let current = reading
        let layout = grid
        let plotHeight = max(60, width / CGFloat(layout.aspect))
        VStack(alignment: .leading, spacing: 8) {
            GraphCanvas(
                x: .blank(), y: .blank(),
                height: plotHeight,
                insets: .none,
                caption: current == nil ? "Waiting for audio" : nil,
                clipsContent: true,
                draw: { context, plot in
                    draw(&context, plot, reading: current, grid: layout)
                })
                .frame(maxWidth: min(CGFloat(layout.columns) * 320, 1024))
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.width
                } action: { newWidth in
                    if newWidth > 0 && abs(newWidth - width) > 0.5 { width = newWidth }
                }
            if settings.mode == ETAnalogMeter.loudnessMode && !graphOnly {
                ETMeasurementButton(title: "Reset") {
                    dsp.resetState(at: index)
                    holds = []
                }
            }
        }
        .onChange(of: current?.sequence) { _, _ in advance() }
        .onChange(of: settings.mode) { _, _ in holds = [] }
    }

    /// 新しい枠が来たときだけ、保持を進める。
    private func advance() {
        guard let r = reading else { return }
        if r.channelCount != channelCount {
            channelCount = r.channelCount
            holds = []
        }
        guard ETAnalogMeter.holdsPeak(mode: r.mode) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        var next = holds
        while next.count < r.channelCount {
            next.append(ETAnalogMeter.Hold(db: .nan, time: now, overTime: nil))
        }
        for (i, channel) in r.channels.enumerated() {
            next[i] = ETAnalogMeter.updateHold(next[i], db: channel.maxDB, now: now,
                                               holdSeconds: settings.peakHold)
        }
        holds = next
    }

    // MARK: 描く

    private func draw(_ context: inout GraphicsContext, _ plot: ETPlot,
                      reading: ETAnalogMeter.Reading?, grid: ETAnalogMeter.Grid) {
        let rect = plot.rect
        let cellWidth = rect.width / CGFloat(grid.columns)
        let cellHeight = rect.height / CGFloat(grid.rows)
        let modeName = ETAnalogMeter.modes[settings.mode]
        let scale = ETAnalogMeter.scale(mode: modeName, settings: settings)
        let loudness = settings.mode == ETAnalogMeter.loudnessMode
        let now = ProcessInfo.processInfo.systemUptime
        for cell in 0..<grid.cells {
            let box = CGRect(x: rect.minX + CGFloat(cell % grid.columns) * cellWidth,
                             y: rect.minY + CGFloat(cell / grid.columns) * cellHeight,
                             width: cellWidth, height: cellHeight)
            drawCell(&context, scale: scale, box: box, channel: loudness ? cell - 1 : cell,
                     reading: reading, now: now)
        }
    }

    private func text(_ context: inout GraphicsContext, _ s: String, size: CGFloat,
                      at point: CGPoint, anchor: UnitPoint, color: Color,
                      weight: Font.Weight = .regular, monospaced: Bool = false) {
        let font: Font = monospaced ? .system(size: size, weight: weight, design: .monospaced)
                                    : .system(size: size, weight: weight)
        context.draw(Text(s).font(font).foregroundStyle(color), at: point, anchor: anchor)
    }

    /// 1 つの針（drawCell、analog_meter.js:577-720）。
    private func drawCell(_ context: inout GraphicsContext, scale: ETAnalogMeter.Scale, box: CGRect,
                          channel: Int, reading: ETAnalogMeter.Reading?, now: Double) {
        let inset: CGFloat = 4
        let arc = Self.arc
        let grid = Color.secondary.opacity(0.35)
        let label = Color.secondary
        let primary = Color.primary
        let danger = Self.danger

        // 枠。
        context.stroke(Path(box.insetBy(dx: inset, dy: inset)), with: .color(grid), lineWidth: 1)

        let fontSize = max(9, min(14, box.width / 22))
        let bottomSpace = 1.8 * fontSize * 1.25
        let pivotX = box.minX + box.width / 2
        let pivotY = box.maxY - inset - bottomSpace
        let topSpace = fontSize * 3.2
        let radius = max(8, min((box.width / 2 - inset - fontSize * 1.5) / CGFloat(sin(arc)),
                                pivotY - (box.minY + inset + topSpace)))

        func angle(_ position: Double) -> Double { -arc + 2 * arc * position }
        func point(_ position: Double, _ distance: CGFloat) -> CGPoint {
            let a = angle(position)
            return CGPoint(x: pivotX + CGFloat(sin(a)) * distance,
                           y: pivotY - CGFloat(cos(a)) * distance)
        }
        func arcPath(_ from: Double, _ to: Double, _ distance: CGFloat) -> Path {
            var path = Path()
            let steps = 48
            for i in 0...steps {
                let p = point(from + (to - from) * Double(i) / Double(steps), distance)
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            return path
        }

        // 弧と赤い帯と目盛り。
        context.stroke(arcPath(0, 1, radius), with: .color(label), lineWidth: 1)
        if let red = scale.redFrom {
            context.stroke(arcPath(scale.valuePosition(red), 1, radius + 2),
                           with: .color(danger), lineWidth: 3)
        }
        // 隣の字がぶつかるときは、基準から数えて 1 つおきにする（analog_meter.js:632-647）。
        let labelRadius = radius + 9
        let labeled = scale.ticks.filter { !$0.label.isEmpty }
        var widest: CGFloat = 0
        var spacing = CGFloat.infinity
        for (i, tick) in labeled.enumerated() {
            let w = CGFloat(tick.label.count) * fontSize * 0.85 * 0.6
            widest = max(widest, w)
            guard i > 0 else { continue }
            let step = abs(scale.valuePosition(tick.value) - scale.valuePosition(labeled[i - 1].value))
            spacing = min(spacing, CGFloat(2 * arc * Double(labelRadius) * step))
        }
        let kept: Set<Double>? = spacing < widest + fontSize * 0.3 ? ETAnalogMeter.sparseLabels(scale) : nil
        for tick in scale.ticks {
            let position = scale.valuePosition(tick.value)
            let major = !tick.label.isEmpty
            let isReference = tick.value == scale.reference
            var mark = Path()
            mark.move(to: point(position, radius))
            mark.addLine(to: point(position, radius + (major ? 7 : 4)))
            context.stroke(mark, with: .color(isReference ? primary : label),
                           lineWidth: isReference ? 2 : 1)
            if !major { continue }
            if let kept, !kept.contains(tick.value) { continue }
            text(&context, tick.label, size: fontSize * 0.85, at: point(position, labelRadius),
                 anchor: .bottom, color: isReference ? primary : label)
        }

        // 見出しとモード。
        let holdMode = ETAnalogMeter.holdsPeak(mode: settings.mode)
        let channelCount = reading?.channelCount ?? self.channelCount
        text(&context, ETAnalogMeter.cellTitle(channel: channel, mode: settings.mode,
                                               channelCount: channelCount),
             size: fontSize, at: CGPoint(x: box.minX + inset * 2, y: box.minY + inset * 2),
             anchor: .topLeading, color: primary, weight: .bold)
        let modeLabel: String
        if settings.mode == ETAnalogMeter.loudnessMode {
            modeLabel = settings.needle == 1 ? "Short-term" : "Momentary"
        } else if ETAnalogMeter.modes[settings.mode] == "PPM" {
            modeLabel = "PPM \(ETAnalogMeter.ppmScales[settings.ppmScale])"
        } else {
            modeLabel = ETAnalogMeter.modes[settings.mode]
        }
        text(&context, modeLabel, size: fontSize * 0.85,
             at: CGPoint(x: box.maxX - inset * 2 - (holdMode ? fontSize * 1.2 : 0), y: box.minY + inset * 2),
             anchor: .topTrailing, color: label)

        // ピークホールドと 0 dBFS を越えたときのランプ。
        let hold: ETAnalogMeter.Hold? = channel >= 0 && holds.indices.contains(channel) ? holds[channel] : nil
        if holdMode {
            let lampRadius = fontSize * 0.4
            let lamp = CGRect(x: box.maxX - inset * 2 - lampRadius * 2,
                              y: box.minY + inset * 2 + fontSize * 0.5 - lampRadius,
                              width: lampRadius * 2, height: lampRadius * 2)
            if ETAnalogMeter.isOverLit(hold, now: now, holdSeconds: settings.peakHold) {
                context.fill(Path(ellipseIn: lamp), with: .color(danger))
            } else {
                context.stroke(Path(ellipseIn: lamp), with: .color(grid), lineWidth: 1)
            }
            if settings.peakHold > 0, let hold, hold.db.isFinite, hold.db > ETAnalogMeter.silenceDB {
                let position = scale.dbPosition(hold.db)
                var mark = Path()
                mark.move(to: point(position, radius * 0.86))
                mark.addLine(to: point(position, radius))
                context.stroke(mark, with: .color(danger), lineWidth: 3)
            }
        }

        // 針。届いた値のまま（バリスティクスは DSP が済ませている）。
        let db = ETAnalogMeter.cellReading(channel: channel, reading: reading,
                                           mode: settings.mode, needle: settings.needle)
        let needlePosition = db.map { scale.dbPosition($0) } ?? 0
        var needle = Path()
        needle.move(to: CGPoint(x: pivotX, y: pivotY))
        needle.addLine(to: point(needlePosition, radius * 1.02))
        context.stroke(needle, with: .color(primary), lineWidth: 2)
        context.fill(Path(ellipseIn: CGRect(x: pivotX - 3, y: pivotY - 3, width: 6, height: 6)),
                     with: .color(primary))

        // 読み値。
        text(&context, db.map { scale.readout($0) } ?? "---", size: fontSize,
             at: CGPoint(x: pivotX, y: pivotY + fontSize * 0.8), anchor: .top, color: primary,
             monospaced: true)
        if channel < 0, let program = reading?.program, let reading {
            drawProgramStats(&context, program: program, reading: reading, box: box, inset: inset,
                             fontSize: fontSize)
        }
    }

    /// Program の針の下の両隅に出す M / S / I と LRA / TP / Time（drawProgramStats、:722-766）。
    private func drawProgramStats(_ context: inout GraphicsContext, program: ETAnalogMeter.Program,
                                  reading: ETAnalogMeter.Reading, box: CGRect, inset: CGFloat,
                                  fontSize: CGFloat) {
        func lufs(_ v: Double) -> String { v <= ETAnalogMeter.silenceDB ? "-∞" : String(format: "%.1f", v) }
        let tables: [[(String, String)]] = [
            [("M", "\(lufs(program.momentary)) LUFS"),
             ("S", "\(lufs(program.shortTerm)) LUFS"),
             ("I", "\(reading.integratedValid ? lufs(program.integrated) : "---") LUFS")],
            [("LRA", "\(reading.lraValid ? String(format: "%.1f", program.lra) : "---") LU"),
             ("TP", "\(lufs(program.maxTruePeak)) dBTP"),
             ("Time", ETAnalogMeter.duration(program.integratedSeconds))],
        ]
        let margin = inset + fontSize * 0.5
        var size = fontSize * 0.9
        // 等幅なので 1 字は約 0.6 em。固定幅の見本で、読み値が変わっても表が動かない。
        func measure(_ s: String, _ size: CGFloat) -> CGFloat { CGFloat(s.count) * size * 0.6 }
        let labelWidths = tables.map { rows in rows.map { measure($0.0, size) }.max() ?? 0 }
        let valueWidths = tables.map { rows in rows.map { measure($0.1, size) }.max() ?? 0 }
        let gap = size * 0.6
        let tableWidth = max(labelWidths[0] + valueWidths[0], labelWidths[1] + valueWidths[1]) + gap
        let readoutHalf = measure("-88.8 LUFS", fontSize) / 2
        let available = box.width / 2 - margin - readoutHalf - fontSize * 0.6
        guard available > 0 else { return }
        // 狭い針では、表が読み値にぶつからないよう縮める。
        let fit = tableWidth > available ? available / tableWidth : 1
        size *= fit
        let scaledWidth = tableWidth * fit
        let lineHeight = size * 1.3
        let bottom = box.maxY - inset * 2
        for (tableIndex, rows) in tables.enumerated() {
            let left = tableIndex == 0 ? box.minX + margin : box.maxX - margin - scaledWidth
            for (row, entry) in rows.enumerated() {
                let y = bottom - CGFloat(rows.count - 1 - row) * lineHeight
                text(&context, entry.0, size: size, at: CGPoint(x: left, y: y),
                     anchor: .bottomLeading, color: .secondary, monospaced: true)
                text(&context, entry.1, size: size, at: CGPoint(x: left + scaledWidth, y: y),
                     anchor: .bottomTrailing, color: .primary, monospaced: true)
            }
        }
    }
}
