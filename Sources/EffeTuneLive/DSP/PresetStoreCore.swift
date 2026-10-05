//  PresetStoreCore.swift
//  名前を付けた鎖の入れ物の中身。**Foundationだけ。**
//
//  PresetStore.swift から出した。あちらは画面が観測する ObservableObject（Combine は
//  Linux に無い）で、鎖の Node からショート形式を作るのと、貼られた字の読み込みを持つ。
//  こちらは入れ物（ETKeyValueStorage）と iCloud への当て方（CloudPatch）を受け取って、
//  名前の出し入れだけをする（PresetStoreTests）。
//
//  入れ物の形は `presets = { "<名前>": [ ショート形式の段 … ] }`。
//  **フォルダは名前の付け方だけで表す**（`Rock/Heavy`、ETUserPresetName）。

import Foundation

final class PresetStoreCore {

    /// **private ではない。** CloudMirror が iCloud 側を同じ鍵で読む
    /// （PipelineStore.lastKey と同じ理由）。
    static let key = "presets"

    /// 中身の無いフォルダを覚えておく鍵。
    ///
    /// **フォルダは名前の付け方だけで表す**（`Rock/Heavy`）ので、
    /// 中身が 1 つも無いフォルダは名前のどこにも現れない。作った直後に
    /// 消えて見えるのは分かりにくいので、空のぶんだけここに持つ。
    /// **iCloud へは写さない。**中身が入れば名前の側に現れるし、
    /// 空の入れ物を端末間で合わせる意味が薄い。
    static let emptyFoldersKey = "presetEmptyFolders"

    private let storage: ETKeyValueStorage
    private let patch: CloudPatch

    /// `storage` は手元の入れ物（アプリでは UserDefaults.standard）。
    /// `patch` は iCloud へ触った項目だけを当てる口（アプリでは CloudMirror.patch）。
    init(storage: ETKeyValueStorage, patch: @escaping CloudPatch) {
        self.storage = storage
        self.patch = patch
    }

    // MARK: - 読む

    /// 保存してある名前（並べ替え済み）。
    var names: [String] { dict().keys.sorted() }

    /// 中身の無いフォルダ（並べ替え済み）。**中身が入ったものは、もう空ではない。**
    var emptyFolders: [String] {
        let used = Set(names.map(ETUserPresetName.folder))
        return storedEmptyFolders().filter { !used.contains($0) }.sorted()
    }

    /// 保存してあるショート形式。無ければ nil。
    func form(named name: String) -> Any? { dict()[name] }

    // MARK: - フォルダ

    /// 空のフォルダを作る。**入れ子は作らない。**`/` は名前から落とす。
    func addFolder(_ name: String) {
        let clean = ETUserPresetName.clean(name)
        guard !clean.isEmpty else { return }
        var list = storedEmptyFolders()
        guard !list.contains(clean) else { return }
        list.append(clean)
        storage.set(list, forKey: Self.emptyFoldersKey)
    }

    /// その名前のフォルダが在るか（プリセットが入っているものと、空のもの）。
    func folderExists(_ name: String) -> Bool {
        names.contains { ETUserPresetName.folder($0) == name } || storedEmptyFolders().contains(name)
    }

    func removeFolder(_ name: String) {
        let list = storedEmptyFolders().filter { $0 != name }
        storage.set(list, forKey: Self.emptyFoldersKey)
    }

    /// フォルダの名前を替える。**中のプリセットを全部付け替える。**
    /// 入れ物という実体が無いので、まとめて名前を書き替えるのがそのまま移動になる。
    ///
    /// **全部移すか、何も動かさないか。**前は 1 本ずつ rename していて、確かめる名前
    /// （`X/B/C`）と rename が書く名前（正規化した `X/B C`）が違った。`A/B/C` のような
    /// 名前（バックアップや web から入る。前の save も打ったまま入れていた）が混ざると
    /// ぶつかる相手を見落とし、何本か動かしたところで黙って止まり、それでも true を返していた。
    ///
    /// 今は先に移す先の名前を全部決め（rename と同じ ETUserPresetName.normalized）、
    /// 動かさない名前・移す先どうしのどちらかとぶつかれば何も書かずに false。
    /// ぶつからなければ手元へ 1 回、iCloud へ 1 回で書く。
    @discardableResult
    func renameFolder(_ old: String, to new: String) -> Bool {
        let target = ETUserPresetName.clean(new)
        guard !target.isEmpty, target != old else { return false }
        // **既に在るフォルダの名前へは付け替えない。**付け替えると2つのフォルダが黙って
        // 1つにまとまる（名前がぶつかるときだけ断っていた）。「その名前は使われている」で断る。
        guard !folderExists(target) else { return false }

        var d = dict()
        let moving = d.keys.filter { ETUserPresetName.folder($0) == old }.sorted()
        var moved: [(from: String, to: String, form: Any)] = []
        for full in moving {
            guard let form = d.removeValue(forKey: full) else { continue }
            let to = ETUserPresetName.normalized(target + "/" + ETUserPresetName.leaf(full))
            guard !to.isEmpty else { return false }
            moved.append((full, to, form))
        }
        // 動かさない名前（d に残っている）と、移す先どうしの両方を見る。
        // `A/B C` と `A/B/C` はどちらも `X/B C` になる。
        var taken = Set(d.keys)
        for m in moved {
            guard taken.insert(m.to).inserted else { return false }
        }

        if !moved.isEmpty {
            for m in moved { d[m.to] = m.form }
            write(d)
            patch(Self.key, moved.map { CloudChange(path: [$0.from], value: nil) }
                          + moved.map { CloudChange(path: [$0.to], value: $0.form) })
        }
        if emptyFolders.contains(old) {
            removeFolder(old)
            addFolder(target)
        }
        return true
    }

