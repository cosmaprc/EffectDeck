//  RemoteProtocol.swift
//  PC の EffeTune を LAN から操る PoC（remote-v1）の、通信に触らない部分。**Foundationだけ。**
//
//  RemoteMirror.swift（URLSession と画面）から出した。あちらは EffeTuneDSP と Preferences を
//  引くので単体テストに入れられない。こちらは判断だけを持つ（RemoteProtocolTests）:
//    - 手元の鎖を、上流（PC の EffeTune）が読める形へ写す。**写した段の番号の対応表も返す**
//    - 手元の 1 段のパラメータを、params メッセージの中身へ写す
//    - 画面で打たれた接続先の読み方（host:port/token・ws:// の URL）と、PC の QR のリンク
//    - v2: state の出どころ（origin / seq）で追うか捨てるか、プリセットと IR の足し合わせの決まり、
//      PC の変更を値だけで当てられるか（ETRemoteFollow）
//
//  ---------------------------------------------------------------------------
//  **外部の段（AU / JSFX）は、符号化する前に振り分ける。**
//
//  ETShareLink.effeTuneForm は先に PipelineStore.shortForm を全段へ回すので、外部の段の
//  externalState が base64 になる（JSFX の @serialize は 16 MB まで来て、21 MB の文字列になる）。
//  そこで捨てるものを符号化するのは無駄で、つまみを動かすたびに走らせるには重い。
//  ここは外部の段を見た時点で、落とすか 0 dB の Volume に替えるかを決めて、符号化しない。
//  規則は effeTuneForm と同じ（同じバスの中の段は消す。バスを渡る段は入切とバスを残した
//  0 dB の Volume にする）。
//  ---------------------------------------------------------------------------
//
//  ---------------------------------------------------------------------------
//  **手元の段の番号と、PC へ送った段の番号はずれる。**
//
//  外部の段が落ちると PC の鎖のほうが短くなる。params メッセージは PC の鎖の番号で宛てるので、
//  写すときに「手元の i 番目 → PC の j 番目（落ちたら nil）」の表を一緒に作る。
//  表は鎖を送るたびに作り直す。params を送る側はその表で引く。
//  ---------------------------------------------------------------------------

import Foundation

enum ETRemoteProjection {

    /// 上流へ渡す鎖と、手元の番号から上流の番号への対応。
    struct Projected {
        /// PC へ送るショート形式（`[{"nm":"Volume","en":true,"vl":-3}, …]`）。
        var pipeline: [[String: Any]]
        /// `remoteIndex[手元の番号]` が PC の番号。落とした段は nil。
        var remoteIndex: [Int?]
    }

    static func project(_ chain: [ETChainNode]) -> Projected {
        project(chain.map { PipelineStore.Loaded($0) })
    }

    static func project(_ items: [PipelineStore.Loaded]) -> Projected {
        var pipeline: [[String: Any]] = []
        var map: [Int?] = []
        for item in items {
            if let entry = entry(for: item) {
                map.append(pipeline.count)
                pipeline.append(entry)
            } else {
                map.append(nil)
            }
        }
        return Projected(pipeline: pipeline, remoteIndex: map)
    }

    /// 1 段を上流の形へ。落とす段は nil。
    static func entry(for item: PipelineStore.Loaded) -> [String: Any]? {
        guard item.externalID.isEmpty else {
            // 同じバスの中なら、切ることは消すことと同じ。
            guard item.inputBus != item.outputBus else { return nil }
            // 切ってある段は音に何も足さないので、替えの段も切ったままにする。
            var o: [String: Any] = ["nm": "Volume", "en": item.enabled, "vl": 0.0]
            if item.inputBus != 0 { o["ib"] = Int(item.inputBus) }
            if item.outputBus != 0 { o["ob"] = Int(item.outputBus) }
            if let ch = ETChannel.channel(from: item.channelSpec) { o["ch"] = ch }
            return o
        }
        // 外部の段はここへ来ない。1 段だけ渡すので、ほかの段の状態は符号化されない。
        guard let entry = PipelineStore.shortForm([item]).first else { return nil }
        // 終端の印（rr）は上流に無い綴りなので外す。
        return PipelineStore.upstreamEntry(entry)
    }

