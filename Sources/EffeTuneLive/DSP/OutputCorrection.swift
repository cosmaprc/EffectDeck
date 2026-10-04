//  OutputCorrection.swift
//  出力補正（Output Correction）の持ち主。入切・落ち着いた出力先・いま入っている写し・書き出し。
//
//  出力補正は、使う人の鎖（EffeTuneDSP.chain）の後ろに付く固定の層で、出力先ごとに自分の写しを持つ。
//  出力先が替わると写しだけを入れ替える。main には触らない。
//  段そのものは EffeTuneDSP.correction に入っていて、入れ替えは EffeTuneDSP.loadCorrection が行う。
//
//  何をどの順でやるか（書き出す・外す・入れる）は ETOutputCorrectionPolicy.steps が決める
//  （OutputCorrectionCore.swift、OutputCorrectionTests）。入切・出力先の確定・リモートの出入り・
//  DSP の用意のどれが起きても、ここは状態を直して reconcile() を 1 回呼ぶだけ。
//
//  写しは端末の UserDefaults にだけ持つ（ETOutputCorrectionStoreCore）。iCloud とバックアップへは出さない。
//
//  **ここから AudioIO.shared に触らない。**最初に作られるのは AudioIO の初期化の中
//  （prepare → restore → publish → persist → persistLoaded）で、触ると static の初期化が自分を待って止まる。

import Foundation
import os

@MainActor
final class OutputCorrection: ObservableObject {

    static let shared = OutputCorrection()

    private let log = Logger(subsystem: "ai.nemut.effetune", category: "correction")

    /// 層の入切。既定は切。端末にだけ残す。
    @Published private(set) var isOn: Bool
    /// 落ち着いた出力先。画面の見出しに名前を出す。
    @Published private(set) var device: ETOutputCorrectionDevice?
    /// いま入っている写しの元のプリセット名。Choose Preset の印に使うだけ。
    @Published private(set) var source: String?

    /// PC の鎖を編集している間（RemoteMirror が知らせる）。補正は外す。
    private var remote = false

    /// dsp.correction に入っている写しの出力先。
    ///
    /// **決まり：ある出力先の写しを書くのは、その出力先の段が dsp.correction に入っている間だけ。**
    /// 入れる・外すときは、dsp.loadCorrection を呼ぶ**前**に nil にして、入れ終えた**後**に新しい出力先を入れる。
    /// 逆にすると、loadCorrection の中の publish → persist() → persistLoaded が、
    /// 入れ替えた後の段（か空）を前の出力先の鍵で書いてしまう。
    private var loaded: ETOutputCorrectionDevice?

    /// いま入っている写しの鍵。JSFX を読み終えたときに、選んだときの出力先のままかを見るのに使う。
    var loadedKey: String? { loaded?.key }

    /// いまの出力先の写しが入っていて、層をいじれるか。
    var isEditable: Bool {
        guard let loaded, let device else { return false }
        return loaded.key == device.key
    }

    private let core: ETOutputCorrectionStoreCore

    /// 写しを書く列。JSFX の @serialize は大きいので、JSON にして書くのはメインでやらない
    /// （PipelineStore.saveLast と同じ）。直列なので書く順は呼んだ順のまま。
    private let writer = DispatchQueue(label: "ai.nemut.effectdeck.store.correction", qos: .utility)

    private init() {
        // 入れ物だけを読む。AudioIO にも EffeTuneDSP にもここでは触らない。
        core = ETOutputCorrectionStoreCore(storage: UserDefaults.standard)
        isOn = core.isOn
        device = core.currentDevice
    }

    // MARK: - 起きたこと

    /// 層の入切。画面の見出しのトグルから。
    func setOn(_ on: Bool) {
        guard on != isOn else { return }
        core.setOn(on)
        isOn = on
        reconcile(cause: on ? "on" : "off")
    }

    /// 出力先が落ち着いた（AudioIO の .switched）。覚えて、入っていれば写しを入れ替える。
    func deviceSettled(_ d: ETOutputDevice) {
        guard let next = Self.entryDevice(d) else { return }
        core.setCurrentDevice(next)
        if device != next { device = next }
        // 切り替えは入れ替えが無くても（切・リモート中）1 行残す。
        reconcile(cause: "switch", always: true)
    }

    /// 落ち着いている出力先の名前が変わった（設定で付け直したなど）。名前だけ出し直す。入れ替えない。
    func deviceSeen(_ d: ETOutputDevice) {
        guard let next = Self.entryDevice(d), device?.key == next.key, device != next else { return }
        core.setCurrentDevice(next)
        device = next
        if loaded?.key == next.key { loaded = next }
    }

    /// PC の鎖の編集に入った・出た（RemoteMirror）。
    func setRemote(_ on: Bool) {
        guard on != remote else { return }
        remote = on
        reconcile(cause: on ? "remote" : "local")
    }

