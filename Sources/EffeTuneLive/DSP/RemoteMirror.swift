//  RemoteMirror.swift
//  PC の EffeTune（fork）を LAN から操る PoC。EffectDeck が操作する側（remote-v1）。
//
//  手元の鎖の変更を WebSocket で PC へ写す。**正は手元。**PC は写された結果を鳴らすだけで、
//  こちらから PC の変更を取りに行くのは「Pull Chain from PC」「Import Presets from PC」を
//  押したときだけ。PC が勝手に変えた鎖（state の push）は読み捨てる。
//
//  つなぎ先: ws://<host>:47300/?t=<token>（ETRemoteAddress）。トークンが違うと PC は
//  コード 4401 で閉じるので、その場合は再接続しない（繰り返しても通らない）。
//
//  ---------------------------------------------------------------------------
//  **何を送るか（メッセージの一覧は remote-v1）**
//    hello       つないだ直後に 1 回。返事は state で、それが来たら Connected にする
//    chain       鎖ごと入れ替え。つないだ直後と、並び・入切・バス・段の中身が変わったとき
//    params      1 段のパラメータ。つまみ操作。30 Hz でまとめ、段ごとに最後の値だけ送る
//    bypass      全体のバイパス
//    get / listPresets / getPreset   Pull と Import のとき
//
//  **鎖は persist() の入口で受ける**（EffeTuneDSP.persist）。鎖を触る経路は全部ここへ来る。
//  ただし persist() の先頭の門（ETChainEditing.shouldPersist）は起動直後の既定の鎖を
//  端末へ残さないためのもので、こちらには関係ないので、門より前に呼ぶ。
//
//  **同じ中身は送らない。**つまみを動かした後の 0.5 秒遅れの persist() が、もう params で
//  送った値の鎖をもう一度送らないように、params を送るたびに「最後に送った鎖」の
//  その段も書き換えておく。
//
//  **外部の段（AU / JSFX）は PC へ渡らない**（RemoteProtocol.swift）。段の番号が
//  ずれるので、params は最後に送った鎖の対応表で PC の番号へ直して送る。
//
//  音のスレッドには触らない。ここは全部メインで、通信は URLSession が別のスレッドで持つ。
//  ---------------------------------------------------------------------------

import Foundation
import os

@MainActor
final class RemoteMirror: ObservableObject {

    static let shared = RemoteMirror()

    enum Status: Equatable {
        case off
        case connecting
        case connected
        case error(String)

        var label: String {
            switch self {
            case .off:            return "Off"
            case .connecting:     return "Connecting"
            case .connected:      return "Connected"
            case .error(let why): return "Error: \(why)"
            }
        }
    }

    @Published private(set) var status: Status = .off

    private let log = Logger(subsystem: "ai.nemut.effetune", category: "remote")
    private let session = URLSession(configuration: .default)

    private var task: URLSessionWebSocketTask?
    /// つなぎ直すたびに進める。古い receive の結果が新しいつなぎを壊さないため。
    private var generation = 0
    private var seq = 0
    private var backoff: TimeInterval = 1
    private var reconnectTask: Task<Void, Never>?
    private var addressTask: Task<Void, Never>?

    /// 最後に PC へ送った鎖と、手元の番号 → PC の番号の対応。
    private var sentForm: [[String: Any]]?
    private var sentMap: [Int?] = []

    /// params を送りたい段（手元の番号）。30 Hz でまとめて送る。
    private var pendingParams: Set<Int> = []
    private var flushTask: Task<Void, Never>?

    /// Pull で受けた鎖を入れているあいだ。入れた結果の persist() を PC へ送り返さない。
    private var applyingRemote = false
    private var pullRequested = false
    /// Import で返事を待っているプリセットの名前。
    private var presetsPending: Set<String> = []

    private init() {}

    // MARK: - 設定

    /// 起動で 1 回。**App の init から呼ぶ**（EffeTuneLiveApp.swift）。
    func start() { apply() }

    /// Toggle が変わった。すぐ反映する。
    func enabledChanged() {
        addressTask?.cancel()
        backoff = 1
        apply()
    }

