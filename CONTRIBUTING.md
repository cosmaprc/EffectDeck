# Contributing

An issue on its own is plenty. You do not have to send code.

## Written with an AI is fine

Issues, pull requests, either one. I am not asking you to declare it, and it counts
the same as anything else.

The one thing I do ask: **run it on a device first.** The extension needs iOS 27 and
no audio flows in the simulator, so a change can look right in the diff and still pass
silence through. Say which device and which iOS version you tried it on.

Running it on a device means you need a paid Apple Developer Program membership.
A free Apple ID (Personal Team) is not enough: the extension needs the
`com.apple.developer.media-device-extension` entitlement (see
`Sources/Extension/Extension.entitlements`), and Apple gates that behind a paid
account. `Scripts/build.sh` will not get past code signing without one.

The tests below need neither a device nor a paid account. Running them is a real way to
help even without the membership.

## Issues

Say what you were playing from (Spotify, Safari, a podcast app), what was in the chain,
and what you heard. If picking EffectDeck shows Unable to Connect or the output switches
back, read **If it says Unable to Connect** in the README first — it is usually Spotify's
Canvas.

## Pull requests

`bash Scripts/build.sh` builds and installs on the attached device. `bash Scripts/setup.sh`
generates the Xcode project. Both are in the README under **Building**.

Run the tests that cover what you changed. If you change a generator in `Tools/`, or
anything a generator reads, run `bash Scripts/setup.sh` and commit what it regenerates
(`Sources/EffeTuneLive/Generated/`, `chain/`); CI fails when the committed files differ
from a fresh run.

`site/` is the official website (a Cloudflare Worker). You do not need it to build the app.

## Running the tests

| Suite | Needs | Covers |
|---|---|---|
| Logic tests | Mac, Xcode 27, xcodegen | Everything in `Tests/Unit`, the JSFX host included |
| Linux harness | Swift 6 on Linux or WSL | The Foundation-only part of the same tests |
| Native tests | CMake 3.24, gcc or clang | The plain C code under `Sources/` |
| Website | Node 22 | `site/` |
| UI tests | Mac, Xcode 27, xcodegen | The app on a simulator, without the extension |

### Logic tests (Mac)

```bash
bash Scripts/test.sh                          # everything in Tests/Unit
bash Scripts/test.sh PipelineRulesTests       # one class (several may follow)
bash Scripts/test.sh ChainTextTests/testFoo   # one test
SIM="iPhone 17 Pro" bash Scripts/test.sh      # another simulator, by exact name
```

This runs the `Logic` scheme (`EffeTuneLiveUnitTests`) on one simulator. It runs
`Scripts/setup.sh` first (patches, generated files, xcodegen); `SKIP_SETUP=1` skips all of
that except xcodegen. `SAN=address`, `SAN=thread` or `SAN=undefined` turns on a sanitizer.
Other simulators that are running are shut down, so that Xcode never starts a second one.

The whole log is `test.log` and the result bundle is `build/Logic.xcresult`. The run
passed when the script exits 0 and `test.log` says `** TEST SUCCEEDED **`.

A simulator build needs no paid account. If Xcode still asks for the team in
`DEVELOPMENT_TEAM`, pass `XCODEBUILD_EXTRA="CODE_SIGNING_ALLOWED=NO"`, as CI does.

### Linux harness (Linux, WSL)

```bash
bash Tests/Linux/run.sh --name local                           # all of it
bash Tests/Linux/run.sh --name local --filter PipelineStoreTests
bash Tests/Linux/run.sh --name local --sanitize=address
```

From Windows, run it inside WSL: `wsl -e bash /mnt/c/<path to the clone>/Tests/Linux/run.sh
--name local`. In Git Bash, prefix `MSYS_NO_PATHCONV=1` so the `/mnt/c` path is not
rewritten. `-e` keeps a `--filter` regex such as `A|B` away from the shell.

It copies the Logic bundle into a SwiftPM package and runs `swift test` in Swift 5 mode.
The file list comes from the `EffeTuneLiveUnitTests` target in `project.yml`, minus the
C and C++ files and `JSFX*Tests`, which need ysfx and the Mac. `os`, `Accelerate`,
`CryptoKit` and `Compression` are replaced by small stand-ins in `Tests/Linux/Shims`.

