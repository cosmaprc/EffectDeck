//  ETCaptureRing.m
//  読み方は ETLinkReceiver.readInterleaved と同じ（貼り直し・切り詰め・溜め直しは
//  ETLinkJitterRead の中）。違うのは、書き手がソケットではなく
//  ScreenCaptureKit のサンプルキューで、溜まりの方針の状態を別に持つ点。

#import "ETCaptureRing.h"
#import "ETLinkCodec.h"
#import <stdatomic.h>
#import <stdlib.h>

/// 取り込み専用の溜まりの方針。ETLinkReceiver の gJitter とは別物。
/// 書くのは音のスレッド（readInterleaved）と取り込みの開始（beginCapture）だけ。
static ETLinkJitter gCaptureJitter = ET_LINK_JITTER_INIT;

@implementation ETCaptureRing {
    float *_ring;
    _Atomic uint64_t _w;        // 書くのはサンプルキューだけ（単位はサンプル）
    uint64_t _r;                // 音のスレッドだけが読み書きする
    _Atomic uint64_t _pushed;   // 積んだフレームの累計
    _Atomic uint64_t _base;     // 今回の取り込みを始めた時点の _pushed
    _Atomic bool _capturing;
    _Atomic bool _useCapture;
}

+ (ETCaptureRing *)shared {
    static ETCaptureRing *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[ETCaptureRing alloc] init]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _ring = calloc(ET_LINK_RECV_RING_SAMPLES, sizeof(float));
    }
    return self;
}

- (BOOL)useCapture { return atomic_load_explicit(&_useCapture, memory_order_relaxed); }
- (void)setUseCapture:(BOOL)v { atomic_store_explicit(&_useCapture, v, memory_order_relaxed); }

- (BOOL)capturing { return atomic_load_explicit(&_capturing, memory_order_acquire); }
- (void)setCapturing:(BOOL)v { atomic_store_explicit(&_capturing, v, memory_order_release); }

- (uint64_t)receivedFrames {
    uint64_t total = atomic_load_explicit(&_pushed, memory_order_relaxed);
    uint64_t base = atomic_load_explicit(&_base, memory_order_relaxed);
    return total > base ? total - base : 0;
}

- (uint32_t)bufferedFrames {
    uint64_t w = atomic_load_explicit(&_w, memory_order_acquire);
    uint64_t r = _r;
    if (w <= r) return 0;
    uint64_t samples = w - r;
    if (samples > ET_LINK_RECV_RING_SAMPLES) samples = ET_LINK_RECV_RING_SAMPLES;
    return (uint32_t)(samples / 2);
}

- (void)beginCapture {
    // **浅い側から始め直す。**前の取り込みで枯れて深くしたぶんを引き継がない。
    ETLinkJitterReset(&gCaptureJitter);
    atomic_store_explicit(&_base, atomic_load_explicit(&_pushed, memory_order_relaxed),
                          memory_order_relaxed);
    atomic_store_explicit(&_capturing, true, memory_order_release);
}

- (void)endCapture {
    atomic_store_explicit(&_capturing, false, memory_order_release);
}

- (void)pushInterleaved:(const float *)samples frames:(uint32_t)frames {
    if (!samples || frames == 0) return;
    uint64_t w = atomic_load_explicit(&_w, memory_order_relaxed);
    w = ETLinkRingPush(_ring, ET_LINK_RECV_RING_SAMPLES, w, samples, frames, 2);
    atomic_store_explicit(&_w, w, memory_order_release);
    atomic_fetch_add_explicit(&_pushed, frames, memory_order_relaxed);
}

- (uint32_t)readInterleaved:(float *)out frames:(uint32_t)frames {
    uint64_t w = atomic_load_explicit(&_w, memory_order_acquire);
    uint64_t r = _r;
    uint64_t total = atomic_load_explicit(&_pushed, memory_order_relaxed);
    uint64_t base = atomic_load_explicit(&_base, memory_order_relaxed);
    // 開始の直後に古い累計が見えても、桁あふれで「鳴っている」にしない。
    uint64_t received = total > base ? total - base : 0;
    bool has = atomic_load_explicit(&_capturing, memory_order_acquire);
    uint32_t got = ETLinkJitterRead(&gCaptureJitter, _ring, ET_LINK_RECV_RING_SAMPLES, w, &r,
                                    out, frames, has, received, NULL);
    _r = r;
    return got;
}

@end
