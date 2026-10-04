//  OutputCorrectionTests.swift
//  出力補正の、値だけで決まる判断（OutputCorrectionCore.swift・ETPipelineAnalysis.merged）。
//
//  壊れると: main の終わりの OFF Section が補正まで止める、補正の Section が main を引き込む、
//  slot の数え違いで別の段を消す、別の出力先の写しが混ざる、OFF にしても残る、
//  共有した鎖で補正が最後の組に呑まれる。

import XCTest

final class OutputCorrectionTests: XCTestCase {

    // MARK: - 道具

    private func effect(_ type: String = "VolumePlugin") throws -> PipelineStore.Loaded {
        let spec = try XCTUnwrap(ETCatalog.first { $0.type == type }, "カタログに無い: \(type)")
        return PipelineStore.Loaded(spec: spec, values: spec.defaults, enabled: true,
                                    inputBus: 0, outputBus: 0, channelSpec: -1)
    }

    private func section(_ name: String, on: Bool = true) -> PipelineStore.Loaded {
        PipelineStore.Loaded(spec: ETSection.spec, values: [], enabled: on,
                             inputBus: 0, outputBus: 0, channelSpec: -1, sectionName: name)
    }

    private func rootReset() -> PipelineStore.Loaded {
        var item = section("")
        item.isRootReset = true
        return item
    }

    private func role(_ l: PipelineStore.Loaded) -> ETItemRole { ETOutputCorrectionForm.role(l) }

    /// 並びと id と分析。
    private func analyze(_ items: [PipelineStore.Loaded], ids: [UUID]? = nil)
        -> (ids: [UUID], a: ETPipelineAnalysis) {
        let ids = ids ?? items.map { _ in UUID() }
        let a = ETPipelineAnalysis.analyze(roles: items.map(role), ids: ids, enabled: items.map(\.enabled))
        return (ids, a)
    }

    // MARK: - slot

    func testLocateMainAndCorrection() {
        func at(_ s: Int) -> (ETChainPart, Int)? {
            ETChainSlots.locate(s, mainCount: 3, correctionCount: 2).map { ($0.part, $0.local) }
        }
        XCTAssertTrue(at(0)! == (.main, 0))
        XCTAssertTrue(at(2)! == (.main, 2))
        XCTAssertTrue(at(3)! == (.correction, 0))
        XCTAssertTrue(at(4)! == (.correction, 1))
        XCTAssertNil(at(5))
        XCTAssertNil(at(-1))
    }

    func testLocateEmptyMain() {
        let r = ETChainSlots.locate(0, mainCount: 0, correctionCount: 1)
        XCTAssertEqual(r?.part, .correction)
        XCTAssertEqual(r?.local, 0)
    }

    func testSplitOffsets() {
        let r = ETChainSlots.split(IndexSet([1, 3, 4]), mainCount: 3)
        XCTAssertEqual(r.main, IndexSet([1]))
        XCTAssertEqual(r.correction, IndexSet([0, 1]))
    }

    func testSlotForLocal() {
        XCTAssertEqual(ETChainSlots.slot(1, in: .correction, mainCount: 3), 4)
        XCTAssertEqual(ETChainSlots.slot(2, in: .main, mainCount: 3), 2)
    }

    // MARK: - 合わせた分析

    func testOffSectionAtEndOfMainDoesNotGateCorrection() throws {
        let main = [section("S", on: false), try effect()]
        let corr = [try effect()]
        let m = analyze(main)
        let c = analyze(corr)
        let merged = ETPipelineAnalysis.merged([m.a, c.a])
        XCTAssertEqual(merged.gate(of: m.ids[1]), 0)
        XCTAssertEqual(merged.gate(of: c.ids[0]), 1)
        XCTAssertNil(merged.owner(of: c.ids[0]))
    }

    func testCorrectionSectionGatesOnlyItsMembers() throws {
        let main = [try effect()]
        let corr = [section("S", on: false), try effect(), rootReset(), try effect()]
        let m = analyze(main)
        let c = analyze(corr)
        let merged = ETPipelineAnalysis.merged([m.a, c.a])
        XCTAssertEqual(merged.gate(of: m.ids[0]), 1)
        XCTAssertEqual(merged.gate(of: c.ids[1]), 0)
        XCTAssertEqual(merged.gate(of: c.ids[3]), 1)
        XCTAssertEqual(merged.members(of: c.ids[0]), [c.ids[1]])
    }

