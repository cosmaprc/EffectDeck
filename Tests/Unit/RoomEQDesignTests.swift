//  RoomEQDesignTests.swift
//  Room EQ の設計（RoomEQDesign.swift）。**実機もエンジンも要らない。**
//
//  約束は 3 つ。
//    1. min / lin の補正 FIR（周波数特性だけの測定・インパルス応答・別レートの伸縮・
//       Additional EQ・測定の無い枠）と、遅延・分解能・注意・基準レベルが上流の designRoomEq と同じ。
//    2. full は移していないので lin に落とし、そのことを必ず知らせる。
//    3. 32MiB の枠に入るかを設計の前に判断する（checkCapacity / largestUsableTaps）。
//       latencyMode の保存値（添字）と headBlock の行き来。

import XCTest
import Foundation

final class RoomEQDesignTests: XCTestCase {

    // MARK: - latencyMode

    /// 添字 ↔ headBlock。表に無い headBlock は既定の添字 1（128）に倒す。
    func testLatencyModeRoundTrip() {
        for (index, mode) in RoomEQDesigner.allowedLatencyModes.enumerated() {
            XCTAssertEqual(RoomEQDesigner.parameterValue(forLatencyMode: mode), Float(index))
            XCTAssertEqual(RoomEQDesigner.latencyMode(fromParameterValue: Float(index)), mode)
            XCTAssertEqual(RoomEQDesigner.latencyMode(
                fromParameterValue: RoomEQDesigner.parameterValue(forLatencyMode: mode)), mode)
        }
        XCTAssertEqual(RoomEQDesigner.parameterValue(forLatencyMode: 64), 1)
        XCTAssertEqual(RoomEQDesigner.latencyMode(fromParameterValue: 2.4), 256)
        XCTAssertEqual(RoomEQDesigner.latencyMode(fromParameterValue: -0.4), 0)
        XCTAssertEqual(RoomEQDesigner.latencyMode(fromParameterValue: -0.6), 128)
        XCTAssertEqual(RoomEQDesigner.latencyMode(fromParameterValue: 5), 128)
    }

    /// 有限でない値や Int に入らない値でも落ちずに 128。
    /// 直す前は `Int(value.rounded())` が NaN・無限大・1e30 で trap していた。
    func testLatencyModeNonFiniteFallsBackTo128() {
        for value: Float in [.nan, .infinity, -.infinity, 1e30, -1e30, .greatestFiniteMagnitude] {
            XCTAssertEqual(RoomEQDesigner.latencyMode(fromParameterValue: value), 128, "\(value)")
        }
    }

    // MARK: - 持ち上げの頭打ち

    /// 上限の 1dB 手前まではそのまま、上限で止まり、そのあいだは 3 次で繋ぐ（値も傾きも続く）。
    func testSoftLimitBoost() throws {
        XCTAssertEqual(RoomEQDesigner.softLimitBoost(-3, maximum: 6), -3)
        XCTAssertEqual(RoomEQDesigner.softLimitBoost(5, maximum: 6), 5)
        XCTAssertEqual(RoomEQDesigner.softLimitBoost(6, maximum: 6), 6)
        XCTAssertEqual(RoomEQDesigner.softLimitBoost(40, maximum: 6), 6)
        XCTAssertEqual(RoomEQDesigner.softLimitBoost(1, maximum: 0), 0)
        var previous = -Double.infinity
        for step in 0...200 {
            let decibels = 4.5 + Double(step) * 0.01
            let value = RoomEQDesigner.softLimitBoost(decibels, maximum: 6)
            XCTAssertGreaterThanOrEqual(value, previous, "\(decibels)")
            XCTAssertLessThanOrEqual(value, 6)
            previous = value
        }
        // 継ぎ目の傾き: 手前は 1、上限では 0。
        let h = 1e-6
        XCTAssertEqual((RoomEQDesigner.softLimitBoost(5 + h, maximum: 6) - 5) / h, 1, accuracy: 1e-5)
        XCTAssertEqual((6 - RoomEQDesigner.softLimitBoost(6 - h, maximum: 6)) / h, 0, accuracy: 1e-5)

        let golden = try DesignersBGolden.load()
        XCTAssertGreaterThanOrEqual(golden.roomEq.softLimitBoost.count, 20)
        for entry in golden.roomEq.softLimitBoost {
            XCTAssertEqual(RoomEQDesigner.softLimitBoost(entry.decibels, maximum: entry.maximum), entry.expected,
                           accuracy: 1e-15, "\(entry.decibels) / \(entry.maximum)")
        }
    }

