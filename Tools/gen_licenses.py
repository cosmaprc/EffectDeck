#!/usr/bin/env python3
"""ライセンス本文を Swift へ焼く。

外へリンクを張るのではなく、本文をアプリに同梱する。
配布物の中身と表示が食い違わないよう、置き場のファイルをそのまま読む。

ライセンスが別ファイルでなくソースの頭のコメントにしか無いもの（DPF の Base64.hpp）は、
その文面を Licenses/ に写して読む。写しが元のコメントとずれていれば止める（COPIES）。
Tools/check_repo.py は、ここの ITEMS が全部 NOTICE.md に書いてあるかも見る。
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "Sources" / "EffeTuneLive" / "Generated" / "Licenses.swift"

ITEMS = [
    ("EffectDeck", "MIT", "nemut.ai", "LICENSE"),
    ("EffeTune", "MIT", "Yoshiyuki Kobayashi", "Vendor/effetune/LICENSE"),
    ("PFFFT", "BSD-3-Clause", "Julien Pommier", "Vendor/effetune/dsp/vendor/pffft/LICENSE.txt"),
    ("ysfx", "Apache-2.0", "Jean Pierre Cimalando, Joep Vanlier and contributors", "Vendor/ysfx/LICENSE"),
    ("WDL / LICE", "zlib-style", "Cockos Incorporated and contributors", "Vendor/ysfx/thirdparty/WDL/LICENSE.txt"),
    # ysfx_utils.cpp が #include して base64 の出し入れに使う（JSFX の状態の保存）。
    # 注意書きは DPF の ISC と、元になった René Nyffenegger のコードの zlib 形式の 2 つ。
    ("DPF Base64", "ISC, zlib-style", "Filipe Coelho, Jean Pierre Cimalando, René Nyffenegger",
     "Licenses/dpf-base64.LICENSE"),
    # Synthetic Binaural Room（MIT、M0Rf30/easyeffects-presets）は外してある。使うのは
    # Virtual Room（feature/brir）で、まだアプリに入っていない。入れるときに、
    # 142c217で足したLicenses/easyeffects-presets.LICENSEとNOTICE.mdの節と一緒に戻す。
    # **feature/brirをそのまま混ぜると、ここで外したものは戻らない**（あちらは触っていないので）。
]


# Licenses/ の写し -> 元のソース。元がある木（Vendor/ysfx を取ってある）では文面を突き合わせる。
COPIES = {
    "Licenses/dpf-base64.LICENSE": "Vendor/ysfx/sources/base64/Base64.hpp",
}


def squash(text: str) -> str:
    """コメントの印（/* * //）・改行・空白の違いを無視して比べるための形。"""
    return re.sub(r"[\s*/]+", "", text)


def raw_hashes(text: str) -> str:
    """text を Swift の生文字列 #…#\"\"\"…\"\"\"#…# に書いたとき、書いたとおりに読まれる # の数。

    \\ に同じ数の # が続けばエスケープ、\"\"\" に同じ数の # が続けばそこで閉じるので、
    どちらも中身に出ない数まで増やす。Tools/gen_presets.py の raw_hashes と同じ。
    """
    hashes = "#"
    while "\\" + hashes in text or '"""' + hashes in text:
        hashes += "#"
    return hashes


def source_tree(source: str) -> pathlib.Path:
    """元のソースが入っている木（Vendor/ysfx）。submodule を取っていなければ空のフォルダか無い。"""
    return ROOT.joinpath(*pathlib.PurePosixPath(source).parts[:2])


def check_copies():
    """写しの文面が元のソースの頭のコメントにそのまま在るか。ずれていれば説明の列を返す。"""
    bad = []
    for copy, source in COPIES.items():
        src = ROOT / source
        if not src.is_file():
            tree = source_tree(source)
            if tree.is_dir() and any(tree.iterdir()):
                # 木は在るのに元が無い＝上流が動かした。黙って確かめるのをやめない。
                bad.append("%s の元の %s が無い（上流で動いた？ COPIES を直す）" % (copy, source))
            # 木ごと無い（Vendor/ysfx を取っていない）ときは確かめられない
            continue
        whole = squash(src.read_text(encoding="utf-8"))
        # 写しは段落ごとに元のどこかに在ればよい（元は 2 つのコメントの間に #include がある）。
        for para in re.split(r"\n\s*\n", (ROOT / copy).read_text(encoding="utf-8")):
            if squash(para) and squash(para) not in whole:
                bad.append("%s の段落が %s に無い: %s…" % (copy, source, para.strip()[:40]))
    return bad


def main() -> int:
    drift = check_copies()
    if drift:
        for d in drift:
            print("!!", d, file=sys.stderr)
        return 1
    lines = [
        "//  Licenses.swift",
        "//  Tools/gen_licenses.py が作る。手で直さないこと。",
        "//",
        "//  本文は置き場のファイルをそのまま読んでいる。",
        "//  外へリンクを張らず同梱するのは、配布物と表示が食い違わないようにするため。",
        "",
        "import Foundation",
        "",
        "struct ETLicense: Identifiable {",
        "    var id: String { name }",
        "    let name: String",
        "    let license: String",
        "    let author: String",
        "    let text: String",
        "}",
        "",
        "let ETLicenses: [ETLicense] = [",
    ]
    for name, lic, author, rel in ITEMS:
        path = ROOT / rel
        if not path.is_file():
            print("!! 無い", rel, file=sys.stderr)
            return 1
        text = path.read_text(encoding="utf-8").strip()
        hashes = raw_hashes(text)
        lines += [
            "    ETLicense(",
            '      name: "%s",' % name,
            '      license: "%s",' % lic,
            '      author: "%s",' % author,
            '      text: %s"""' % hashes,
            # Swift の複数行文字列は、中身の行が閉じ記号より浅いとエラーになる。
            *['      ' + ln if ln else '' for ln in text.splitlines()],
            '      """%s),' % hashes,
        ]
    lines += ["]", ""]
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text("\n".join(lines), encoding="utf-8", newline="\n")
    print("licenses: %d 本" % len(ITEMS))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
