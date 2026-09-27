"""Tools/check_privacy_manifest.py の試験。stdlibだけ（Tests/Toolsの他の試験の道具には頼らない）。

    python -m unittest discover -s Tests/Tools -p "test_check_privacy_manifest.py"

- 実物のリポジトリ（project.ymlと3本のマニフェスト）がそのまま通ること
- 報告に載るログへ起動からの秒を書いている間は、アプリのマニフェストに3D61.1があること
- 使っているのに申告が無い分類で落ちること（静的ライブラリの分はアプリの分）
- grepが注釈・字・メンバー呼び出しに騙されないこと
- マニフェストの無効な形（TN3181）を拾うこと
- --binary は cc と nm があるときだけ（Linuxのオブジェクトで同じ道を通す）
"""
import contextlib
import importlib.util
import io
import pathlib
import plistlib
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
TOOL = ROOT / "Tools" / "check_privacy_manifest.py"
_loaded = 0


def load():
    global _loaded
    _loaded += 1
    spec = importlib.util.spec_from_file_location("check_privacy_manifest_%d" % _loaded, TOOL)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def write(path, text):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8", newline="\n")
    return path


def manifest(categories=None, **top):
    data = {"NSPrivacyTracking": False, "NSPrivacyCollectedDataTypes": []}
    if categories:
        data["NSPrivacyAccessedAPITypes"] = [
            {"NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategory" + cat,
             "NSPrivacyAccessedAPITypeReasons": list(reasons)}
            for cat, reasons in categories.items()]
    data.update(top)
    return plistlib.dumps(data)


PROJECT = """\
name: Sample
targets:
  # アプリ。静的ライブラリLibを畳み込む
  App:
    type: application
    sources:
      - path: App
        excludes: ["**/*.icon/**"]
      - path: Shared
        excludes:
          - "Skip.*"
      - path: Vendor/lib
        includes: ["**/*.c"]
        excludes: ["**/*test*.c"]
      - path: Resources
        buildPhase: resources
    dependencies:
      - target: Lib
      - target: Share
        embed: true
  Lib:
    type: library.static
    sources:
      - path: Lib
  Share:
    type: app-extension
    sources:
      - path: Share
  Tests:
    type: bundle.unit-test
    sources:
      - path: Tests
"""


class Repo:
    """試験用のリポジトリ。App / Share の2本を出す。"""

    def __enter__(self):
        self.root = pathlib.Path(tempfile.mkdtemp(prefix="privacy-"))
        write(self.root / "project.yml", PROJECT)
        write(self.root / "App/Main.swift", "let x = 1\n")
        write(self.root / "Share/Share.swift", "let y = 2\n")
        write(self.root / "Lib/lib.c", "int lib(void) { return 0; }\n")
        write(self.root / "Shared/Keep.c", "int keep;\n")
        write(self.root / "Vendor/lib/a.c", "int a;\n")
        write(self.root / "Tests/T.swift", "import Foundation\nlet d = UserDefaults.standard\n")
        self.set_manifest("App")
        self.set_manifest("Share")
        return self

    def __exit__(self, *exc):
        shutil.rmtree(self.root, ignore_errors=True)
        return False

    def set_manifest(self, target, categories=None, **top):
        (self.root / target / "PrivacyInfo.xcprivacy").write_bytes(manifest(categories, **top))

    def run(self, *args):
        mod = load()
        mod.BUNDLES = {"App": "App/PrivacyInfo.xcprivacy", "Share": "Share/PrivacyInfo.xcprivacy"}
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
            code = mod.main(["--repo", str(self.root)] + list(args))
        return code, out.getvalue()


