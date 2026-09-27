#!/usr/bin/env python3
"""EffeTune 同梱のプリセットを Swift へ焼く。

Vendor/effetune/presets/<category>/<name>.effetune_preset をそのまま持ち込む。
中身は PipelineStore.parse がそのまま受ける形（{"pipeline": [...]}) なので、
変換はせず JSON の文字列のまま埋める。エフェクト名と鍵の対応は読み込み時に取る。

リソースとして同梱しないのは、.xcassets の外のファイルを束ねると
名前の衝突で「Multiple commands produce」に当たるため。

**読めないファイルは黙って落とさない。**いつもは stderr に !! で出して残りを書き、
ET_STRICT=1（CI）か --strict では何も書かずに 1 で止める（17 本が 16 本になっても
終了コードが 0 のままだった）。

  python Tools/gen_presets.py [--strict]
"""
import json
import os
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "Vendor" / "effetune" / "presets"
OUT = ROOT / "Sources" / "EffeTuneLive" / "Generated" / "SystemPresets.swift"

LABEL = {
    "4ch": "4 Channel",
    "amp_sim": "Amp Simulation",
    "lofi": "Lo-Fi",
    "others": "Others",
    "processor": "Processor",
    "spatial": "Spatial",
    "spkr_sim": "Speaker Simulation",
    "utils": "Utilities",
    "visualize": "Visualize",
}


def title(stem: str) -> str:
    return " ".join(w.capitalize() if w.islower() else w for w in stem.split("_"))


def strict_mode() -> bool:
    return os.environ.get("ET_STRICT", "") not in ("", "0") or "--strict" in sys.argv[1:]


def swift_raw(compact: str) -> str:
    # Swift の #"""…"""# の生文字列に入れる字。閉じ記号 """# を含むものは入れられないので止める。
    # （生文字列なので \" や \\ は JSON のまま残る。見るのは閉じ記号だけでよい）
    if '"""#' in compact:
        raise ValueError('生文字列の閉じ記号 """# を含む')
    return compact


def main() -> int:
    if not SRC.is_dir():
        print("!! presets が無い", SRC, file=sys.stderr)
        return 1

    items = []
    broken = []
    for path in sorted(SRC.rglob("*.effetune_preset")):
        category = path.parent.name
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except Exception as e:  # noqa: BLE001
            broken.append("読めない %s: %s" % (path.relative_to(SRC).as_posix(), e))
            continue
        if not isinstance(data, dict) or not isinstance(data.get("pipeline"), list):
            broken.append("形が違う（pipeline の配列が無い） %s" % path.relative_to(SRC).as_posix())
            continue
        # 余分な空白を落として埋める。往復はしないので整形は不要。
        compact = json.dumps(data, ensure_ascii=False, separators=(",", ":"))
        try:
            compact = swift_raw(compact)
        except ValueError as e:
            broken.append("%s: %s" % (path.relative_to(SRC).as_posix(), e))
            continue
        items.append((LABEL.get(category, category), title(path.stem), compact,
                      len(data["pipeline"])))

    for b in broken:
        print("!! 落とした:", b, file=sys.stderr)
    if broken and strict_mode():
        print("!! 落としたプリセットが %d 本ある（ET_STRICT）。何も書いていない" % len(broken),
              file=sys.stderr)
        return 1

    lines = [
        "//  SystemPresets.swift",
        "//  Tools/gen_presets.py が作る。手で直さないこと。",
        "//",
        "//  中身は EffeTune 同梱の .effetune_preset をそのまま持ってきたもの。",
        "//  読むのは PipelineStore.parse で、ユーザーが保存したものと同じ経路を通る。",
        "",
        "import Foundation",
        "",
        "struct ETSystemPreset: Identifiable {",
        "    var id: String { category + \"/\" + name }",
        "    let category: String",
        "    let name: String",
        "    let effectCount: Int",
        "    let json: String",
        "}",
        "",
        "let ETSystemPresets: [ETSystemPreset] = [",
    ]
    for category, name, compact, count in items:
        lines.append("    ETSystemPreset(")
        lines.append('      category: "%s",' % category)
        lines.append('      name: "%s",' % name)
        lines.append("      effectCount: %d," % count)
        # Swift の複数行文字列は、中身の行が閉じ記号より浅いとエラーになる。
        lines.append('      json: #"""')
        lines.append('      ' + compact)
        lines.append('      """#),')
    lines.append("]")
    lines.append("")

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text("\n".join(lines), encoding="utf-8", newline="\n")
    print("presets: %d 本 / %d カテゴリ%s" % (len(items), len({i[0] for i in items}),
                                             "（%d 本を落とした）" % len(broken) if broken else ""))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
