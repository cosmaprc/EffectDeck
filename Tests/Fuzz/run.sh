#!/usr/bin/env bash
# Tests/Fuzz/run.sh
# 外から来る字を読むコードを libFuzzer で叩く（Linux・WSL・CI）。Mac は要らない。
#
#   wsl bash Tests/Fuzz/run.sh [--name <名前>] [--target <的>[,<的>...]|all] [--time <秒>]
#                              [--clean] [--build-only] [--repro <入力のファイル>] [-- <libFuzzerへ>]
#
#   --name      写し先 ~/.cache/effectdeck-fuzz/<名前>/、ログ build/fuzz-<名前>-<的>.log、
#               落ちた入力 build/fuzz/<名前>/<的>/crash-*。並べて走らせるときは別の名前にする
#   --target    的（下の一覧）。既定は all
#   --time      的 1 つあたりの秒数（-max_total_time）。既定 60。CI は 20〜30 で足りる
#   --clean     写し先の .build と育てた corpus を消してから
#   --build-only 建てて種を書くところまで
#   --repro     1 つの入力を的に 1 度だけ通す（落ちた入力の再現。--target は 1 つだけ）
#
# 的（Swift は 1 本の実行ファイル EffectDeckFuzz で、ET_FUZZ_TARGET が選ぶ）:
#   chaintext    貼られた字から鎖を探して直す（ETChainText.json(from:) → prepare）
#   sharelink    鎖のリンク・貼られた字を読んで書き戻す（ETShareLink.parseChecked）
#   fxdlink      開かれた URL の振り分けと /j#… の JSFX（ETFXDLink）
#   pipelineform prepare を通らずに読む口（PipelineStore.parse、ETBackup.read）
#   peqtext      15Band PEQ の Import（ETPEQTextImport）
#   remotefile   貼られたリンクの読み替えと gist の名前選び（ETRemoteFile）
#   jsfxtext     JSFX の囲い・desc:/author:・付け替えの表（ETCodeBlock、JSFXReplace、ETJSFXLoader）
#   irprep       IR Reverb の下ごしらえ（ETIRPreparation）
#   jsfxgate     C++ の JSFX ソースの門（ETJSFXHost.cpp。Tests/Fuzz/Native）
#
# 何を建てるかは Linux の単体テストと同じ（project.yml、Tests/Fuzz/make_package.py）。
# 種は 3 か所から: Tests/Fuzz/Corpus/<的>（手で書いたもの）、リポジトリの見本（下の seed_files）、
# カタログから作るもの（Harness/Seeds.swift）。育った corpus は写し先に残り、次の回が続きから回る。
# 落ちたら終了値 1。ログの "fuzz oracle:" か ASan / Swift の止めの行が理由。
# 要るもの: swift（swiftly でもよい。-sanitize=fuzzer は Linux のツールチェーンに入っている）、python3。
# Windows の Git Bash から呼ぶときは MSYS_NO_PATHCONV=1 を付ける。
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "$here/../.." && pwd)

all_targets=(chaintext sharelink fxdlink pipelineform peqtext remotefile jsfxtext irprep jsfxgate)
name=default
targets=all
seconds=60
clean=0
build_only=0
repro=
passthrough=()

usage() { sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
die() { echo "run.sh: $*" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case $1 in
    --name) [ $# -ge 2 ] || die "--name に値が無い"; name=$2; shift 2 ;;
    --name=*) name=${1#*=}; shift ;;
    --target) [ $# -ge 2 ] || die "--target に値が無い"; targets=$2; shift 2 ;;
    --target=*) targets=${1#*=}; shift ;;
    --time) [ $# -ge 2 ] || die "--time に値が無い"; seconds=$2; shift 2 ;;
    --time=*) seconds=${1#*=}; shift ;;
    --clean) clean=1; shift ;;
    --build-only) build_only=1; shift ;;
    --repro) [ $# -ge 2 ] || die "--repro に値が無い"; repro=$2; shift 2 ;;
    --repro=*) repro=${1#*=}; shift ;;
    --) shift; passthrough=("$@"); break ;;
    -h|--help) usage; exit 0 ;;
    *) die "知らない引数: $1（--help）" ;;
  esac
done
[[ $name =~ ^[A-Za-z0-9._-]+$ ]] || die "--name は英数字と . _ - だけ: $name"
[[ $seconds =~ ^[0-9]+$ ]] || die "--time は秒の整数: $seconds"
if [ "$targets" = all ]; then
  selected=("${all_targets[@]}")