class RealRepositoryTests(unittest.TestCase):
    def test_repository_manifests_cover_sources(self):
        mod = load()
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = mod.main([])
        self.assertEqual(code, 0, out.getvalue())
        self.assertIn("OK", out.getvalue())

    def test_every_shipped_bundle_has_a_manifest_file(self):
        mod = load()
        for target, rel in mod.BUNDLES.items():
            declared, errors = mod.read_manifest(ROOT / rel)
            self.assertEqual(errors, [], "%s: %s" % (target, errors))
            self.assertTrue(declared, target)

    def test_project_yml_is_read(self):
        mod = load()
        targets = mod.parse_yaml((ROOT / "project.yml").read_text(encoding="utf-8"))["targets"]
        self.assertEqual(targets["EffeTuneLive"]["type"], "application")
        self.assertEqual(targets["YSFX"]["type"], "library.static")
        self.assertEqual(targets["EffectDeckShare"]["type"], "app-extension")
        self.assertEqual(targets["EffeTuneLiveExtension"]["type"], "extensionkit-extension")
        share = [s if isinstance(s, str) else s["path"] for s in targets["EffectDeckShare"]["sources"]]
        self.assertIn("Sources/EffeTuneLive/DSP/ETShareInbox.swift", share)
        ysfx = targets["YSFX"]["sources"][0]
        self.assertEqual(ysfx["path"], "Vendor/ysfx/sources")
        self.assertIn("ysfx_utils_fts.cpp", ysfx["excludes"])
        self.assertIn({"target": "YSFX"}, targets["EffeTuneLive"]["dependencies"])

    def test_uptime_in_report_log_declares_bug_report_reason(self):
        # ETLogTapの行には壁時計の時刻が付くので、そこへsystemUptimeを書くと起動時刻が出る。
        # その末尾はReport a problemの本文に入って端末の外へ出る（人が見て送る）。35F9.1では足りず3D61.1が要る。
        carriers = []
        for path in sorted((ROOT / "Sources" / "EffeTuneLive").rglob("*.swift")):
            lines = path.read_text(encoding="utf-8").split("\n")
            for i, line in enumerate(lines):
                m = re.search(r"let (\w+) = ProcessInfo\.processInfo\.systemUptime\b", line)
                if not m:
                    continue
                after = lines[i + 1:i + 14]
                formatted = any(re.search(r"\b%s\b" % m.group(1), l) for l in after)
                if formatted and any("String(format:" in l for l in after) and any(
                        "ETLogTap.record" in l for l in after):
                    carriers.append("%s:%d" % (path.relative_to(ROOT).as_posix(), i + 1))
        if not carriers:
            self.skipTest("報告のログにsystemUptimeを書いている所が無い（3D61.1は外してよい）")
        declared, errors = load().read_manifest(ROOT / "Sources/EffeTuneLive/PrivacyInfo.xcprivacy")
        self.assertEqual(errors, [])
        self.assertIn("3D61.1", declared.get("SystemBootTime", set()),
                      "報告のログに起動からの秒が入る: %s" % ", ".join(carriers))


