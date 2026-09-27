//  LocalLink.m
//  BSD ソケットで書いてある。Network.framework だと拡張側の制約が読みにくいので、
//  拒否が出たときにどのシステムコールかがそのまま分かる形にした。

#import "LocalLink.h"
#import "ETLinkCodec.h"
#import <sys/socket.h>
#import <netinet/in.h>
#import <netinet/tcp.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <fcntl.h>
#import <errno.h>
#import <string.h>
#import <os/log.h>
#import <stdatomic.h>

static os_log_t ETLinkLog(void) {
    static os_log_t l;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ l = os_log_create("ai.nemut.effetune", "link"); });
    return l;
}

// ---- 線の形式 ----
//
// チャンクのヘッダ（マジック 8 + サンプル数 4）、送り手のリングからの組み立て、
// 受け手の再同期、溜まりの方針は ETLinkCodec.{h,c} にある。
// ここに残したのはソケット・タイマー・スレッド・ログだけ。
// 形式を変えるときは ETLinkCodec.h の説明と Tests/Native/link を先に読むこと。

// ---- 送り手 ----

// ポンプの周期は繋がっているかどうかで変える。
//
// **繋がっていないあいだに 2ms は要らない。**やることは connect の 1 回だけで、
// 相手が待ち受けを開いていなければ何度撃っても同じ結果しか返らない。
// 200ms は今までの間引き（2ms の 100 回に 1 回）と同じ 5 回/秒なので、
// 繋がるまでの時間は変わらない。変わるのは空振りの起床が 500 回/秒から
// 5 回/秒に減ることだけ。
//
// **繋がってからは触らない。**ここは音そのものの粒で、周期がそのまま
// 受け手の谷の深さになる（下の LIVE の行）。leeway も 0 のまま。
#define TX_WAIT_NS          (200ull * NSEC_PER_MSEC)
#define TX_WAIT_LEEWAY_NS   (100ull * NSEC_PER_MSEC)
#define TX_LIVE_NS          (2ull * NSEC_PER_MSEC)
#define TX_LIVE_LEEWAY_NS   0ull

@implementation ETLinkSender {
    int _fd;
    dispatch_queue_t _q;
    dispatch_source_t _timer;
    float *_ring;
    _Atomic uint64_t _w;
    uint64_t _r;
    BOOL _running;
    // 送信中のチャンク。_txOff はサンプルではなくバイト位置。
    uint8_t *_txBuf;
    size_t _txLen;
    size_t _txOff;
    uint32_t _txSamples;
    // いまタイマーに入れてある周期が「繋がっている側」か。
    // 同じ値の set_timer を毎回撃たないための札。
    BOOL _timedLive;
}

+ (ETLinkSender *)shared {
    static ETLinkSender *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[ETLinkSender alloc] init]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _fd = -1;
        _q = dispatch_queue_create("ai.nemut.effetune.link.send", DISPATCH_QUEUE_SERIAL);
        _ring = calloc(ET_LINK_SEND_RING_SAMPLES, sizeof(float));
        // malloc 由来なので先頭は 16 バイト境界。ヘッダ 12 の直後の float 配列も 4 で揃う。
        _txBuf = calloc(1, ET_LINK_CHUNK_BYTES);
    }
    return self;
}

- (BOOL)connected { return _fd >= 0; }

- (void)start {
    if (_running) return;
    _running = YES;
    _r = atomic_load(&_w);
    _txLen = _txOff = 0;
    _txSamples = 0;
    // 毎回 0 から数える。累計のままだと、今回何も送っていなくても
    // 「送信=188万」のように見えて、ログで判断を誤る。
    _sentFrames = 0;
    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _q);
    // **まだ繋がっていないので遅い側から始める。**
    // DISPATCH_TIME_NOW から始めるので、**最初の 1 回は必ずすぐ撃つ**。
    // 繋がった時点で pump が下の retimePump を呼び、2ms へ上げる。
    //
    // 繋がってからの 2ms が**受け手の詰められる下限を決める。**音は滑らかに
    // 流れず、この周期ぶんの塊で届く。10ms なら 480 フレームの塊で、受け手は
    // 塊と塊の谷を埋めるだけ溜めていないと読み切ってしまう（実測で
    // 384 フレームが下限だった）。2ms なら 96 フレーム。
    // leeway を 0 にするのは、合流で遅れると谷がその分深くなるから。
    _timedLive = NO;
    dispatch_source_set_timer(_timer, DISPATCH_TIME_NOW, TX_WAIT_NS, TX_WAIT_LEEWAY_NS);
    __weak typeof(self) weak = self;
    dispatch_source_set_event_handler(_timer, ^{ [weak pump]; });
    dispatch_resume(_timer);
    os_log_error(ETLinkLog(), "ET sender 開始");
}

