//  Preferences.swift
//  設定の置き場。EffeTune が localStorage の effetune_audio_preferences に
//  持っているものと、同じ考え方・同じ名前で揃えてある。
//
//  note は「選んでいる値だとどうなるか」を 1 文で言うもの。
//  画面では選択肢のすぐ下に出す。反対側（選ばなかったときの話）は書かない。

import Foundation
import AVFoundation
import UIKit

@MainActor
final class Preferences: ObservableObject {

    static let shared = Preferences()

    /// 無音と見なす大きさの範囲と刻み。理由は PreferencesValues.silenceRange の注記。
    static let silenceRange = PreferencesValues.silenceRange
    static let silenceStep = PreferencesValues.silenceStep

    @Published var processingRate: ETProcessingRate {
        didSet { save(processingRate.rawValue, Key.rate); onAudioChange?() }
    }
    @Published var latency: ETLatency {
        didSet { save(latency.rawValue, Key.latency); onAudioChange?() }
    }
    @Published var powerMode: ETPowerMode {
        didSet { save(powerMode.rawValue, Key.power); onAudioChange?() }
    }
    /// 無音と見なす大きさ。EffeTune の Silence threshold と同じ。
    ///
    /// **組み直さない。**この値は RenderState.gate の中の数字で、書き換えれば
    /// 次の枠から効く。以前は組み直しを呼んでいたので、Stepper を押しっぱなしに
    /// すると反復のたびに音の系が組み直され、そのたびに音が切れていた。
    @Published var silenceThresholdDb: Double {
        didSet { save(silenceThresholdDb, Key.silence); onSilenceThresholdChange?() }
    }
    @Published var keepScreenAwake: Bool {
        didSet {
            save(keepScreenAwake, Key.awake)
            UIApplication.shared.isIdleTimerDisabled = keepScreenAwake
        }
    }

    @Published var syncVisualsToAudio: Bool {
        didSet { save(syncVisualsToAudio, Key.syncVisualsToAudio) }
    }

    @Published var jsfxCanvasMode: ETJSFXCanvasMode {
        didSet { save(jsfxCanvasMode.rawValue, Key.jsfxCanvasMode) }
    }

    /// 他のアプリの音の取り込み元。
    ///
    /// **組み直さない。**音のスレッドが読む札（ETCaptureRing.useCapture）を書くだけで、
    /// 次の枠から読み先が変わる。Media Device へ戻すときは取り込みも止める
    /// （鳴らない ScreenCaptureKit のストリームを握り続けない）。
    @Published var audioSource: ETAudioSource {
        didSet {
            save(audioSource.rawValue, Key.audioSource)
            ETCaptureRing.shared.useCapture = (audioSource == .screenCapture)
            if audioSource == .mediaDevice { ETScreenAudioCapture.shared.stop() }
        }
    }

    /// しきい値だけが変わったときに呼ばれる。組み直さずに値を差し替える。
    var onSilenceThresholdChange: (() -> Void)?

    /// 音の経路を組み直す必要がある設定が変わったときに呼ばれる。
    var onAudioChange: (() -> Void)?

    private typealias Key = PreferencesValues.Key

    /// 読み書きする入れ物。アプリは shared（UserDefaults.standard）。
    private let defaults: UserDefaults

    /// **読んだ値は PreferencesValues で範囲へ収める**（Silence threshold は -90 … -20）。
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let d = defaults
        processingRate = PreferencesValues.processingRate(d.object(forKey: Key.rate))
        latency = PreferencesValues.latency(d.string(forKey: Key.latency))
        powerMode = ETPowerMode(rawValue: d.string(forKey: Key.power) ?? "") ?? .balanced
        silenceThresholdDb = PreferencesValues.silenceThreshold(d.object(forKey: Key.silence))
        keepScreenAwake = d.object(forKey: Key.awake) as? Bool ?? false
        syncVisualsToAudio = d.bool(forKey: Key.syncVisualsToAudio)
        // 既定は Adaptive（PreferencesValues.jsfxCanvasMode の注記）。
        jsfxCanvasMode = PreferencesValues.jsfxCanvasMode(d.string(forKey: Key.jsfxCanvasMode))
        audioSource = PreferencesValues.audioSource(d.string(forKey: Key.audioSource))
        // init の代入では didSet が走らないので、札はここで立てる。
        ETCaptureRing.shared.useCapture = (audioSource == .screenCapture)

        // **init の代入では didSet が走らない。**
        // そのため、保存値が true でも起動直後だけ画面が落ちていた。
        // 設定を開いて触るまで効かない設定は、効いていないのと同じ。
        UIApplication.shared.isIdleTimerDisabled = keepScreenAwake
    }

    private func save(_ v: Any, _ key: String) {
        defaults.set(v, forKey: key)
    }
}