- Needs Swift 6 (swiftly works), python3 and the zlib headers.
- The log is `build/linux-unit-<name>.log`. Each `--name` builds in its own
  `~/.cache/effectdeck-linux/<name>/`, so two runs with different names do not collide.
- New test files in `Tests/Unit` are picked up on their own. A new source file or
  fixture that `project.yml` does not list yet is passed with `--add <path>`.
- `Tests/Linux/skip.txt` lists, with a reason, the tests that fail only because Linux's
  Foundation differs from Apple's. Nothing else goes there, and app code is never changed
  to make Linux pass.
- The vDSP stand-in is a substitute. For `FIRDesign`, only the Mac result counts.

### Native tests

```bash
cd Tests/Native
cmake --preset asan && cmake --build --preset asan && ctest --preset asan        # ASan + UBSan
cmake --preset tsan && cmake --build --preset tsan && ctest --preset tsan        # TSan, threaded tests only
cmake --preset engine && cmake --build --preset engine && ctest --preset engine  # also the real engine
```

These build the plain C files under `Sources/` with gcc or clang, without Xcode. The presets
are in `Tests/Native/CMakePresets.json`; `plain` has no sanitizer and also builds with
MSVC. Build directories are `build/native-<preset>` at the top of the repository.

- The tests that use a stand-in engine read `effetune/abi.h`, so the `Vendor/effetune`
  submodule must be checked out.
- `engine` also builds the pinned EffeTune engine with the patches from `Patches/` applied
  to a copy under the build directory; `Vendor/effetune` itself is not touched. It needs a
  POSIX system.
- If a sanitizer dies at startup on a kernel with 32 bits of mmap randomization (Ubuntu
  24.04 does this), run `sudo sysctl -w vm.mmap_rnd_bits=28` first; CI does the same.

### Website

```bash
cd site
npm ci
npm test
```

wrangler and miniflare need Node 22 or later.

### UI tests (Mac)

```bash
bash Scripts/uitest.sh                   # the smoke tests
bash Scripts/uitest.sh MenuProbe         # one class
```

The simulator SDK has no `MediaDevice.framework`, so the app is built from a simulator
project without the extension (`Tools/gen_sim_spec.py` writes `project-sim.yml`). The same
`SIM`, `SKIP_SETUP` and `DRY_RUN` variables as `Scripts/test.sh` apply. The log is
`uitest.log` and the result bundle is `build/UITest.xcresult`.

## CI

GitHub Actions, on every push to `main` and every pull request. No secrets; nothing is
signed.

`.github/workflows/ci.yml`:

| Job | What it checks |
|---|---|
| `site` | `npm ci` and `npm test` on Node 22 |
| `checks` | Python and shell syntax, shellcheck, actionlint, and the repository checks and tool tests in `Tools/` and `Tests/Tools` |
| `native` | The native tests with gcc and clang, each under ASan+UBSan and TSan |
| `linux-swift` | The Linux harness in the `swift:6.4.0-noble` image, plain and with ASan |
| `generated` | Runs `Scripts/setup.sh` (without xcodegen) and the golden generators with both submodules at the pin, then fails if any committed file changed |
| `macos (logic)` | The Logic tests on an iOS 27 simulator |
| `macos (sim-build)` | Builds the app for the simulator without the extension |

The macOS jobs run on GitHub's `xcode-27` image, the only one with the iOS 27 SDK (the
deployment target is 27.0). It is a preview image, so the workflow pins the Xcode with
`xcode-select` and stops if the iOS 27 SDK is missing. The label is in one place, the
`runs-on` of the `macos` job; the comment at the top of `ci.yml` says what to change
with it.

`.github/workflows/dsp.yml` runs upstream's own DSP test suite on `Vendor/effetune` with
our patches applied, in Debug and with ASan+UBSan. It runs nightly and when `Patches/`,
`Vendor/`, `Sources/Shared/`, `Tests/Native/` or `Scripts/setup.sh` change.

## About the DSP under `Vendor/effetune`

That code is EffeTune's, not this project's. If something looks wrong in there, raise it
here first. This host uses that code in ways upstream never intended, so most of what
looks like a DSP bug turns out to be ours.

**Do not report it upstream until you have reproduced it in EffeTune itself** — the
desktop or web build, without this app in the picture. Upstream is not responsible for
EffectDeck and must not be made to carry its bugs.
