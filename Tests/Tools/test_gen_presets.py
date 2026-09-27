"""Tools/gen_presets.py の試験。同梱の鎖プリセットを黙って落とさないこと。"""
import json
import re

from tools_support import ROOT, TempDir, env_patch, load_tool, quiet, run_main, unittest, write

RAW = re.compile(r'      category: "([^"]*)",\n      name: "([^"]*)",\n      effectCount: (\d+),\n'
                 r'      json: #"""\n      (.*)\n      """#\),')


def embedded(swift_text):
    """SystemPresets.swift に埋めた (分類, 名前, 段数, JSON) を読み戻す。"""
    return [(m.group(1), m.group(2), int(m.group(3)), json.loads(m.group(4)))
            for m in RAW.finditer(swift_text)]


class GenPresetsTests(unittest.TestCase):
    def setUp(self):
        self.gp = load_tool("gen_presets")

    def run_gen(self, tmp, strict=None):
        self.gp.SRC = tmp / "presets"
        self.gp.OUT = tmp / "SystemPresets.swift"
        with env_patch(ET_STRICT=strict), quiet() as (out, err):
            code = run_main(self.gp.main)
        return code, out.getvalue(), err.getvalue()

    def preset(self, tmp, rel, data):
        write(tmp / "presets" / rel, json.dumps(data, ensure_ascii=False))

    def test_count_equals_files(self):
        with TempDir() as tmp:
            self.preset(tmp, "spatial/wide_room.effetune_preset", {"pipeline": [{"name": "A"}, {"name": "B"}]})
            self.preset(tmp, "utils/level.effetune_preset", {"pipeline": [{"name": "Level Meter"}]})
            self.preset(tmp, "odd/Mixed_case.effetune_preset", {"pipeline": []})
            code, out, err = self.run_gen(tmp)
            self.assertEqual(code, 0, err)
            items = embedded((tmp / "SystemPresets.swift").read_text("utf-8"))
        self.assertEqual(len(items), 3)
        self.assertEqual([(c, n, k) for c, n, k, _ in items],
                         [("odd", "Mixed Case", 0), ("Spatial", "Wide Room", 2), ("Utilities", "Level", 1)])

    def test_broken_fails_strict(self):
        with TempDir() as tmp:
            self.preset(tmp, "utils/good.effetune_preset", {"pipeline": []})
            write(tmp / "presets/utils/broken.effetune_preset", '{"pipeline": [')
            write(tmp / "presets/utils/shape.effetune_preset", '{"chain": []}')
            code, out, err = self.run_gen(tmp, strict="1")
            self.assertNotEqual(code, 0)
            self.assertIn("broken.effetune_preset", err)
            self.assertIn("shape.effetune_preset", err)
            self.assertFalse((tmp / "SystemPresets.swift").exists())
            # ET_STRICT が無ければ今までどおり書く（警告は出す）。
            code, out, err = self.run_gen(tmp)
            self.assertEqual(code, 0)
            self.assertIn("broken.effetune_preset", err)
            self.assertEqual(len(embedded((tmp / "SystemPresets.swift").read_text("utf-8"))), 1)

    def test_embedded_json_roundtrip(self):
        # 埋めた字を JSON として読み戻すと元のファイルと同じ。生文字列の終わり（"""#）を含む中身は止める。
        data = {"pipeline": [{"name": "Section", "cm": "引用\"符 \\ と #"}, {"name": "Gain", "vl": -3.5}]}
        with TempDir() as tmp:
            self.preset(tmp, "utils/tricky.effetune_preset", data)
            code, out, err = self.run_gen(tmp)
            self.assertEqual(code, 0, err)
            items = embedded((tmp / "SystemPresets.swift").read_text("utf-8"))
        self.assertEqual(items[0][3], data)
        with self.assertRaises(ValueError):
            self.gp.swift_raw('{"a":"x"}"""#')

    @unittest.skipUnless((ROOT / "Vendor/effetune/presets").is_dir(), "Vendor/effetune が無い")
    def test_committed_file_matches_vendor(self):
        # 追跡している SystemPresets.swift が Vendor の .effetune_preset と同じ中身を持つ。
        committed = embedded((ROOT / "Sources/EffeTuneLive/Generated/SystemPresets.swift").read_text("utf-8"))
        files = sorted((ROOT / "Vendor/effetune/presets").rglob("*.effetune_preset"))
        self.assertEqual(len(committed), len(files))
        by_name = {(c, n): d for c, n, _, d in committed}
        for f in files:
            key = (self.gp.LABEL.get(f.parent.name, f.parent.name), self.gp.title(f.stem))
            self.assertEqual(by_name[key], json.loads(f.read_text("utf-8")), f.name)


if __name__ == "__main__":
    unittest.main()