    // MARK: - 1 本ずつ

    /// 名前を付け替える。**フォルダの出し入れもこれ。**
    /// 中身は動かさず鍵だけ差し替えるので、鎖は一切触らない。
    @discardableResult
    func rename(_ old: String, to new: String) -> Bool {
        let target = ETUserPresetName.normalized(new)
        guard !target.isEmpty, target != old else { return false }
        var d = dict()
        guard let form = d[old], d[target] == nil else { return false }
        d.removeValue(forKey: old)
        d[target] = form
        write(d)
        patch(Self.key, [CloudChange(path: [old], value: nil),
                         CloudChange(path: [target], value: form)])
        return true
    }

    /// 名前を付けて残す。同じ名前は置き換わる。
    /// 返すのは入れた名前（入れなかったら nil）。
    ///
    /// **名前は `フォルダ/名前` の形に整えてから入れる**（rename と同じ
    /// ETUserPresetName.normalized）。前は打ったまま入れていたので `A/B/C` が入り、
    /// フォルダの付け替えが確かめ損ねる名前の元になっていた。
    ///
    /// **既に在る名前そのものなら、その名前へ上書きする。**一覧から選んだプリセットの
    /// 上書き（PresetsView の Overwrite）は保存してある名前をそのまま渡す。前の版や
    /// バックアップが入れた `A/B/C` を整えてから書くと、上書きのつもりが `A/B C` という
    /// 別の 1 本になり、元の 1 本も残る。
    @discardableResult
    func save(_ name: String, form: [[String: Any]]) -> String? {
        var d = dict()
        guard let key = savedName(for: name, in: d), !form.isEmpty else { return nil }
        d[key] = form
        write(d)
        patch(Self.key, [CloudChange(path: [key], value: form)])
        return key
    }

    /// save が書く名前。空になる名前は nil。
    ///
    /// **押す前に「もう在る」を言うのはこれで確かめる。**save は名前を整えるので、
    /// 打ったままの名前で確かめると `Live/ Set 1` は在ると言われないまま
    /// `Live/Set 1` を上書きする。
    func savedName(for name: String) -> String? {
        savedName(for: name, in: dict())
    }

    private func savedName(for name: String, in d: [String: Any]) -> String? {
        let key = d[name] != nil ? name : ETUserPresetName.normalized(name)
        return key.isEmpty ? nil : key
    }

    func remove(_ name: String) {
        var d = dict()
        d.removeValue(forKey: name)
        write(d)
        patch(Self.key, [CloudChange(path: [name], value: nil)])
    }

    // MARK: - ファイルとのやり取り（ETBackup）

    /// 書き出し用。入れ物の中身をそのまま返す。
    /// 上流の包み方（`{ plugins: [...] }`）は ETBackup が被せる。
    func exported() -> [String: Any] { dict() }

    /// 読み込み。**名前ごとに入れ替える。**ファイルに無い名前はそのまま残す。
    /// 返すのは入れた本数。
    @discardableResult
    func merge(_ incoming: [String: [[String: Any]]]) -> Int {
        var d = dict()
        var touched: [String: Any] = [:]
        for (name, entries) in incoming {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !entries.isEmpty else { continue }
            d[trimmed] = entries
            touched[trimmed] = entries
        }
        guard !touched.isEmpty else { return 0 }
        write(d)
        // 入れた名前だけ写す。まるごと写すと別の端末に在るものが消える。
        // **1 本ずつ当てる。**まとめると、大きさの上限に当たったときに 1 本も写らない。
        for (name, entries) in touched {
            patch(Self.key, [CloudChange(path: [name], value: entries)])
        }
        return touched.count
    }

    // MARK: - 入れ物

    private func dict() -> [String: Any] {
        storage.dictionary(forKey: Self.key) ?? [:]
    }

    private func storedEmptyFolders() -> [String] {
        storage.object(forKey: Self.emptyFoldersKey) as? [String] ?? []
    }

    /// 手元へ書く。**iCloud へは写さない。**
    ///
    /// 写すのは触った名前だけ（patch）。辞書をまるごと写すと、
    /// 手元の分が iCloud の分を置き換えて、別の端末に在るものが消える。
    private func write(_ d: [String: Any]) {
        storage.set(d, forKey: Self.key)
    }
}
