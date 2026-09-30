//  RemoteProtocolTests.swift
//  PC の EffeTune を LAN から操る PoC の、通信に触らない部分（DSP/RemoteProtocol.swift）。
//
//  見ているもの:
//    - 外部の段（AU / JSFX）は、同じバスの中なら落ち、バスを渡るなら 0 dB の Volume になる
//    - 落ちた段のぶん、手元の番号 → PC の番号の対応表がずれる（params の宛先）
//    - 外部の段の externalState は PC へ渡す形に入らない（符号化する前に振り分ける）
//    - params には動かせるパラメータのショートキーだけが入る
//    - 接続先の字の読み方（host:port/token・ws:// の URL・読めない字）
//    - v2: QR のリンク（ws://host:port/?t=token）、state の origin / seq の振り分け、
//      プリセットの足し合わせ（名前の付け足し・2 回目は何もしない・PC の字と手元の保存が同じ中身）、
//      IR の塊の切り方と継ぎ方、PC の変更を値だけで当てられるか
//    - telemetry: PC の枠のヘッダの読み方・壊れた項目を落とす・tapId の付け替え・番号の対応表の裏返し

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

    // MARK: - v2: QR のリンク

    func testPairingLinkReadsHostPortAndToken() throws {
        let url = try XCTUnwrap(URL(string: "ws://192.168.1.10:47300/?t=ab12cd34"))
        let a = ETRemoteAddress.pairingLink(url)
        XCTAssertEqual(a, ETRemoteAddress(host: "192.168.1.10", port: 47300, token: "ab12cd34"))
        // 控える字は parse がそのまま読み戻せる。
        XCTAssertEqual(a.flatMap { ETRemoteAddress.parse($0.text) }, a)
    }

    func testPairingLinkDefaultsThePort() throws {
        let url = try XCTUnwrap(URL(string: "WS://10.0.0.5?t=tok"))
        XCTAssertEqual(ETRemoteAddress.pairingLink(url),
                       ETRemoteAddress(host: "10.0.0.5", port: 47300, token: "tok"))
    }

    func testPairingLinkRejectsOtherLinks() throws {
        for text in ["https://effectdeck.nemut.ai/remote?h=1.2.3.4:47300&t=x",   // 共有リンクの側
                     "effectdeck://remote?h=1.2.3.4:47300&t=x",                  // 前の形（使わない）
                     "ws://1.2.3.4:47300/chain?t=x",                             // 行き先が違う
                     "ws://1.2.3.4:47300/",                                      // トークンが無い
                     "wss://1.2.3.4:47300/?t=x",                                 // 暗号つき（作らない）
                     "ws://1.2.3.4:99999/?t=x"] {                                // ポートが範囲の外
            let url = try XCTUnwrap(URL(string: text))
            XCTAssertNil(ETRemoteAddress.pairingLink(url), text)
        }
    }

    // MARK: - v2: state の出どころ

    func testStateOriginFiltering() {
        let ours: Set<Int> = [3, 4]
        XCTAssertTrue(ETRemoteStateFilter.follows(origin: "local", seq: nil, ours: ours))
        XCTAssertTrue(ETRemoteStateFilter.follows(origin: "local", seq: 3, ours: ours))
        // 自分のコマンドの結果は捨てる。ほかの端末のコマンドの結果は追う。
        XCTAssertFalse(ETRemoteStateFilter.follows(origin: "remote", seq: 4, ours: ours))
        XCTAssertTrue(ETRemoteStateFilter.follows(origin: "remote", seq: 9, ours: ours))
        XCTAssertTrue(ETRemoteStateFilter.follows(origin: "remote", seq: nil, ours: ours))
        // v1 の PC（origin が無い）は読み捨てる。
        XCTAssertFalse(ETRemoteStateFilter.follows(origin: nil, seq: nil, ours: ours))
    }

    // MARK: - v2: プリセットの足し合わせ

    func testPresetUnionCopiesMissingBothWays() {
        let plan = ETRemotePresetSync.plan(pc: ["A": "a", "Same": "s"],
                                           local: ["B": "b", "Same": "s"])
        XCTAssertEqual(plan.toLocal, [.init(source: "A", target: "A")])
        XCTAssertEqual(plan.toPC, [.init(source: "B", target: "B")])
    }

    func testPresetNameClashGetsATagOnTheOtherSide() {
        let plan = ETRemotePresetSync.plan(pc: ["N": "pc"], local: ["N": "pad"])
        XCTAssertEqual(plan.toLocal, [.init(source: "N", target: "N (PC)")])
        XCTAssertEqual(plan.toPC, [.init(source: "N", target: "N (iPad)")])
    }

    func testPresetTaggedNameThatIsTakenCountsUp() {
        let plan = ETRemotePresetSync.plan(pc: ["N": "pc"], local: ["N": "pad", "N (PC)": "other"])
        XCTAssertEqual(plan.toLocal, [.init(source: "N", target: "N (PC 2)")])
    }

    func testPresetBlockedLocalIsNotSent() {
        let plan = ETRemotePresetSync.plan(pc: [:], local: ["AU": "x", "Plain": "y"], localBlocked: ["AU"])
        XCTAssertEqual(plan.toPC, [.init(source: "Plain", target: "Plain")])
    }

    /// 1 回目の結果を両側へ当てて、2 回目は何もしない。
    func testPresetUnionIsIdempotent() {
        var pc = ["N": "pc", "OnlyPC": "p"]
        var local = ["N": "pad", "OnlyPad": "q", "AU": "x"]
        let first = ETRemotePresetSync.plan(pc: pc, local: local, localBlocked: ["AU"])
        for copy in first.toLocal { local[copy.target] = pc[copy.source] }
        for copy in first.toPC { pc[copy.target] = local[copy.source] }
        let second = ETRemotePresetSync.plan(pc: pc, local: local, localBlocked: ["AU"])
        XCTAssertEqual(second, ETRemotePresetSync.Plan())
        XCTAssertEqual(Set(local.keys), ["N", "N (PC)", "OnlyPC", "OnlyPad", "AU"])
        XCTAssertEqual(Set(pc.keys), ["N", "N (iPad)", "OnlyPC", "OnlyPad"])
    }

    func testPresetTagSplit() {
        XCTAssertEqual(ETRemotePresetSync.split("Rock (PC)")?.base, "Rock")
        XCTAssertEqual(ETRemotePresetSync.split("Rock (iPad 3)")?.tag, "iPad")
        XCTAssertNil(ETRemotePresetSync.split("Rock (live)"))
        XCTAssertNil(ETRemotePresetSync.split("Rock (PC 1)"))
        XCTAssertNil(ETRemotePresetSync.split("Rock"))
    }

    /// PC の字（0.1）と、手元に保存して読み戻したもの（Float を経た 0.10000000149…）が同じ中身になる。
    func testPresetCanonicalSurvivesALocalRoundTrip() throws {
        let volume = try effect("VolumePlugin")
        let fromPC = "[{\"nm\":\"\(volume.spec.name)\",\"en\":true,\"vl\":-3.1}]"
        let loaded = ETShareLink.parse(fromPC, catalog: ETCatalog)
        XCTAssertEqual(loaded.count, 1)
        let pcCanon = ETRemotePresetSync.canonical(ETRemoteProjection.project(loaded).pipeline)
        // 手元の保存（PresetStore.save → shortForm）と読み戻し（PresetStore.load → parse）。
        let stored = PipelineStore.shortForm(loaded)
        let data = try JSONSerialization.data(withJSONObject: stored)
        let reloaded = PipelineStore.parse(try JSONSerialization.jsonObject(with: data), catalog: ETCatalog)
        let localCanon = ETRemotePresetSync.canonical(ETRemoteProjection.project(reloaded).pipeline)
        XCTAssertEqual(pcCanon, localCanon)
        XCTAssertFalse(pcCanon.isEmpty)
    }

    // MARK: - v2: IR

    func testIRPlanAndChunks() {
        let plan = ETRemoteIRSync.plan(pc: ["b", "a", "c"], local: ["c", "d"])
        XCTAssertEqual(plan.download, ["a", "b"])
        XCTAssertEqual(plan.upload, ["d"])
        XCTAssertEqual(ETRemoteIRSync.chunks(0), [0..<0])
        XCTAssertEqual(ETRemoteIRSync.chunks(10, size: 4), [0..<4, 4..<8, 8..<10])
        XCTAssertEqual(ETRemoteIRSync.chunks(8, size: 4), [0..<4, 4..<8])
    }

    func testIRFileName() {
        XCTAssertEqual(ETRemoteIRSync.fileName(name: "Hall", ext: "wav"), "Hall.wav")
        XCTAssertEqual(ETRemoteIRSync.fileName(name: "Hall.WAV", ext: "wav"), "Hall.wav")
        XCTAssertEqual(ETRemoteIRSync.fileName(name: "a/b:c", ext: "flac"), "a-b-c.flac")
        XCTAssertEqual(ETRemoteIRSync.fileName(name: "", ext: "wav"), "IR.wav")
    }

    func testIRAssemblyNeedsEveryChunkInOrder() {
        var ok = ETRemoteIRSync.Assembly()
        ok.add(index: 0, total: 2, data: Data([1]))
        XCTAssertFalse(ok.isComplete)
        ok.add(index: 1, total: 2, data: Data([2]))
        XCTAssertTrue(ok.isComplete)
        XCTAssertEqual(ok.data, Data([1, 2]))

        var skipped = ETRemoteIRSync.Assembly()
        skipped.add(index: 1, total: 2, data: Data([2]))
        skipped.add(index: 0, total: 2, data: Data([1]))
        XCTAssertFalse(skipped.isComplete)
    }

    // MARK: - v2: PC の変更を追う

    func testSameShapeOnlyWhenValuesAloneDiffer() throws {
        let a = [try effect("VolumePlugin"), section("S")]
        var b = a
        b[0].values = b[0].values.map { $0 - 1 }
        XCTAssertTrue(ETRemoteFollow.sameShape(a, b))
        var c = a
        c[0].enabled = false
        XCTAssertFalse(ETRemoteFollow.sameShape(a, c))
        XCTAssertFalse(ETRemoteFollow.sameShape(a, [a[0]]))
        XCTAssertFalse(ETRemoteFollow.sameShape([external(inputBus: 0, outputBus: 0)],
                                                [external(inputBus: 0, outputBus: 0)]))
    }

    // MARK: - telemetry: PC のアナライザの枠

    /// dsp/core/telemetry.cpp:109-117 と同じ 16 バイトのヘッダ（リトルエンディアン）＋ペイロード。
    private func wire(type: UInt16, version: UInt16, tap: UInt32, sequence: UInt32,
                      flags: UInt16, payload: [UInt8], payloadBytes: UInt16? = nil) -> String {
        var b: [UInt8] = []
        func put16(_ v: UInt16) { b += [UInt8(v & 0xff), UInt8(v >> 8)] }
        func put32(_ v: UInt32) { for s in stride(from: 0, to: 32, by: 8) { b.append(UInt8((v >> UInt32(s)) & 0xff)) } }
        put16(type); put16(version); put32(tap); put32(sequence)
        put16(payloadBytes ?? UInt16(payload.count)); put16(flags)
        b += payload
        return Data(b).base64EncodedString()
    }

    func testTelemetryParseReadsHeaderAndPayload() {
        let message: [String: Any] = ["op": "telemetry", "frames": [
            ["index": 3, "nm": "Spectrum Analyzer", "type": 4,
             "data": wire(type: 4, version: 2, tap: 0x01020304, sequence: 0xA0B0C0D0,
                          flags: 1, payload: [9, 8, 7, 6, 5])],
        ]]
        let entries = ETRemoteTelemetry.parse(message)
        XCTAssertEqual(entries.count, 1)
        guard let e = entries.first else { return }
        XCTAssertEqual(e.index, 3)
        XCTAssertEqual(e.nm, "Spectrum Analyzer")
        XCTAssertEqual(e.frame.type, 4)
        XCTAssertEqual(e.frame.version, 2)
        XCTAssertEqual(e.frame.tapId, 0x01020304)
        XCTAssertEqual(e.frame.sequence, 0xA0B0C0D0)
        XCTAssertTrue(e.frame.dropped)
        XCTAssertEqual(e.frame.payload, [9, 8, 7, 6, 5])

        let local = ETRemoteTelemetry.frame(e, tap: 42)
        XCTAssertEqual(local.tapId, 42)
        XCTAssertEqual(local.type, 4)
        XCTAssertEqual(local.version, 2)
        XCTAssertEqual(local.sequence, 0xA0B0C0D0)
        XCTAssertTrue(local.dropped)
        XCTAssertEqual(local.payload, [9, 8, 7, 6, 5])
    }

    func testTelemetryParseDropsBrokenEntries() {
        let good = wire(type: 1, version: 1, tap: 1, sequence: 1, flags: 0, payload: [1, 2, 3, 4])
        let message: [String: Any] = ["op": "telemetry", "frames": [
            ["nm": "Level Meter", "type": 1, "data": good],                       // index が無い
            ["index": 0, "type": 1, "data": good],                                // nm が無い
            ["index": 0, "nm": "Level Meter", "type": 1, "data": "%%%"],          // base64 でない
            ["index": 0, "nm": "Level Meter", "type": 1,
             "data": Data([1, 0, 1, 0]).base64EncodedString()],                   // 16 バイトに満たない
            ["index": 0, "nm": "Level Meter", "type": 1,
             "data": wire(type: 1, version: 1, tap: 1, sequence: 1, flags: 0,
                          payload: [1, 2, 3, 4], payloadBytes: 8)],               // 長さがヘッダと合わない
            ["index": 0, "nm": "Level Meter", "type": 1,
             "data": wire(type: 1, version: 1, tap: 1, sequence: 1, flags: 0,
                          payload: [1, 2, 3, 4, 0, 0, 0, 0], payloadBytes: 4)],   // 余りがある
            ["index": 5, "nm": "Level Meter", "type": 1, "data": good],
        ]]
        let entries = ETRemoteTelemetry.parse(message)
        XCTAssertEqual(entries.map(\.index), [5])
        XCTAssertFalse(entries[0].frame.dropped)
        XCTAssertTrue(ETRemoteTelemetry.parse(["op": "telemetry"]).isEmpty)
    }

    func testTelemetryParseAcceptsEmptyPayload() {
        let message: [String: Any] = ["frames": [
            ["index": 0, "nm": "Level Meter", "type": 1,
             "data": wire(type: 1, version: 1, tap: 1, sequence: 7, flags: 0, payload: [])],
        ]]
        XCTAssertEqual(ETRemoteTelemetry.parse(message).first?.frame.payload, [])
    }

    func testTelemetryInverseSkipsDroppedStages() {
        // 手元 0 → PC 0、手元 1 は外部の段で落ちた、手元 2 → PC 1。
        XCTAssertEqual(ETRemoteTelemetry.inverse([0, nil, 1]), [0: 0, 1: 2])
        XCTAssertEqual(ETRemoteTelemetry.inverse([]), [:])
    }
}
