"""Tools/gen_effect_presets.py の試験。ET_STRICT=1 では飛ばさずに止まること。"""
import json
import shutil
import subprocess
from unittest import mock

from tools_support import (ROOT, TempDir, env_patch, have_node, load_tool, quiet, run_main,
                           unittest, write)

PLUGINS_TXT = """\
[core]
ignored: x | y | z
[plugins]
# comment
dynamics/sag: Power Amp Sag | Dynamics | PowerAmpSagPlugin | css
dynamics/broken: Broken | Dynamics | BrokenPlugin
"""

SAG_JS = """
const SAG_PRESETS = Object.freeze([{ id: 'soft', label: 'Soft', params: { sg: 1 } }]);
class PowerAmpSagPlugin extends PluginBase {
    static getSystemPresetGroups() { return [{ label: '', presets: SAG_PRESETS }]; }
}
"""

BROKEN_JS = """
class BrokenPlugin extends PluginBase {
    static getSystemPresetGroups() { throw new Error('boom'); }
}
"""


def fake_run(stdout, stderr=b"", returncode=0):
    def run(*args, **kwargs):
        if returncode:
            raise subprocess.CalledProcessError(returncode, args[0], stdout, stderr)
        return subprocess.CompletedProcess(args[0], 0, stdout, stderr)
    return run


class GenEffectPresetsTests(unittest.TestCase):
    def setUp(self):
        self.ge = load_tool("gen_effect_presets")

    def vendor(self, tmp, broken=False):
        write(tmp / "vendor/plugins/plugins.txt", PLUGINS_TXT)
        write(tmp / "vendor/plugins/dynamics/sag.js", SAG_JS)
        if broken:
            write(tmp / "vendor/plugins/dynamics/broken.js", BROKEN_JS)
        self.ge.OUT = tmp / "EffectPresets.swift"
        return tmp / "vendor"

    def run_gen(self, vendor, strict=None):
        with env_patch(ET_STRICT=strict), quiet() as (out, err):
            code = run_main(self.ge.main, [str(vendor)])
        return code, out.getvalue(), err.getvalue()

    def test_swift_quoted_rejects_quote_and_backslash(self):
        self.assertEqual(self.ge.swift_quoted("Pre+Power"), '"Pre+Power"')
        with self.assertRaises(ValueError):
            self.ge.swift_quoted('a"b')
        with self.assertRaises(ValueError):
            self.ge.swift_quoted("a\\b")

    def test_footer_keeps_keypath_backslash(self):
        self.assertIn("by: \\.effect)", self.ge.FOOTER)

    def test_missing_vendor_fails_strict(self):
        with TempDir() as tmp:
            self.ge.OUT = tmp / "EffectPresets.swift"
            self.assertEqual(self.run_gen(tmp / "nowhere")[0], 0)
            self.assertNotEqual(self.run_gen(tmp / "nowhere", strict="1")[0], 0)

    def test_missing_node_fails_strict(self):
        with TempDir() as tmp:
            vendor = self.vendor(tmp)
            with mock.patch.object(self.ge.shutil, "which", return_value=None):
                self.assertEqual(self.run_gen(vendor)[0], 0)
                code, out, err = self.run_gen(vendor, strict="1")
            self.assertNotEqual(code, 0)
            self.assertIn("node", err)
            self.assertFalse(self.ge.OUT.exists())

    def test_unparsable_output_fails_strict(self):
        # 切れた JSON（Mac のパイプで 65536 バイトで切れた事故）。既定では既存を残して 0、strict では止める。
        with TempDir() as tmp:
            vendor = self.vendor(tmp)
            with mock.patch.object(self.ge.shutil, "which", return_value="node"), \
                    mock.patch.object(self.ge.subprocess, "run", fake_run(b'[{"name": "x", "gro')):
                self.assertEqual(self.run_gen(vendor)[0], 0)
                code, out, err = self.run_gen(vendor, strict="1")
            self.assertNotEqual(code, 0)
            self.assertFalse(self.ge.OUT.exists())

    def test_dumper_warning_fails_strict(self):
        # dump が評価できなかったプラグイン（!! 行）を飛ばして続けても、strict では止める。
        good = json.dumps([{"name": "Power Amp Sag", "groups": [
            {"label": "", "presets": [{"id": "soft", "label": "Soft", "params": {"sg": 1}}]}]}]).encode()
        with TempDir() as tmp:
            vendor = self.vendor(tmp)
            run = fake_run(good, b"!! dynamics/broken \xe3\x82\x92\xe8\xa9\x95\xe4\xbe\xa1\xe3\x81\xa7\xe3\x81\x8d\xe3\x81\xaa\xe3\x81\x84: boom\n")
            with mock.patch.object(self.ge.shutil, "which", return_value="node"), \
                    mock.patch.object(self.ge.subprocess, "run", run):
                code, out, err = self.run_gen(vendor, strict="1")
                self.assertNotEqual(code, 0)
                self.assertFalse(self.ge.OUT.exists())
                code, out, err = self.run_gen(vendor)
            self.assertEqual(code, 0)
            self.assertIn("!! dynamics/broken", err)
            text = self.ge.OUT.read_text("utf-8")
        self.assertIn('presetId: "soft"', text)
        self.assertIn('      {"sg":1}', text)

    @unittest.skipUnless(have_node(), "node が無い")
    def test_end_to_end_with_node(self):
        with TempDir() as tmp:
            vendor = self.vendor(tmp, broken=True)
            code, out, err = self.run_gen(vendor)
            self.assertEqual(code, 0, err)
            self.assertIn("!! dynamics/broken", err)
            text = self.ge.OUT.read_text("utf-8")
            self.assertIn('effect: "Power Amp Sag"', text)
            self.assertIn("effect presets: 1 件 / 1 エフェクト", out)
            code, out, err = self.run_gen(vendor, strict="1")
            self.assertNotEqual(code, 0)

    @unittest.skipUnless(have_node() and (ROOT / "Vendor/effetune/plugins/plugins.txt").is_file(),
                         "node か Vendor/effetune が無い")
    def test_committed_file_matches_vendor(self):
        # 追跡している EffectPresets.swift を Vendor から作り直すと同じになる。
        with TempDir() as tmp:
            self.ge.OUT = tmp / "EffectPresets.swift"
            code, out, err = self.run_gen(ROOT / "Vendor/effetune", strict="1")
            self.assertEqual(code, 0, err)
            fresh = self.ge.OUT.read_text("utf-8")
        committed = (ROOT / "Sources/EffeTuneLive/Generated/EffectPresets.swift").read_bytes()
        self.assertEqual(fresh, committed.decode("utf-8").replace("\r\n", "\n"))


if __name__ == "__main__":
    unittest.main()
