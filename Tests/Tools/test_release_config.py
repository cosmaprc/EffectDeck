"""配布まわり（.github/workflows/release.yml・project.yml の構成・書き出しの設定）の照合。

- 道具の版（xcodegen の版と sha256・Xcode・runner のラベル）が ci.yml・canary.yml・release.yml で食い違わない。
- release.yml が守る決まり（承認の Environment・秘密の置き場・submodule の取り方・上げ先）。
- 紫（アイコン EffectDeckPublicBeta）と ET_BETA は Beta 構成の同じ所にだけ書いてある。
- Scripts/ExportOptions-ci.plist（クラウド署名の書き出し）の鍵。
"""
import plistlib
import re

from tools_support import ROOT, unittest

CI = ".github/workflows/ci.yml"
CANARY = ".github/workflows/canary.yml"
RELEASE = ".github/workflows/release.yml"


def read(rel):
    return (ROOT / rel).read_text(encoding="utf-8").replace("\r\n", "\n")


def code(rel):
    """コメント行を除いた本文。"""
    return "\n".join(l for l in read(rel).splitlines() if not l.lstrip().startswith("#"))


def pin(text, name):
    m = re.search(r"^\s*%s[:=]\s*\"?([0-9A-Za-z./_-]+)\"?\s*$" % name, text, re.M)
    return m.group(1) if m else None


def runs_on(text):
    return set(re.findall(r"(?m)^\s*runs-on:\s*(xcode-\S+)\s*$", text))


def job_block(text, job):
    """トップレベルの jobs: の下の job 1 つ分（次の同じ深さの job まで）。"""
    m = re.search(r"(?ms)^  %s:\n(.*?)(?=^  [A-Za-z0-9_-]+:\n|\Z)" % re.escape(job), text)
    return m.group(1) if m else None


class ReleaseConfigTest(unittest.TestCase):
    def test_tool_pins_match_across_workflows(self):
        ci, canary, release = read(CI), read(CANARY), read(RELEASE)
        for name in ("XCODEGEN_VERSION", "XCODEGEN_SHA256"):
            want = pin(ci, name)
            self.assertTrue(want, name)
            self.assertEqual(pin(canary, name), want, "canary %s" % name)
            self.assertEqual(pin(release, name), want, "release %s" % name)
        xcode = pin(ci, "XCODE_APP")
        self.assertTrue(xcode)
        self.assertEqual(pin(release, "XCODE_APP"), xcode)
        self.assertEqual(pin(canary, "STABLE_XCODE_APP"), xcode)
        label = runs_on(ci)
        self.assertEqual(len(label), 1, label)
        self.assertEqual(runs_on(canary), label)
        self.assertEqual(runs_on(release), label)

    def test_release_triggers(self):
        rel = read(RELEASE)
        self.assertRegex(rel, r"(?m)^on:\n  push:\n    tags: \['tf-\*'\]\n  workflow_dispatch:")
        self.assertNotIn("pull_request", code(RELEASE))
        self.assertRegex(rel, r"(?m)^concurrency:\n  group: release\n  cancel-in-progress: false\n")
        # dry_run の既定は true（手で回したときは上げない）。
        self.assertRegex(rel, r"(?m)^      dry_run:\n(?:        .*\n)*?        default: true\n")

    def test_only_the_release_job_reads_secrets_and_it_needs_approval(self):
        text = read(RELEASE)
        gate, release = job_block(text, "gate"), job_block(text, "release")
        self.assertTrue(gate and release)
        self.assertNotIn("secrets.", gate)
        self.assertNotIn("environment:", gate)
        self.assertRegex(release, r"(?m)^    environment: release$")
        self.assertRegex(release, r"(?m)^    needs: gate$")
        for name in ("ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_KEY_P8"):
            self.assertIn("secrets.%s" % name, release)
        # 秘密の参照は release ジョブの 3 つだけ。ほかのワークフローは ASC の secret を持たない。
        self.assertEqual(len(re.findall(r"secrets\.", code(RELEASE))), 3)
        for wf in (CI, CANARY, ".github/workflows/dsp.yml"):
            self.assertNotIn("secrets.ASC_", read(wf), wf)

    def test_release_matches_the_local_build_recipe(self):
        rel = code(RELEASE)
        self.assertIn("ET_STRICT=1 bash Scripts/setup.sh", rel)
        self.assertNotIn("--recursive", rel)
        self.assertIn("bash Scripts/archive.sh EffeTuneLive", rel)
        self.assertIn("Scripts/ExportOptions-ci.plist", rel)
        self.assertIn("check_release_binary.py", rel)
        # submodule の取り方は ci.yml と同じ行（effetune は履歴ごと、ysfx は浅く）。
        ci = read(CI)
        for line in ("git submodule update --init --filter=blob:none Vendor/effetune",
                     "git submodule update --init --depth 1 Vendor/ysfx"):
            self.assertIn(line, ci)
            self.assertIn(line, rel)

    def test_release_never_touches_external_testers_or_review(self):
        rel = code(RELEASE)
        for bad in ("86b1db0a", "Public Beta", "reviewSubmissions", "appStoreVersions/",
                    "Tools/asc.py attach", "Tools/asc.py submit", "betaGroups"):
            self.assertNotIn(bad, rel, bad)
        # 足してよいのは Internal だけ（asc.py が内部グループか確かめる）。
        self.assertEqual(len(re.findall(r"Tools/asc\.py add-internal", rel)), 1)

    def test_release_uploads_no_binaries_as_artifacts(self):
        rel = code(RELEASE)
        m = re.search(r"(?ms)uses: actions/upload-artifact@\S+\n        with:\n(.*?)(?=^      - |\Z)", rel)
        self.assertTrue(m, "upload-artifact が無い")
        path = re.search(r"(?m)^          path: \|\n((?:            .*\n?)+)", m.group(1))
        self.assertTrue(path)
        for forbidden in (".ipa", ".xcarchive", ".p8", "appstoreconnect", "private_keys"):
            self.assertNotIn(forbidden, path.group(1), forbidden)
        # 鍵は必ず消す。
        self.assertRegex(rel, r"(?s)if: always\(\)\n        run: \|\n          rm -f .*AuthKey_")

    def test_export_options_use_cloud_signing(self):
        with open(ROOT / "Scripts" / "ExportOptions-ci.plist", "rb") as f:
            opts = plistlib.load(f)
        self.assertEqual(opts["method"], "app-store-connect")
        self.assertEqual(opts["destination"], "export")
        self.assertEqual(opts["signingStyle"], "automatic")
        self.assertEqual(opts["teamID"], "C82ST8T9MN")
        self.assertIs(opts["manageAppVersionAndBuildNumber"], False)
        self.assertNotIn("provisioningProfiles", opts)
        self.assertNotIn("signingCertificate", opts)

    def test_no_xcode_cloud_leftovers(self):
        self.assertFalse((ROOT / "ci_scripts").exists())

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
