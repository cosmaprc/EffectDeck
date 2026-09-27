#!/bin/bash
# 配布用の書庫を作る。
#
#   bash Scripts/archive.sh                            紫（TestFlight 行き。ET_BETA）
#   bash Scripts/archive.sh EffeTuneLive EffeTuneLive  青（店へ出す版）
#
# 先に Scripts/setup.sh を通す（パッチ・カタログ・プリセット・note-models・版・プロジェクト）。
# 前は gen_version と xcodegen しか走らせず、書庫が正しいかは、前のビルドが木を
# 整えていたかどうか次第だった。
#
# 書庫は $ARCHIVE_DIR/<scheme>.xcarchive（既定 /tmp。Scripts/ship.sh と archive_install.sh、
# Mac の ~/gui_ship.sh がそこを読む）。前の書庫は**真っ先に**消す（setup.sh より前）。
# 残っていると、setup.sh や書庫で落ちても古い書庫が書き出されたり実機に入ったりする。
#
# 全部 archive.log へ。判定は "ARCHIVE SUCCEEDED" の行と、このスクリプトの終了値。
set -u
export PATH="/opt/homebrew/bin:$PATH"
cd "$(dirname "$0")/.." || exit 1
. Scripts/asc_auth.sh || exit 1   # PROVISIONING（API キー）。画面ロック中の "No Accounts" よけ
SCHEME="${1:-EffeTuneLive}"
# アイコン。**既定は紫**（EffectDeckPublicBeta）。ここから出る書庫は TestFlight 行きで、
# 端末で青と紫を見分けられると、いまどちらを触っているか分かる。
#
# 店へ出すときだけ第 2 引数に EffeTuneLive を渡して青にする。
# 起動時に setAlternateIconName で差し替える形にしないのは、系が毎回
# 「アイコンを変えました」の確認を出すから。
APPICON="${2:-EffectDeckPublicBeta}"
# **アイコンと中身を 1 つの引数で決める。**別々にすると噛み合わなくなる
# （紫なのに JSFX が無い形を一度作った）。
# ベータ側だけ ET_BETA を立てる。いま ET_BETA で変わるのは同梱の JSFX の見本
# （ETJSFXHost.showsBundledSamples）だけ。見本を.appに積むかも同じ値で決まる
# （Scripts/embed_debug_jsfx.shがこの変数を読む）。JSFX 本体は店の版でも開いている
# （ETJSFXHost.isEnabled）。店に出さない機能を足すときはここで開ける。
if [ "$APPICON" = "EffectDeckPublicBeta" ]; then
  SWIFT_FLAGS='$(inherited) ET_BETA'
else
  SWIFT_FLAGS='$(inherited)'
fi
LOG="$PWD/archive.log"
ARCHIVE="${ARCHIVE_DIR:-/tmp}/$SCHEME.xcarchive"
# xcodebuild は名指し。ET_XCODEBUILD は Tests/Scripts/sim_test.sh が偽物を渡すための口。
XCODEBUILD="${ET_XCODEBUILD:-/usr/bin/xcodebuild}"

main() {
  echo "=== start $(date) === icon=$APPICON"
  rm -rf "$ARCHIVE"
  # setup.sh が gen_version と xcodegen（project.yml）まで走らせる。
  bash Scripts/setup.sh || { echo "!! Scripts/setup.sh が落ちた。書庫は作らない"; return 1; }
  "$XCODEBUILD" -project EffeTuneLive.xcodeproj -scheme "$SCHEME" \
    -configuration Release -sdk iphoneos -arch arm64 "${PROVISIONING[@]}" \
    ET_APPICON="$APPICON" \
    SWIFT_ACTIVE_COMPILATION_CONDITIONS="$SWIFT_FLAGS" \
    archive -archivePath "$ARCHIVE" 2>&1 \
    | grep -E "error:|ARCHIVE SUCCEEDED|ARCHIVE FAILED|errSec" | tail -10
  local code="${PIPESTATUS[0]}"
  [ "$code" -eq 0 ] || { echo "!! xcodebuild archive が落ちた (exit $code)"; return 1; }
  echo "書庫: $ARCHIVE"
  echo "=== done $(date) ==="
  return 0
}

main > "$LOG" 2>&1
CODE=$?
echo "FINISHED: $LOG (exit=$CODE)"
exit "$CODE"
