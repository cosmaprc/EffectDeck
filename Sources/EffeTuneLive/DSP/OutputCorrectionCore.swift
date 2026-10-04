//  OutputCorrectionCore.swift
//  出力補正（Output Correction）の、値だけで決まる判断。**Foundationだけ**（OutputCorrectionTests）。
//
//  出力補正は、使う人の鎖（main）の後ろに付く固定の層。出力先（ヘッドホンなど）ごとに
//  自分の補正の写しを持ち、出力先が替わると写しだけが入れ替わる。main には触らない。
//
//  ここに置くのは4つ。
//    - slot の数え方：エンジンへ渡す並び（main + 補正）の中の位置と、部分ごとの位置の行き来
//    - 端末ごとの写しの入れ物：UserDefaults にだけ持つ（iCloud・バックアップへは出さない）
//    - 読み込み・外し・書き出しの段取り：いまの状態から「何をどの順でやるか」だけを返す
//    - 共有のための平らげ：main + 終端 + 補正を、受け手が普通の鎖として開ける1本にする

import Foundation

// MARK: - slot

/// 鎖の部分。補正は main と別の並びで持つ。
enum ETChainPart: Equatable {
    case main
    case correction
}

/// `nodes = main + 補正` の中の位置（slot）と、部分ごとの位置の計算。
/// main の slot は main の添字と同じなので、既存の呼び手はそのまま通る。
enum ETChainSlots {

    /// slot がどの部分の何番目か。範囲の外なら nil。
    static func locate(_ slot: Int, mainCount: Int, correctionCount: Int)
        -> (part: ETChainPart, local: Int)? {
        guard slot >= 0 else { return nil }
        if slot < mainCount { return (.main, slot) }
        let local = slot - mainCount
        return local < correctionCount ? (.correction, local) : nil
    }

    /// 部分の中の位置から slot へ。
    static func slot(_ local: Int, in part: ETChainPart, mainCount: Int) -> Int {
        part == .main ? local : mainCount + local
    }

    /// slot の集まりを部分ごとの位置の集まりに分ける。
    static func split(_ slots: IndexSet, mainCount: Int) -> (main: IndexSet, correction: IndexSet) {
        var main = IndexSet()
        var correction = IndexSet()
        for s in slots where s >= 0 {
            if s < mainCount { main.insert(s) } else { correction.insert(s - mainCount) }
        }
        return (main, correction)
    }
}

// MARK: - 端末ごとの写し

/// 補正を持つ出力先。`key` は ETOutputDevice.key、`name` は最後に見た名前、
/// `kind` は ETOutputDevice.Kind の字。
struct ETOutputCorrectionDevice: Equatable {
    let key: String
    let name: String
    let kind: String
}

/// 1台ぶんの写し。`chain` は短い形の JSON（鍵を並べたもの）。
/// `source` は写し元のプリセット名で、画面に出すだけ。
struct ETOutputCorrectionEntry: Equatable {
    let name: String
    let kind: String
    let source: String?
    let chain: Data
}

/// 出力補正の入れ物。**UserDefaults だけ**（iCloud・バックアップへは出さない。patch も持たない）。
///
/// 持つのは3つ。
///   - 入切（既定は切）
///   - 最後に落ち着いた出力先
///   - 出力先ごとの写し `{ "<鍵>": { name, kind, source?, chain } }`
/// 値は字と Data だけなので plist に載る。
final class ETOutputCorrectionStoreCore {

    static let onKey = "outputCorrection.on"
    static let deviceKey = "outputCorrection.device"
    static let devicesKey = "outputCorrection.devices"

    private let storage: ETKeyValueStorage

    init(storage: ETKeyValueStorage) {
        self.storage = storage
    }

    // MARK: 入切

    var isOn: Bool { storage.object(forKey: Self.onKey) as? Bool ?? false }

    /// 同じなら書かない。
    func setOn(_ on: Bool) {
        guard on != isOn else { return }
        storage.set(on, forKey: Self.onKey)
    }

    // MARK: 最後の出力先

    var currentDevice: ETOutputCorrectionDevice? {
        guard let d = storage.dictionary(forKey: Self.deviceKey),
              let key = d["key"] as? String, !key.isEmpty else { return nil }
        return ETOutputCorrectionDevice(key: key,
                                        name: d["name"] as? String ?? "",
                                        kind: d["kind"] as? String ?? "")
    }

    /// 同じなら書かない。
    func setCurrentDevice(_ d: ETOutputCorrectionDevice) {
        guard d != currentDevice else { return }
        storage.set(["key": d.key, "name": d.name, "kind": d.kind], forKey: Self.deviceKey)
    }

    // MARK: 写し

    /// その出力先の写し。形の崩れたもの（辞書でない・chain が Data でない）は nil。
    func entry(for key: String) -> ETOutputCorrectionEntry? {
        guard let raw = devices()[key] as? [String: Any],
              let chain = raw["chain"] as? Data else { return nil }
        return ETOutputCorrectionEntry(name: raw["name"] as? String ?? "",
                                       kind: raw["kind"] as? String ?? "",
                                       source: raw["source"] as? String,
                                       chain: chain)
    }

