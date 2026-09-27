#!/usr/bin/env python3
"""pick_simulator.py の試験。simctl は叩かない（JSON を渡す）。

    python3 -m unittest discover -s .github/scripts -p 'test_*.py'
"""
import contextlib
import io
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pick_simulator  # noqa: E402

IOS = "com.apple.CoreSimulator.SimRuntime.iOS-"
NAME = "iPad Pro 13-inch (M5)"


def dev(name, udid, available=True):
    return {"name": name, "udid": udid, "isAvailable": available, "state": "Shutdown"}


class PickSimulatorTests(unittest.TestCase):
    def run_main(self, devices):
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False,
                                         encoding="utf-8") as f:
            json.dump({"devices": devices}, f)
        self.addCleanup(os.unlink, f.name)
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = pick_simulator.main(["--name", NAME, "--os", "27.0", "--json", f.name])
        return code, out.getvalue().strip(), err.getvalue()

    def test_exact_name_and_version(self):
        code, udid, _ = self.run_main({
            IOS + "27-0": [dev("iPhone 17", "A-17"), dev(NAME, "A-PRO13"), dev("iPad Air 11-inch (M4)", "A-AIR")],
            IOS + "27-2": [dev(NAME, "B-PRO13-272")],
            "com.apple.CoreSimulator.SimRuntime.watchOS-27-0": [dev("Apple Watch Ultra 4 (49mm)", "W")],
        })
        self.assertEqual((code, udid), (0, "A-PRO13"))

    def test_other_version_of_same_name_is_not_taken(self):
        # 27.2 にしか居ない名前より、27.0 の別の iPad Pro を選ぶ。
        code, udid, err = self.run_main({
            IOS + "27-2": [dev(NAME, "B-PRO13-272")],
            IOS + "27-0": [dev("iPad Pro 11-inch (M5)", "C-PRO11")],
        })
        self.assertEqual((code, udid), (0, "C-PRO11"))
        self.assertIn("代わり", err)

    def test_fallback_prefers_ipad_pro_then_ipad_then_iphone(self):
        code, udid, _ = self.run_main({IOS + "27-0": [
            dev("iPhone 17e", "C-17E"), dev("iPad mini (A17 Pro)", "C-MINI"), dev("iPad Pro 11-inch (M5)", "C-PRO11")]})
        self.assertEqual((code, udid), (0, "C-PRO11"))
        code, udid, _ = self.run_main({IOS + "27-0": [dev("iPhone 17e", "C-17E"), dev("iPad mini (A17 Pro)", "C-MINI")]})
        self.assertEqual((code, udid), (0, "C-MINI"))
        code, udid, _ = self.run_main({IOS + "27-0": [dev("iPhone 17e", "C-17E")]})
        self.assertEqual((code, udid), (0, "C-17E"))

    def test_point_release_runtime_matches(self):
        code, udid, _ = self.run_main({IOS + "27-0-1": [dev(NAME, "P-PRO13")]})
        self.assertEqual((code, udid), (0, "P-PRO13"))

    def test_minor_version_does_not_match(self):
        # 27.1 は 27.0 ではない（startswith("27.0") の取り違えを防ぐ）。
        code, udid, err = self.run_main({IOS + "27-1": [dev(NAME, "M-PRO13")], IOS + "27-10": [dev(NAME, "M-PRO13-10")]})
        self.assertEqual((code, udid), (1, ""))
        self.assertIn("27.1", err)

    def test_unavailable_device_is_skipped(self):
        code, udid, _ = self.run_main({IOS + "27-0": [dev(NAME, "X-GONE", available=False), dev("iPad (A16)", "X-A16")]})
        self.assertEqual((code, udid), (0, "X-A16"))

    def test_no_matching_version_fails_and_lists_devices(self):
        code, udid, err = self.run_main({IOS + "26-4": [dev(NAME, "D-264")]})
        self.assertEqual((code, udid), (1, ""))
        self.assertIn("D-264", err)

    def test_only_udid_on_stdout(self):
        _, udid, err = self.run_main({IOS + "27-0": [dev(NAME, "A-PRO13")]})
        self.assertEqual(udid.splitlines(), ["A-PRO13"])
        self.assertIn("simulator:", err)


if __name__ == "__main__":
    unittest.main()