    /// params メッセージの `params` に入れるもの。**段のショート形式から段の鍵を抜いたもの**
    /// （`nm` / `en` / バス / `ch` は入れない）。動かせるパラメータが無い段（Section・終端・外部）は nil。
    ///
    /// **float の値だけでなく、IR の鍵（`ir`）・図の見せ方・designer の材料（`pm` / `tp` など）も入れる。**
    /// params を送るたびに RemoteMirror は控えの鎖のその段を entry(for:) で書き換えるので、
    /// ここで材料を落とすと、材料だけ変わった段は後の persist() でも「もう送った」と見なされ、
    /// PC へ一度も届かない。
    static func params(for item: PipelineStore.Loaded) -> [String: Any]? {
        guard item.externalID.isEmpty, !item.isRootReset, !ETSection.isSection(item.spec),
              var o = PipelineStore.shortForm([item]).first else {
            return nil
        }
        for key in ["nm", "en", "ib", "ob", "ch", ETSection.rootResetKey] {
            o.removeValue(forKey: key)
        }
        return o.isEmpty ? nil : o
    }

    static func params(for node: ETChainNode) -> [String: Any]? {
        params(for: PipelineStore.Loaded(node))
    }
}

/// 画面で打たれた接続先。`host:port/token` が基本で、`ws://host:port/?t=token` も受ける。
struct ETRemoteAddress: Equatable {

    static let defaultPort = 47300

    let host: String
    let port: Int
    let token: String

    /// `ws://<host>:<port>/?t=<token>`。トークンは URLQueryItem に任せて符号化する。
    var url: URL? {
        var c = URLComponents()
        c.scheme = "ws"
        c.host = host
        c.port = port
        c.path = "/"
        c.queryItems = [URLQueryItem(name: "t", value: token)]
        return c.url
    }

    /// 読めなければ nil。空白は前後だけ落とす。
    ///
    /// 受ける形:
    ///   192.168.1.10:47300/ab12cd34
    ///   192.168.1.10/ab12cd34               （ポートは 47300）
    ///   ws://192.168.1.10:47300/?t=ab12cd34
    ///   ws://192.168.1.10:47300/ab12cd34
    static func parse(_ text: String) -> ETRemoteAddress? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        // 完全な URL。scheme を見て、無ければ下の素の形へ回す。
        if let range = s.range(of: "://") {
            let scheme = s[s.startIndex..<range.lowerBound].lowercased()
            // wss は受けない。url は ws しか作らないので、受けると暗号なしへ黙って落ちる。
            guard scheme == "ws",
                  let c = URLComponents(string: s), let host = c.host, !host.isEmpty else { return nil }
            let token = c.queryItems?.first(where: { $0.name == "t" })?.value
                ?? c.path.split(separator: "/").last.map(String.init) ?? ""
            return make(host: host, port: c.port ?? defaultPort, token: token)
        }

        // 素の形。最初の `/` までが host[:port]、残りがトークン。
        let parts = s.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        let hostPort = String(parts[0])
        var token = parts.count > 1 ? String(parts[1]) : ""
        // `host:47300/?t=token` のように URL から scheme だけ抜いた貼り方も受ける。
        if token.hasPrefix("?t=") { token.removeFirst(3) }
        token = token.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        var host = hostPort
        var port = defaultPort
        if let colon = hostPort.lastIndex(of: ":") {
            host = String(hostPort[hostPort.startIndex..<colon])
            guard let p = Int(hostPort[hostPort.index(after: colon)...]) else { return nil }
            port = p
        }
        return make(host: host, port: port, token: token)
    }

    private static func make(host: String, port: Int, token: String) -> ETRemoteAddress? {
        guard !host.isEmpty, (1...65535).contains(port), !token.isEmpty else { return nil }
        return ETRemoteAddress(host: host, port: port, token: token)
    }
}

// MARK: - v2（remote-v1 の足し分。"v" は 1 のまま）

extension ETRemoteAddress {

    /// Preferences.remoteAddress に書く字（`host:port/token`）。parse がそのまま読む。
    var text: String { "\(host):\(port)/\(token)" }

