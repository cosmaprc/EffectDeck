//  PresetDeviceBindingTests.swift
//  出力先（ヘッドホンなど）ごとのプリセットの紐付け（PresetStoreCore）。
//
//  **端末だけに持つ。**iCloudへは写さない（patch へ presets 以外を渡さない）、バックアップへも出さない。
//  プリセットの名前が動いたら紐付けも付いていく。消えたら紐付けも消える。
//
//  入れ物は ETMemoryStorage。patch は呼ばれた中身を残すだけの見張り。

import XCTest

final class PresetDeviceBindingTests: XCTestCase {

    // MARK: - 道具

    private var device: ETMemoryStorage!
    /// patch に渡された鍵と、触った名前（呼ばれた順）。
    private var patched: [(key: String, paths: [[String]])] = []

    override func setUp() {
        super.setUp()
        device = ETMemoryStorage()
        patched = []
    }

    override func tearDown() {
        // 本物の UserDefaults なら落ちる書き込みが無かったか。
        XCTAssertEqual(device.rejected, [], "手元に plist へ載らない値を書いた")
        super.tearDown()
    }

    private func presets(_ initial: [String: Any] = [:]) -> PresetStoreCore {
        if !initial.isEmpty { device.set(initial, forKey: PresetStoreCore.key) }
        return PresetStoreCore(storage: device, patch: { [unowned self] key, changes in
            self.patched.append((key, changes.map(\.path)))
        })
    }

    /// ショート形式の 1 本。中身は見ないので、見分けが付けば何でもよい。
    private func form(_ tag: Double) -> [[String: Any]] {
        [["nm": "Volume", "en": true, "vl": tag]]
    }

    private func tag(_ value: Any?) -> Double? {
        ((value as? [[String: Any]])?.first?["vl"]) as? Double
    }

    private func storedDevices() -> [String: [String: String]] {
        (device.values[PresetStoreCore.devicesKey] as? [String: [String: String]]) ?? [:]
    }

    private let airpods = "bluetooth:AA:BB"

    // MARK: - 紐付ける

    func testBindStoresPlistSafeShape() {
        let store = presets(["Rock": form(1)])

        XCTAssertTrue(store.bindDevice(airpods, name: "AirPods Pro", kind: "bluetooth", preset: "Rock"))

        XCTAssertEqual(device.values["presetDevices"] as? [String: [String: String]],
                       [airpods: ["preset": "Rock", "name": "AirPods Pro", "kind": "bluetooth"]])
        XCTAssertEqual(store.preset(forDevice: airpods), "Rock")
        XCTAssertEqual(store.deviceBindings,
                       [PresetStoreCore.DeviceBinding(key: airpods, name: "AirPods Pro", kind: "bluetooth", preset: "Rock")])
    }

    func testBindRejectsMissingPreset() {
        let store = presets(["Rock": form(1)])
        let writesBefore = device.writes

        XCTAssertFalse(store.bindDevice(airpods, name: "AirPods Pro", kind: "bluetooth", preset: "Nope"))

        XCTAssertEqual(device.writes, writesBefore, "無いプリセットなのに書いた")
        XCTAssertNil(store.preset(forDevice: airpods))
        XCTAssertTrue(store.deviceBindings.isEmpty)
    }

    func testBindNilUnbinds() {
        let store = presets(["Rock": form(1)])
        store.bindDevice(airpods, name: "AirPods Pro", kind: "bluetooth", preset: "Rock")

        XCTAssertTrue(store.bindDevice(airpods, name: "AirPods Pro", kind: "bluetooth", preset: nil))

        XCTAssertNil(store.preset(forDevice: airpods))
        XCTAssertTrue(store.deviceBindings.isEmpty)
        XCTAssertEqual(storedDevices(), [:])

        // 紐付けが無い出力先を外しても書かない。
        let writesBefore = device.writes
        XCTAssertTrue(store.bindDevice(airpods, name: "AirPods Pro", kind: "bluetooth", preset: nil))
        XCTAssertEqual(device.writes, writesBefore)
    }

    func testRebindSameValueDoesNotWrite() {
        let store = presets(["Rock": form(1)])
        store.bindDevice(airpods, name: "AirPods Pro", kind: "bluetooth", preset: "Rock")
        let writesBefore = device.writes

        XCTAssertTrue(store.bindDevice(airpods, name: "AirPods Pro", kind: "bluetooth", preset: "Rock"))

        XCTAssertEqual(device.writes, writesBefore, "同じ値なのに書いた")
    }

