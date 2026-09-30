//  RemoteProtocolTests.swift
//  PC の EffeTune を LAN から操る PoC の、通信に触らない部分（DSP/RemoteProtocol.swift）。
//
//  見ているもの:
//    - 外部の段（AU / JSFX）は、同じバスの中なら落ち、バスを渡るなら 0 dB の Volume になる
//    - 落ちた段のぶん、手元の番号 → PC の番号の対応表がずれる（params の宛先）
//    - 外部の段の externalState は PC へ渡す形に入らない（符号化する前に振り分ける）
//    - params には動かせるパラメータのショートキーだけが入る
//    - 接続先の字の読み方（host:port/token・ws:// の URL・読めない字）

import XCTest

final class RemoteProtocolTests: XCTestCase {

    // MARK: - 道具

    private func effect(_ type: String) throws -> PipelineStore.Loaded {
        let spec = try XCTUnwrap(ETCatalog.first { $0.type == type }, "カタログに無い: \(type)")
        return PipelineStore.Loaded(spec: spec, values: spec.defaults, enabled: true,
                                    inputBus: 0, outputBus: 0, channelSpec: -1)
    }

    private func section(_ name: String) -> PipelineStore.Loaded {
        PipelineStore.Loaded(spec: ETSection.spec, values: [], enabled: true,
                             inputBus: 0, outputBus: 0, channelSpec: -1, sectionName: name)
    }

    private func external(inputBus: UInt8, outputBus: UInt8, enabled: Bool = true,
                          state: Data? = Data([1, 2, 3])) -> PipelineStore.Loaded {
        PipelineStore.Loaded(
            spec: ETEffect.external(type: "External:au:aufx-dely-abcd", name: "My Delay",
                                    category: "Audio Units"),
            values: [], enabled: enabled, inputBus: inputBus, outputBus: outputBus,
            channelSpec: -1, externalID: "au:aufx-dely-abcd",
            externalInstanceID: "inst-1", externalState: state)
    }

    // MARK: - 鎖の写し

    func testInPlaceExternalIsDroppedAndIndexMapSkipsIt() throws {
        let chain = [try effect("VolumePlugin"),
                     external(inputBus: 0, outputBus: 0),
                     try effect("DelayPlugin")]
        let projected = ETRemoteProjection.project(chain)
        XCTAssertEqual(projected.pipeline.count, 2)
        XCTAssertEqual(projected.pipeline.map { $0["nm"] as? String },
                       [chain[0].spec.name, chain[2].spec.name])
        // 手元の 2 番目（Delay）は PC では 1 番目。落ちた段は nil。
        XCTAssertEqual(projected.remoteIndex, [0, nil, 1])
    }

    func testBusCrossingExternalBecomesZeroDbVolumeKeepingRouting() throws {
        let chain = [external(inputBus: 1, outputBus: 2, enabled: false)]
        let projected = ETRemoteProjection.project(chain)
        XCTAssertEqual(projected.remoteIndex, [0])
        let entry = try XCTUnwrap(projected.pipeline.first)
        XCTAssertEqual(entry["nm"] as? String, "Volume")
        XCTAssertEqual(entry["en"] as? Bool, false)
        XCTAssertEqual(entry["vl"] as? Double, 0)
        XCTAssertEqual(entry["ib"] as? Int, 1)
        XCTAssertEqual(entry["ob"] as? Int, 2)
        XCTAssertNil(entry["external"])
    }