class SourceModeTests(unittest.TestCase):
    def test_missing_category_fails(self):
        with Repo() as repo:
            write(repo.root / "App/Store.swift", "let v = UserDefaults.standard.bool(forKey: \"a\")\n")
            code, out = repo.run()
        self.assertEqual(code, 1, out)
        self.assertRegex(out, r"MISSING UserDefaults .*App/Store.swift:1")

    def test_declared_category_passes(self):
        with Repo() as repo:
            write(repo.root / "App/Store.swift", "@AppStorage(\"k\") var k = 0\n")
            repo.set_manifest("App", {"UserDefaults": ["CA92.1"]})
            code, out = repo.run()
        self.assertEqual(code, 0, out)

    def test_static_library_counts_for_the_app(self):
        with Repo() as repo:
            write(repo.root / "Lib/io.c", "#include <sys/stat.h>\nint f(int fd) { struct stat s; return fstat(fd, &s); }\n")
            code, out = repo.run()
            self.assertEqual(code, 1, out)
            self.assertRegex(out, r"MISSING FileTimestamp .*Lib/io.c:2")
            repo.set_manifest("App", {"FileTimestamp": ["C617.1"]})
            code, out = repo.run()
        self.assertEqual(code, 0, out)

    def test_each_bundle_is_judged_on_its_own_sources(self):
        with Repo() as repo:
            write(repo.root / "Share/Clock.swift", "let t = ProcessInfo.processInfo.systemUptime\n")
            repo.set_manifest("App", {"SystemBootTime": ["35F9.1"]})
            code, out = repo.run()
        self.assertEqual(code, 1, out)
        self.assertRegex(out, r"Share  Share/PrivacyInfo.xcprivacy\n  MISSING SystemBootTime")
        self.assertRegex(out, r"UNUSED  SystemBootTime")

    def test_includes_and_excludes_follow_xcodegen(self):
        with Repo() as repo:
            write(repo.root / "Shared/Skip.c", "unsigned long long t(void) { return mach_absolute_time(); }\n")
            write(repo.root / "Vendor/lib/sub/fs_test.c", "int g(const char *p) { return statfs(p, 0); }\n")
            write(repo.root / "Vendor/lib/sub/fs.h", "int h(const char *p) { return statfs(p, 0); }\n")
            write(repo.root / "App/Icon.icon/x.swift", "let d = UserDefaults.standard\n")
            write(repo.root / "Resources/r.swift", "let d = UserDefaults.standard\n")
            code, out = repo.run()
            self.assertEqual(code, 0, out)
            write(repo.root / "Vendor/lib/sub/fs.c", "int g(const char *p) { return statfs(p, 0); }\n")
            code, out = repo.run()
        self.assertEqual(code, 1, out)
        self.assertRegex(out, r"MISSING DiskSpace .*Vendor/lib/sub/fs.c:1")

    def test_unit_test_bundle_is_not_shipped(self):
        with Repo() as repo:
            code, out = repo.run()
        self.assertEqual(code, 0, out)
        self.assertNotIn("Tests/T.swift", out)

    def test_unknown_shipped_target_fails(self):
        with Repo() as repo:
            text = (repo.root / "project.yml").read_text(encoding="utf-8")
            write(repo.root / "project.yml", text + "  Widget:\n    type: app-extension\n    sources:\n      - path: Share\n")
            code, out = repo.run()
        self.assertEqual(code, 1, out)
        self.assertIn("Widget", out)

    def test_missing_manifest_fails_even_without_api_use(self):
        with Repo() as repo:
            (repo.root / "Share/PrivacyInfo.xcprivacy").unlink()
            code, out = repo.run()
        self.assertEqual(code, 1, out)
        self.assertIn("マニフェストが無い", out)

    def test_missing_vendor_is_a_note_unless_required(self):
        with Repo() as repo:
            shutil.rmtree(repo.root / "Vendor/lib")
            (repo.root / "Vendor/lib").mkdir()
            code, out = repo.run()
            self.assertEqual(code, 0, out)
            self.assertIn("NOTE App: Vendor/lib", out)
            code, out = repo.run("--require-vendor")
        self.assertEqual(code, 1, out)

    def test_unused_declaration_warns_and_strict_fails(self):
        with Repo() as repo:
            repo.set_manifest("App", {"DiskSpace": ["E174.1"]})
            code, out = repo.run()
            self.assertEqual(code, 0, out)
            self.assertIn("UNUSED  DiskSpace", out)
            code, out = repo.run("--strict")
        self.assertEqual(code, 1, out)


class GrepTests(unittest.TestCase):
    def hits(self, text, name="x.swift"):
        mod = load()
        with tempfile.TemporaryDirectory() as tmp:
            path = write(pathlib.Path(tmp) / name, text)
            return [(cat, place.split(":")[1]) for cat, place, _ in mod.scan_file(path, name)]

    def test_comments_do_not_count(self):
        self.assertEqual(self.hits("// UserDefaults\n/* systemUptime\n /* nested */ mach_absolute_time() */\nlet a = 1\n"), [])
        self.assertEqual(self.hits("/* stat(p) */ int a; // fstat(fd)\n", "x.c"), [])

    def test_string_with_slashes_does_not_hide_code(self):
        self.assertEqual(self.hits('let u = "https://x"; let t = mach_absolute_time()\n'), [("SystemBootTime", "1")])
        self.assertEqual(self.hits('let s = "\\(a ?? "//") \\(ProcessInfo.processInfo.systemUptime)"\n'),
                         [("SystemBootTime", "1")])
        self.assertEqual(self.hits('let r = #"a"b//"#; let d = UserDefaults.standard\n'), [("UserDefaults", "1")])
        self.assertEqual(self.hits('let m = """\n// UserDefaults\n"""\n'), [("UserDefaults", "2")])
        self.assertEqual(self.hits("char q = '\"'; int r = lstat(p, &s); // '\n", "x.c"), [("FileTimestamp", "1")])

    def test_member_calls_and_prefixes_do_not_count(self):
        src = "int lstate = 0;\nobj.stat(1);\np->fstat(2);\nfstatus(3);\nstruct stat s;\n#include <sys/stat.h>\n"
        self.assertEqual(self.hits(src, "x.cpp"), [])
        self.assertEqual(self.hits("::stat(p, &s);\nfstat (fd, &s);\n", "x.cpp"),
                         [("FileTimestamp", "1"), ("FileTimestamp", "2")])

    def test_foundation_names(self):
        src = ("fm.setAttributes([.modificationDate: Date()], ofItemAtPath: p)\n"
               "let k: URLResourceKey = .contentModificationDateKey\n"
               "let c = attrs[.creationDate]\n"
               "let f = attrs[.systemFreeSize]\n"
               "let v = URLResourceKey.volumeAvailableCapacityForImportantUsageKey\n"
               "let m = UITextInputMode.activeInputModes\n"
               "let values = try url.resourceValues(forKeys: [.fileSizeKey])\n"
               "let x = values.contentModificationDate\n")
        self.assertEqual(self.hits(src), [("FileTimestamp", "1"), ("FileTimestamp", "2"), ("FileTimestamp", "3"),
                                          ("DiskSpace", "4"), ("DiskSpace", "5"), ("ActiveKeyboards", "6")])
        self.assertEqual(self.hits("[NSUserDefaults standardUserDefaults];\nNSFileModificationDate;\n"
                                   "CFPreferencesCopyAppValue(k, a);\n", "x.m"),
                         [("UserDefaults", "1"), ("FileTimestamp", "2"), ("UserDefaults", "3")])

    def test_getattrlist_counts_for_both_categories(self):
        self.assertEqual(sorted(self.hits("getattrlist(p, &l, b, n, 0);\n", "x.c")),
                         [("DiskSpace", "1"), ("FileTimestamp", "1")])

    def test_ignore_marker(self):
        self.assertEqual(self.hits("let d = model.creationDate // privacy-manifest: ignore 記事の作成日\n"), [])


