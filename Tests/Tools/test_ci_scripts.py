"""Xcode Cloud まわり（ci_scripts/ci_post_clone.sh と project.yml の構成）の照合。

- 道具の版（xcodegen の版と sha256）が ci.yml・canary.yml・ci_post_clone.sh で食い違わない。
- ci_post_clone.sh は実行ビット付きで追跡され、bash の構文が通る。
- 紫（アイコン EffectDeckPublicBeta）と ET_BETA は Beta 構成の同じ所にだけ書いてある。
"""
import re
import shutil
import subprocess

from tools_support import ROOT, unittest

POST_CLONE = ROOT / "ci_scripts" / "ci_post_clone.sh"


def read(rel):
    return (ROOT / rel).read_text(encoding="utf-8")


def pin(text, name):
    m = re.search(r"^\s*%s[:=]\s*\"?([0-9A-Za-z.]+)\"?\s*$" % name, text, re.M)
    return m.group(1) if m else None


class CiScriptsTest(unittest.TestCase):
    def test_xcodegen_pin_matches_workflows(self):
        post = read("ci_scripts/ci_post_clone.sh")
        for name in ("XCODEGEN_VERSION", "XCODEGEN_SHA256"):
            want = pin(post, name)
            self.assertTrue(want, name)
            for wf in (".github/workflows/ci.yml", ".github/workflows/canary.yml"):
                self.assertEqual(pin(read(wf), name), want, "%s %s" % (wf, name))

    def test_post_clone_is_executable_and_parses(self):
        git = shutil.which("git")
        if git and (ROOT / ".git").exists():
            out = subprocess.run([git, "ls-files", "-s", "ci_scripts/ci_post_clone.sh"],
                                 cwd=ROOT, capture_output=True, text=True).stdout
            if out:
                self.assertTrue(out.startswith("100755"), out)
        bash = shutil.which("bash")
        if bash:
            r = subprocess.run([bash, "-n", str(POST_CLONE)], capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stderr)

    def test_post_clone_reuses_setup_sh(self):
        post = read("ci_scripts/ci_post_clone.sh")
        self.assertIn("ET_STRICT=1 bash Scripts/setup.sh", post)
        self.assertNotIn("--recursive", post.replace("--recursive は付けない", ""))

    def test_beta_configuration_owns_icon_and_flag(self):
        yml = read("project.yml").replace("\r\n", "\n")
        self.assertRegex(yml, r"(?m)^configs:\n  Debug: debug\n  Release: release\n  Beta: release\n")
        m = re.search(r"(?m)^settings:\n  configs:\n    Beta:\n((?:      .*\n)+)", yml)
        self.assertTrue(m, "settings.configs.Beta が無い")
        beta = m.group(1)
        self.assertIn("ET_APPICON: EffectDeckPublicBeta", beta)
        self.assertIn('SWIFT_ACTIVE_COMPILATION_CONDITIONS: "$(inherited) ET_BETA"', beta)
        # ET_BETA は Beta 構成のほかに書かない。紫のアイコンも同じ。
        code = [l for l in yml.splitlines() if not l.lstrip().startswith("#")]
        self.assertEqual(sum("ET_BETA" in l for l in code), 1)
        self.assertEqual(sum("ET_APPICON: EffectDeckPublicBeta" in l for l in code), 1)
        self.assertEqual(len(re.findall(r"(?m)^\s*ET_APPICON:", yml)), 2)
        # 既定の ET_APPICON は青。
        self.assertRegex(yml, r"(?m)^  base:\n(?:    #.*\n)*    ET_APPICON: EffeTuneLive\n")

    def test_schemes_archive_with_matching_configuration(self):
        yml = read("project.yml").replace("\r\n", "\n")
        self.assertRegex(yml, r"(?m)^  EffeTuneLive:\n(?:    .*\n|\n|    #.*\n)*?    archive:\n      config: Release\n")
        self.assertRegex(yml, r'(?m)^  "EffectDeck Beta":\n    build:\n      targets:\n        EffeTuneLive: all\n    archive:\n      config: Beta\n')

    def test_app_entitlements_keep_empty_media_device_key(self):
        # 本体はキーを空の配列で持つ（アップロードの検査 ITMS-91183 が要る）。値を入れると
        # AVAudioSession の有効化が拒まれる。値は拡張（.appex）だけが持つ。
        app = read("Sources/EffeTuneLive/EffeTuneLive.entitlements")
        self.assertRegex(app, r"<key>com\.apple\.developer\.media-device-extension</key>\s*<array/>")
        ext = read("Sources/Extension/Extension.entitlements")
        self.assertIn("media-device-protocol.ai.nemut.effetune", ext)


if __name__ == "__main__":
    unittest.main()