    func testSinglePartEqualsAnalyze() throws {
        let items = [try effect(), section("A"), try effect(), rootReset(), try effect(),
                     section("B", on: false), try effect()]
        let one = analyze(items)
        let merged = ETPipelineAnalysis.merged([one.a])
        for (i, item) in items.enumerated() where role(item) == .effect {
            XCTAssertEqual(merged.gate(of: one.ids[i]), one.a.gate(of: one.ids[i]))
            XCTAssertEqual(merged.owner(of: one.ids[i]), one.a.owner(of: one.ids[i]))
        }
        for (i, item) in items.enumerated() where role(item) == .section {
            XCTAssertEqual(merged.members(of: one.ids[i]), one.a.members(of: one.ids[i]))
        }
    }

    func testMainMembersUnaffectedByCorrection() throws {
        let main = [section("S"), try effect(), try effect()]
        let corr = [try effect()]
        let m = analyze(main)
        let c = analyze(corr)
        let merged = ETPipelineAnalysis.merged([m.a, c.a])
        XCTAssertEqual(merged.members(of: m.ids[0]), [m.ids[1], m.ids[2]])
        XCTAssertNil(merged.owner(of: c.ids[0]))
    }

    // MARK: - 平らげ

    func testEmptyCorrectionReturnsMain() throws {
        let main = [section("S"), try effect()]
        let flat = ETOutputCorrectionForm.flatten(main: main, correction: [])
        XCTAssertEqual(flat.map(role), main.map(role))
        XCTAssertEqual(flat.count, 2)
    }

    func testMainAtRootNoMarker() throws {
        let flat = ETOutputCorrectionForm.flatten(main: [try effect()], correction: [try effect()])
        XCTAssertEqual(flat.map(role), [.effect, .effect])
    }

    func testMainEndingInSectionGetsMarker() throws {
        let flat = ETOutputCorrectionForm.flatten(main: [section("S"), try effect()],
                                                  correction: [try effect()])
        XCTAssertEqual(flat.map(role), [.section, .effect, .rootReset, .effect])
    }

    func testCorrectionStartingWithSectionNoMarker() throws {
        let flat = ETOutputCorrectionForm.flatten(main: [section("S"), try effect()],
                                                  correction: [section("T"), try effect()])
        XCTAssertEqual(flat.map(role), [.section, .effect, .section, .effect])
    }

    func testEmptyMainNoMarker() throws {
        let flat = ETOutputCorrectionForm.flatten(main: [], correction: [try effect()])
        XCTAssertEqual(flat.map(role), [.effect])
    }

    /// エンジンの模型（部分ごとに分析して gate を付ける）と、共有に出す 1 本の形の分析が、
    /// 段ごとの gate で一致する。
    func testFlattenGatesEqualMergedGates() throws {
        let shapes: [(main: [PipelineStore.Loaded], corr: [PipelineStore.Loaded])] = [
            ([section("S", on: false), try effect()], [try effect()]),
            ([section("S", on: true), try effect()], [try effect(), try effect()]),
            ([try effect(), section("S", on: false), try effect(), try effect()],
             [section("T", on: false), try effect(), rootReset(), try effect()]),
            ([section("S", on: false), try effect()],
             [section("T", on: true), try effect(), section("U", on: false), try effect()]),
            ([], [section("T", on: false), try effect()]),
            ([try effect()], [try effect(), section("T", on: false), try effect()]),
        ]
        for (n, shape) in shapes.enumerated() {
            let m = analyze(shape.main)
            let c = analyze(shape.corr)
            let merged = ETPipelineAnalysis.merged([m.a, c.a])
            var expected: [UInt8] = []
            for (i, item) in shape.main.enumerated() where role(item) == .effect {
                expected.append(merged.gate(of: m.ids[i]))
            }
            for (i, item) in shape.corr.enumerated() where role(item) == .effect {
                expected.append(merged.gate(of: c.ids[i]))
            }

            let flat = ETOutputCorrectionForm.flatten(main: shape.main, correction: shape.corr)
            let f = analyze(flat)
            var actual: [UInt8] = []
            for (i, item) in flat.enumerated() where role(item) == .effect {
                actual.append(f.a.gate(of: f.ids[i]))
            }
            XCTAssertEqual(actual, expected, "shape \(n)")
        }
    }