class ManifestTests(unittest.TestCase):
    def errors(self, data):
        mod = load()
        with tempfile.TemporaryDirectory() as tmp:
            path = pathlib.Path(tmp) / "PrivacyInfo.xcprivacy"
            path.write_bytes(data if isinstance(data, bytes) else plistlib.dumps(data))
            return mod.read_manifest(path)

    def assertInvalid(self, data, fragment):
        _, errors = self.errors(data)
        self.assertTrue(any(fragment in e for e in errors), "%r not in %r" % (fragment, errors))

    def base(self, **extra):
        data = {"NSPrivacyTracking": False, "NSPrivacyCollectedDataTypes": []}
        data.update(extra)
        return data

    def api(self, cat, reasons):
        return {"NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategory" + cat,
                "NSPrivacyAccessedAPITypeReasons": reasons}

    def test_valid(self):
        declared, errors = self.errors(self.base(NSPrivacyAccessedAPITypes=[
            self.api("UserDefaults", ["CA92.1", "1C8F.1"]), self.api("DiskSpace", ["E174.1"])]))
        self.assertEqual(errors, [])
        self.assertEqual(declared, {"UserDefaults": {"CA92.1", "1C8F.1"}, "DiskSpace": {"E174.1"}})

    def test_tn3181_shapes(self):
        self.assertInvalid(self.base(NSPrivacyAccessedAPITypes=[]), "NSPrivacyAccessedAPITypesが空")
        self.assertInvalid(self.base(NSPrivacyAccessedAPITypes=[self.api("UserDefaults", [])]), "理由が空")
        self.assertInvalid(self.base(NSPrivacyAccessedAPITypes=[self.api("Camera", ["CA92.1"])]), "知らない分類")
        self.assertInvalid(self.base(NSPrivacyAccessedAPITypes=[self.api("UserDefaults", ["35F9.1"])]),
                           "UserDefaultsの理由に35F9.1は無い")
        self.assertInvalid(self.base(NSPrivacyAccessedAPITypes=[self.api("SystemBootTime", ["35F9.1"]),
                                                                self.api("SystemBootTime", ["8FFB.1"])]), "2回ある")
        self.assertInvalid(self.base(NSPrivacyTrackingDomains=["t.example.com"]), "falseなのに")
        self.assertInvalid(self.base(NSPrivacyTracking=True, NSPrivacyTrackingDomains=[]), "trueなのに")
        self.assertInvalid(self.base(NSPrivacyTracking="NO"), "Booleanでない")
        self.assertInvalid(self.base(NSPrivacyTracking=True, NSPrivacyTrackingDomains=["https://t.example.com/"]),
                           "追跡ドメインの形")
        self.assertInvalid(self.base(NSPrivacyUnknown=1), "知らない鍵 NSPrivacyUnknown")
        self.assertInvalid(self.base(NSPrivacyAccessedAPITypes=[dict(self.api("UserDefaults", ["CA92.1"]), Extra=1)]),
                           "知らない鍵 Extra")
        self.assertInvalid(b"<plist><dict><key>a</key></plist>", "plistとして読めない")

    def test_sdk_only_reasons_rejected_in_app(self):
        self.assertInvalid(self.base(NSPrivacyAccessedAPITypes=[self.api("UserDefaults", ["C56D.1"])]), "third-party SDK")
        self.assertInvalid(self.base(NSPrivacyAccessedAPITypes=[self.api("FileTimestamp", ["0A2A.1"])]), "third-party SDK")

    def test_app_policy(self):
        self.assertInvalid({"NSPrivacyCollectedDataTypes": []}, "NSPrivacyTrackingをfalse")
        self.assertInvalid({"NSPrivacyTracking": False}, "NSPrivacyCollectedDataTypesを配列")
        self.assertInvalid(self.base(NSPrivacyCollectedDataTypes=[{
            "NSPrivacyCollectedDataType": "NSPrivacyCollectedDataTypeCrashData",
            "NSPrivacyCollectedDataTypeLinked": False, "NSPrivacyCollectedDataTypeTracking": False,
            "NSPrivacyCollectedDataTypePurposes": ["NSPrivacyCollectedDataTypePurposeAppFunctionality"]}]),
            "何も集めない")


