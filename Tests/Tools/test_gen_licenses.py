"""Tools/gen_licenses.py の試験。アプリに積んでいるコードのライセンスを全部出すこと。"""
import re

from tools_support import ROOT, TempDir, load_tool, quiet, run_main, unittest, write


class GenLicensesTests(unittest.TestCase):
    def setUp(self):
        self.gl = load_tool("gen_licenses")

    def test_lists_dpf_base64(self):
        # ysfx_utils.cpp が #include する DPF の Base64.hpp（ISC と zlib 形式の注意書き）。
        names = [item[0] for item in self.gl.ITEMS]
        self.assertIn("DPF Base64", names)
        entry = next(item for item in self.gl.ITEMS if item[0] == "DPF Base64")
        self.assertEqual(entry[3], "Licenses/dpf-base64.LICENSE")
        text = (ROOT / entry[3]).read_text("utf-8")
        self.assertIn("Filipe Coelho", text)
        self.assertIn("René Nyffenegger", text)
        self.assertIn("permission notice appear in all copies", text)

    @unittest.skipUnless((ROOT / "Vendor/ysfx/sources/base64/Base64.hpp").is_file(), "Vendor/ysfx が無い")
    def test_base64_copy_matches_vendor_header(self):
        self.assertEqual(self.gl.check_copies(), [])

    def test_copy_drift_detected(self):
        with TempDir() as tmp:
            write(tmp / "src.hpp", "/*\n * Copyright (C) 2020 Someone\n * Permission granted.\n */\ncode();\n")
            write(tmp / "copy.LICENSE", "Copyright (C) 2020 Someone\nPermission granted.\n")
            self.gl.ROOT = tmp
            self.gl.COPIES = {"copy.LICENSE": "src.hpp"}
            self.assertEqual(self.gl.check_copies(), [])
            write(tmp / "copy.LICENSE", "Copyright (C) 2021 Someone Else\nPermission granted.\n")
            self.assertEqual(len(self.gl.check_copies()), 1)

    def test_missing_file_fails(self):
        with TempDir() as tmp:
            self.gl.ROOT = tmp
            self.gl.OUT = tmp / "Licenses.swift"
            self.gl.COPIES = {}
            self.gl.ITEMS = [("Nothing", "MIT", "x", "NOPE")]
            with quiet():
                self.assertNotEqual(run_main(self.gl.main), 0)
            self.assertFalse((tmp / "Licenses.swift").exists())

    def test_committed_file_lists_every_item(self):
        text = (ROOT / "Sources/EffeTuneLive/Generated/Licenses.swift").read_text("utf-8")
        names = re.findall(r'^      name: "([^"]*)",$', text, re.M)
        self.assertEqual(names, [item[0] for item in self.gl.ITEMS])


if __name__ == "__main__":
    unittest.main()