    /// PC が QR に出す接続先 `ws://<IPv4>:47300/?t=<token>` を読む。
    /// **QR には API の接続先そのものを入れる**（2026-09-30 本人の決定）。EffectDeck の名前の
    /// リンクにすると、PC 側が特定のクライアントを知ることになる。代わりにカメラのアプリからは
    /// 開けないので、読むのはアプリの中の読み取り（RemoteScannerView）だけ。
    /// ws 以外・t の無いもの・パスが / 以外のものは nil（カメラで拾った別の QR を受けない）。
    static func pairingLink(_ url: URL) -> ETRemoteAddress? {
        guard url.scheme?.lowercased() == "ws",
              let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              c.path.isEmpty || c.path == "/",
              let t = c.queryItems?.first(where: { $0.name == "t" })?.value, !t.isEmpty else { return nil }
        return parse(url.absoluteString)
    }
}

/// state の push を手元へ入れるか（origin と seq）。
///
/// **"local" は PC の上で起きた変更**（PC の画面・取り消し・PC でのプリセット読み込み）なので追う。
/// **"remote" は誰かのコマンドの結果。**seq が自分の送ったものなら、手元はもうその形なので捨てる
/// （入れると、つまみを動かしている最中に 1 つ前の値へ引き戻される）。seq が無いか自分のものでなければ、
/// 同じ PC につないだ別の端末の変更なので追う。
/// origin が無いのは v1 の PC。どこから来たか分からないので、v1 のときと同じく読み捨てる。
enum ETRemoteStateFilter {
    static func follows(origin: String?, seq: Int?, ours: Set<Int>) -> Bool {
        switch origin {
        case "local":
            return true
        case "remote":
            guard let seq else { return true }
            return !ours.contains(seq)
        default:
            return false
        }
    }
}

/// プリセットの足し合わせ（つないだ瞬間に 1 回）。**消さない・上書きしない。**
///
/// 中身は canonical（ショート形式を鍵の順を固定した JSON）で比べる。両側とも同じ読み書き
/// （ETShareLink.parse → ETRemoteProjection.project）を通してから比べるので、
/// 数の表し方（0.1 と 0.10000000149）の違いでは「違う」にならない。
///
/// 名前が同じで中身が違えば、相手側に `名前 (PC)` / `名前 (iPad)` で置く。空いていなければ
/// `名前 (PC 2)` …。**何度つないでも増えない**ように、次の 2 つは写さない:
///   - 相手に同じ名前・同じ中身が在る（付け足した名前のほうも含めて）
///   - 自分が前に相手へ置いた写し（`名前 (iPad)` が PC に在り、その中身が手元の `名前` と同じ）
enum ETRemotePresetSync {

    static let pcTag = "PC"
    static let localTag = "iPad"

    struct Copy: Equatable {
        /// 元の側での名前。
        let source: String
        /// 置く側での名前。
        let target: String
    }

    struct Plan: Equatable {
        var toLocal: [Copy] = []
        var toPC: [Copy] = []
    }

    static func canonical(_ pipeline: [[String: Any]]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: pipeline, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

    /// `名前 (PC)` / `名前 (iPad 3)` を（名前, "PC"）へ分ける。付け足しが無ければ nil。
    static func split(_ name: String) -> (base: String, tag: String)? {
        guard name.hasSuffix(")"), let open = name.range(of: " (", options: .backwards) else { return nil }
        let inner = name[open.upperBound..<name.index(before: name.endIndex)]
        let words = inner.split(separator: " ")
        guard let first = words.first, [pcTag, localTag].contains(String(first)),
              words.count <= 2 else { return nil }
        if words.count == 2 {
            guard let n = Int(words[1]), n >= 2 else { return nil }
        }
        return (String(name[name.startIndex..<open.lowerBound]), String(first))
    }

    /// - Parameters:
    ///   - pc: PC のプリセット（手元の名前の整え方に寄せた名前 → canonical）
    ///   - local: 手元のプリセット（名前 → canonical）
    ///   - localBlocked: PC へ送らない手元のプリセット（AU / JSFX の段を持つもの）
    static func plan(pc: [String: String], local: [String: String],
                     localBlocked: Set<String> = []) -> Plan {
        var plan = Plan()
        var localAfter = local
        for name in pc.keys.sorted() {
            guard let content = pc[name] else { continue }
            if let s = split(name), s.tag == localTag, local[s.base] == content { continue }
            if let target = place(name, content, tag: pcTag, in: &localAfter) {
                plan.toLocal.append(Copy(source: name, target: target))
            }
        }
        var pcAfter = pc
        for name in local.keys.sorted() where !localBlocked.contains(name) {
            guard let content = local[name] else { continue }
            if let s = split(name), s.tag == pcTag, pc[s.base] == content { continue }
            if let target = place(name, content, tag: localTag, in: &pcAfter) {
                plan.toPC.append(Copy(source: name, target: target))
            }
        }
        return plan
    }

    /// 置く名前。同じ中身がもう在れば nil。
    private static func place(_ name: String, _ content: String, tag: String,
                              in existing: inout [String: String]) -> String? {
        var candidate = name
        var n = 1
        while let there = existing[candidate] {
            if there == content { return nil }
            candidate = n == 1 ? "\(name) (\(tag))" : "\(name) (\(tag) \(n))"
            n += 1
        }
        existing[candidate] = content
        return candidate
    }
}

/// IR の受け渡し（listIRs / getIR / putIR）。鍵は IRLibraryFiles.key と同じ 24 桁。
enum ETRemoteIRSync {