/// いまの接続の状態に合う周期をタイマーへ入れ直す。**同じなら何もしない。**
/// 呼ぶのは _q の上（pump の中）だけ。
- (void)retimePump {
    BOOL live = (_fd >= 0);
    if (live == _timedLive) return;
    dispatch_source_t t = _timer;
    if (!t) return;
    _timedLive = live;
    uint64_t every  = live ? TX_LIVE_NS : TX_WAIT_NS;
    uint64_t leeway = live ? TX_LIVE_LEEWAY_NS : TX_WAIT_LEEWAY_NS;
    dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, (int64_t)every),
                              every, leeway);
}

- (void)stop {
    _running = NO;
    if (_timer) { dispatch_source_cancel(_timer); _timer = nil; }
    dispatch_async(_q, ^{
        if (self->_fd >= 0) { close(self->_fd); self->_fd = -1; }
        self->_txLen = self->_txOff = 0;
        self->_txSamples = 0;
    });
    os_log(ETLinkLog(), "sender 停止 sent=%llu", (unsigned long long)_sentFrames);
}

- (void)pushInterleaved:(const float *)samples frames:(uint32_t)frames channels:(uint32_t)channels {
    if (!samples || frames == 0) return;
    uint64_t w = atomic_load_explicit(&_w, memory_order_relaxed);
    w = ETLinkRingPush(_ring, ET_LINK_SEND_RING_SAMPLES, w, samples, frames, channels);
    atomic_store_explicit(&_w, w, memory_order_release);
}

- (void)ensureConnected {
    if (_fd >= 0) return;
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        os_log_error(ETLinkLog(), "socket 失敗 errno=%d", errno);
        return;
    }
    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));

    struct sockaddr_in a;
    memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET;
    a.sin_port = htons(ET_LINK_PORT);
    inet_pton(AF_INET, ET_LINK_HOST, &a.sin_addr);

    if (connect(fd, (struct sockaddr *)&a, sizeof(a)) != 0) {
        static int logged = 0;
        if (logged++ < 5) os_log_error(ETLinkLog(), "ET connect 失敗 errno=%d", errno);
        close(fd);
        return;
    }
    int fl = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, fl | O_NONBLOCK);
    _fd = fd;
    _r = atomic_load(&_w);   // 繋がった時点から送る
    // 前の接続で送り残したチャンクの途中から流すと、新しいストリームの先頭が
    // ヘッダにならない。持ち越しはここで捨てる。
    _txLen = _txOff = 0;
    _txSamples = 0;
    os_log_error(ETLinkLog(), "ET connect 成功 port=%d", ET_LINK_PORT);
}

