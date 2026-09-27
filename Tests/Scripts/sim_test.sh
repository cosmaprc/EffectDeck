#!/bin/bash
# Scripts/lib/sim.sh と、それを使う Scripts/*.sh を Mac なしで確かめる。
#
#   bash Tests/Scripts/sim_test.sh
#   SCRIPTS_UNDER_TEST=<dir> bash Tests/Scripts/sim_test.sh   別の版の Scripts/（直す前の赤を見るとき）
#
# xcrun・xcodegen・python3 を PATH の先頭の偽物に差し替える。偽物の simctl list は
# 決めた一覧を返し、どの偽物も呼ばれた引数を calls.log に書く。Scripts/setup.sh も偽物にする。
# Scripts/ は一時ディレクトリへ写して走らせるので、test.log などはそちらに書かれ、
# 作業ツリーは汚れない。Linux の bash でも Mac の /bin/bash 3.2 でも走る形で書く。
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
SRC="${SCRIPTS_UNDER_TEST:-$REPO/Scripts}"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/et-scripts-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

ROOT="$WORK/root"
STUB_DIR="$WORK/stub"
export STUB_DIR
OUTF="$WORK/out.txt"
CALLS="$STUB_DIR/calls.log"

IPAD13=0DCB706C-8169-4EE7-87B1-C2C12C074245
IPAD11=D78EFBC3-8635-4B51-BA79-648FEC435088
OLDIPAD=AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA
CLONE=BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB
WATCH=CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC
UNAVAIL=DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD
P18=4102BEEF-6704-4570-90FC-B9BDEE577469
P17_26=11111111-1111-4111-8111-111111111111
P17_27=9B054D93-0516-4F6E-9B66-8716209F4132

PASS=0
FAIL=0
FAILED=""
ok() { PASS=$((PASS + 1)); echo "ok   $1"; }
ng() { FAIL=$((FAIL + 1)); FAILED="$FAILED $1"; echo "FAIL $1${2:+ -- $2}"; }
has()   { grep -qF -- "$2" "$1"; }
hasnt() { ! grep -qF -- "$2" "$1"; }
# calls.log に simctl list 以外（状態を変えるもの）が 1 行も無いか。
only_reads() { ! grep -v '^xcrun simctl list' "$CALLS" | grep -q .; }

# ---- 偽物 -------------------------------------------------------------------
mkdir -p "$STUB_DIR/bin" "$ROOT/Scripts" "$ROOT/Tools" "$ROOT/Vendor/effetune/dsp"

cat > "$STUB_DIR/bin/xcrun" <<'EOF'
#!/bin/bash
echo "xcrun $*" >> "$STUB_DIR/calls.log"
case "$*" in
  "simctl list devices available") cat "$STUB_DIR/available.txt" ;;
  "simctl list devices") cat "$STUB_DIR/all.txt" ;;
esac
exit 0
EOF
cat > "$STUB_DIR/bin/xcodegen" <<'EOF'
#!/bin/bash
echo "xcodegen $*" >> "$STUB_DIR/calls.log"
exit "${STUB_XCODEGEN_EXIT:-0}"
EOF
cat > "$STUB_DIR/bin/xcodebuild" <<'EOF'
#!/bin/bash
echo "xcodebuild $*" >> "$STUB_DIR/calls.log"
code="${STUB_XCODEBUILD_EXIT:-0}"
if [ "$code" = 0 ]; then echo "** TEST SUCCEEDED **"; else echo "** TEST FAILED **"; fi
exit "$code"
EOF
cat > "$STUB_DIR/bin/python3" <<'EOF'
#!/bin/bash
echo "python3 $*" >> "$STUB_DIR/calls.log"
exit "${STUB_PY_EXIT:-0}"
EOF
chmod +x "$STUB_DIR/bin/"*
STUB_PATH="$STUB_DIR/bin:$PATH"