    func testFlattenRoundTripKeepsMarker() throws {
        let flat = ETOutputCorrectionForm.flatten(main: [section("S"), try effect()],
                                                  correction: [try effect()])
        XCTAssertEqual(flat.map(role), [.section, .effect, .rootReset, .effect])

        let back = PipelineStore.parse(PipelineStore.shortForm(flat), catalog: ETCatalog)
        XCTAssertEqual(back.map(role), [.section, .effect, .rootReset, .effect])
        XCTAssertTrue(back[2].isRootReset)

        // EffeTune へ出す形には印が無く、名前の空の Section になる。
        let upstream = ETShareLink.effeTuneForm(flat)
        XCTAssertEqual(upstream.count, 4)
        XCTAssertNil(upstream[2][ETSection.rootResetKey])
        XCTAssertEqual(upstream[2]["nm"] as? String, ETSection.name)
        XCTAssertEqual(upstream[2][ETSection.commentKey] as? String, "")
        // 本物の Section は名前を持ったまま。
        XCTAssertEqual(upstream[0][ETSection.commentKey] as? String, "S")
    }

    // MARK: - 入れ物

    private let dev = ETOutputCorrectionDevice(key: "bluetooth:AA", name: "AirPods", kind: "bluetooth")
    private let speaker = ETOutputCorrectionDevice(key: "speaker", name: "iPhone Speaker", kind: "speaker")

    private func form(_ vl: Double = 0) -> [[String: Any]] {
        [["nm": "Volume", "en": true, "vl": vl],
         ["nm": "Section", "cm": "Room", "en": false, "rr": true,
          "sub": [1, 2.5, ["x": true]] as [Any], "st": "AQID"]]
    }