    func testExternalStateNeverReachesTheWire() throws {
        let chain = [try effect("VolumePlugin"),
                     external(inputBus: 1, outputBus: 2, state: Data(repeating: 7, count: 4096)),
                     external(inputBus: 0, outputBus: 0, state: Data(repeating: 9, count: 4096))]
        let projected = ETRemoteProjection.project(chain)
        let data = try JSONSerialization.data(withJSONObject: projected.pipeline)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("externalState"))
        XCTAssertFalse(text.contains("external"))
        XCTAssertFalse(text.contains(Data(repeating: 7, count: 4096).base64EncodedString()))
    }

    func testSectionAndRootResetProjectWithoutTheMark() throws {
        var reset = section("")
        reset.isRootReset = true
        let projected = ETRemoteProjection.project([section("A"), try effect("VolumePlugin"), reset])
        XCTAssertEqual(projected.remoteIndex, [0, 1, 2])
        XCTAssertEqual(projected.pipeline[0]["cm"] as? String, "A")
        XCTAssertEqual(projected.pipeline[2]["cm"] as? String, "")
        XCTAssertNil(projected.pipeline[2][ETSection.rootResetKey])
    }

    // MARK: - params

    func testParamsHoldOnlyParameterKeys() throws {
        var volume = try effect("VolumePlugin")
        let spec = volume.spec
        let param = try XCTUnwrap(spec.params.first { $0.key == "vl" })
        volume.values[param.offset] = -3
        let params = try XCTUnwrap(ETRemoteProjection.params(for: volume))
        XCTAssertEqual((params["vl"] as? NSNumber)?.doubleValue, -3)
        XCTAssertNil(params["nm"])
        XCTAssertNil(params["en"])
    }

    /// float に載らない鍵（IR の素材）も params に入る。落とすと控えの鎖だけが進み、PC へ届かない。
    func testParamsCarryKeysOutsideTheFloats() throws {
        var ir = try effect("IRReverbPlugin")
        ir.irId = "user:hall"
        ir.inputBus = 1
        let params = try XCTUnwrap(ETRemoteProjection.params(for: ir))
        XCTAssertEqual(params["ir"] as? String, "user:hall")
        XCTAssertNil(params["ib"])
        XCTAssertNil(params["nm"])
    }

    func testParamsAreNilForStagesWithoutParameters() throws {
        XCTAssertNil(ETRemoteProjection.params(for: section("A")))
        XCTAssertNil(ETRemoteProjection.params(for: external(inputBus: 0, outputBus: 0)))
    }

    // MARK: - 接続先

    func testAddressHostPortToken() {
        let a = ETRemoteAddress.parse("192.168.1.10:47300/ab12cd34")
        XCTAssertEqual(a, ETRemoteAddress(host: "192.168.1.10", port: 47300, token: "ab12cd34"))
        XCTAssertEqual(a?.url?.absoluteString, "ws://192.168.1.10:47300/?t=ab12cd34")
    }

    func testAddressDefaultsThePortAndTrims() {
        XCTAssertEqual(ETRemoteAddress.parse("  pc.local/tok \n"),
                       ETRemoteAddress(host: "pc.local", port: 47300, token: "tok"))
    }

    func testAddressFullWebSocketURL() {
        XCTAssertEqual(ETRemoteAddress.parse("ws://10.0.0.5:47301/?t=abc"),
                       ETRemoteAddress(host: "10.0.0.5", port: 47301, token: "abc"))
        XCTAssertEqual(ETRemoteAddress.parse("ws://10.0.0.5/abc"),
                       ETRemoteAddress(host: "10.0.0.5", port: 47300, token: "abc"))
    }

    func testAddressRejectsWhatItCannotRead() {
        XCTAssertNil(ETRemoteAddress.parse(""))
        XCTAssertNil(ETRemoteAddress.parse("192.168.1.10:47300"))          // トークンが無い
        XCTAssertNil(ETRemoteAddress.parse("192.168.1.10:99999/tok"))      // ポートが範囲の外
        XCTAssertNil(ETRemoteAddress.parse("192.168.1.10:abc/tok"))
        XCTAssertNil(ETRemoteAddress.parse("http://192.168.1.10:47300/?t=x"))
        XCTAssertNil(ETRemoteAddress.parse("wss://192.168.1.10:47300/?t=x"))  // ws しか作らない
    }
}
