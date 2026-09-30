//  RemoteProtocol.swift
//  PC の EffeTune を LAN から操る PoC（remote-v1）の、通信に触らない部分。**Foundationだけ。**
//
//  RemoteMirror.swift（URLSession と画面）から出した。あちらは EffeTuneDSP と Preferences を
//  引くので単体テストに入れられない。こちらは判断だけを持つ（RemoteProtocolTests）:
//    - 手元の鎖を、上流（PC の EffeTune）が読める形へ写す。**写した段の番号の対応表も返す**
//    - 手元の 1 段のパラメータを、params メッセージの中身へ写す
//    - 画面で打たれた接続先の読み方（host:port/token・ws:// の URL）
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

    /// params メッセージの `params` に入れるもの。**パラメータのショートキーだけ**
    /// （`nm` / `en` / バスは入れない）。動かせるパラメータが無い段（Section・終端・外部）は nil。
    static func params(for item: PipelineStore.Loaded) -> [String: Any]? {
        guard item.externalID.isEmpty, !item.isRootReset, !ETSection.isSection(item.spec) else {
            return nil
        }
        let o = ETParamCoding.encode(params: item.spec.params, values: item.values)
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
            guard scheme == "ws" || scheme == "wss",
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