    private func jsonData(_ x: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: x, options: [.sortedKeys])
    }

    func testDefaultsOffAndNoDevice() {
        let core = ETOutputCorrectionStoreCore(storage: ETMemoryStorage())
        XCTAssertFalse(core.isOn)
        XCTAssertNil(core.currentDevice)
        XCTAssertNil(core.entry(for: "x"))
        XCTAssertNil(core.form(for: "x"))
    }

    func testSetOnRoundTripAndSkipsSameValue() {
        let s = ETMemoryStorage()
        let core = ETOutputCorrectionStoreCore(storage: s)
        core.setOn(false)
        XCTAssertEqual(s.writes, 0)
        core.setOn(true)
        XCTAssertTrue(core.isOn)
        XCTAssertEqual(s.writes, 1)
        core.setOn(true)
        XCTAssertEqual(s.writes, 1)
        XCTAssertTrue(ETOutputCorrectionStoreCore(storage: s).isOn)
        core.setOn(false)
        XCTAssertFalse(core.isOn)
    }

    func testCurrentDeviceRoundTripAndSkipsSame() {
        let s = ETMemoryStorage()
        let core = ETOutputCorrectionStoreCore(storage: s)
        core.setCurrentDevice(dev)
        XCTAssertEqual(core.currentDevice, dev)
        XCTAssertEqual(s.writes, 1)
        core.setCurrentDevice(dev)
        XCTAssertEqual(s.writes, 1)
        core.setCurrentDevice(speaker)
        XCTAssertEqual(ETOutputCorrectionStoreCore(storage: s).currentDevice, speaker)
        XCTAssertEqual(s.writes, 2)
        XCTAssertTrue(s.rejected.isEmpty)
    }

    func testSaveIsPlistSafe() {
        let s = ETMemoryStorage()
        let core = ETOutputCorrectionStoreCore(storage: s)
        XCTAssertTrue(core.save(dev, source: "Flat", form: form()))
        XCTAssertTrue(s.rejected.isEmpty)
        core.setCurrentDevice(dev)
        core.setOn(true)
        XCTAssertTrue(s.rejected.isEmpty)
    }

    func testSaveRoundTripForm() throws {
        let core = ETOutputCorrectionStoreCore(storage: ETMemoryStorage())
        let f = form(-3.5)
        XCTAssertTrue(core.save(dev, source: "Flat", form: f))
        let back = try XCTUnwrap(core.form(for: dev.key))
        XCTAssertEqual(try jsonData(back), try jsonData(f))
        let e = try XCTUnwrap(core.entry(for: dev.key))
        XCTAssertEqual(e.name, "AirPods")
        XCTAssertEqual(e.kind, "bluetooth")
        XCTAssertEqual(e.source, "Flat")
    }

    func testSaveSkipsIdenticalBytes() {
        let s = ETMemoryStorage()
        let core = ETOutputCorrectionStoreCore(storage: s)
        core.save(dev, source: "Flat", form: form())
        let w = s.writes
        XCTAssertTrue(core.save(dev, source: "Flat", form: form()))
        XCTAssertEqual(s.writes, w)
        // 名前や source が変われば書く。
        core.save(ETOutputCorrectionDevice(key: dev.key, name: "AirPods Pro", kind: dev.kind),
                  source: "Flat", form: form())
        XCTAssertEqual(s.writes, w + 1)
        core.save(ETOutputCorrectionDevice(key: dev.key, name: "AirPods Pro", kind: dev.kind),
                  source: nil, form: form())
        XCTAssertEqual(s.writes, w + 2)
    }

    func testSaveEmptyRemovesEntry() {
        let s = ETMemoryStorage()
        let core = ETOutputCorrectionStoreCore(storage: s)
        core.save(dev, source: "Flat", form: form())
        XCTAssertNotNil(core.entry(for: dev.key))
        XCTAssertTrue(core.save(dev, source: "Flat", form: []))
        XCTAssertNil(core.entry(for: dev.key))
        XCTAssertNil(core.form(for: dev.key))
        // 無いものを空で保存しても書かない。
        let w = s.writes
        XCTAssertTrue(core.save(dev, source: nil, form: []))
        XCTAssertEqual(s.writes, w)
    }

    func testSourceOmittedWhenNil() throws {
        let s = ETMemoryStorage()
        let core = ETOutputCorrectionStoreCore(storage: s)
        core.save(dev, source: nil, form: form())
        XCTAssertNil(core.entry(for: dev.key)?.source)
        let all = try XCTUnwrap(s.dictionary(forKey: ETOutputCorrectionStoreCore.devicesKey))
        let raw = try XCTUnwrap(all[dev.key] as? [String: Any])
        XCTAssertNil(raw["source"])
        XCTAssertNotNil(raw["chain"] as? Data)
    }

    func testDevicesAreIndependent() throws {
        let core = ETOutputCorrectionStoreCore(storage: ETMemoryStorage())
        core.save(dev, source: "A", form: form(1))
        core.save(speaker, source: nil, form: form(2))
        XCTAssertEqual(try jsonData(try XCTUnwrap(core.form(for: dev.key))), try jsonData(form(1)))
        XCTAssertEqual(try jsonData(try XCTUnwrap(core.form(for: speaker.key))), try jsonData(form(2)))
        XCTAssertEqual(core.entry(for: dev.key)?.source, "A")
        XCTAssertNil(core.entry(for: speaker.key)?.source)
        core.save(speaker, source: nil, form: [])
        XCTAssertNotNil(core.entry(for: dev.key))
    }

    func testRemove() {
        let s = ETMemoryStorage()
        let core = ETOutputCorrectionStoreCore(storage: s)
        core.save(dev, source: nil, form: form())
        core.save(speaker, source: nil, form: form())
        core.remove(key: dev.key)
        XCTAssertNil(core.entry(for: dev.key))
        XCTAssertNotNil(core.entry(for: speaker.key))
        let w = s.writes
        core.remove(key: "nothing")
        XCTAssertEqual(s.writes, w)
    }

    func testMalformedEntryIgnored() throws {
        let good = try jsonData(form())
        let s = ETMemoryStorage([
            ETOutputCorrectionStoreCore.devicesKey: [
                "notDict": "oops",
                "noChain": ["name": "X", "kind": "wired"],
                "badChain": ["name": "X", "kind": "wired", "chain": "text"],
                "good": ["name": "G", "kind": "wired", "chain": good],
            ] as [String: Any],
        ])
        let core = ETOutputCorrectionStoreCore(storage: s)
        XCTAssertNil(core.entry(for: "notDict"))
        XCTAssertNil(core.entry(for: "noChain"))
        XCTAssertNil(core.entry(for: "badChain"))
        XCTAssertEqual(core.entry(for: "good")?.name, "G")
        XCTAssertNotNil(core.form(for: "good"))
        // 壊れたものが居ても、別の出力先は保存できて、読めたものは残る。
        XCTAssertTrue(core.save(dev, source: nil, form: form()))
        XCTAssertNotNil(core.entry(for: "good"))
    }

    func testUnencodableFormWritesNothing() {
        let s = ETMemoryStorage()
        let core = ETOutputCorrectionStoreCore(storage: s)
        let bad: [[String: Any]] = [["nm": "Volume", "vl": Double.nan]]
        XCTAssertFalse(core.save(dev, source: nil, form: bad))
        XCTAssertEqual(s.writes, 0)
        // すでに在る写しを壊さない。
        core.save(dev, source: nil, form: form())
        let w = s.writes
        XCTAssertFalse(core.save(dev, source: nil, form: bad))
        XCTAssertEqual(s.writes, w)
        XCTAssertNotNil(core.entry(for: dev.key))
    }

    // MARK: - 段取り

    private func state(on: Bool = true, remote: Bool = false, ready: Bool = true,
                       device: String? = "A", loaded: String? = nil) -> ETOutputCorrectionState {
        ETOutputCorrectionState(isOn: on, isRemote: remote, ready: ready, device: device, loaded: loaded)
    }

    func testOffLoadsNothing() {
        XCTAssertEqual(ETOutputCorrectionPolicy.steps(state(on: false)), [])
    }

    func testOnLoadsDevice() {
        XCTAssertEqual(ETOutputCorrectionPolicy.steps(state()), [.load("A")])
    }

    func testSwitchFlushesOutgoingFirst() {
        XCTAssertEqual(ETOutputCorrectionPolicy.steps(state(device: "B", loaded: "A")),
                       [.flush("A"), .load("B")])
    }

    func testTurningOffFlushesAndUnloads() {
        XCTAssertEqual(ETOutputCorrectionPolicy.steps(state(on: false, loaded: "A")),
                       [.flush("A"), .unload])
    }

    func testEnteringRemoteFlushesAndUnloads() {
        XCTAssertEqual(ETOutputCorrectionPolicy.steps(state(remote: true, loaded: "A")),
                       [.flush("A"), .unload])
    }

    func testLeavingRemoteReloads() {
        XCTAssertEqual(ETOutputCorrectionPolicy.steps(state(remote: false, loaded: nil)),
                       [.load("A")])
    }

    func testNotReadyDoesNothing() {
        XCTAssertEqual(ETOutputCorrectionPolicy.steps(state(ready: false, device: "B", loaded: "A")), [])
        XCTAssertEqual(ETOutputCorrectionPolicy.steps(state(on: false, ready: false, loaded: "A")), [])
        XCTAssertEqual(ETOutputCorrectionPolicy.steps(state(ready: false)), [])
    }

    func testSameDeviceNoSteps() {
        XCTAssertEqual(ETOutputCorrectionPolicy.steps(state(loaded: "A")), [])
    }

    func testOnWithoutDeviceNoSteps() {
        XCTAssertEqual(ETOutputCorrectionPolicy.steps(state(device: nil)), [])
        // 入っているのに出力先が無くなった（ありえないが）なら外す。
        XCTAssertEqual(ETOutputCorrectionPolicy.steps(state(device: nil, loaded: "A")),
                       [.flush("A"), .unload])
    }
}
