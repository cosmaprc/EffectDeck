//  PresetStoreTests.swift
//  名前を付けた鎖（PresetStoreCore）とエフェクトごとのプリセット（EffectPresetStoreCore）の出し入れ。
//
//  **フォルダの付け替えが途中で止まっていた**（5.2）。確かめる名前（`X/B/C`）と
//  書く名前（正規化した `X/B C`）が違ったので、ぶつかる相手を見落として 1 本目だけ動かし、
//  2 本目で黙って止まり、それでも true を返していた。名前も `B/C` から `B C` へ黙って変わる。
//
//  入れ物は ETMemoryStorage。iCloud への当て方は本物の決まり（CloudMirrorCore）を
//  メモリの入れ物へ向けてつなぎ、写った結果を見る。CloudMirror.swift の頭にある
//  「50 本が 1 本になった」形を書く側で塞いでいるかを、結果で確かめるため。

import XCTest

final class PresetStoreTests: XCTestCase {

    // MARK: - 道具

    private var device: ETMemoryStorage!
    private var cloud: ETMemoryStorage!
    /// patch に渡された中身（呼ばれた順）。
    private var patched: [(key: String, paths: [[String]])] = []

    override func setUp() {
        super.setUp()
        device = ETMemoryStorage()
        cloud = ETMemoryStorage()
        patched = []
    }

    override func tearDown() {
        // 本物の UserDefaults / KVS なら落ちる書き込みが無かったか。
        XCTAssertEqual(device.rejected, [], "手元に plist へ載らない値を書いた")
        XCTAssertEqual(cloud.rejected, [], "iCloud に plist へ載らない値を書いた")
        super.tearDown()
    }

    private func patch() -> CloudPatch {
        let mirror = CloudMirrorCore(cloud: cloud, seeded: false)
        return { [unowned self] key, changes in
            self.patched.append((key, changes.map(\.path)))
            mirror.patch(key: key, changes: changes)
        }
    }

    private func presets(_ initial: [String: Any] = [:]) -> PresetStoreCore {
        if !initial.isEmpty { device.set(initial, forKey: PresetStoreCore.key) }
        return PresetStoreCore(storage: device, patch: patch())
    }

    private func effectPresets(_ initial: [String: Any] = [:]) -> EffectPresetStoreCore {
        if !initial.isEmpty { device.set(initial, forKey: EffectPresetStoreCore.key) }
        return EffectPresetStoreCore(storage: device, patch: patch())
    }

    /// ショート形式の 1 本。中身は見ないので、見分けが付けば何でもよい。
    private func form(_ tag: Double) -> [[String: Any]] {
        [["nm": "Volume", "en": true, "vl": tag]]
    }

    private func tag(_ value: Any?) -> Double? {
        ((value as? [[String: Any]])?.first?["vl"]) as? Double
    }

    private func devicePresets() -> [String: Any] {
        device.dictionary(forKey: PresetStoreCore.key) ?? [:]
    }

    private func cloudPresets() -> [String: Any] {
        cloud.dictionary(forKey: PresetStoreCore.key) ?? [:]
    }

    // MARK: - フォルダの付け替え（5.2）

    /// 1 本でもぶつかるなら、何も動かさずに false。
    /// 前は `A/one` だけ `X/one` へ動いて、`A/B/C` は残り、true が返っていた。
    func testRenameFolderAllOrNothingOnConflict() {
        let store = presets(["A/one": form(1), "A/B/C": form(2), "X/B C": form(3)])
        let writesBefore = device.writes

        XCTAssertFalse(store.renameFolder("A", to: "X"))

        XCTAssertEqual(store.names, ["A/B/C", "A/one", "X/B C"])
        XCTAssertEqual(tag(devicePresets()["X/B C"]), 3, "ぶつかった相手が上書きされた")
        XCTAssertEqual(device.writes, writesBefore, "断ったのに手元へ書いた")
        XCTAssertTrue(patched.isEmpty, "断ったのに iCloud へ当てた")
    }

    /// 確かめる名前と書く名前は同じ（正規化した `X/B C`）。
    func testRenameFolderNestedNameUsesNormalizedKey() {
        let store = presets(["A/B/C": form(1)])

        XCTAssertTrue(store.renameFolder("A", to: "X"))

        XCTAssertEqual(store.names, ["X/B C"])
        XCTAssertEqual(tag(devicePresets()["X/B C"]), 1)
        XCTAssertEqual(Set(cloudPresets().keys), ["X/B C"])
    }

