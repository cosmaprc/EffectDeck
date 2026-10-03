//  RemoteScannerView.swift
//  PC の EffeTune を LAN から操る PoC の画面側（DSP/RemoteMirror.swift）。
//
//    - RemoteToolbarButton     鎖の画面のツールバーのアイコン。押すと RemotePanelView を開く。
//                              入切はここでしない。状態（入・つなぎ中・つながった）だけを絵で見せる
//    - RemotePanelView         アイコンから開くシート。行は RemoteRows（Settings の Remote Control 節と同じもの）
//    - RemoteRows              Remote Control の入切・Status・つなぎ先・Mirror Analyzers・QR の読み取り・Forget
//    - RemoteScannerView       PC の画面の QR（ws://host:port/?t=…）を読む。VisionKit の
//                              DataScannerViewController（公開 API）。そのリンク以外の QR は拾わない
//    - ETRemoteMeasurementDim  PC の鎖を編集しているあいだ、PC の測定値を映していない Analyzer の図を沈める
//
//  **Analyzer の図を沈める訳。**編集しているあいだ鳴っているのは PC で、Analyzer の図が描くのは
//  この端末の音（Telemetry）。PC の音の図ではないので、読めない形にして押せなくする。
//  沈めるのは GraphCanvas（ほぼ全部の図の土台）と Pitch Meter の図だけで、つまみは PC へ送れるので残す。
//  EQ の曲線のような設計の図も GraphCanvas を使うが、印はカードが Analyzer のときしか立てない。
//  **Mirror Analyzers を入れて PC が telemetry を持っていれば沈めない。**図は PC の枠で描く
//  （RemoteMirror.mirroredTaps）。映す段に入った時点で手元の枠は捨ててあるので、
//  PC の枠が来るまでは Waiting のまま。PC の番号が無い段・PC が古い版・切のときは沈めたまま。

import AVFoundation
import SwiftUI
import VisionKit

// MARK: - ツールバー

/// アイコン。**観測するのはこのビューだけ**にして、PipelineToolbar 自体は RemoteMirror を見ない
/// （あちらは提示の途中の Menu を作り直さないよう、渡す値を絞ってある）。
/// 押しても入切はしない。開くのは設定のシートで、入切もつなぎ先の変更もそちらでする。
struct RemoteToolbarButton: View {
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var mirror = RemoteMirror.shared
    let open: () -> Void

    init(open: @escaping () -> Void) {
        self.open = open
    }

    var body: some View {
        styled(Button("Remote Control", systemImage: "dot.radiowaves.left.and.right", action: open))
            // 入れてあるのにつながっていない（つないでいる途中・つなぎ直しを待っている）あいだ脈を打つ。
            .symbolEffect(.pulse, isActive: prefs.remoteEnabled && mirror.status != .connected)
            .accessibilityValue(mirror.statusText)
    }

    /// 入れてあるあいだは青く塗る。PC 側（EffeTune の見出しのアイコン）も入のとき青で塗るので合わせる。
    /// ガラスのツールバーでは foregroundStyle の色が乗らないことがあるので、塗りのある形にする。
    @ViewBuilder
    private func styled<Label: View>(_ button: Button<Label>) -> some View {
        if prefs.remoteEnabled {
            button.buttonStyle(.borderedProminent).tint(.blue)
        } else {
            button
        }
    }
}

/// ナビゲーションバー中央の枠。ふだんは LiveStatusStrip、PC の鎖を編集しているあいだは
/// 「Remote Control」の札にして、押すとリモートのシートを開く。
/// リモート中にこの端末の遅れと CPU を出しても、鳴っているのは PC なので意味が無い。
/// iPhone ではツールバーにリモートのアイコンを置けない（幅が足りない）ので、ここが入口になる。
struct RemoteStatusSlot: View {
    @ObservedObject private var mirror = RemoteMirror.shared
    let io: AudioIO
    let open: () -> Void

    init(io: AudioIO, open: @escaping () -> Void) {
        self.io = io
        self.open = open
    }

    var body: some View {
        if mirror.isRemote {
            Button(action: open) {
                Label("Remote Control", systemImage: "dot.radiowaves.left.and.right")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.blue)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .buttonStyle(.plain)
            .accessibilityValue(mirror.statusText)
        } else {
            LiveStatusStrip(io: io)
        }
    }
}

// MARK: - 設定のシート

/// アイコンから開くシート。行は Settings の Remote Control 節と同じ RemoteRows。
struct RemotePanelView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    RemoteRows()
                }
            }
            .navigationTitle("Remote Control")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        // 行が 5 本しかないので、画面の半分も要らない。上へ引けば広がるように .large も残す（RoutingView と同じ）。
        .presentationDetents([.medium, .large])
    }
}

/// Remote Control の行。シートと Settings が同じものを並べる（食い違わないよう 1 か所に置く）。
/// List / Form の中に置く前提。QR の読み取りは自分で出す（親のシートの上に重なる）。
struct RemoteRows: View {
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var mirror = RemoteMirror.shared
    @State private var scanning = false

    init() {}