    // MARK: - 名前が動く

    func testRenameFollowsBinding() {
        let store = presets(["Rock": form(1), "Other": form(2)])
        store.bindDevice(airpods, name: "AirPods Pro", kind: "bluetooth", preset: "Rock")
        store.bindDevice("speaker", name: "iPad Speakers", kind: "speaker", preset: "Other")

        XCTAssertTrue(store.rename("Rock", to: "Live/Rock"))

        XCTAssertEqual(store.preset(forDevice: airpods), "Live/Rock")
        XCTAssertEqual(store.preset(forDevice: "speaker"), "Other", "関係の無い紐付けが動いた")
        XCTAssertEqual(storedDevices()[airpods]?["preset"], "Live/Rock")
    }

    func testRenameFolderFollowsBinding() {
        let store = presets(["A/Rock": form(1), "A/Jazz": form(2), "Solo": form(3)])
        store.bindDevice(airpods, name: "AirPods Pro", kind: "bluetooth", preset: "A/Rock")
        store.bindDevice("wired", name: "Headphones", kind: "wired", preset: "Solo")

        XCTAssertTrue(store.renameFolder("A", to: "B"))

        XCTAssertEqual(store.preset(forDevice: airpods), "B/Rock")
        XCTAssertEqual(store.preset(forDevice: "wired"), "Solo")
        XCTAssertEqual(tag(store.form(named: "B/Rock")), 1)
    }

    func testFailedRenameKeepsBinding() {
        let store = presets(["Rock": form(1), "Jazz": form(2)])
        store.bindDevice(airpods, name: "AirPods Pro", kind: "bluetooth", preset: "Rock")
        let writesBefore = device.writes

        XCTAssertFalse(store.rename("Rock", to: "Jazz"), "ぶつかる名前へは付け替えない")
        XCTAssertFalse(store.rename("Missing", to: "Else"))

        XCTAssertEqual(store.preset(forDevice: airpods), "Rock")
        XCTAssertEqual(device.writes, writesBefore, "断ったのに書いた")
    }

    func testFailedRenameFolderKeepsBinding() {
        let store = presets(["A/one": form(1), "X/one": form(2)])
        store.bindDevice(airpods, name: "AirPods Pro", kind: "bluetooth", preset: "A/one")
        let writesBefore = device.writes

        XCTAssertFalse(store.renameFolder("A", to: "X"), "在るフォルダへは付け替えない")

        XCTAssertEqual(store.preset(forDevice: airpods), "A/one")
        XCTAssertEqual(device.writes, writesBefore, "断ったのに書いた")
    }

    /// フォルダを消すとき、中身はルートへ rename で出る。紐付けも付いていく。
    func testDeleteFolderPathFollows() {
        let store = presets(["A/Rock": form(1)])
        store.bindDevice(airpods, name: "AirPods Pro", kind: "bluetooth", preset: "A/Rock")

        XCTAssertTrue(store.rename("A/Rock", to: "Rock"))

        XCTAssertEqual(store.preset(forDevice: airpods), "Rock")
    }

    func testRemoveUnbinds() {
        let store = presets(["Rock": form(1), "Jazz": form(2)])
        store.bindDevice(airpods, name: "AirPods Pro", kind: "bluetooth", preset: "Rock")
        store.bindDevice("wired", name: "Headphones", kind: "wired", preset: "Jazz")

        store.remove("Rock")

        // 隠れただけでなく、入れ物から消えている。
        XCTAssertNil(storedDevices()[airpods])
        XCTAssertEqual(storedDevices()["wired"]?["preset"], "Jazz")
        XCTAssertNil(store.preset(forDevice: airpods))

        // 同じ名前でもう一度入れても、昔の紐付けは戻らない。
        store.save("Rock", form: form(5))
        XCTAssertNil(store.preset(forDevice: airpods))
    }

    func testMergeKeepsBinding() {
        let store = presets(["Rock": form(1)])
        store.bindDevice(airpods, name: "AirPods Pro", kind: "bluetooth", preset: "Rock")

        XCTAssertEqual(store.merge(["Rock": form(9)]), 1)

        XCTAssertEqual(store.preset(forDevice: airpods), "Rock")
        XCTAssertEqual(tag(store.form(named: "Rock")), 9, "紐付けは新しい中身を指す")
    }

