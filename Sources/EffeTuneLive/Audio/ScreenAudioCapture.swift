//  ScreenAudioCapture.swift
//  iOS 27 の ScreenCaptureKit でシステム音を受ける取り込み元。
//  もう 1 つの取り込み元（Media Device の拡張 → TCP）とは別の経路で、
//  設定の Audio Source で選ぶ。音の行き先は ETCaptureRing（読むのは AudioIO の音のスレッド）。
//
//  **流れ。**Start Capture → システムのピッカー（SCContentSharingPicker）で画面を選ぶ →
//  filter が届く → 新しい SCStream を作って音だけ受ける。
//  iOS では updateContentFilter / updateConfiguration が使えないので、選び直すたびに
//  ストリームを作り直す。
//
//  **excludesCurrentProcessAudio = true は必須。**外すと、このアプリが鳴らす処理後の音を
//  自分で取り直して帰還する（iOS 27.2 beta 2 より前は効かなかった）。
//
//  映像は要らないが filter は映像つきなので、寸法を 2x2 に絞って捨てる。
//  captureMicrophone・minimumFrameInterval・queueDepth・pixelFormat・showsCursor は
//  iOS では使えないので触らない。
//
//  スレッド: ピッカーの通知とストリームの delegate は main とは限らない。
//  @Published へ書くのは必ず main へ寄せてから。ストリームの参照はロックで守り、
//  古いストリームの通知（選び直した後に届く didStopWithError など）は捨てる。
//  音のサンプルは専用のシリアルキューで届く（音のスレッドではない）。

import Foundation
import Combine
import ScreenCaptureKit
import CoreMedia
import AudioToolbox
import os

