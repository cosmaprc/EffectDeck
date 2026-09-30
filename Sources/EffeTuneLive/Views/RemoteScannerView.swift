//  RemoteScannerView.swift
//  PC の EffeTune を LAN から操る PoC の画面側（DSP/RemoteMirror.swift）。
//
//    - RemoteToolbarToggle     鎖の画面のツールバーの入切。控えが無ければ QR の読み取りを開く
//    - RemoteScannerView       PC の画面の QR（effectdeck://remote?h=…&t=…）を読む。VisionKit の
//                              DataScannerViewController（公開 API）。そのリンク以外の QR は拾わない
//    - ETRemoteMeasurementDim  PC の鎖を編集しているあいだ、Analyzer の図を沈める
//
//  **Analyzer の図を沈める訳。**編集しているあいだ鳴っているのは PC で、Analyzer の図が描くのは
//  この端末の音（Telemetry）。PC の音の図ではないので、読めない形にして押せなくする。
//  沈めるのは GraphCanvas（ほぼ全部の図の土台）と Pitch Meter の図だけで、つまみは PC へ送れるので残す。
//  EQ の曲線のような設計の図も GraphCanvas を使うが、印はカードが Analyzer のときしか立てない。

import AVFoundation
import SwiftUI
import VisionKit

// MARK: - ツールバー

/// 入切。**観測するのはこのビューだけ**にして、PipelineToolbar 自体は RemoteMirror を見ない
/// （あちらは提示の途中の Menu を作り直さないよう、渡す値を絞ってある）。
struct RemoteToolbarToggle: View {
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var mirror = RemoteMirror.shared
    let scan: () -> Void

    init(scan: @escaping () -> Void) {
        self.scan = scan
    }

    var body: some View {
        Toggle(isOn: Binding(
            get: { prefs.remoteEnabled },
            set: { on in
                if on && !mirror.hasPairing {
                    scan()
                } else {
                    prefs.remoteEnabled = on
                }
            })) {
            Label("Remote Control", systemImage: "dot.radiowaves.left.and.right")
        }
        .toggleStyle(.button)
        // 入れてあるのにつながっていない（つないでいる途中・つなぎ直しを待っている）あいだ脈を打つ。
        .symbolEffect(.pulse, isActive: prefs.remoteEnabled && mirror.status != .connected)
        .accessibilityValue(mirror.statusText)
    }
}

// MARK: - QR の読み取り

struct RemoteScannerView: View {
    /// 読めたリンク。effectdeck://remote で h と t の揃ったものだけが来る。
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

/// カードに掛ける。Analyzer のカードで、PC の鎖を編集しているあいだだけ印を立てる。
/// RemoteMirror を観測するのはここ（カードの本体は観測しない）。
struct ETRemoteMeasurementDim: ViewModifier {
    let applies: Bool
    @ObservedObject private var mirror = RemoteMirror.shared

    init(applies: Bool) {
        self.applies = applies
    }

    func body(content: Content) -> some View {
        content.environment(\.etMeasurementDimmed, applies && mirror.isRemote)
    }
}
