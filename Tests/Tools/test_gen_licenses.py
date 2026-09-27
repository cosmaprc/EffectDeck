"""Tools/gen_licenses.py の試験。アプリに積んでいるコードのライセンスを全部出すこと。"""
import re

from tools_support import ROOT, TempDir, load_tool, quiet, run_main, swift_raw_text, unittest, write


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

    # Base64.hpp でなく木の LICENSE で見る。上流が Base64.hpp を動かしたら、飛ばさずに落ちる。
    @unittest.skipUnless((ROOT / "Vendor/ysfx/LICENSE").is_file(), "Vendor/ysfx が無い")
    def test_base64_copy_matches_vendor_header(self):
        self.assertEqual(self.gl.check_copies(), [])

    def test_copy_source_moved_is_reported(self):
        # 元の木（Vendor/ysfx）は在るのに元のファイルが無い＝上流が動かした。黙って確かめるのを
        # やめず、止める。木ごと無い（submodule を取っていない、空のフォルダ）ときだけ飛ばす。
        with TempDir() as tmp:
            write(tmp / "copy.LICENSE", "Copyright (C) 2020 Someone\n")
            self.gl.ROOT = tmp
            self.gl.COPIES = {"copy.LICENSE": "Vendor/lib/src/a.hpp"}
            self.assertEqual(self.gl.check_copies(), [])
            (tmp / "Vendor/lib").mkdir(parents=True)
            self.assertEqual(self.gl.check_copies(), [])
            write(tmp / "Vendor/lib/LICENSE", "x\n")
            bad = self.gl.check_copies()
            self.assertEqual(len(bad), 1, bad)
            self.assertIn("Vendor/lib/src/a.hpp", bad[0])
            self.gl.OUT = tmp / "Licenses.swift"
            self.gl.ITEMS = [("Copy", "MIT", "x", "copy.LICENSE")]
            with quiet():
                self.assertNotEqual(run_main(self.gl.main), 0)
            self.assertFalse((tmp / "Licenses.swift").exists())

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

    def test_backslash_hash_survives_swift_raw_string(self):
        # 本文に \# か """# があれば、#"""…"""# の中では Swift が別の字に読む（閉じる）。
        # 中身に出ない数まで # を増やし、本文は書いたとおりに読まれる。
        body = 'Copyright (C) 2020 Someone\n\nSee C:\\#docs and the """# marker.'
        with TempDir() as tmp:
            write(tmp / "odd.LICENSE", body + "\n")
            self.gl.ROOT = tmp
            self.gl.OUT = tmp / "Licenses.swift"
            self.gl.COPIES = {}
            self.gl.ITEMS = [("Odd", "MIT", "x", "odd.LICENSE")]
            with quiet():
                self.assertEqual(run_main(self.gl.main), 0)
            text = (tmp / "Licenses.swift").read_text("utf-8")
        m = re.search(r'      text: (#+)"""\n(.*?)\n      """\1\),', text, re.S)
        self.assertIsNotNone(m, text)
        self.assertEqual(m.group(1), "##")
        lines = [ln[6:] if ln else "" for ln in m.group(2).split("\n")]
        self.assertEqual(swift_raw_text(m.group(1), "\n".join(lines)), body)

    def test_committed_file_lists_every_item(self):
        text = (ROOT / "Sources/EffeTuneLive/Generated/Licenses.swift").read_text("utf-8")
        names = re.findall(r'^      name: "([^"]*)",$', text, re.M)
        self.assertEqual(names, [item[0] for item in self.gl.ITEMS])


if __name__ == "__main__":
    unittest.main()
