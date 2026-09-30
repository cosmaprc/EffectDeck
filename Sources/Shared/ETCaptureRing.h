//  ETCaptureRing.h
//  ScreenCaptureKit で取ったシステム音を、音のスレッドへ渡す輪。**本体だけ**（拡張には入れない）。
//
//  ETLinkReceiver（拡張から TCP で届く音）とは別の輪と別の溜まりの方針を持つ。
//  gJitter を共有すると、片方の枯れ・切り詰めの数と狙い（1024 / 2048）がもう片方へ
//  漏れるので、共有しない。形式は同じ（float32 インターリーブ 2ch 48kHz）。
//
//  書き手は ScreenCaptureKit のサンプルキュー 1 本だけ、読み手は音のスレッドだけ。
//  ETLinkCodec.h は _Atomic の構造体を持つので、この .h からは読み込まない
//  （Swift の橋に入る。LocalLink.h と同じ理由）。

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ETCaptureRing : NSObject
@property (class, readonly) ETCaptureRing *shared;

/// 設定で「Screen Capture」を選んでいるか。音のスレッドが毎回読む。
/// 切り替えでエンジンは組み直さない。
@property (nonatomic) BOOL useCapture;

/// 取り込み中か。beginCapture / endCapture が書く。
/// ETLinkJitterRead の hasPeer に渡す（鳴る前の空回りを枯れと数えないため）。
@property (nonatomic) BOOL capturing;

/// 今回の取り込みが始まってから積んだフレーム数。
@property (nonatomic, readonly) uint64_t receivedFrames;
/// まだ読み出していないフレーム数。そのまま遅延になる。
@property (nonatomic, readonly) uint32_t bufferedFrames;

/// 取り込みの開始。溜まりの方針を浅い側へ戻し、数え直して capturing を立てる。
- (void)beginCapture;
/// 取り込みの終わり。capturing を下ろす。
- (void)endCapture;

/// ScreenCaptureKit のサンプルキューから呼ぶ（書き手は 1 本だけ）。
/// samples は float32 インターリーブ 2ch。frames はフレーム数（サンプル数の半分）。
/// 非有限値は呼ぶ側で 0 にしておくこと（ETLinkRingPush は落とさない）。
- (void)pushInterleaved:(const float *)samples frames:(uint32_t)frames;

/// 音のスレッドから呼ぶ。足りない分は無音で埋める。返すのは実際に読めたフレーム数。
- (uint32_t)readInterleaved:(float *)out frames:(uint32_t)frames;
@end

NS_ASSUME_NONNULL_END