    /// DSP を用意した（EffeTuneDSP.prepare の restore() の後）。
    /// 組み直し（レートの変更など）では、入っている写しはそのまま残る（段は rebuildAll が作り直してある）。
    func dspPrepared() {
        reconcile(cause: "prepared")
    }

    // MARK: - 段取り

    private func reconcile(cause: String, always: Bool = false) {
        let dsp = EffeTuneDSP.shared
        let steps = ETOutputCorrectionPolicy.steps(ETOutputCorrectionState(
            isOn: isOn, isRemote: remote, ready: dsp.ready,
            device: device?.key, loaded: loaded?.key))
        guard !steps.isEmpty else {
            if always { record(cause: cause, steps: []) }
            return
        }
        for step in steps {
            switch step {
            case .flush(let key):
                // 出ていく出力先の写しを、いまの段で書き切る（待っている遅延保存のぶんも入る）。
                if let l = loaded, l.key == key { save(l) }
            case .unload:
                loaded = nil
                source = nil
                dsp.unloadCorrection()
            case .load(let key):
                load(key)
            }
        }
        record(cause: cause, steps: steps)
    }

    /// その出力先の写しを入れる。写しが無ければ空の補正になる。
    private func load(_ key: String) {
        guard let d = device, d.key == key else { return }
        loaded = nil
        writer.sync {}
        let entry = core.entry(for: key)
        let items = core.form(for: key).map { PipelineStore.parse($0, catalog: ETCatalog) } ?? []
        EffeTuneDSP.shared.loadCorrection(items)
        loaded = d
        source = entry?.source
    }

    // MARK: - 層の操作（画面から）

    /// プリセットの中身をこの出力先の補正へ写す。元のプリセットには触らない。
    /// 写した後は独立していて、プリセットを直してもこちらは変わらない。
    func choose(name: String, items: [PipelineStore.Loaded]) {
        guard isEditable, let d = loaded, !items.isEmpty else { return }
        // 外の段には新しい身元を付ける。プリセットの身元のままだと、同じプリセットを読んだ main の段と
        // 1 つの AU・1 つの外部の席を取り合う（ETChainEditing.presetInsertion と同じ）。
        let fresh = items.map { item -> PipelineStore.Loaded in
            var item = item
            if !item.externalID.isEmpty { item.externalInstanceID = UUID().uuidString }
            return item
        }
        loaded = nil
        EffeTuneDSP.shared.loadCorrection(fresh)
        loaded = d
        source = name
        save(d)
        record(cause: "choose", steps: [])
    }

    /// この出力先の補正を空にする。層はこの出力先のまま残る（後から足したものはまた書かれる）。
    func clear() {
        guard isEditable, let d = loaded else { return }
        source = nil
        EffeTuneDSP.shared.unloadCorrection()
        let core = self.core
        writer.async { core.remove(key: d.key) }
        record(cause: "clear", steps: [])
    }

    // MARK: - 書き出し

    /// EffeTuneDSP.persist() から。入っている写しを、その出力先の鍵で書く。
    /// 構造の変更は publish()、値の変更は persistSoon() の待ちに乗って来る。
    func persistLoaded() {
        guard let l = loaded else { return }
        save(l)
    }

    private func save(_ d: ETOutputCorrectionDevice) {
        // 短い形にするのはメイン（段を読むので）。JSON と書き込みは列の先。
        let form = EffeTuneDSP.shared.correctionForm()
        // 空になった写しは元のプリセットごと消える（入れ物の決まり）。印も外す。
        if form.isEmpty, source != nil { source = nil }
        let origin = source
        let core = self.core
        writer.async {
            if !core.save(d, source: origin, form: form) {
                Logger(subsystem: "ai.nemut.effetune", category: "correction")
                    .error("出力補正を書けなかった（JSON にできない値）")
            }
        }
    }

    // MARK: - 記録

    /// 1 行残す。**uid は出さない**（鍵にも入っているので鍵も出さない）。
    private func record(cause: String, steps: [ETOutputCorrectionStep]) {
        let names = steps.map { step -> String in
            switch step {
            case .flush: return "flush"
            case .unload: return "unload"
            case .load: return "load"
            }
        }
        let line = String(format: "device t=%.3f kind=%@ name=%@ cause=%@ oc=%@ steps=%@ nodes=%ld",
                          ProcessInfo.processInfo.systemUptime,
                          device?.kind ?? "-", device?.name ?? "-", cause,
                          isOn ? "on" : "off",
                          names.isEmpty ? "-" : names.joined(separator: ","),
                          EffeTuneDSP.shared.correction.count)
        log.notice("\(line, privacy: .public)")
        ETLogTap.record(line)
        if ETConsoleLog.on { print(line) }
    }

    /// 出力先を入れ物の形へ。鍵の無い口（HFP など）は nil。
    private static func entryDevice(_ d: ETOutputDevice) -> ETOutputCorrectionDevice? {
        guard let key = d.key else { return nil }
        return ETOutputCorrectionDevice(key: key, name: d.name, kind: d.kind.rawValue)
    }
}