    // MARK: - 枠に入るか

    /// 入る taps のうち一番大きいもの。AssetUpload.maximumFrames をそのまま当てはめた答えと同じ。
    func testLargestUsableTaps() {
        for channels in [1, 2, 4, 8, 16] {
            for latency: UInt32 in [0, 128, 1024] {
                let topology: ETAssetTopology = channels > 1 ? .independent : .mono
                let expected = RoomEQConfig.allowedTaps.sorted(by: >).first { taps in
                    AssetUpload.maximumFrames(sourceFrames: taps, assetChannels: channels, topology: topology,
                                              processingChannels: channels, headBlock: Int(latency)) >= taps
                }
                XCTAssertEqual(RoomEQDesigner.largestUsableTaps(channelCount: channels,
                                                                processingChannels: channels,
                                                                latencyMode: latency),
                               expected, "\(channels)ch lt \(latency)")
            }
        }
        // mono の 131072 は入る。多チャンネルほど小さくなり、増えることはない。
        XCTAssertEqual(RoomEQDesigner.largestUsableTaps(channelCount: 1, processingChannels: 1), 131072)
        var previous = Int.max
        for channels in 1...16 {
            let taps = RoomEQDesigner.largestUsableTaps(channelCount: channels, processingChannels: channels) ?? 0
            XCTAssertLessThanOrEqual(taps, previous, "\(channels)ch")
            previous = taps
        }
        print("RoomEQ largestUsableTaps 1…16ch:",
              (1...16).map { RoomEQDesigner.largestUsableTaps(channelCount: $0, processingChannels: $0) ?? 0 })
    }

    /// 入らないときは入る一番大きい taps を添えて落ちる。0 チャンネルは noSources。
    /// taps は倒してから見る（許されない値は 32768）。
    func testCheckCapacity() throws {
        XCTAssertNoThrow(try RoomEQDesigner.checkCapacity(config: RoomEQConfig(taps: 8192),
                                                          channelCount: 1, processingChannels: 1))
        XCTAssertThrowsError(try RoomEQDesigner.checkCapacity(config: RoomEQConfig(), channelCount: 0,
                                                              processingChannels: 2)) {
            guard case RoomEQDesignError.noSources = $0 else { return XCTFail("\($0)") }
        }
        let largest = try XCTUnwrap(RoomEQDesigner.largestUsableTaps(channelCount: 16, processingChannels: 16))
        XCTAssertLessThan(largest, 131072, "16 チャンネルの 131072 は 32MiB に入らないはず")
        XCTAssertThrowsError(try RoomEQDesigner.checkCapacity(config: RoomEQConfig(taps: 131072),
                                                              channelCount: 16, processingChannels: 16)) {
            guard case RoomEQDesignError.tapsExceedAssetCapacity(let taps, let maximum) = $0 else {
                return XCTFail("\($0)")
            }
            XCTAssertEqual(taps, 131072)
            XCTAssertEqual(maximum, largest)
            XCTAssertEqual(($0 as? LocalizedError)?.errorDescription,
                           "131072 taps do not fit in the 32 MiB asset slot. Use \(largest) or fewer.")
        }
        // 12345 は許されないので 32768 として見る。
        let normalizedFits = (RoomEQDesigner.largestUsableTaps(channelCount: 16, processingChannels: 16) ?? 0) >= 32768
        XCTAssertEqual((try? RoomEQDesigner.checkCapacity(config: RoomEQConfig(taps: 12345),
                                                          channelCount: 16, processingChannels: 16)) != nil,
                       normalizedFits)
    }

