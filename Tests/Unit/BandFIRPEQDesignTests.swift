//  BandFIRPEQDesignTests.swift
//  5Band FIR PEQの設計（BandFIRPEQDesign.swift）を上流のdesign-core.jsと照合する。
//  **実機もエンジンも要らない。**見本はTools/golden/designers_a_golden.mjsが上流に作らせた
//  Tests/Fixtures/Designers/designers-a-golden.json（読み方はDesignersAGolden.swift）。
//
//  設計は電話の上で作ってカーネルへ渡すので、曲線がずれてもカーネルの検査は通る。
//  ずれを報せるのはここだけ。

import XCTest

final class BandFIRPEQDesignTests: XCTestCase {

    // MARK: - RBJの係数

    /// 7種それぞれの帯域1本の応答が、上流のfiveBandFirPeqMagnitudeと一致する
    /// （中心が0.49·srを超えると頭打ち、lp/hpはslope/12乗、slopeは0.1〜384に寄せる）。
    ///
    /// 対数で比べ、許す幅はlnで1e-6×max(1, 指数)。相対1e-12では比べない。
    /// 上流は双2次を直に評価するので、零点の近く（hpのDC、lpのNyquist）と低い中心の1−cos ω0で
    /// 桁落ちし、lp/hpはそれをslope/12乗（最大32乗）する。cos・sin・pow・hypotの結果はV8と
    /// Darwinのlibmで1ulpまでは違いうる。呼び出しごとに±1ulpを全組み合わせで振ると、420点中79点が
    /// 相対1e-12を超えて動く（最大はlnで6.2e-7、lp・48kHz・中心23520・slope 384・23999Hz）。
    /// この幅はどの点でもその動きの46倍以上ある。それでもdBでは1e-5〜3e-4なので、式の取り違え
    /// （頭打ちの位置、指数、Qや利得の扱い）は見逃さない。
    func testRBJPerTypeMatchesUpstream() throws {
        let golden = try DesignersAGolden.load().bandFirPeq.magnitude
        XCTAssertEqual(Set(golden.map(\.type)), Set(BandFIRPEQFilterType.allCases.map(\.rawValue)),
                       "見本が7種を覆っていない")
        var checked = 0
        for entry in golden {
            let type = try XCTUnwrap(BandFIRPEQFilterType(rawValue: entry.type), entry.type)
            let band = BandFIRPEQBand(enabled: true, type: type, frequency: entry.center,
                                      gain: entry.gain, q: entry.q, slope: entry.slope)
            let exponent = type.usesSlope ? min(max(entry.slope, 0.1), 384) / 12 : 1
            let tolerance = 1e-6 * max(1, exponent)
            for (frequency, expected) in zip(entry.frequencies, entry.magnitudes) {
                let actual = BandFIRPEQCore.magnitude(of: band, at: frequency, sampleRate: entry.sampleRate)
                XCTAssertTrue(DesignerMatch.logClose(actual, expected, tolerance: tolerance),
                              "\(entry.type) fc=\(entry.center) sr=\(entry.sampleRate) f=\(frequency): "
                              + "\(actual)、上流は \(expected)")
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 300)
    }

    // MARK: - 正規化

    /// sampleRateの丸め（0は48000、8000〜768000）、周波数の上限（0.49·srか20kHz）、
    /// 利得・Q・slopeの範囲が上流のnormalizeConfigと同じ。
    func testConfigNormalizesLikeUpstream() throws {
        for design in try DesignersAGolden.load().bandFirPeq.designs {
            let config = BandFIRPEQConfig(settings: try settings(design.input), sampleRate: design.input.sampleRate)
            let label = design.input.name
            XCTAssertEqual(config.sampleRate, design.config.sampleRate, "\(label) sampleRate")
            XCTAssertEqual(config.taps, design.config.taps, "\(label) taps")
            XCTAssertEqual(config.phase.rawValue, design.config.phase, "\(label) phase")
            XCTAssertEqual(config.bands.count, design.config.eqBands.count, "\(label) 帯の数")
            for (index, (band, expected)) in zip(config.bands, design.config.eqBands).enumerated() {
                XCTAssertEqual(band.enabled, expected.enabled, "\(label) [\(index)] enabled")
                XCTAssertEqual(band.type.rawValue, expected.type, "\(label) [\(index)] type")
                XCTAssertEqual(band.frequency, expected.frequency, "\(label) [\(index)] frequency")
                XCTAssertEqual(band.gain, expected.gain, "\(label) [\(index)] gain")
                XCTAssertEqual(band.q, expected.q, "\(label) [\(index)] q")
                XCTAssertEqual(band.slope, expected.slope, "\(label) [\(index)] slope")
            }
        }
    }

    /// NaNは48000に倒れ、無限大は上流と同じく頭打ちに寄る（JSのNumber(x) || 48000は
    /// NaNと0だけを既定へ倒し、Infinityはそのまま丸めと切り詰めを通る）。1e300でもInt(_:)で落ちない。
    func testConfigRateNaNInfinityAndHuge() {
        let settings = BandFIRPEQSettings.default
        XCTAssertEqual(BandFIRPEQConfig(settings: settings, sampleRate: .nan).sampleRate, 48000)
        XCTAssertEqual(BandFIRPEQConfig(settings: settings, sampleRate: .infinity).sampleRate, 768000)
        XCTAssertEqual(BandFIRPEQConfig(settings: settings, sampleRate: -.infinity).sampleRate, 8000)
        XCTAssertEqual(BandFIRPEQConfig(settings: settings, sampleRate: 1e300).sampleRate, 768000)
        XCTAssertEqual(BandFIRPEQConfig(settings: settings, sampleRate: -1e300).sampleRate, 8000)
        XCTAssertEqual(BandFIRPEQConfig(settings: settings, sampleRate: 44100.5).sampleRate, 44101)
    }

    /// 帯が5本に足りなければ既定の中心周波数で埋め、多ければ捨てる（上流はeqBands?.[index] || {}）。
    func testConfigPadsAndTruncatesBands() {
        var short = BandFIRPEQSettings.default
        short.bands = [BandFIRPEQBand(frequency: 55)]
        let padded = BandFIRPEQConfig(settings: short, sampleRate: 48000)
        XCTAssertEqual(padded.bands.map(\.frequency), [55, 316, 1000, 3160, 10000])
        XCTAssertEqual(padded.bands.map(\.gain), [0, 0, 0, 0, 0])

        var long = BandFIRPEQSettings.default
        long.bands += [BandFIRPEQBand(frequency: 12345)]
        XCTAssertEqual(BandFIRPEQConfig(settings: long, sampleRate: 48000).bands.count, 5)

        // 8kHzでは既定の10000Hzが上限（3920Hz）を超えるので、上限に寄る。
        var none = BandFIRPEQSettings.default
        none.bands = []
        XCTAssertEqual(BandFIRPEQConfig(settings: none, sampleRate: 8000).bands.last?.frequency, 3920)
    }

    // MARK: - 設計

    /// 係数・遅延・分解能・狙いと出来上がりの曲線・精度の警告が、上流のdesignFiveBandFirPeqと一致する。
    func testDesignMatchesUpstream() throws {
        for design in try DesignersAGolden.load().bandFirPeq.designs {
            let label = design.input.name
            let config = BandFIRPEQConfig(settings: try settings(design.input), sampleRate: design.input.sampleRate)
            let result = try BandFIRPEQCore.design(config)

            XCTAssertEqual(result.channels.count, 1, "\(label) monoなので1本")
            DesignerMatch.assertChannel(result.channels[0], matches: design.channel, label)
            XCTAssertEqual(result.filterDelaySamples, design.filterDelaySamples, "\(label) fd")
            XCTAssertEqual(result.resolutionHz, design.resolutionHz, accuracy: 1e-12, "\(label) 分解能")
            XCTAssertEqual(result.hasAccuracyWarning, !design.qualityWarnings.isEmpty,
                           "\(label) 精度の警告（最大誤差 \(result.maximumErrorDb) dB）")

            XCTAssertEqual(result.response.frequencies.count, design.responsePointCount, "\(label) 曲線の点数")
            for (k, index) in design.response.indices.enumerated() {
                guard result.response.frequencies.indices.contains(index) else {
                    XCTFail("\(label) 曲線に\(index)番目が無い")
                    continue
                }
                XCTAssertTrue(DesignerMatch.close(result.response.frequencies[index],
                                                  design.response.frequencies[k], relative: 1e-12),
                              "\(label) f[\(index)]")
                XCTAssertEqual(result.response.targetDb[index], design.response.targetDb[k], accuracy: 1e-9,
                               "\(label) 狙い[\(index)] @\(design.response.frequencies[k])Hz")
                let realized = pow(10, result.response.realizedDb[index] / 20)
                let expected = pow(10, design.response.realizedDb[k] / 20)
                XCTAssertTrue(DesignerMatch.magnitudeClose(realized, expected),
                              "\(label) 出来上がり[\(index)] @\(design.response.frequencies[k])Hz: "
                              + "\(result.response.realizedDb[index]) dB、上流は \(design.response.realizedDb[k]) dB")
            }
        }
    }

    /// 見本に警告の出る設計と出ない設計の両方が入っている（片側だけだと境目を見ていない）。
    func testGoldenCoversBothAccuracyOutcomes() throws {
        let warnings = try DesignersAGolden.load().bandFirPeq.designs.map { !$0.qualityWarnings.isEmpty }
        XCTAssertTrue(warnings.contains(true))
        XCTAssertTrue(warnings.contains(false))
    }

    // MARK: - 小さな約束

    /// 警告の境目はdesign-core.js:386と同じ0.5dB（ちょうど0.5は出さない）。
    func testAccuracyWarningThreshold() throws {
        let base = try BandFIRPEQCore.design(BandFIRPEQConfig(settings: .default, sampleRate: 48000))
        func with(_ error: Double) -> BandFIRPEQDesign {
            BandFIRPEQDesign(config: base.config, channels: base.channels,
                             filterDelaySamples: base.filterDelaySamples, resolutionHz: base.resolutionHz,
                             maximumErrorDb: error, response: base.response)
        }
        XCTAssertFalse(with(0.5).hasAccuracyWarning)
        XCTAssertTrue(with(0.5000001).hasAccuracyWarning)
        // 帯が全部効かない既定の設定は平らで、誤差はほぼ0。
        XCTAssertLessThan(base.maximumErrorDb, 0.5)
    }

    /// packed paramsのltは値でなく並びの添字（dsp-params.generated.jsの
    /// ["0","128","256","512","1024"].indexOf(lt)）。
    func testLatencyParameterIndexIsPosition() {
        let order = ["0", "128", "256", "512", "1024"]
        for latency in BandFIRPEQLatency.allCases {
            XCTAssertEqual(latency.parameterIndex, Float(order.firstIndex(of: String(latency.rawValue))!))
        }
    }

    /// 最小位相は遅延0、線形位相はtaps/2。分解能はsr/taps（design-core.js:387-389）。
    func testLatencyAndResolution() throws {
        var settings = BandFIRPEQSettings.default
        settings.taps = .taps8192
        settings.phase = .linear
        let linear = try BandFIRPEQCore.design(BandFIRPEQConfig(settings: settings, sampleRate: 44100))
        XCTAssertEqual(linear.filterDelaySamples, 4096)
        XCTAssertEqual(linear.resolutionHz, 44100.0 / 8192.0)
        settings.phase = .minimum
        let minimum = try BandFIRPEQCore.design(BandFIRPEQConfig(settings: settings, sampleRate: 44100))
        XCTAssertEqual(minimum.filterDelaySamples, 0)
    }

    /// 同じ条件の2回目は作り直さず控えから返る。値が同じなだけなら控えが無くても通るので、
    /// 係数の置き場（配列の中身のアドレス）まで同じことを見る。
    func testSameConfigReturnsCachedDesign() throws {
        let config = cacheProbeConfig(gain: 7.125)
        let first = try BandFIRPEQCore.design(config)
        let second = try BandFIRPEQCore.design(config)
        XCTAssertTrue(sharesStorage(first, second), "2回目を作り直した")
        XCTAssertEqual(first.channels, second.channels)
        XCTAssertEqual(first.maximumErrorDb, second.maximumErrorDb)
    }

    /// 控えは上流のdesignCacheと同じく2つまで（design-core.js:394-395）。
    /// A・B・Cと作るとAは追い出され、Bは残る。
    func testDesignCacheKeepsTwoAndDropsOldest() throws {
        // この試験でしか使わない条件にして、前の試験が残した控えと重ならないようにする。
        let a = cacheProbeConfig(gain: 7.375)
        let b = cacheProbeConfig(gain: 7.625)
        let c = cacheProbeConfig(gain: 7.875)
        let firstA = try BandFIRPEQCore.design(a)
        let firstB = try BandFIRPEQCore.design(b)
        _ = try BandFIRPEQCore.design(c)

        let againB = try BandFIRPEQCore.design(b)
        XCTAssertTrue(sharesStorage(firstB, againB), "2つ目までの控えを落とした")

        let againA = try BandFIRPEQCore.design(a)
        XCTAssertFalse(sharesStorage(firstA, againA), "3つ目を作っても一番古い控えが残っている")
        XCTAssertEqual(firstA.channels, againA.channels, "作り直した設計が前と違う")
    }

    // MARK: - 道具

    /// 控えを見る試験用の条件。8192タップ・48kHzで、3本目の帯の利得だけを変える。
    private func cacheProbeConfig(gain: Double) -> BandFIRPEQConfig {
        var settings = BandFIRPEQSettings.default
        settings.taps = .taps8192
        settings.bands[2].gain = gain
        return BandFIRPEQConfig(settings: settings, sampleRate: 48000)
    }

    /// 2つの設計が係数の配列の中身を共有している（控えから返った）か。
    /// 呼ぶ側が両方を持っているあいだは、作り直した配列が同じアドレスになることはない。
    private func sharesStorage(_ a: BandFIRPEQDesign, _ b: BandFIRPEQDesign) -> Bool {
        guard let left = a.channels.first, let right = b.channels.first else { return false }
        return left.withUnsafeBufferPointer { l in
            right.withUnsafeBufferPointer { r in l.baseAddress == r.baseAddress }
        }
    }

    private func settings(_ input: DesignersAGolden.BandFIRPEQ.Input) throws -> BandFIRPEQSettings {
        let bands = try input.bands.map { band -> BandFIRPEQBand in
            BandFIRPEQBand(enabled: band.enabled,
                           type: try XCTUnwrap(BandFIRPEQFilterType(rawValue: band.type), band.type),
                           frequency: band.frequency, gain: band.gain, q: band.q, slope: band.slope)
        }
        return BandFIRPEQSettings(bands: bands,
                                  taps: try XCTUnwrap(BandFIRPEQTaps(rawValue: input.taps), "\(input.taps)"),
                                  phase: try XCTUnwrap(BandFIRPEQPhase(rawValue: input.phase), input.phase),
                                  latency: .block128)
    }
}