def _tool(name):
    return shutil.which(name)


@unittest.skipUnless(_tool("cc") and _tool("nm"), "cc と nm が要る（Linux/Mac）")
class BinaryModeTests(unittest.TestCase):
    """--binary。Linuxではオブジェクトファイル（ELF）で同じ道を通す。Macでは.appのMach-Oを読む。"""

    C = r"""
#include <sys/stat.h>
extern unsigned long long mach_absolute_time(void);
const char selectors[] = "\0systemUptime\0";
int f(int fd) { struct stat s; return fstat(fd, &s) + (int)mach_absolute_time(); }
"""

    def build_app(self, root, with_manifest):
        app = root / "Sample.app"
        (app / "PlugIns" / "Share.appex").mkdir(parents=True)
        src = write(root / "main.c", self.C)
        subprocess.run(["cc", "-c", "-o", str(app / "Sample"), str(src)], check=True)
        with open(app / "Info.plist", "wb") as f:
            plistlib.dump({"CFBundleExecutable": "Sample"}, f)
        write(root / "empty.c", "int nothing(void) { return 0; }\n")
        subprocess.run(["cc", "-c", "-o", str(app / "PlugIns/Share.appex/Share"), str(root / "empty.c")], check=True)
        if with_manifest:
            (app / "PrivacyInfo.xcprivacy").write_bytes(
                manifest({"FileTimestamp": ["C617.1"], "SystemBootTime": ["35F9.1"]}))
        return app

    def run_binary(self, app):
        mod = load()
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
            code = mod.main(["--binary", str(app), "-v"])
        return code, out.getvalue()

    def test_imports_and_selectors_are_found(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = self.build_app(pathlib.Path(tmp), with_manifest=False)
            code, out = self.run_binary(app)
        self.assertEqual(code, 1, out)
        self.assertIn("マニフェストが無い", out)
        self.assertRegex(out, r"MISSING FileTimestamp .*fstat")
        self.assertRegex(out, r"MISSING SystemBootTime .*mach_absolute_time \(\+1\)\n +Sample  systemUptime\n")

    def test_debug_dylib_is_read(self):
        # XcodeのDebugでは実行ファイルは殻で、中身は<App>.debug.dylibにある
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            app = self.build_app(root, with_manifest=False)
            (app / "Sample").replace(app / "Sample.debug.dylib")
            subprocess.run(["cc", "-c", "-o", str(app / "Sample"), str(root / "empty.c")], check=True)
            code, out = self.run_binary(app)
        self.assertEqual(code, 1, out)
        self.assertRegex(out, r"MISSING FileTimestamp .*Sample.debug.dylib  fstat")

    def test_declared_passes_and_clean_extension_needs_nothing(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = self.build_app(pathlib.Path(tmp), with_manifest=True)
            code, out = self.run_binary(app)
        self.assertEqual(code, 0, out)
        self.assertIn("Share.appex", out)
        self.assertIn("Required Reason APIは見つからない", out)


if __name__ == "__main__":
    unittest.main()