    /// フォルダの中どうしが同じ名前に潰れるときも、何も動かさない。
    /// `A/B C` と `A/B/C` はどちらも `X/B C` になる。前は片方だけ動いて片方が残っていた。
    func testRenameFolderCollisionInsideFolderRejected() {
        let store = presets(["A/B C": form(1), "A/B/C": form(2)])

        XCTAssertFalse(store.renameFolder("A", to: "X"))

        XCTAssertEqual(store.names, ["A/B C", "A/B/C"])
        XCTAssertTrue(patched.isEmpty)
    }

    /// 全部動かす。手元も iCloud も 1 回で書く。
    /// 2 回に分けると、iCloud の上限に当たったときに消すほうだけが残る。
    func testRenameFolderMovesEverythingInOneWrite() {
        cloud.set(["Other": form(9)], forKey: PresetStoreCore.key)  // 別の端末の分
        let store = presets(["A/one": form(1), "A/two": form(2), "Solo": form(3)])
        let deviceBefore = device.writes
        let cloudBefore = cloud.writes

        XCTAssertTrue(store.renameFolder("A", to: "X"))

        XCTAssertEqual(store.names, ["Solo", "X/one", "X/two"])
        XCTAssertEqual(tag(devicePresets()["X/one"]), 1)
        XCTAssertEqual(tag(devicePresets()["X/two"]), 2)
        XCTAssertEqual(device.writes - deviceBefore, 1)
        XCTAssertEqual(cloud.writes - cloudBefore, 1)
        // 触ったのは動かした名前だけ。別の端末の分も、動かしていない Solo も写さない。
        XCTAssertEqual(Set(cloudPresets().keys), ["Other", "X/one", "X/two"])
    }

    /// 空のフォルダとして覚えていたものは、付け替えた先の名前で覚え直す。
    func testRenameEmptyFolder() {
        let store = presets()
        store.addFolder("Live")

        XCTAssertTrue(store.renameFolder("Live", to: "Gigs"))

        XCTAssertEqual(store.emptyFolders, ["Gigs"])
    }

    func testRenameFolderRejectsEmptyOrSameName() {
        let store = presets(["A/one": form(1)])

        XCTAssertFalse(store.renameFolder("A", to: "  "))
        XCTAssertFalse(store.renameFolder("A", to: "/"))
        XCTAssertFalse(store.renameFolder("A", to: "A"))
        XCTAssertEqual(store.names, ["A/one"])
    }

    // MARK: - 1 本ずつ

    func testRenameConflictRejected() {
        let store = presets(["a": form(1), "b": form(2)])

        XCTAssertFalse(store.rename("a", to: "b"))
        XCTAssertFalse(store.rename("a", to: "  b "), "正規化すると同じ名前")
        XCTAssertFalse(store.rename("a", to: ""))
        XCTAssertFalse(store.rename("a", to: "a"))
        XCTAssertFalse(store.rename("missing", to: "c"))

        XCTAssertEqual(store.names, ["a", "b"])
        XCTAssertEqual(tag(devicePresets()["b"]), 2)
        XCTAssertTrue(patched.isEmpty)
    }

    func testRenameMovesAndMirrorsBothEntries() {
        cloud.set(["a": form(1)], forKey: PresetStoreCore.key)
        let store = presets(["a": form(1)])

        XCTAssertTrue(store.rename("a", to: "Folder/a"))

        XCTAssertEqual(store.names, ["Folder/a"])
        XCTAssertEqual(Set(cloudPresets().keys), ["Folder/a"])
    }

    /// 保存する名前も `フォルダ/名前` の形に整える。付け替えと同じ規則にしないと、
    /// 保存した名前をフォルダの付け替えで確かめ損ねる（5.2 の入り口）。
    func testSaveNormalizesName() {
        let store = presets()

        XCTAssertEqual(store.save("A/B/C", form: form(1)), "A/B C")
        XCTAssertEqual(store.save("  plain  ", form: form(2)), "plain")
        XCTAssertEqual(store.save("/lead", form: form(3)), "lead")
        XCTAssertNil(store.save("   ", form: form(4)))
        XCTAssertNil(store.save("empty", form: []))

        XCTAssertEqual(store.names, ["A/B C", "lead", "plain"])
        XCTAssertEqual(Set(cloudPresets().keys), ["A/B C", "lead", "plain"])
    }