else
  IFS=, read -r -a selected <<< "$targets"
  for t in "${selected[@]}"; do
    [[ " ${all_targets[*]} " == *" $t "* ]] || die "知らない的: $t（${all_targets[*]}）"
  done
fi
if [ -n "$repro" ]; then
  [ ${#selected[@]} -eq 1 ] || die "--repro は --target を 1 つだけ"
  [ -f "$repro" ] || die "--repro のファイルが無い: $repro"
  repro=$(cd "$(dirname "$repro")" && pwd)/$(basename "$repro")
fi

if ! command -v swift >/dev/null 2>&1; then
  for env in "${SWIFTLY_HOME_DIR:-$HOME/.local/share/swiftly}/env.sh" "$HOME/.swiftly/env.sh"; do
    # shellcheck disable=SC1090
    if [ -f "$env" ]; then . "$env"; break; fi
  done
fi
command -v swift >/dev/null 2>&1 || die "swift が無い"
command -v python3 >/dev/null 2>&1 || die "python3 が無い"

work="${EFFECTDECK_FUZZ_CACHE:-$HOME/.cache/effectdeck-fuzz}/$name"
out="$repo/build/fuzz/$name"
mkdir -p "$work" "$out"
if [ "$clean" = 1 ]; then rm -rf "$work/.build" "$work/corpus" "$work/seeds" "$work/native"; fi

# LinuxのFoundationは自前で漏らす（NSRegularExpression・Bundle）。漏れで毎回止まらないよう切る。
export ASAN_OPTIONS="${ASAN_OPTIONS:-detect_leaks=0:allocator_may_return_null=1}"
export UBSAN_OPTIONS="${UBSAN_OPTIONS:-print_stacktrace=1:halt_on_error=1}"
# Swift の止め（fatalError・範囲の外）のあとに走る backtracer は、ASan の下では自分の読み出しで
# "unknown-crash" を重ねて出し、1 回に数分かかる。止めの行（Fatal error: …）は先に出るので切る。
# libFuzzer は落ちた入力をそのまま残す。
export SWIFT_BACKTRACE="${SWIFT_BACKTRACE:-enable=no}"

build_log="$repo/build/fuzz-$name-build.log"
swift_needed=0
native_needed=0
for t in "${selected[@]}"; do
  if [ "$t" = jsfxgate ]; then native_needed=1; else swift_needed=1; fi
done

{
  echo "== fuzz run.sh --name $name  $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "== repo $repo  HEAD $(git -C "$repo" rev-parse --short HEAD 2>/dev/null || echo '?')"
  echo "== $(swift --version 2>&1 | head -1)"
  echo "== work $work  targets ${selected[*]}  time ${seconds}s"
} > "$build_log"

bin=
if [ "$swift_needed" = 1 ]; then
  # 失敗の行を出してから止めるため、パイプの間だけ -e を外す（-e のままだと tee の行で黙って抜ける）。
  set +e
  python3 "$here/make_package.py" --repo "$repo" --out "$work" 2>&1 | tee -a "$build_log"
  status=${PIPESTATUS[0]}
  set -e
  [ "$status" = 0 ] || { echo "== make_package failed ($status). log $build_log"; exit "$status"; }
  # -parse-as-library: main は libFuzzer が持つ。-sanitize=fuzzer は計測（edge・比較の値）と
  # libFuzzer のリンクの両方。address で配列の外・解放済みを拾う。
  # **release（-O、WMO）で建てる。**debug の 10〜50 倍回る。WSL で約 5 分・約 700 MB。
  # Swift の範囲・溢れの止めは -O でも残る（-Ounchecked ではない）。
  set +e
  swift build --package-path "$work" -c release -j "${FUZZ_JOBS:-2}" \
    -Xswiftc -sanitize=fuzzer,address -Xswiftc -parse-as-library 2>&1 | tee -a "$build_log"
  status=${PIPESTATUS[0]}
  set -e
  [ "$status" = 0 ] || { echo "== build failed ($status). log $build_log"; exit "$status"; }
  bin="$(swift build --package-path "$work" -c release --show-bin-path)/EffectDeckFuzz"
  [ -x "$bin" ] || die "実行ファイルが無い: $bin"
fi

gate=
if [ "$native_needed" = 1 ]; then
  cxx=$(command -v clang++ || true)
  [ -n "$cxx" ] || die "clang++ が無い（swiftly のツールチェーンに入っている）"
  mkdir -p "$work/native"
  gate="$work/native/jsfx_source_gate"
  # ysfx は宣言だけ使う（門は呼ばない）。未定義の参照はリンクで無視させる（jsfx_source_gate.cpp の頭）。
  set +e
  "$cxx" -std=c++20 -g -O1 -fsanitize=fuzzer,address,undefined -fno-sanitize-recover=all \
    -I "$repo/Sources/Shared" -I "$repo/Vendor/ysfx/include" \
    -I "$repo/Vendor/ysfx/thirdparty/WDL/source" \
    "$here/Native/jsfx_source_gate.cpp" -o "$gate" \
    -Wl,--unresolved-symbols=ignore-all 2>&1 | tee -a "$build_log"
  status=${PIPESTATUS[0]}
  set -e
  [ "$status" = 0 ] || { echo "== native build failed ($status). log $build_log"; exit "$status"; }
fi

# 的ごとの見本（リポジトリにあるもの）。ファイルでもフォルダでもよい。
seed_files() {
  case $1 in
    chaintext|sharelink) echo "$repo/CHAIN.md"; ls "$repo"/chain/v*/*.md 2>/dev/null || true ;;
    fxdlink) echo "$repo/site/test-vector.json" ;;
    jsfxtext|jsfxgate) ls "$repo"/Tests/Fixtures/JSFX/*.jsfx ;;
    *) ;;
  esac
}
dict_for() {
  case $1 in
    chaintext|sharelink|pipelineform) echo "$here/Dict/json.dict" ;;
    fxdlink) echo "$here/Dict/fxd.dict" ;;
    peqtext) echo "$here/Dict/peq.dict" ;;
    remotefile) echo "$here/Dict/remote.dict" ;;
    jsfxtext|jsfxgate) echo "$here/Dict/jsfx.dict" ;;
    *) ;;
  esac
}
max_len() {
  case $1 in
    irprep) echo 20000 ;;
    chaintext|sharelink|jsfxgate) echo 16384 ;;
    *) echo 8192 ;;
  esac
}

failed=()
summary=()
for t in "${selected[@]}"; do
  log="$repo/build/fuzz-$name-$t.log"
  corpus="$work/corpus/$t"
  seeds="$work/seeds/$t"
  artifacts="$out/$t/"
  mkdir -p "$corpus" "$artifacts"
  rm -rf "$seeds"; mkdir -p "$seeds"
  if [ -d "$here/Corpus/$t" ]; then cp -R "$here/Corpus/$t/." "$seeds/"; fi
  while IFS= read -r f; do
    [ -n "$f" ] && [ -f "$f" ] && cp "$f" "$seeds/seed-$(basename "$f")"
  done < <(seed_files "$t")

  if [ "$t" = jsfxgate ]; then
    cmd=("$gate")
  else
    cmd=("$bin")
    export ET_FUZZ_TARGET=$t
    ET_FUZZ_SEEDS_OUT="$seeds/gen" "$bin" >/dev/null
  fi
  dict=$(dict_for "$t")
  args=(-max_len="$(max_len "$t")" -timeout=20 -rss_limit_mb=3072 -print_final_stats=1
        -artifact_prefix="$artifacts")
  if [ -n "$dict" ] && [ -f "$dict" ]; then args+=(-dict="$dict"); fi

  echo "== $t" | tee "$log"
  set +e
  if [ -n "$repro" ]; then
    "${cmd[@]}" "${args[@]}" "${passthrough[@]}" "$repro" 2>&1 | tee -a "$log"
  elif [ "$build_only" = 1 ]; then
    echo "== build-only: seeds $(find "$seeds" -type f | wc -l)" | tee -a "$log"
    (exit 0)
  else
    "${cmd[@]}" "${args[@]}" -max_total_time="$seconds" "${passthrough[@]}" \
      "$corpus" "$seeds" 2>&1 | tee -a "$log"
  fi
  status=${PIPESTATUS[0]}
  set -e
  execs=$(grep -Eo "stat::number_of_executed_units: *[0-9]+" "$log" | grep -Eo "[0-9]+$" | tail -1 || true)
  cov=$(grep -Eo "cov: [0-9]+" "$log" | tail -1 || true)
  line="$t: exit $status, runs ${execs:-?}, ${cov:-cov ?}, corpus $(find "$corpus" -type f | wc -l)"
  summary+=("$line")
  if [ "$status" != 0 ]; then failed+=("$t"); fi
done

for s in "${summary[@]}"; do echo "== FUZZ $s" | tee -a "$build_log"; done
if [ ${#failed[@]} -gt 0 ]; then
  echo "== FUZZ failed: ${failed[*]}  (inputs in $out/<target>/, logs build/fuzz-$name-<target>.log)" \
    | tee -a "$build_log"
  exit 1
fi
echo "== FUZZ ok: ${selected[*]}" | tee -a "$build_log"
