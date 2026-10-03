#!/bin/bash
# 配布用の書庫を作る。
#
#   bash Scripts/archive.sh                            紫（-configuration Beta。TestFlight 行き。ET_BETA）
#   bash Scripts/archive.sh EffeTuneLive EffeTuneLive  青（-configuration Release。店へ出す版）
#   CONFIG=Release bash Scripts/archive.sh             同上（構成名で直接選ぶ）
#
# ローカルの非常用。ふだんの配布は Xcode Cloud（ci_scripts/ci_post_clone.sh と
# scheme "EffectDeck Beta"〈Archive は Beta〉・EffeTuneLive〈Archive は Release〉）。
# どちらも project.yml の同じ構成を読む。
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
# ビルド構成で決める。**アイコンと ET_BETA は project.yml の構成（Beta / Release）が持つ**
# ので、ここでは構成名を選ぶだけ。Xcode Cloud もローカルも同じ定義を読む。
#   Beta     紫（EffectDeckPublicBeta）＋ ET_BETA。TestFlight 行き。**既定**。
#            端末で青と紫を見分けられると、いまどちらを触っているか分かる。
#   Release  青（EffeTuneLive）。店へ出す版。
# 選び方は環境変数 CONFIG=Beta|Release、または第 2 引数（従来のアイコン名）。
#   EffectDeckPublicBeta -> Beta、EffeTuneLive -> Release。それ以外は xcodebuild を呼ばずに落とす。
# 起動時に setAlternateIconName で差し替える形にしないのは、系が毎回
# 「アイコンを変えました」の確認を出すから。
# いま ET_BETA で変わるのは同梱の JSFX の見本（ETJSFXHost.showsBundledSamples）だけ。
# 見本を .app に積むかも同じ構成で決まる（Scripts/embed_debug_jsfx.sh が
# SWIFT_ACTIVE_COMPILATION_CONDITIONS を読む）。JSFX 本体は店の版でも開いている
# （ETJSFXHost.isEnabled）。店に出さない機能を足すときは Beta 構成の側で開ける。
APPICON="${2:-EffectDeckPublicBeta}"
if [ -n "${CONFIG:-}" ]; then
  case "$CONFIG" in
    Beta|Release) ;;
    *) echo "FINISHED: CONFIG は Beta か Release（受け取った値: $CONFIG）。書庫は作らない (exit=2)"; exit 2 ;;
  esac
else
  case "$APPICON" in
    EffectDeckPublicBeta) CONFIG=Beta ;;
    EffeTuneLive)         CONFIG=Release ;;
    *) echo "FINISHED: 第 2 引数は EffectDeckPublicBeta か EffeTuneLive（受け取った値: $APPICON）。書庫は作らない (exit=2)"; exit 2 ;;
  esac
fi
LOG="$PWD/archive.log"
ARCHIVE="${ARCHIVE_DIR:-/tmp}/$SCHEME.xcarchive"
# xcodebuild は名指し。ET_XCODEBUILD は Tests/Scripts/sim_test.sh が偽物を渡すための口。
XCODEBUILD="${ET_XCODEBUILD:-/usr/bin/xcodebuild}"

main() {
  echo "=== start $(date) === config=$CONFIG"
  rm -rf "$ARCHIVE"
  # setup.sh が gen_version と xcodegen（project.yml）まで走らせる。
  bash Scripts/setup.sh || { echo "!! Scripts/setup.sh が落ちた。書庫は作らない"; return 1; }
  "$XCODEBUILD" -project EffeTuneLive.xcodeproj -scheme "$SCHEME" \
    -configuration "$CONFIG" -sdk iphoneos -arch arm64 "${PROVISIONING[@]}" \
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