/// 送信中のチャンクの残りを吐き出す。全部出せたら YES。
/// 端数で止まったら _txOff にバイト位置を残して NO を返す。
/// send が返すのはバイト数で、float の途中で止まりうる。ここをサンプル単位で
/// 数えると端数バイトは送信済みなのに読み位置が戻り、同じサンプルの先頭を
/// 送り直す＝受け側が 1〜3 バイトずれる。だからバイトで数える。
- (BOOL)flushPending {
    while (_txOff < _txLen) {
        ssize_t sent = send(_fd, _txBuf + _txOff, _txLen - _txOff, 0);
        if (sent > 0) { _txOff += (size_t)sent; continue; }
        if (sent < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return NO;
        os_log_error(ETLinkLog(), "send 失敗 errno=%d", errno);
        close(_fd); _fd = -1;
        _txLen = _txOff = 0;
        _txSamples = 0;
        return NO;
    }
    // 送り切ったチャンクだけ数える。途中で止まったぶんは次の pump で数える。
    if (_txSamples) { _sentFrames += _txSamples / 2; _txSamples = 0; }
    return YES;
}

- (void)pump {
    if (!_running) return;
    // 前の回で切れていたらここで遅い側へ戻る。繋がったままなら何もしない。
    //
    // **間引きではなく周期そのものを変える。**前は 2ms のまま回して
    // 100 回に 1 回だけ connect していたので、本体が 47101 を開くまで
    // 何もしない起床が 495 回/秒残っていた。撃つ回数（5 回/秒）は同じまま、
    // 起床ごと 5 回/秒に落とす。
    [self retimePump];
    if (_fd < 0) {
        [self ensureConnected];
        if (_fd < 0) return;
        [self retimePump];   // 繋がった。次の回から 2ms
    }

    if (![self flushPending]) return;   // 前回の残りが先

    uint64_t w = atomic_load_explicit(&_w, memory_order_acquire);
    uint64_t r = _r;
    if (w <= r) return;

    // 1 チャンクずつ _txBuf に組んで吐く。偶数サンプルで切ること、書き手が
    // 1 周先へ行っていたら古いぶんを捨てることは ETLinkEncodeNext の中。
    // w はこの回のあいだ同じ値を渡し続ける（読み切ったら 0 が返って抜ける）。
    uint32_t n;
    while ((n = ETLinkEncodeNext(_txBuf, &_txLen, _ring, ET_LINK_SEND_RING_SAMPLES, w, &r)) != 0) {
        _txOff = 0;
        _txSamples = n;

        // リングから _txBuf へ写した時点で読み位置を進める。送信が途中で止まっても
        // 残りは _txBuf が持っているので、リングを読み直す必要は無い。
        _r = r;

        if (![self flushPending]) return;   // 続きは次の pump
    }
    _r = r;
}

@end

// ---- 受け手 ----

// 送り手と同じく、ポンプの周期を相手の有無で変える。
//
// **相手が居ないあいだの 1ms は完全に無駄。**やっているのは accept 1 回で、
// しかも待ち受けの backlog はカーネルが受けるので、こちらが遅れても
// 相手の connect は即座に成功する（遅れるのは読み始めだけで、その間の
// サンプルはソケットの受信バッファに溜まる）。1000 回/秒の起床が 50 回/秒になる。
//
// **相手が居るあいだは 1ms のまま。**周期は溜まりに足し算されるので詰める。
// leeway だけ 1ms 与える。合流でずれても 1〜2ms で、送り手自身の 2ms の
// 塊より細かい。狙いの溜まり（ET_LINK_TARGET_FRAMES = 1024 ＝ 21.3ms）から見れば
// 1 割で、**遅れそのものは増えない**（読み位置は書き位置から狙いのぶん
// 下げて置き直すので、ポンプのゆらぎで動くのは谷の深さだけ）。
// **戻すときはここ。**深くなったかどうかは Diagnostics の Ran dry と
// Extension link（1024 のままか 2048 へ逃げたか）に出る。
#define RX_WAIT_NS          (20ull * NSEC_PER_MSEC)
#define RX_WAIT_LEEWAY_NS   (20ull * NSEC_PER_MSEC)
#define RX_LIVE_NS          (1ull * NSEC_PER_MSEC)
#define RX_LIVE_LEEWAY_NS   (1ull * NSEC_PER_MSEC)

@implementation ETLinkReceiver {
    int _listenFd;
    int _peerFd;
    dispatch_queue_t _q;
    dispatch_source_t _timer;
    float *_ring;
    _Atomic uint64_t _w;
    uint64_t _r;
    // 受信したバイトをそのまま溜める。float に切り出すのは境界が揃ってから。
    uint8_t *_rxBuf;
    size_t _rxLen;
    uint64_t _badSamples;
    // いまタイマーに入れてある周期が「相手が居る側」か。
    BOOL _timedLive;
}

+ (ETLinkReceiver *)shared {
    static ETLinkReceiver *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[ETLinkReceiver alloc] init]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _listenFd = -1;
        _peerFd = -1;
        _q = dispatch_queue_create("ai.nemut.effetune.link.recv", DISPATCH_QUEUE_SERIAL);
        _ring = calloc(ET_LINK_RECV_RING_SAMPLES, sizeof(float));
        _rxBuf = calloc(1, ET_LINK_RX_BUF_BYTES);
    }
    return self;
}

- (BOOL)listening { return _listenFd >= 0; }
- (BOOL)hasPeer   { return _peerFd >= 0; }

/// 溜まりの方針が持つ状態（狙い 1024 / 2048、枯れ・切り詰めの数、溜め直し）。
/// 数と閾値の意味は ETLinkCodec.h。受け手は 1 つしか無いのでプロセスに 1 組。
/// 書くのは音のスレッド（readInterleaved）と繋ぎ直し（resetLinkState）だけ。
static ETLinkJitter gJitter = ET_LINK_JITTER_INIT;

+ (uint32_t)targetFrames { return atomic_load_explicit(&gJitter.target, memory_order_relaxed); }
+ (uint32_t)starveCount  { return atomic_load_explicit(&gJitter.starveCount, memory_order_relaxed); }
+ (uint64_t)starveFrames { return atomic_load_explicit(&gJitter.starveFrames, memory_order_relaxed); }
+ (uint32_t)trimCount    { return atomic_load_explicit(&gJitter.trimCount, memory_order_relaxed); }
+ (uint64_t)trimFrames   { return atomic_load_explicit(&gJitter.trimFrames, memory_order_relaxed); }