    /// 前の版やバックアップが入れた整っていない名前（`A/B/C`）を一覧から選んで上書きすると、
    /// その 1 本が置き換わる。整えた `A/B C` という別の 1 本を作らない。
    func testSaveOverwritesExistingLegacyName() {
        let store = presets(["A/B/C": form(1)])

        XCTAssertEqual(store.save("A/B/C", form: form(2)), "A/B/C")

        XCTAssertEqual(store.names, ["A/B/C"])
        XCTAssertEqual(tag(store.form(named: "A/B/C")), 2)
    }

    /// 押す前に「もう在る」を言うには、save が書く名前で確かめる。打ったままの名前で
    /// 確かめると、`Live/ Set 1` は整えて `Live/Set 1` になり、言われないまま上書きする。
    func testSavedNameIsTheKeySaveWrites() {
        let store = presets(["Live/Set 1": form(1), "A/B/C": form(2), "X/Y Z": form(3)])

        XCTAssertEqual(store.savedName(for: "Live/ Set 1"), "Live/Set 1")
        XCTAssertTrue(store.names.contains(store.savedName(for: "Live/ Set 1") ?? ""),
                      "整えた名前が在るので、押す前に言える")
        XCTAssertEqual(store.savedName(for: "A/B/C"), "A/B/C", "在る名前そのものはそのまま")
        XCTAssertEqual(store.savedName(for: "X/Y/Z"), "X/Y Z")
        XCTAssertNil(store.savedName(for: "   "))
        XCTAssertNil(store.savedName(for: "/"))

        for typed in ["Live/ Set 1", "A/B/C", "X/Y/Z", "  new  ", "/lead", "F/", "   "] {
            let predicted = store.savedName(for: typed)
            XCTAssertEqual(store.save(typed, form: form(9)), predicted, typed)
        }
        XCTAssertEqual(store.names, ["A/B/C", "F", "Live/Set 1", "X/Y Z", "lead", "new"])
        XCTAssertEqual(tag(store.form(named: "Live/Set 1")), 9)
    }

    func testSaveReplacesSameName() {
        let store = presets(["a": form(1)])

        store.save("a", form: form(2))

        XCTAssertEqual(store.names, ["a"])
        XCTAssertEqual(tag(store.form(named: "a")), 2)
    }

    // MARK: - フォルダ

    func testSlashRemovedFromFolderNames() {
        let store = presets()

        store.addFolder("Rock/Heavy")
        store.addFolder("  /  ")
        store.addFolder("Rock Heavy")  // 同じ名前は 2 度入れない

        XCTAssertEqual(store.emptyFolders, ["Rock Heavy"])
        XCTAssertTrue(store.renameFolder("Rock Heavy", to: "Hard/Rock"))
        XCTAssertEqual(store.emptyFolders, ["Hard Rock"])
    }

    /// 中身が入ったフォルダは空の一覧に出ない。中身が無くなればまた出る。
    /// 空のフォルダは iCloud へ写さない。
    func testEmptyFolderHiddenOnceItHasPresets() {
        let store = presets()
        store.addFolder("Live")
        XCTAssertEqual(store.emptyFolders, ["Live"])

        store.save("Live/Set 1", form: form(1))
        XCTAssertEqual(store.emptyFolders, [])
        XCTAssertEqual(store.names, ["Live/Set 1"])

        store.remove("Live/Set 1")
        XCTAssertEqual(store.emptyFolders, ["Live"])

        store.removeFolder("Live")
        XCTAssertEqual(store.emptyFolders, [])
        XCTAssertNil(cloud.object(forKey: PresetStoreCore.emptyFoldersKey))
    }

    // MARK: - 読み込み（ETBackup）

    /// 入れた名前だけを iCloud へ当てる。手元の他の名前も、別の端末の分も触らない。
    func testMergePatchesOnlyTouchedEntries() {
        cloud.set(["other": form(9)], forKey: PresetStoreCore.key)
        let store = presets(["mine": form(1)])

        let count = store.merge(["new": form(2), "  ": form(3), "empty": [], " mine ": form(4)])

        XCTAssertEqual(count, 2)
        XCTAssertEqual(store.names, ["mine", "new"])
        XCTAssertEqual(tag(devicePresets()["mine"]), 4, "同じ名前は入れ替わる")
        XCTAssertEqual(Set(patched.flatMap(\.paths)), [["new"], ["mine"]])
        XCTAssertEqual(Set(cloudPresets().keys), ["other", "new", "mine"])
    }