final class ETScreenAudioCapture: NSObject, ObservableObject, SCContentSharingPickerObserver,
                                  SCStreamDelegate, SCStreamOutput, @unchecked Sendable {

    static let shared = ETScreenAudioCapture()

    /// 取り込み中か（ストリームが走り出してから）。
    @Published private(set) var capturing = false
    /// 直近の失敗。"domain code" の形。取り込みが始まれば消える。
    @Published private(set) var lastError: String?

    private let log = Logger(subsystem: "ai.nemut.effetune", category: "capture")

    /// リンクは 48kHz 固定。この版はリサンプルしない。
    private static let linkRate = 48000.0

    // ---- 状態（ロックで守る） ----
    private let lock = NSLock()
    private var current: SCStream?

    /// main だけが触る。
    private var observerAdded = false

    // ---- サンプルキューだけが触る ----
    private let sampleQueue = DispatchQueue(label: "ai.nemut.effetune.capture.sample",
                                            qos: .userInteractive)
    /// インターリーブ 2ch の float。足りなくなったときだけ広げる。
    private var scratch: UnsafeMutablePointer<Float>?
    private var scratchFrames = 0
    private var loggedFormat = false
    private var loggedRate = false
    private var loggedUnsupported = false
    private var statFrames: UInt64 = 0
    private var statPeak: Float = 0
    private var statSince: TimeInterval = 0
    private var lastRate = 0.0
    private var lastChannels = 0
    private var lastInterleaved = true

    private override init() {
        super.init()
    }

    /// システムのピッカーが使える端末か（iOS 27）。使えなければ設定に開始の行を出さない。
    @MainActor
    static var isAvailable: Bool { SCContentSharingPicker.shared.isAvailable }

    // MARK: - 操作

    /// ピッカーを出す。**isActive が真でないと何も出ない。**
    @MainActor
    func present() {
        let picker = SCContentSharingPicker.shared
        picker.isActive = true
        if !observerAdded {
            picker.add(self)
            observerAdded = true
        }
        picker.present(using: .display)
    }

    /// 取り込みを止める。何度呼んでもよい。
    func stop() {
        lock.lock()
        let old = current
        current = nil
        lock.unlock()
        // 先に current を外したので、この停止で届く didStopWithError は捨てられる。
        old?.stopCapture { _ in }
        ETCaptureRing.shared.endCapture()
        onMain { self.capturing = false }
    }

    // MARK: - ストリーム

    private func startStream(filter: SCContentFilter) {
        // 前のストリームを外す（選び直し）。
        lock.lock()
        let old = current
        current = nil
        lock.unlock()
        old?.stopCapture { _ in }

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = Int(Self.linkRate)
        config.channelCount = 2
        config.width = 2
        config.height = 2

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        } catch {
            fail(error)
            return
        }

        lock.lock()
        current = stream
        lock.unlock()

        // 統計と「最初の 1 本」の札は、この後に届くサンプルより先に戻しておく
        // （同じシリアルキューなので順序が保たれる）。
        sampleQueue.async { self.resetStats() }
        ETCaptureRing.shared.beginCapture()

        stream.startCapture { [weak self] error in
            guard let self else { return }
            self.lock.lock()
            let stillCurrent = (self.current === stream)
            if stillCurrent && error != nil { self.current = nil }
            self.lock.unlock()
            guard stillCurrent else { return }
            if let error {
                ETCaptureRing.shared.endCapture()
                self.fail(error)
            } else {
                self.log.notice("sck 開始")
                self.onMain {
                    self.lastError = nil
                    self.capturing = true
                }
            }
        }
    }

    private func fail(_ error: Error) {
        let ns = error as NSError
        let text = "\(ns.domain) \(ns.code)"
        log.error("sck 失敗 \(text, privacy: .public)")
        ETLogTap.record("sck failed \(text)")
        onMain {
            self.lastError = text
            self.capturing = false
        }
    }

    /// main にいればその場で、いなければ main へ寄せて実行する。
    private func onMain(_ work: @escaping @Sendable () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    // MARK: - SCContentSharingPickerObserver

    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        // 取り消しでは何も変えない（走っている取り込みはそのまま）。
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker,
                              didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        // ピッカーを出している間に Media Device へ戻していたら始めない
        // （止める口が設定から消えていて、鳴らないストリームを握り続ける）。
        guard ETCaptureRing.shared.useCapture else { return }
        startStream(filter: filter)
    }

    func contentSharingPickerStartDidFailWithError(_ error: Error) {
        fail(error)
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        lock.lock()
        let stillCurrent = (current === stream)
        if stillCurrent { current = nil }
        lock.unlock()
        // 選び直しや stop() で外したストリームの通知は捨てる。
        guard stillCurrent else { return }
        ETCaptureRing.shared.endCapture()
        fail(error)
    }

    // MARK: - SCStreamOutput（sampleQueue の上）

    private func resetStats() {
        loggedFormat = false
        loggedRate = false
        loggedUnsupported = false
        statFrames = 0
        statPeak = 0
        statSince = 0
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        // **外したストリームの残りは積まない。**選び直しの直後は前のストリームの
        // stopCapture が終わるまで同じキューへ届き続け、新しい方と交互に輪へ入る。
        lock.lock()
        let live = (current === stream)
        lock.unlock()
        guard live else { return }
        guard let asbd = sampleBuffer.formatDescription?.audioStreamBasicDescription else { return }
        let frames = sampleBuffer.numSamples
        guard frames > 0 else { return }

        do {
            try sampleBuffer.withAudioBufferList { abl, _ in
                let n = convert(abl, asbd: asbd, frames: frames)
                guard n > 0, let scratch else { return }
                ETCaptureRing.shared.pushInterleaved(scratch, frames: UInt32(n))
                noteBuffer(asbd: asbd, frames: n)
            }
        } catch {
            if !loggedUnsupported {
                loggedUnsupported = true
                let ns = error as NSError
                log.error("sck バッファ取得失敗 \(ns.domain, privacy: .public) \(ns.code)")
            }
        }
    }

    /// AudioBufferList を scratch の float インターリーブ 2ch へ写す。写したフレーム数を返す。
    /// float32 / int16 の、インターリーブ・非インターリーブに対応。
    /// モノは左右へ複製、3ch 以上は先頭の 2 本だけ。非有限値は 0。
    private func convert(_ abl: UnsafeMutableAudioBufferListPointer,
                         asbd: AudioStreamBasicDescription, frames: Int) -> Int {
        let ch = Int(asbd.mChannelsPerFrame)
        guard ch > 0, abl.count > 0 else { return 0 }
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let planar = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let bits = Int(asbd.mBitsPerChannel)
        guard (isFloat && bits == 32) || (!isFloat && bits == 16) else {
            if !loggedUnsupported {
                loggedUnsupported = true
                log.error("sck 未対応の形式 bits=\(bits) float=\(isFloat)")
            }
            return 0
        }
        let bytes = bits / 8

        // 左右それぞれの (先頭, 1 フレームあたりの刻み, 先頭からのずれ)。
        let leftBase: UnsafeRawPointer?
        let rightBase: UnsafeRawPointer?
        let stride: Int
        let leftOffset: Int
        let rightOffset: Int
        var n = frames
        if planar {
            let rightIndex = ch > 1 ? 1 : 0
            guard abl.count > rightIndex else { return 0 }
            leftBase = UnsafeRawPointer(abl[0].mData)
            rightBase = UnsafeRawPointer(abl[rightIndex].mData)
            stride = 1
            leftOffset = 0
            rightOffset = 0
            n = min(n, Int(abl[0].mDataByteSize) / bytes, Int(abl[rightIndex].mDataByteSize) / bytes)
        } else {
            leftBase = UnsafeRawPointer(abl[0].mData)
            rightBase = leftBase
            stride = ch
            leftOffset = 0
            rightOffset = ch > 1 ? 1 : 0
            n = min(n, Int(abl[0].mDataByteSize) / (bytes * ch))
        }
        guard n > 0, let left = leftBase, let right = rightBase else { return 0 }

        if n > scratchFrames {
            scratch?.deallocate()
            scratch = UnsafeMutablePointer<Float>.allocate(capacity: n * 2)
            scratchFrames = n
        }
        guard let out = scratch else { return 0 }

        var peak = statPeak
        for i in 0..<n {
            let li = i * stride + leftOffset
            let ri = i * stride + rightOffset
            var l: Float
            var r: Float
            if isFloat {
                l = left.loadUnaligned(fromByteOffset: li * 4, as: Float.self)
                r = right.loadUnaligned(fromByteOffset: ri * 4, as: Float.self)
            } else {
                l = Float(left.loadUnaligned(fromByteOffset: li * 2, as: Int16.self)) / 32768
                r = Float(right.loadUnaligned(fromByteOffset: ri * 2, as: Int16.self)) / 32768
            }
            if !l.isFinite { l = 0 }
            if !r.isFinite { r = 0 }
            out[i * 2] = l
            out[i * 2 + 1] = r
            peak = max(peak, abs(l), abs(r))
        }
        statPeak = peak
        return n
    }

    /// 形式の最初の 1 回と、約 10 秒ごとの 1 行。.info は残らないので .notice。
    private func noteBuffer(asbd: AudioStreamBasicDescription, frames: Int) {
        let planar = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        lastRate = asbd.mSampleRate
        lastChannels = Int(asbd.mChannelsPerFrame)
        lastInterleaved = !planar
        statFrames += UInt64(frames)

        if !loggedFormat {
            loggedFormat = true
            let line = "sck first rate=\(asbd.mSampleRate) ch=\(asbd.mChannelsPerFrame) "
                     + "bits=\(asbd.mBitsPerChannel) flags=\(asbd.mFormatFlags) "
                     + "interleaved=\(!planar) frames=\(frames)"
            log.notice("\(line, privacy: .public)")
            ETLogTap.record(line)
        }
        if !loggedRate && asbd.mSampleRate != Self.linkRate {
            loggedRate = true
            let line = "sck rate \(asbd.mSampleRate) != 48000, link is fixed at 48k (no resampling)"
            log.notice("\(line, privacy: .public)")
            ETLogTap.record(line)
        }

        let now = ProcessInfo.processInfo.systemUptime
        if statSince == 0 { statSince = now }
        if now - statSince >= 10 {
            let line = "sck frames=\(statFrames) rate=\(lastRate) ch=\(lastChannels) "
                     + "interleaved=\(lastInterleaved) peak=\(String(format: "%.4f", statPeak))"
            log.notice("\(line, privacy: .public)")
            ETLogTap.record(line)
            statFrames = 0
            statPeak = 0
            statSince = now
        }
    }

    deinit {
        scratch?.deallocate()
    }
}