    /// chain を JSON に戻したもの（PipelineStore.parse へ渡す）。読めなければ nil。
    func form(for key: String) -> Any? {
        guard let e = entry(for: key) else { return nil }
        return try? JSONSerialization.jsonObject(with: e.chain)
    }

    /// 写しを書く。**空なら消す**（source ごと）。
    ///
    /// JSON にできない形（NaN など）は false で何も書かない。data(withJSONObject:) は
    /// 不正な値だとトラップするので、先に isValidJSONObject で見る。
    /// 中身が同じなら書かない。
    @discardableResult
    func save(_ d: ETOutputCorrectionDevice, source: String?, form: [[String: Any]]) -> Bool {
        var all = devices()
        if form.isEmpty {
            guard all.removeValue(forKey: d.key) != nil else { return true }
            write(all)
            return true
        }
        guard JSONSerialization.isValidJSONObject(form),
              let data = try? JSONSerialization.data(withJSONObject: form, options: [.sortedKeys])
        else { return false }

        let next = ETOutputCorrectionEntry(name: d.name, kind: d.kind, source: source, chain: data)
        guard entry(for: d.key) != next else { return true }

        var raw: [String: Any] = ["name": d.name, "kind": d.kind, "chain": data]
        if let source { raw["source"] = source }
        all[d.key] = raw
        write(all)
        return true
    }

    func remove(key: String) {
        var all = devices()
        guard all.removeValue(forKey: key) != nil else { return }
        write(all)
    }

    // MARK: 中

    private func devices() -> [String: Any] {
        storage.dictionary(forKey: Self.devicesKey) ?? [:]
    }

    private func write(_ all: [String: Any]) {
        storage.set(all, forKey: Self.devicesKey)
    }
}

// MARK: - 段取り

/// 段取りを決めるための、いまの状態。
struct ETOutputCorrectionState: Equatable {
    var isOn: Bool
    var isRemote: Bool
    /// エンジンが立っているか。
    var ready: Bool
    /// 落ち着いた出力先の鍵。
    var device: String?
    /// dsp.correction に入っている写しの鍵。
    var loaded: String?
}

enum ETOutputCorrectionStep: Equatable {
    /// 外へ出す前に、入っている補正をその鍵で書く。
    case flush(String)
    /// 補正を外す。
    case unload
    /// その鍵の写しを入れる（いま入っているものは置き換わる）。
    case load(String)
}

enum ETOutputCorrectionPolicy {

    /// いまの状態から、やることを順に返す。**切り替え・切・リモートの出入り・準備完了の
    /// どれが起きても、この1つで決める。**
    ///
    /// - エンジンが立っていないときは何もしない（段に触らない）。
    /// - 欲しい鍵は「入っていて、リモートでなく、出力先が在る」ときだけその出力先。
    /// - 外す前、入れ替える前には、出ていく鍵で flush する（debounce 待ちの編集を拾うため）。
    static func steps(_ s: ETOutputCorrectionState) -> [ETOutputCorrectionStep] {
        guard s.ready else { return [] }
        let desired = (s.isOn && !s.isRemote) ? s.device : nil
        guard desired != s.loaded else { return [] }

        var out: [ETOutputCorrectionStep] = []
        if let loaded = s.loaded { out.append(.flush(loaded)) }
        if let desired {
            out.append(.load(desired))
        } else {
            out.append(.unload)
        }
        return out
    }
}

// MARK: - 共有

enum ETOutputCorrectionForm {

    /// main + 補正を、受け手が普通の鎖として開ける1本にする。
    /// 補正が空なら main をそのまま返す。
    ///
    /// 補正は main の後ろに独立して付くので、main が組の中で終わっていると、そのまま
    /// つなげれば補正が main の最後の組に呑まれる。それを防ぐ終端（rootReset）を挟む。
    /// 要らないとき（main が root で終わる・補正が Section で始まる・main が空）は
    /// 正規形（ETRootResetRule.keep）が落とすので、挟まない。
    /// 受け手には出力先の属性は付かない。
    static func flatten(main: [PipelineStore.Loaded],
                        correction: [PipelineStore.Loaded]) -> [PipelineStore.Loaded] {
        guard !correction.isEmpty else { return main }
        var out = main + [rootResetMarker] + correction
        if !ETRootResetRule.keep(roles: out.map(role))[main.count] { out.remove(at: main.count) }
        return out
    }

    /// 段の役目。終端・Section・普通の段。
    static func role(_ l: PipelineStore.Loaded) -> ETItemRole {
        if l.isRootReset { return .rootReset }
        return ETSection.isSection(l.spec) ? .section : .effect
    }

    /// leaveSection が挿すものと同じ（specは Section、入っている、名前は空）。
    private static var rootResetMarker: PipelineStore.Loaded {
        PipelineStore.Loaded(spec: ETSection.spec, values: [], enabled: true,
                             inputBus: 0, outputBus: 0, channelSpec: -1, isRootReset: true)
    }
}