    /// 接続先の字が変わった。打っている最中に何度もつなぎ直さないよう、止まってから反映する。
    func addressChanged() {
        guard Preferences.shared.remoteEnabled else { return }
        addressTask?.cancel()
        addressTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            if Task.isCancelled { return }
            self?.backoff = 1
            self?.apply()
        }
    }

    private func apply() {
        disconnect()
        guard Preferences.shared.remoteEnabled else {
            status = .off
            return
        }
        connect()
    }

    // MARK: - 手元の変更を写す（EffeTuneDSP から 1 行で呼ぶ）

    /// 鎖の並び・入切・バス・中身が変わったとき。persist() の入口から。
    func chainChanged(_ chain: [ETChainNode]) {
        guard task != nil, !applyingRemote else { return }
        sendChain(chain, force: false)
    }

    /// つまみが動いたとき。setValue / setValues / resetParams から。
    func paramsChanged(at index: Int) {
        guard task != nil, !applyingRemote else { return }
        pendingParams.insert(index)
        guard flushTask == nil else { return }
        flushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 33_000_000)
            if Task.isCancelled { return }
            self?.flushParams()
        }
    }

    /// 全体のバイパス。NowPlaying が切り替えたものも来る（PoC なので区別しない）。
    func bypassChanged(_ on: Bool) {
        guard task != nil, !applyingRemote else { return }
        send(["op": "bypass", "on": on])
    }

    // MARK: - PC から取る

    /// PC の鎖を手元へ入れる。返事（state）が来たら入れ替える。
    func pullChain() {
        guard status == .connected else { return }
        pullRequested = true
        send(["op": "get"])
    }

    /// PC のプリセットを名前付きの鎖として取り込む。
    func importPresets() {
        guard status == .connected else { return }
        send(["op": "listPresets"])
    }

    // MARK: - 接続

    private func connect() {
        guard let address = ETRemoteAddress.parse(Preferences.shared.remoteAddress),
              let url = address.url else {
            status = .error("Invalid address")
            return
        }
        status = .connecting
        generation += 1
        let gen = generation
        let t = session.webSocketTask(with: url)
        task = t
        t.resume()
        listen(t, generation: gen)

        // つないだ直後: hello → 手元の鎖 → バイパス。EffectDeck が操る側なので、こちらの状態を渡す。
        // 送りの順は保たれる。open を待たずに積んでよい（URLSession が開いてから流す）。
        send(["op": "hello", "app": "EffectDeck", "v": 1])
        sentForm = nil
        sendChain(EffeTuneDSP.shared.chain, force: true)
        send(["op": "bypass", "on": EffeTuneDSP.shared.bypass])
    }

    private func disconnect() {
        generation += 1
        reconnectTask?.cancel()
        reconnectTask = nil
        flushTask?.cancel()
        flushTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        sentForm = nil
        sentMap = []
        pendingParams.removeAll()
        pullRequested = false
        presetsPending.removeAll()
    }

    private func listen(_ t: URLSessionWebSocketTask, generation gen: Int) {
        Task { @MainActor [weak self] in
            while let self, gen == self.generation {
                do {
                    let message = try await t.receive()
                    guard gen == self.generation else { return }
                    self.handle(message)
                } catch {
                    self.failed(t, generation: gen, error: error)
                    return
                }
            }
        }
    }

    private func failed(_ t: URLSessionWebSocketTask, generation gen: Int, error: Error) {
        guard gen == generation else { return }
        // 閉じ方のコードは、閉じ終えてから task に載る。
        let code = t.closeCode.rawValue
        disconnect()
        if code == 4401 {
            // トークンが違う。同じ字で繰り返しても通らないので、つなぎ直さない。
            status = .error("Wrong token")
            log.notice("remote: 4401 トークンが違う")
            return
        }
        log.notice("remote: 切れた code=\(code) \(error.localizedDescription, privacy: .public)")
        status = .error("Can't connect")
        scheduleReconnect()
    }

    /// 1, 2, 4 … 15 秒。有効のあいだ続ける。つながったら 1 秒へ戻す。
    private func scheduleReconnect() {
        guard Preferences.shared.remoteEnabled else { return }
        let delay = backoff
        backoff = min(backoff * 2, 15)
        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if Task.isCancelled { return }
            self?.connect()
        }
    }

    // MARK: - 送る

    @discardableResult
    private func send(_ message: [String: Any]) -> Bool {
        guard let t = task else { return false }
        seq += 1
        var m = message
        m["seq"] = seq
        guard let data = try? JSONSerialization.data(withJSONObject: m),
              let text = String(data: data, encoding: .utf8) else { return false }
        let log = self.log
        t.send(.string(text)) { error in
            // 送れなかったときは receive 側も失敗して、つなぎ直しに入る。ここは記録だけ。
            if let error { log.notice("remote: 送れない \(error.localizedDescription, privacy: .public)") }
        }
        return true
    }

    private func sendChain(_ chain: [ETChainNode], force: Bool) {
        // 起動直後は鎖がまだ空（restore() の前）。空で送ると PC の鎖が消える。
        // restore() が並べ終えれば persist() から来る。
        guard !chain.isEmpty else { return }
        let projected = ETRemoteProjection.project(chain)
        sentMap = projected.remoteIndex
        if !force, let sent = sentForm, (sent as NSArray).isEqual(to: projected.pipeline) { return }
        sentForm = projected.pipeline
        send(["op": "chain", "pipeline": projected.pipeline])
    }

    private func flushParams() {
        flushTask = nil
        let chain = EffeTuneDSP.shared.chain
        let pending = pendingParams.sorted()
        pendingParams.removeAll()
        // 並びが変わって、まだ鎖を送っていない。鎖のほうが新しい値ごと送るので、ここは捨てる。
        guard chain.count == sentMap.count else { return }
        for index in pending {
            guard chain.indices.contains(index), let remote = sentMap[index],
                  let params = ETRemoteProjection.params(for: chain[index]) else { continue }
            send(["op": "params", "index": remote, "params": params])
            // 後から来る persist() の鎖と食い違わないよう、送ったぶんを控えへ写す。
            if sentForm?.indices.contains(remote) == true,
               let entry = ETRemoteProjection.entry(for: PipelineStore.Loaded(chain[index])) {
                sentForm?[remote] = entry
            }
        }
    }

    // MARK: - 受ける

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .string(let s): data = Data(s.utf8)
        case .data(let d):   data = d
        @unknown default:    return
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let op = object["op"] as? String else { return }

        switch op {
        case "state":
            if status != .connected { status = .connected }
            backoff = 1
            // PC が勝手に変えた鎖は読み捨てる。Pull を頼んだときだけ入れる。
            if pullRequested {
                pullRequested = false
                applyPulled(object["pipeline"])
            }
        case "ack":
            if object["ok"] as? Bool == false {
                let seq = object["seq"] as? Int ?? -1
                let why = object["error"] as? String ?? ""
                log.notice("remote: 拒否 seq=\(seq) \(why, privacy: .public)")
            }
        case "presets":
            guard let names = object["names"] as? [String] else { return }
            presetsPending = Set(names)
            for name in names { send(["op": "getPreset", "name": name]) }
        case "preset":
            guard let name = object["name"] as? String, presetsPending.remove(name) != nil else { return }
            savePreset(named: name, pipeline: object["pipeline"])
        default:
            break
        }
    }

    /// ショート形式の配列を段の並びへ。読めない値は寄せ、知らない段は落ちる（ETShareLink.parse）。
    private func items(from pipeline: Any?) -> [PipelineStore.Loaded] {
        guard let list = pipeline as? [[String: Any]],
              let data = try? JSONSerialization.data(withJSONObject: list),
              let text = String(data: data, encoding: .utf8) else { return [] }
        return ETShareLink.parse(text, catalog: ETCatalog)
    }

    private func applyPulled(_ pipeline: Any?) {
        let loaded = items(from: pipeline)
        guard !loaded.isEmpty else { return }
        applyingRemote = true
        EffeTuneDSP.shared.replaceChain(with: loaded)
        applyingRemote = false
        // いま入れた鎖は PC と同じなので、送ったことにして控えを合わせる。
        let projected = ETRemoteProjection.project(EffeTuneDSP.shared.chain)
        sentForm = projected.pipeline
        sentMap = projected.remoteIndex
    }

    /// 同じ名前が手元に在れば " (PC)" を付ける。それでも在れば " (PC 2)" …
    private func savePreset(named pcName: String, pipeline: Any?) {
        let loaded = items(from: pipeline)
        guard !loaded.isEmpty else { return }
        let store = PresetStore.shared
        func exists(_ name: String) -> Bool {
            store.names.contains(store.savedName(for: name) ?? name)
        }
        var name = pcName
        if exists(name) {
            name = "\(pcName) (PC)"
            var n = 2
            while exists(name) {
                name = "\(pcName) (PC \(n))"
                n += 1
            }
        }
        store.save(name, items: loaded)
    }
}