/// 繋ぎ直したときに、浅い側から始め直す。
+ (void)resetLinkState {
    ETLinkJitterReset(&gJitter);
}

- (uint32_t)bufferedFrames {
    uint64_t w = atomic_load_explicit(&_w, memory_order_acquire);
    uint64_t r = _r;
    if (w <= r) return 0;
    uint64_t samples = w - r;
    if (samples > ET_LINK_RECV_RING_SAMPLES) samples = ET_LINK_RECV_RING_SAMPLES;
    return (uint32_t)(samples / 2);
}

- (BOOL)start {
    if (_listenFd >= 0) return YES;
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        os_log_error(ETLinkLog(), "receiver socket 失敗 errno=%d", errno);
        return NO;
    }
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

    struct sockaddr_in a;
    memset(&a, 0, sizeof(a));
    a.sin_family = AF_INET;
    a.sin_port = htons(ET_LINK_PORT);
    inet_pton(AF_INET, ET_LINK_HOST, &a.sin_addr);

    if (bind(fd, (struct sockaddr *)&a, sizeof(a)) != 0) {
        os_log_error(ETLinkLog(), "bind 失敗 errno=%d", errno);
        close(fd);
        return NO;
    }
    if (listen(fd, 1) != 0) {
        os_log_error(ETLinkLog(), "listen 失敗 errno=%d", errno);
        close(fd);
        return NO;
    }
    int fl = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, fl | O_NONBLOCK);
    _listenFd = fd;
    _rxLen = 0;
    os_log_error(ETLinkLog(), "ET receiver 待ち受け開始 port=%d", ET_LINK_PORT);

    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _q);
    // まだ相手が居ないので遅い側から始める。受けた時点で pump が 1ms へ上げる。
    _timedLive = NO;
    dispatch_source_set_timer(_timer, DISPATCH_TIME_NOW, RX_WAIT_NS, RX_WAIT_LEEWAY_NS);
    __weak typeof(self) weak = self;
    dispatch_source_set_event_handler(_timer, ^{ [weak pump]; });
    dispatch_resume(_timer);
    return YES;
}

/// いまの相手の有無に合う周期をタイマーへ入れ直す。**同じなら何もしない。**
/// 呼ぶのは _q の上（pump の中）だけ。
- (void)retimePump {
    BOOL live = (_peerFd >= 0);
    if (live == _timedLive) return;
    dispatch_source_t t = _timer;
    if (!t) return;
    _timedLive = live;
    uint64_t every  = live ? RX_LIVE_NS : RX_WAIT_NS;
    uint64_t leeway = live ? RX_LIVE_LEEWAY_NS : RX_WAIT_LEEWAY_NS;
    dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, (int64_t)every),
                              every, leeway);
}

- (void)stop {
    if (_timer) { dispatch_source_cancel(_timer); _timer = nil; }
    dispatch_async(_q, ^{
        if (self->_peerFd >= 0) { close(self->_peerFd); self->_peerFd = -1; }
        if (self->_listenFd >= 0) { close(self->_listenFd); self->_listenFd = -1; }
        self->_rxLen = 0;
    });
}

/// チャンク本体をリングへ写す。
/// 非有限値は ETLinkRingWrite が 0 に置き換えて数を返す（NaN を 1 つ通すと
/// IIR の状態が戻らなくなるので落とす。黙って埋めると原因が見えないので数える）。
- (void)writeSamples:(const uint8_t *)bytes count:(uint32_t)count {
    uint64_t w = atomic_load_explicit(&_w, memory_order_relaxed);
    uint64_t badBefore = _badSamples;
    _badSamples += ETLinkRingWrite(_ring, ET_LINK_RECV_RING_SAMPLES, w, bytes, count);
    atomic_store_explicit(&_w, w + count, memory_order_release);
    _receivedFrames += count / 2;

    // ここで出さないと、同期ずれを伴わない非有限値（送り手側で既に壊れている音）が
    // 黙って 0 に置き換わる。consume 側の bad= は同期ずれが起きたときしか通らない。
    if (_badSamples > badBefore) {
        static int logged = 0;
        if (logged++ < 20) {
            os_log_error(ETLinkLog(), "ET 非有限値 %llu 個を 0 にした 累計=%llu",
                         (unsigned long long)(_badSamples - badBefore),
                         (unsigned long long)_badSamples);
        }
    }
}