    func testMergeNothingWritesNothing() {
        let store = presets(["mine": form(1)])
        let before = device.writes

        XCTAssertEqual(store.merge(["": form(1), "x": []]), 0)

        XCTAssertEqual(device.writes, before)
        XCTAssertTrue(patched.isEmpty)
    }

    // MARK: - エフェクトごとのプリセット

    /// 上流が弾く名前（plugin-preset-store.js:3）は、エフェクトの側でもプリセットの側でも入れない。
    func testReservedNamesRejectedBothLevels() {
        let store = effectPresets()

        let count = store.merge([
            "__proto__": ["a": ["vl": 1.0]],
            " constructor ": ["a": ["vl": 1.0]],
            "Volume": ["prototype": ["vl": 1.0],
                       " __proto__ ": ["vl": 1.0],
                       "constructor": ["vl": 1.0],
                       "ok": ["vl": 2.0]],
        ])

        XCTAssertEqual(count, 1)
        XCTAssertEqual(store.saved, ["Volume": ["ok"]])
        XCTAssertFalse(store.save("__proto__", effect: "Volume", params: ["vl": 1.0]))
        XCTAssertEqual(store.saved, ["Volume": ["ok"]])
    }

    /// Section は上流も preset の UI を出さないので入れない。
    func testSectionSkipped() {
        let store = effectPresets()
        let before = device.writes

        XCTAssertEqual(store.merge([ETSection.name: ["a": ["cm": "x"]]]), 0)
        XCTAssertFalse(store.save("a", effect: ETSection.name, params: ["cm": "x"]))

        XCTAssertEqual(store.saved, [:])
        XCTAssertEqual(device.writes, before)
        XCTAssertTrue(patched.isEmpty)
    }

    /// そのエフェクトのものが無くなったら鍵ごと消す（plugin-preset-store.js:159）。iCloud も同じ。
    func testRemovingLastPresetDeletesEffectKey() {
        let store = effectPresets()
        store.save("a", effect: "Volume", params: ["vl": 1.0])
        store.save("b", effect: "Volume", params: ["vl": 2.0])
        store.save("c", effect: "Delay", params: ["dt": 3.0])

        store.remove("a", of: "Volume")
        XCTAssertEqual(store.saved["Volume"], ["b"])

        store.remove("b", of: "Volume")

        XCTAssertEqual(store.saved, ["Delay": ["c"]])
        XCTAssertNil(store.exported()["Volume"])
        let mirrored = cloud.dictionary(forKey: EffectPresetStoreCore.key) ?? [:]
        XCTAssertEqual(Set(mirrored.keys), ["Delay"], "iCloud に空の枝が残った")
    }

    func testEffectPresetSaveTrimsAndReplaces() {
        let store = effectPresets()

        XCTAssertTrue(store.save("  warm  ", effect: "Volume", params: ["vl": 1.0]))
        XCTAssertTrue(store.save("warm", effect: "Volume", params: ["vl": 2.0]))
        XCTAssertFalse(store.save("   ", effect: "Volume", params: ["vl": 3.0]))

        XCTAssertEqual(store.saved, ["Volume": ["warm"]])
        XCTAssertEqual(store.params(of: "Volume", name: "warm")?["vl"] as? Double, 2.0)
        XCTAssertEqual(patched.map(\.paths), [[["Volume", "warm"]], [["Volume", "warm"]]])
    }

    /// IR Reverb の素材は float に載らないので `ir` の鍵で運ぶ（鎖と同じ綴り）。
    func testParamsCarryIrId() throws {
        let spec = try XCTUnwrap(ETCatalog.first { $0.type == "VolumePlugin" })
        var node = ETChainNode(spec: spec, values: spec.defaults)

        XCTAssertNil(EffectPresetStoreCore.params(for: node)[ETChainText.irKey])

        node.irId = "0123456789abcdef01234567"
        let params = EffectPresetStoreCore.params(for: node)
        XCTAssertEqual(params[ETChainText.irKey] as? String, "0123456789abcdef01234567")
        XCTAssertEqual(Set(params.keys).subtracting([ETChainText.irKey]),
                       Set(ETParamCoding.encode(params: spec.params, values: spec.defaults).keys))
    }
}