    var body: some View {
        Toggle("Remote Control", isOn: Binding(
            get: { prefs.remoteEnabled },
            set: { on in
                // 控えが無いまま入れても、つなぐ先が無い。QR を読ませる。
                if on && !mirror.hasPairing {
                    scanning = true
                } else {
                    prefs.remoteEnabled = on
                }
            }))
        LabeledContent("Status") {
            Text(mirror.statusText)
                .foregroundStyle(.secondary)
        }
        // トークンは出さない。host:port だけ。
        if let address = ETRemoteAddress.parse(prefs.remoteAddress) {
            LabeledContent("Address") {
                Text("\(address.host):\(address.port)")
                    .foregroundStyle(.secondary)
            }
        }
        if let host = mirror.host {
            LabeledContent(host.name) {
                Text(host.label)
                    .foregroundStyle(.secondary)
            }
        }
        // 保存する設定なので、つながっていなくても出して触れるようにしておく。
        // PC の EffeTune が測定値を送れない版のときだけ、つながっている間は触れなくして理由を添える。
        Toggle(isOn: $prefs.remoteMirrorAnalyzers) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Mirror Analyzers")
                if mirror.telemetryUnsupported, let host = mirror.host {
                    Text(host.unsupportedText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .disabled(mirror.telemetryUnsupported)
        Button("Scan QR Code") { scanning = true }
            .sheet(isPresented: $scanning) {
                RemoteScannerView { url in
                    scanning = false
                    mirror.pair(url)
                }
            }
        if !prefs.remoteAddress.isEmpty {
            Button("Forget", role: .destructive) { mirror.forget() }
        }
    }
}

// MARK: - QR の読み取り

struct RemoteScannerView: View {
    /// 読めた接続先。ws:// で t の揃ったものだけが来る。
    let onFound: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var ready = false

    init(onFound: @escaping (URL) -> Void) {
        self.onFound = onFound
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if ready {
                    RemoteDataScanner(onFound: onFound)
                        .ignoresSafeArea()
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .task {
            // まだ訊いていなければ先に訊く。訊く前は isAvailable が偽を返しうる。
            if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .video)
            }
            // 読めない端末・カメラを断られた。何も言わずに閉じる。
            if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                ready = true
            } else {
                dismiss()
            }
        }
    }
}

private struct RemoteDataScanner: UIViewControllerRepresentable {
    let onFound: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFound: onFound) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        guard !scanner.isScanning, !context.coordinator.found else { return }
        try? scanner.startScanning()
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onFound: (URL) -> Void
        /// 1 回で止める。同じ QR を写している間は何度も来る。
        private(set) var found = false

        init(onFound: @escaping (URL) -> Void) {
            self.onFound = onFound
        }

        func dataScanner(_ dataScanner: DataScannerViewController,
                         didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            guard !found else { return }
            for item in addedItems {
                guard case .barcode(let code) = item,
                      let text = code.payloadStringValue,
                      let url = URL(string: text),
                      ETRemoteAddress.pairingLink(url) != nil else { continue }
                found = true
                dataScanner.stopScanning()
                onFound(url)
                return
            }
        }
    }
}

// MARK: - Analyzer の図を沈める

extension EnvironmentValues {
    /// 真のあいだ、測った音を描く図（GraphCanvas・Pitch Meter）を沈めて押せなくする。
    /// 立てるのは ETRemoteMeasurementDim だけ。
    @Entry var etMeasurementDimmed: Bool = false
}

extension View {
    /// 図の範囲に掛ける。dimmed が偽なら何もしない。
    func etDimmedWhenMeasuring(_ dimmed: Bool) -> some View {
        self
            .saturation(dimmed ? 0 : 1)
            .opacity(dimmed ? 0.3 : 1)
            .allowsHitTesting(!dimmed)
    }
}

/// PEQ の図に重ねるスペクトラム（と After ⇄ Compare の札）を包む。PC の鎖を編集しているあいだは
/// PC の前後の枠を映している tap（RemoteMirror.mirroredTaps）だけ描く。手元の音は PC の音と関係ない。
/// 手元で使っているときは素通し。RemoteMirror を観測するのはここ（図の本体は観測しない）。
struct ETRemoteOverlayGate<Content: View>: View {
    let tap: UInt32
    let content: () -> Content
    @ObservedObject private var mirror = RemoteMirror.shared

    init(tap: UInt32, @ViewBuilder content: @escaping () -> Content) {
        self.tap = tap
        self.content = content
    }

    var body: some View {
        if !mirror.isRemote || mirror.mirroredTaps.contains(tap) {
            content()
        }
    }
}

/// カードに掛ける。Analyzer のカードで、PC の鎖を編集しているあいだ、PC の測定値を
/// 映していない段にだけ印を立てる。RemoteMirror を観測するのはここ（カードの本体は観測しない）。
struct ETRemoteMeasurementDim: ViewModifier {
    let applies: Bool
    let tap: UInt32
    @ObservedObject private var mirror = RemoteMirror.shared

    init(applies: Bool, tap: UInt32) {
        self.applies = applies
        self.tap = tap
    }

    func body(content: Content) -> some View {
        content.environment(\.etMeasurementDimmed,
                            applies && mirror.isRemote && !mirror.mirroredTaps.contains(tap))
    }
}