    // MARK: - 設定の倒し方

    func testConfigNormalized() {
        var config = RoomEQConfig(sampleRate: -1, taps: 12345, smoothing: 0, lowFrequency: 1, highFrequency: 1e6,
                                  maxBoostDb: -3, correctionAmount: 7)
        config.phaseSmoothing = nil
        config.referencePoint = -4
        let normalized = config.normalized()
        XCTAssertEqual(normalized.taps, 32768)
        XCTAssertEqual(normalized.sampleRate, 48000)
        XCTAssertEqual(normalized.smoothing, 0.02)
        XCTAssertEqual(normalized.phaseSmoothing, 0.02)   // 自動は振幅の平滑化と同じ
        XCTAssertEqual(normalized.lowFrequency, 20)
        XCTAssertEqual(normalized.highFrequency, 20000)
        XCTAssertEqual(normalized.maxBoostDb, 0)
        XCTAssertEqual(normalized.correctionAmount, 1)
        XCTAssertEqual(normalized.referencePoint, 0)
        XCTAssertEqual(RoomEQConfig(sampleRate: 44099).normalized().sampleRate, 44099)
    }

    // MARK: - 上流の見本

    private func config(_ golden: DesignersBGolden.RoomConfig) throws -> RoomEQConfig {
        var config = RoomEQConfig()
        config.sampleRate = golden.sampleRate
        config.taps = golden.taps
        config.phase = try XCTUnwrap(RoomEQPhase(rawValue: golden.phase ?? "min"))
        config.smoothing = golden.smoothing
        config.lowFrequency = golden.lowFrequency
        config.highFrequency = golden.highFrequency
        config.maxBoostDb = golden.maxBoostDb
        config.correctionAmount = golden.correctionAmount
        config.bands = try (golden.eqBands ?? []).map { band in
            RoomEQBand(enabled: band.enabled,
                       type: try XCTUnwrap(RoomEQBandType(rawValue: band.type)),
                       frequency: band.frequency, gain: band.gain, q: band.q)
        }
        return config
    }

    private func source(_ golden: DesignersBGolden.RoomSource?) -> RoomEQSource? {
        guard let golden else { return nil }
        return RoomEQSource(
            impulses: golden.impulses.map {
                RoomEQImpulse(data: $0.data.floats, sampleRate: $0.sampleRate, onsetIndex: $0.onsetIndex,
                              referenceScale: $0.referenceScale)
            },
            frequencyResponse: golden.frequencyResponse.map {
                RoomEQResponsePoint(frequency: $0.frequency, decibels: $0.decibels)
            })
    }