# 端末の一覧。状態は S_* で変える。名前の似た囮（前に何か付く・後ろに何か付く・11 インチ）と、
# 使えない runtime に居る同じ名前の端末を混ぜてある。
write_lists() {
  {
    echo "== Devices =="
    echo "-- iOS 26.4 --"
    echo "    iPhone 17 Pro ($P17_26) (${S_P17_26:-Shutdown}) "
    echo "-- iOS 27.0 --"
    echo "    iPhone 18 Pro ($P18) (${S_P18:-Booted}) "
    echo "    iPhone 17 Pro ($P17_27) (${S_P17_27:-Shutdown}) "
    echo "    Old iPad Pro 13-inch (M5) ($OLDIPAD) (Shutdown) "
    echo "    iPad Pro 13-inch (M5) Clone ($CLONE) (Shutdown) "
    echo "    iPad Pro 13-inch (M5) ($IPAD13) (${S_IPAD13:-Shutdown}) "
    echo "    iPad Pro 11-inch (M5) ($IPAD11) (Shutdown) "
    echo "-- watchOS 27.0 --"
    echo "    Apple Watch Series 11 (46mm) ($WATCH) (${S_WATCH:-Booted}) "
  } > "$STUB_DIR/available.txt"
  {
    cat "$STUB_DIR/available.txt"
    echo "-- Unavailable: com.apple.CoreSimulator.SimRuntime.iOS-26-0 --"
    echo "    iPad Air 13-inch (M3) ($UNAVAIL) (Shutdown) (unavailable, runtime profile not found)"
  } > "$STUB_DIR/all.txt"
}