/// ETLinkConsume が取り出したチャンクを受ける。ctx は ETLinkReceiver。
static void ETLinkReceiverTakeChunk(void *ctx, const uint8_t *payload, uint32_t count) {
    [(__bridge ETLinkReceiver *)ctx writeSamples:payload count:count];
}

/// 溜めたバイト列から取り出せるチャンクを全部取り出し、残りを先頭へ寄せる。
/// ヘッダが揃わない端数・本体が届いていないチャンクはそのまま次の recv へ持ち越す。
/// ヘッダの検算と 1 バイトずつの再同期は ETLinkConsume の中。
- (void)consume {
    size_t skipped = ETLinkConsume(_rxBuf, &_rxLen, ETLinkReceiverTakeChunk, (__bridge void *)self);
    if (skipped > 0) {
        static int logged = 0;
        if (logged++ < 20) {
            os_log_error(ETLinkLog(), "ET 同期ずれ %zu バイト読み飛ばし bad=%llu",
                         skipped, (unsigned long long)_badSamples);
        }
    }
}

- (void)pump {
    if (_listenFd < 0) return;
    // 前の回で切れていたらここで遅い側へ戻る。続いていれば何もしない。
    [self retimePump];
    if (_peerFd < 0) {
        int c = accept(_listenFd, NULL, NULL);
        if (c >= 0) {
            int fl = fcntl(c, F_GETFL, 0);
            fcntl(c, F_SETFL, fl | O_NONBLOCK);
            _peerFd = c;
            _rxLen = 0;     // 前の相手の書きかけを新しいストリームに混ぜない
            // **浅い側から始め直す。**前の相手で枯れて深くしたぶんを
            // 引き継ぐと、一度の混み合いで遅れが増えたまま固定される。
            [ETLinkReceiver resetLinkState];
            [self retimePump];  // 受けた。次の回から 1ms
            os_log_error(ETLinkLog(), "ET 接続を受けた");
        }
        return;
    }
    for (int pass = 0; pass < 8; pass++) {
        // consume の後は必ず 1 チャンク未満しか残らないので空きはあるが、
        // 長さ 0 の recv は戻り値 0（＝切断）と区別できないので念のため止める。
        if (_rxLen >= ET_LINK_RX_BUF_BYTES) return;
        ssize_t n = recv(_peerFd, _rxBuf + _rxLen, ET_LINK_RX_BUF_BYTES - _rxLen, 0);
        if (n == 0) {
            os_log(ETLinkLog(), "相手が切断した");
            close(_peerFd); _peerFd = -1;
            _rxLen = 0;
            return;
        }
        if (n < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) return;
            os_log_error(ETLinkLog(), "recv 失敗 errno=%d", errno);
            close(_peerFd); _peerFd = -1;
            _rxLen = 0;
            return;
        }
        // n は 4 の倍数とは限らない。端数は _rxBuf に残したまま次の recv と繋ぐ。
        _rxLen += (size_t)n;
        [self consume];
    }
}

- (uint32_t)readInterleaved:(float *)out frames:(uint32_t)frames {
    uint64_t w = atomic_load_explicit(&_w, memory_order_acquire);
    uint64_t r = _r;
    // 貼り直し・溜まりすぎの切り詰め・溜め直し・枯れの数え方・2048 への逃げは
    // ETLinkJitterRead の中（説明もそちら）。ここは状態を渡してログを書くだけ。
    //
    // **鳴る前の空回りは枯れではない。**相手が居るかと受信済みのフレーム数を渡すのは
    // そのため（相手が繋がる前も音のコールバックは回っていて、毎枠足りない）。
    ETLinkStarve starve;
    uint32_t got = ETLinkJitterRead(&gJitter, _ring, ET_LINK_RECV_RING_SAMPLES, w, &r,
                                    out, frames, _peerFd >= 0, _receivedFrames, &starve);
    if (starve.counted) {
        // **最初の何回かだけ書き出す。**毎枠出すと洪水になって、
        // 肝心の間隔が読めなくなる。頻度は Diagnostics の数で見る。
        static int logged = 0;
        if (logged++ < 40) {
            os_log_error(ETLinkLog(),
                         "ET 枯れ 埋め=%u/%u 溜まり=%llu 狙い=%u 受信=%llu 連=%u",
                         starve.filledFrames, starve.wantFrames,
                         (unsigned long long)starve.bufferedFrames,
                         starve.target,
                         (unsigned long long)_receivedFrames,
                         starve.runBefore + 1);
        }
    }
    _r = r;
    return got;
}

@end