    /// 補正 FIR・遅延・分解能・full の可否・注意・基準レベル・倒した設定が上流と同じ。
    func testDesignMatchesUpstream() throws {
        let golden = try DesignersBGolden.load()
        XCTAssertGreaterThanOrEqual(golden.roomEq.designs.count, 3)
        var worst = 0.0
        for entry in golden.roomEq.designs {
            let design = RoomEQDesigner.design(config: try config(entry.config),
                                               sources: entry.sources.map(source))
            let e = entry.expected
            XCTAssertFalse(design.phaseFallback, entry.name)
            XCTAssertEqual(design.filterDelaySamples, e.filterDelaySamples, entry.name)
            XCTAssertEqual(design.resolutionHz, e.resolutionHz, accuracy: 1e-12, entry.name)
            XCTAssertEqual(design.supportsFullPhase, e.supportsFullPhase, entry.name)
            XCTAssertEqual(design.qualityWarnings.map(\.rawValue), e.qualityWarnings, entry.name)
            XCTAssertEqual(design.config.sampleRate, e.config.sampleRate, entry.name)
            XCTAssertEqual(design.config.taps, e.config.taps, entry.name)
            XCTAssertEqual(design.config.smoothing, e.config.smoothing, entry.name)
            XCTAssertEqual(design.config.lowFrequency, e.config.lowFrequency, entry.name)
            XCTAssertEqual(design.config.highFrequency, e.config.highFrequency, entry.name)
            XCTAssertEqual(design.config.maxBoostDb, e.config.maxBoostDb, entry.name)
            XCTAssertEqual(design.config.correctionAmount, e.config.correctionAmount, entry.name)

            XCTAssertEqual(design.referenceLevelDb.count, e.referenceLevelDb.count, entry.name)
            for (got, want) in zip(design.referenceLevelDb, e.referenceLevelDb) {
                XCTAssertEqual(got == nil, want == nil, entry.name)
                if let got, let want { XCTAssertEqual(got, want, accuracy: 1e-9, entry.name) }
            }

            XCTAssertEqual(design.channels.count, e.channels.count, entry.name)
            for (index, (got, want)) in zip(design.channels, e.channels).enumerated() {
                let wanted = want.floats
                XCTAssertEqual(got.count, wanted.count, "\(entry.name) ch\(index)")
                let diff = DesignersBGolden.maxRelativeDiff(got.map { Double($0) }, wanted.map { Double($0) })
                worst = max(worst, diff)
                XCTAssertLessThanOrEqual(diff, 1e-6, "\(entry.name) ch\(index)")
            }
        }
        print("RoomEQ golden: worst channel diff \(worst) of peak")
    }

    // MARK: - 移していない所

    /// full は lin で設計し、phaseFallback と fullPhaseNotPorted で知らせる。
    /// 周波数特性だけの測定なら impulseResponseRequired も付く（上流と同じ注意）。
    func testFullFallsBackToLinearAndSaysSo() {
        var config = RoomEQConfig(taps: 8192)
        config.phase = .full
        let source = RoomEQSource(frequencyResponse: [RoomEQResponsePoint(frequency: 100, decibels: 3),
                                                      RoomEQResponsePoint(frequency: 1000, decibels: -2)])
        let design = RoomEQDesigner.design(config: config, sources: [source])
        XCTAssertTrue(design.phaseFallback)
        XCTAssertEqual(design.appliedPhase, .linear)
        XCTAssertEqual(design.config.phase, .linear)
        XCTAssertEqual(design.filterDelaySamples, 4096)
        XCTAssertFalse(design.supportsFullPhase)
        XCTAssertEqual(design.qualityWarnings, [.fullPhaseNotPorted, .impulseResponseRequired])
    }

    /// 測定の無い枠は素通し: min は頭、lin は真ん中の単位インパルス。遅延は min 0、lin taps/2。
    func testMissingSourceIsUnitImpulse() {
        for phase in [RoomEQPhase.minimum, .linear] {
            var config = RoomEQConfig(taps: 8192)
            config.phase = phase
            let design = RoomEQDesigner.design(config: config, sources: [nil, nil])
            XCTAssertEqual(design.channels.count, 2)
            let at = phase == .minimum ? 0 : 4096
            for channel in design.channels {
                XCTAssertEqual(channel.count, 8192)
                XCTAssertEqual(channel[at], 1)
                XCTAssertEqual(channel.reduce(0) { $0 + abs($1) }, 1)
            }
            XCTAssertEqual(design.referenceLevelDb.count, 2)
            XCTAssertTrue(design.referenceLevelDb.allSatisfy { $0 == nil })
            XCTAssertEqual(design.filterDelaySamples, phase == .minimum ? 0 : 4096)
            XCTAssertTrue(design.supportsFullPhase)
            XCTAssertEqual(design.qualityWarnings, [])
        }
    }
}