    /// 名前が入れ物から無くなっているものは、読むときに隠す。
    func testDanglingBindingIsHidden() {
        let store = presets(["Rock": form(1)])
        device.set([airpods: ["preset": "Gone", "name": "AirPods Pro", "kind": "bluetooth"],
                    "wired": ["preset": "Rock", "name": "Headphones", "kind": "wired"]],
                   forKey: PresetStoreCore.devicesKey)

        XCTAssertNil(store.preset(forDevice: airpods))
        XCTAssertEqual(store.preset(forDevice: "wired"), "Rock")
        XCTAssertEqual(store.deviceBindings.map(\.key), ["wired"])
    }

    // MARK: - iCloud・バックアップへ出さない

    func testBindingsNeverPatchCloud() {
        let store = presets(["Rock": form(1), "A/Jazz": form(2)])

        store.bindDevice(airpods, name: "AirPods Pro", kind: "bluetooth", preset: "Rock")
        store.noteDeviceName(airpods, name: "AirPods Pro 2")
        store.setCurrentDevice(airpods)
        store.rename("Rock", to: "Live/Rock")
        store.renameFolder("A", to: "B")
        store.bindDevice(airpods, name: "AirPods Pro 2", kind: "bluetooth", preset: nil)
        store.remove("Live/Rock")

        XCTAssertFalse(patched.isEmpty)
        XCTAssertTrue(patched.allSatisfy { $0.key == "presets" }, "presets 以外の鍵を iCloud へ当てた")
        XCTAssertFalse(patched.contains { $0.key == PresetStoreCore.devicesKey || $0.key == PresetStoreCore.currentDeviceKey })
    }

    func testExportedExcludesBindings() {
        let store = presets(["Rock": form(1)])
        store.bindDevice(airpods, name: "AirPods Pro", kind: "bluetooth", preset: "Rock")
        store.setCurrentDevice(airpods)

        XCTAssertEqual(Set(store.exported().keys), ["Rock"])
    }

    // MARK: - 名前・今の出力先

    func testNoteDeviceNameUpdatesOnlyBound() {
        let store = presets(["Rock": form(1)])
        store.bindDevice(airpods, name: "AirPods Pro", kind: "bluetooth", preset: "Rock")

        store.noteDeviceName(airpods, name: "My AirPods")
        XCTAssertEqual(store.deviceBindings.first?.name, "My AirPods")
        XCTAssertEqual(storedDevices()[airpods]?["preset"], "Rock", "名前を直したのに中身が変わった")

        // 紐付けの無い出力先は覚えない。
        store.noteDeviceName("usb:XYZ", name: "DAC")
        XCTAssertNil(storedDevices()["usb:XYZ"])

        // 同じ名前なら書かない。
        let writesBefore = device.writes
        store.noteDeviceName(airpods, name: "My AirPods")
        XCTAssertEqual(device.writes, writesBefore)
    }

    func testCurrentDeviceRoundTrip() {
        let store = presets()
        XCTAssertNil(store.currentDevice)

        store.setCurrentDevice("speaker")
        XCTAssertEqual(store.currentDevice, "speaker")
        XCTAssertEqual(device.values["presetDeviceCurrent"] as? String, "speaker")

        // 変わらなければ書かない。
        let writesBefore = device.writes
        store.setCurrentDevice("speaker")
        XCTAssertEqual(device.writes, writesBefore)

        store.setCurrentDevice(nil)
        XCTAssertNil(store.currentDevice)
        XCTAssertNil(device.values["presetDeviceCurrent"], "nil で消えない")
    }

    func testBindingsSortedByName() {
        let store = presets(["Rock": form(1)])
        store.bindDevice("usb:2", name: "dac", kind: "usb", preset: "Rock")
        store.bindDevice("bluetooth:1", name: "AirPods", kind: "bluetooth", preset: "Rock")
        store.bindDevice("usb:1", name: "dac", kind: "usb", preset: "Rock")
        store.bindDevice("wired", name: "Headphones", kind: "wired", preset: "Rock")

        // 名前（大文字小文字を問わない）、同じ名前なら鍵の順。
        XCTAssertEqual(store.deviceBindings.map(\.key), ["bluetooth:1", "usb:1", "usb:2", "wired"])
    }
}
