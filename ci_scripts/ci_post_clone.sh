#!/bin/bash
# Xcode Cloud の clone 直後に走る。新しい clone で、ローカルの普通のビルドと同じ準備をする。
#
#   .xcodeproj は追跡していない（project.yml が正）。ここで Scripts/setup.sh を通して組む。
#   **ビルドの手順を別に持たない。**パッチ・生成物・版・xcodegen は Scripts/setup.sh がやる。
#   このファイルがやるのは、setup.sh が前提にするもの（submodule・道具）を揃えることだけ。
#
# 道具の版は .github/workflows/ci.yml と canary.yml に合わせる（Tests/Tools/test_ci_scripts.py が照合する）。
#   xcodegen  2.46.0（sha256 を確かめて入れる）
#   node      22（ET_STRICT=1 の gen_effect_presets.py が要る）
#   python3   3.10 以降（macOS 付属の 3.9 では embed_models.py が動かない）
#
# 配布まわりの前提（Xcode Cloud 側の設定。ここでは触らない）:
#   Beta は scheme "EffectDeck Beta"（Archive は構成 Beta＝紫・ET_BETA）、
#   店は scheme EffeTuneLive（Archive は構成 Release＝青）。どちらも project.yml の定義。
set -euo pipefail

REPO="${CI_PRIMARY_REPOSITORY_PATH:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$REPO"
echo "=== ci_post_clone: $REPO ==="
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_ENV_HINTS=1

# ---- submodule ---------------------------------------------------------------
# ci.yml と同じ取り方。**--recursive は付けない**（ysfx の中の submodule は使わない）。
# effetune は履歴ごと（blob:none）。gen_version.py が dsp-v* のタグを引き、
# ET_STRICT=1 では浅い clone を拒む。ysfx は浅くてよい（setup.sh が固定した版を確かめる）。
git submodule update --init --filter=blob:none Vendor/effetune
if [ "$(git -C Vendor/effetune rev-parse --is-shallow-repository)" = true ]; then
  git -C Vendor/effetune fetch --unshallow --filter=blob:none --tags origin
fi
git -C Vendor/effetune fetch --tags --filter=blob:none origin || true
git submodule update --init --depth 1 Vendor/ysfx
git submodule status

# ---- xcodegen（版を固定し sha256 を確かめる） -----------------------------------
XCODEGEN_VERSION=2.46.0
XCODEGEN_SHA256=4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806
TOOLS="$(mktemp -d)"
curl -fsSL --retry 3 -o "$TOOLS/xcodegen.zip" \
  "https://github.com/yonaskolb/XcodeGen/releases/download/$XCODEGEN_VERSION/xcodegen.zip"
echo "$XCODEGEN_SHA256  $TOOLS/xcodegen.zip" | shasum -a 256 -c -
unzip -q "$TOOLS/xcodegen.zip" -d "$TOOLS"
export XCODEGEN="$TOOLS/xcodegen/bin/xcodegen"
"$XCODEGEN" --version

# ---- node 22 と python3（Homebrew） ---------------------------------------------
BREW_PREFIX="$(brew --prefix)"
brew list --versions node@22 >/dev/null 2>&1 || brew install node@22
brew list --versions python3 >/dev/null 2>&1 || brew install python3
# Scripts/setup.sh は PATH の先頭に $BREW_PREFIX/bin を足す。そこから見える node が 22 でなければ
# 22 を繋ぎ直す（keg-only なので、何も繋がっていないときは PATH の後ろの node@22 が効く）。
export PATH="$BREW_PREFIX/opt/node@22/bin:$BREW_PREFIX/bin:$PATH"
if ! PATH="$BREW_PREFIX/bin:$PATH" node --version | grep -q '^v22\.'; then
  brew unlink node >/dev/null 2>&1 || true
  brew link --force --overwrite node@22
fi
SETUP_PATH="$BREW_PREFIX/bin:$PATH"
PATH="$SETUP_PATH" node --version | grep -q '^v22\.' || { echo "!! node 22 が PATH に無い"; exit 1; }
PATH="$SETUP_PATH" python3 -c 'import sys; sys.exit(sys.version_info < (3, 10))' \
  || { echo "!! python3 が 3.10 未満: $(PATH="$SETUP_PATH" python3 --version)"; exit 1; }
echo "node $(PATH="$SETUP_PATH" node --version) / $(PATH="$SETUP_PATH" python3 --version)"

# ---- 生成物と .xcodeproj（ローカルと同じ Scripts/setup.sh） -----------------------
ET_STRICT=1 bash Scripts/setup.sh

test -d EffeTuneLive.xcodeproj || { echo "!! EffeTuneLive.xcodeproj ができていない"; exit 1; }
echo "=== ci_post_clone: done ==="