# テストごとに作り直す。
fresh() {
  unset S_P17_26 S_P18 S_P17_27 S_IPAD13 S_WATCH
  write_lists
  : > "$CALLS"
  rm -rf "$ROOT/Scripts" "$ROOT/build" "$ROOT"/*.log
  mkdir -p "$ROOT/Scripts"
  cp -R "$SRC/." "$ROOT/Scripts/"
  cat > "$ROOT/Scripts/setup.sh" <<'EOF'
#!/bin/bash
echo "setup SKIP_XCODEGEN=${SKIP_XCODEGEN:-}" >> "$STUB_DIR/calls.log"
exit "${STUB_SETUP_EXIT:-0}"
EOF
}

# リポジトリの根から Scripts/<名前> を走らせる。出力は OUTF、終了値は RC。
run_script() {
  local name="$1"
  shift
  (cd "$ROOT" && PATH="$STUB_PATH" bash "Scripts/$name" "$@") > "$OUTF" 2>&1
  RC=$?
}

# lib/sim.sh を読み込んだ subshell で 1 行走らせる。
run_lib() {
  if [ ! -f "$ROOT/Scripts/lib/sim.sh" ]; then
    echo "(Scripts/lib/sim.sh が無い)" > "$OUTF"
    RC=99
    return
  fi
  (cd "$ROOT" && ROOT="$ROOT" PATH="$STUB_PATH" bash -c '. Scripts/lib/sim.sh; '"$1") > "$OUTF" 2>&1
  RC=$?
}

# ---- Scripts/lib/sim.sh ------------------------------------------------------
fresh
run_lib 'sim_select && echo "UDID=$SIM_UDID NAME=$SIM_NAME"'
if [ "$RC" = 0 ] && has "$OUTF" "UDID=$IPAD13 NAME=iPad Pro 13-inch (M5)"; then
  ok lib_default_is_ipad_pro_13_exact_name
else ng lib_default_is_ipad_pro_13_exact_name "$(head -3 "$OUTF")"; fi

fresh
run_lib 'SIM="iPhone 99" sim_select; echo "rc=$? UDID=[$SIM_UDID]"'
if has "$OUTF" "rc=1 UDID=[]" && hasnt "$CALLS" "create" && hasnt "$CALLS" "boot"; then
  ok lib_missing_name_stops_without_fallback
else ng lib_missing_name_stops_without_fallback "$(tail -2 "$OUTF")"; fi

fresh
run_lib "SIM=$P18 sim_select && echo \"NAME=\$SIM_NAME\""
if [ "$RC" = 0 ] && has "$OUTF" "NAME=iPhone 18 Pro"; then ok lib_udid_accepted
else ng lib_udid_accepted "$(head -3 "$OUTF")"; fi

fresh
run_lib 'SIM=EEEEEEEE-EEEE-4EEE-8EEE-EEEEEEEEEEEE sim_select'
if [ "$RC" != 0 ]; then ok lib_unknown_udid_rejected; else ng lib_unknown_udid_rejected; fi

fresh
run_lib 'SIM="iPad Air 13-inch (M3)" sim_select'
if [ "$RC" != 0 ]; then ok lib_unavailable_device_not_picked; else ng lib_unavailable_device_not_picked; fi

fresh
run_lib 'SIM="iPhone 17 Pro" sim_select && echo "UDID=$SIM_UDID"'
a_ok=0; has "$OUTF" "UDID=$P17_27" && a_ok=1
S_P17_26=Booted write_lists
run_lib 'SIM="iPhone 17 Pro" sim_select && echo "UDID=$SIM_UDID"'
b_ok=0; has "$OUTF" "UDID=$P17_26" && b_ok=1
write_lists
run_lib 'SIM="iPhone 17 Pro" SIM_OS=26.4 sim_select && echo "UDID=$SIM_UDID"'
c_ok=0; has "$OUTF" "UDID=$P17_26" && c_ok=1
if [ "$a_ok$b_ok$c_ok" = 111 ]; then ok lib_duplicate_name_booted_then_newest_then_sim_os
else ng lib_duplicate_name_booted_then_newest_then_sim_os "last=$a_ok booted=$b_ok os=$c_ok"; fi

fresh
run_lib 'sim_select && sim_only'
if [ "$RC" = 0 ] && has "$CALLS" "xcrun simctl shutdown $P18" && has "$CALLS" "xcrun simctl shutdown $WATCH" \
   && hasnt "$CALLS" "xcrun simctl shutdown $IPAD13" && has "$CALLS" "xcrun simctl boot $IPAD13" \
   && has "$CALLS" "xcrun simctl bootstatus $IPAD13 -b"; then
  ok lib_sim_only_shuts_every_other_booted_device
else ng lib_sim_only_shuts_every_other_booted_device "$(grep -v 'simctl list' "$CALLS" | tr '\n' ';')"; fi

fresh
S_IPAD13=Booted S_P18=Shutdown S_WATCH=Shutdown write_lists
run_lib 'sim_select && sim_only'
if [ "$RC" = 0 ] && hasnt "$CALLS" "simctl boot " && hasnt "$CALLS" "simctl shutdown" \
   && has "$CALLS" "xcrun simctl bootstatus $IPAD13 -b"; then
  ok lib_sim_only_no_second_boot_when_already_up
else ng lib_sim_only_no_second_boot_when_already_up "$(grep -v 'simctl list' "$CALLS" | tr '\n' ';')"; fi

fresh
run_lib 'DRY_RUN=1; sim_select && sim_only'
if [ "$RC" = 0 ] && only_reads && has "$OUTF" "+ xcrun simctl shutdown $P18"; then
  ok lib_dry_run_changes_nothing
else ng lib_dry_run_changes_nothing "$(grep -v 'simctl list' "$CALLS" | tr '\n' ';')"; fi

# ---- Scripts/test.sh ---------------------------------------------------------
fresh
DRY_RUN=1 run_script test.sh
line="+ xcodebuild -project EffeTuneLive.xcodeproj -scheme Logic -destination id=$IPAD13 -parallel-testing-enabled NO -resultBundlePath $ROOT/build/Logic.xcresult -only-testing:EffeTuneLiveUnitTests test"
if [ "$RC" = 0 ] && has "$OUTF" "$line" && only_reads && [ ! -e "$ROOT/test.log" ]; then
  ok test_dry_run_one_ipad_no_parallel_result_bundle
else ng test_dry_run_one_ipad_no_parallel_result_bundle "rc=$RC $(grep xcodebuild "$OUTF" | head -1)"; fi

fresh
SAN=address,undefined XCODEBUILD_EXTRA="CODE_SIGNING_ALLOWED=NO -quiet" DRY_RUN=1 \
  run_script test.sh ChainTextTests FXDLinkTests/testRoute
if [ "$RC" = 0 ] && has "$OUTF" "-enableAddressSanitizer YES -enableUndefinedBehaviorSanitizer YES CODE_SIGNING_ALLOWED=NO -quiet -only-testing:EffeTuneLiveUnitTests/ChainTextTests -only-testing:EffeTuneLiveUnitTests/FXDLinkTests/testRoute test"; then
  ok test_san_extra_and_filters_reach_xcodebuild
else ng test_san_extra_and_filters_reach_xcodebuild "rc=$RC $(grep xcodebuild "$OUTF" | head -1)"; fi

fresh
SAN=address,thread DRY_RUN=1 run_script test.sh
rc1=$RC; x1=0; has "$OUTF" "xcodebuild" && x1=1
SAN=memory DRY_RUN=1 run_script test.sh
rc2=$RC; x2=0; has "$OUTF" "xcodebuild" && x2=1
if [ "$rc1" = 2 ] && [ "$rc2" = 2 ] && [ "$x1$x2" = 00 ]; then ok test_san_conflict_and_unknown_rejected
else ng test_san_conflict_and_unknown_rejected "rc=$rc1/$rc2"; fi

fresh
SIM="iPhone 99" run_script test.sh
if [ "$RC" != 0 ] && hasnt "$CALLS" "setup" && hasnt "$CALLS" "xcodegen" && hasnt "$CALLS" "xcodebuild" \
   && hasnt "$CALLS" "create"; then
  ok test_missing_simulator_stops_before_anything
else ng test_missing_simulator_stops_before_anything "rc=$RC $(grep -v 'simctl list' "$CALLS" | tr '\n' ';')"; fi

fresh
run_script test.sh
order=$(grep -v 'simctl list' "$CALLS" | sed 's/ .*//' | uniq | tr '\n' ' ')
if [ "$RC" = 0 ] && has "$CALLS" "setup SKIP_XCODEGEN=1" && has "$CALLS" "xcodegen generate --spec project.yml" \
   && has "$CALLS" "xcrun simctl shutdown $P18" && [ "$order" = "setup xcodegen xcrun xcodebuild " ] \
   && has "$ROOT/test.log" "** TEST SUCCEEDED **"; then
  ok test_runs_setup_xcodegen_one_sim_then_xcodebuild
else ng test_runs_setup_xcodegen_one_sim_then_xcodebuild "rc=$RC order=$order"; fi

fresh
STUB_XCODEGEN_EXIT=1 run_script test.sh
if [ "$RC" != 0 ] && hasnt "$CALLS" "xcodebuild"; then ok test_xcodegen_failure_stops
else ng test_xcodegen_failure_stops "rc=$RC"; fi

fresh
STUB_SETUP_EXIT=1 run_script test.sh
if [ "$RC" != 0 ] && has "$CALLS" "setup" && hasnt "$CALLS" "xcodegen" && hasnt "$CALLS" "xcodebuild"; then
  ok test_setup_failure_stops
else ng test_setup_failure_stops "rc=$RC"; fi

fresh
SKIP_SETUP=1 run_script test.sh
if [ "$RC" = 0 ] && hasnt "$CALLS" "setup" && has "$CALLS" "xcodegen generate --spec project.yml"; then
  ok test_skip_setup_still_regenerates_project
else ng test_skip_setup_still_regenerates_project "rc=$RC"; fi

fresh
STUB_XCODEBUILD_EXIT=65 run_script test.sh
if [ "$RC" = 65 ]; then ok test_xcodebuild_exit_code_propagates
else ng test_xcodebuild_exit_code_propagates "rc=$RC"; fi

# ---- Scripts/uitest.sh -------------------------------------------------------
fresh
DRY_RUN=1 run_script uitest.sh
line="+ /usr/bin/xcodebuild -project EffeTuneLiveSim.xcodeproj -scheme EffeTuneLive -destination id=$IPAD13 -jobs 2 -derivedDataPath $ROOT/DerivedData -parallel-testing-enabled NO -disable-concurrent-destination-testing -resultBundlePath $ROOT/build/UITest.xcresult -only-testing:EffeTuneLiveUITests/SmokeTests test"
if [ "$RC" = 0 ] && has "$OUTF" "+ python3 Tools/gen_sim_spec.py" \
   && has "$OUTF" "+ xcodegen generate --spec project-sim.yml" && has "$OUTF" "$line" \
   && has "$OUTF" "+ xcrun simctl terminate $IPAD13 ai.nemut.effetune" && only_reads; then
  ok uitest_dry_run_sim_project_one_device_smoke_tests
else ng uitest_dry_run_sim_project_one_device_smoke_tests "rc=$RC $(grep xcodebuild "$OUTF" | head -1)"; fi

fresh
STUB_PY_EXIT=1 run_script uitest.sh
if [ "$RC" != 0 ] && has "$CALLS" "python3 Tools/gen_sim_spec.py" && hasnt "$CALLS" "xcodegen"; then
  ok uitest_gen_sim_spec_failure_stops
else ng uitest_gen_sim_spec_failure_stops "rc=$RC"; fi

# ---- Scripts/shoot_*.sh ------------------------------------------------------
fresh
DRY_RUN=1 run_script shoot_all.sh VolumePlugin
if [ "$RC" = 0 ] && has "$OUTF" "+ xcrun simctl launch $IPAD13 ai.nemut.effetune -ETSeed VolumePlugin -ETMock 1" \
   && has "$OUTF" "+ env SKIP_XCODEGEN=1 bash Scripts/setup.sh" && has "$OUTF" "+ xcrun simctl shutdown $P18" \
   && only_reads; then
  ok shoot_all_uses_setup_and_one_ipad
else ng shoot_all_uses_setup_and_one_ipad "rc=$RC"; fi

fresh
DRY_RUN=1 SKIP_BUILD=1 run_script shoot_screens.sh
a_ok=0; has "$OUTF" "+ xcrun simctl launch $IPAD13 ai.nemut.effetune -ETSeed none -ETWidth 440 -ETMock 1" && a_ok=1
SIM="iPhone 18 Pro" DRY_RUN=1 SKIP_BUILD=1 run_script shoot_screens.sh
b_ok=0; has "$OUTF" "+ xcrun simctl launch $P18 ai.nemut.effetune -ETSeed none -ETWidth 0 -ETMock 1" && b_ok=1
LAYOUT=wide DRY_RUN=1 SKIP_BUILD=1 run_script shoot_screens.sh
c_ok=0; has "$OUTF" "-ETSheet picker -ETLayout wide" && c_ok=1
if [ "$a_ok$b_ok$c_ok" = 111 ] && only_reads; then ok shoot_screens_ipad_default_width_by_device
else ng shoot_screens_ipad_default_width_by_device "ipad=$a_ok iphone=$b_ok layout=$c_ok"; fi

fresh
DRY_RUN=1 run_script shoot_store.sh chain:routing
if [ "$RC" = 0 ] && has "$OUTF" "+ xcrun simctl launch $IPAD13 ai.nemut.effetune -ETSeed chain -ETWidth 440 -ETCollapsed 0 -ETMock 1 -ETSheet routing" \
   && only_reads; then
  ok shoot_store_default_ipad_sheet_spec
else ng shoot_store_default_ipad_sheet_spec "rc=$RC $(grep 'simctl launch' "$OUTF" | head -1)"; fi

# ---- Scripts/build.sh / archive.sh -------------------------------------------
fresh
STUB_SETUP_EXIT=1 run_script build.sh
if [ "$RC" != 0 ] && has "$OUTF" "(exit=1)" && has "$ROOT/build.log" "!! Scripts/setup.sh" \
   && hasnt "$ROOT/build.log" "================ build"; then
  ok build_setup_failure_stops_and_exits_nonzero
else ng build_setup_failure_stops_and_exits_nonzero "rc=$RC $(tail -1 "$OUTF")"; fi

fresh
STUB_SETUP_EXIT=1 ARCHIVE_DIR="$WORK/arch" run_script archive.sh
if [ "$RC" != 0 ] && has "$CALLS" "setup" && has "$ROOT/archive.log" "!! Scripts/setup.sh"; then
  ok archive_runs_setup_and_stops_on_failure
else ng archive_runs_setup_and_stops_on_failure "rc=$RC"; fi

if [ -x /usr/bin/xcodebuild ]; then
  echo "skip archive_removes_previous_archive（本物の xcodebuild がある）"
else
  fresh
  mkdir -p "$WORK/arch/EffeTuneLive.xcarchive"
  ARCHIVE_DIR="$WORK/arch" run_script archive.sh
  if [ "$RC" != 0 ] && [ ! -e "$WORK/arch/EffeTuneLive.xcarchive" ]; then
    ok archive_removes_previous_archive
  else ng archive_removes_previous_archive "rc=$RC"; fi
fi

# ---- 全体 --------------------------------------------------------------------
if [ ! -e "$SRC/sim.sh" ] && [ ! -e "$SRC/shots.sh" ]; then ok dead_sim_and_shots_scripts_removed
else ng dead_sim_and_shots_scripts_removed; fi

hits=$(grep -nE '^[^#]*(simctl create|open -a Simulator)' "$SRC"/*.sh "$SRC"/lib/*.sh 2>/dev/null)
if [ -z "$hits" ]; then ok no_script_creates_devices_or_opens_simulator_app
else ng no_script_creates_devices_or_opens_simulator_app "$hits"; fi

hits=$(grep -nE 'SIM:-|simctl list devices available' "$SRC"/*.sh 2>/dev/null)
if [ -z "$hits" ]; then ok device_choice_only_in_lib
else ng device_choice_only_in_lib "$(echo "$hits" | head -3 | tr '\n' ';')"; fi

echo
echo "PASS $PASS  FAIL $FAIL${FAILED:+  (${FAILED# })}"
[ "$FAIL" = 0 ]