    /// 1 回に送る生のバイト数（base64 にする前）。PC の枠の上限は 4 MB。
    static let chunkSize = 512 * 1024

    /// 取りに行く鍵と、送る鍵。どちらも並びを固定する。
    static func plan(pc: [String], local: [String]) -> (download: [String], upload: [String]) {
        let p = Set(pc), l = Set(local)
        return (p.subtracting(l).sorted(), l.subtracting(p).sorted())
    }

    /// `bytes` を size ごとに切った範囲。0 バイトでも空の塊を 1 つ返す（total が 0 にならない）。
    static func chunks(_ bytes: Int, size: Int = chunkSize) -> [Range<Int>] {
        guard bytes > 0 else { return [0..<0] }
        return stride(from: 0, to: bytes, by: size).map { $0..<min($0 + size, bytes) }
    }

    /// 受け取った IR を置き場へ入れるときのファイル名。IRLibrary.importFile は元の名前から
    /// 見出しと拡張子を取るので、ここで `名前.拡張子` にしておく。名前に拡張子が付いていても二重にしない。
    static func fileName(name: String, ext: String) -> String {
        let cleanExt = String(ext.filter { $0.isLetter || $0.isNumber })
        var base = String(name.map { "/\\:".contains($0) ? "-" : $0 })
        if !cleanExt.isEmpty, base.lowercased().hasSuffix("." + cleanExt.lowercased()) {
            base = String(base.dropLast(cleanExt.count + 1))
        }
        if base.trimmingCharacters(in: .whitespaces).isEmpty { base = "IR" }
        return cleanExt.isEmpty ? base : "\(base).\(cleanExt)"
    }

    /// 塊を順に継ぐ。**順が飛んだら失敗にする**（1 本の接続で順に来る決まり）。
    struct Assembly {
        private(set) var total = 0
        private(set) var next = 0
        private(set) var data = Data()
        private(set) var failed = false

        var isComplete: Bool { !failed && total > 0 && next == total }

        mutating func add(index: Int, total: Int, data chunk: Data) {
            guard !failed else { return }
            guard total > 0, index == next, self.total == 0 || self.total == total else {
                failed = true
                return
            }
            self.total = total
            data.append(chunk)
            next += 1
        }
    }
}

/// PC で起きた変更を手元の鎖へ入れる形。
enum ETRemoteFollow {
    /// 並び・入切・バス・材料・見せ方が同じで、違いうるのは値（values）だけか。
    /// そうなら段を作り直さず値だけ当てる（カードの開閉も音の途切れも起きない）。
    static func sameShape(_ a: [PipelineStore.Loaded], _ b: [PipelineStore.Loaded]) -> Bool {
        guard a.count == b.count else { return false }
        for (x, y) in zip(a, b) {
            guard x.spec.type == y.spec.type, x.enabled == y.enabled,
                  x.inputBus == y.inputBus, x.outputBus == y.outputBus,
                  x.channelSpec == y.channelSpec, x.sectionName == y.sectionName,
                  x.irId == y.irId, x.display == y.display, x.design == y.design,
                  x.isRootReset == y.isRootReset,
                  x.externalID.isEmpty, y.externalID.isEmpty,
                  x.values.count == y.values.count else { return false }
        }
        return true
    }
}
