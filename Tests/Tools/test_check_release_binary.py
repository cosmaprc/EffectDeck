"""Tools/check_release_binary.py の試験。stdlib だけ。

    python3 -m unittest discover -s Tests/Tools -p 'test_check_release_binary.py' -v

Mach-O はここで組む（chained fixups・export trie・ObjC のクラス一覧・署名の superblob）ので、
Mac の無い所でも回る。clang と iOS を建てられる ld64.lld（LD64_LLD で名指しできる）と llvm-nm が
あれば、本物のリンカが吐いたものを llvm-nm・llvm-objdump と突き合わせる試験も回る。
"""
import contextlib
import importlib.util
import io
import os
import pathlib
import plistlib
import shutil
import stat
import struct
import subprocess
import sys
import tempfile
import unittest
import zipfile

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
TOOL = ROOT / "Tools" / "check_release_binary.py"
_loaded = [0]


def load():
    _loaded[0] += 1
    spec = importlib.util.spec_from_file_location("check_release_binary_%d" % _loaded[0], TOOL)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


CRB = load()


def write(path, text):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8", newline="\n")
    return path


# ---------------------------------------------------------------------------
# Mach-O を組む
# ---------------------------------------------------------------------------

def uleb(v):
    out = bytearray()
    while True:
        b = v & 0x7F
        v >>= 7
        if v:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


def export_trie(names):
    """根から名前ごとに 1 本ずつ枝を出すだけの trie（dyld が読める形）。"""
    names = sorted(names)
    leaves = [uleb(len(uleb(0) + uleb(0x1000 + i))) + uleb(0) + uleb(0x1000 + i) + b"\0" for i in range(len(names))]
    root_len = 2
    while True:
        offs, off = [], root_len
        for leaf in leaves:
            offs.append(off)
            off += len(leaf)
        root = b"\0" + bytes([len(names)]) + b"".join(n.encode() + b"\0" + uleb(o) for n, o in zip(names, offs))
        if len(root) == root_len:
            return root + b"".join(leaves)
        root_len = len(root)


def align(n, a=8):
    return (n + a - 1) // a * a


BASE = 0x100000000


def build_macho(cstrings=(), exports=("__mh_execute_header",), imports=(), locals_count=0, classes=(),
                methnames=(), entitlements=None, simulated=None, chained=True, pointer_format=6, cputype=None,
                import_format=1, nlist_imports=True):
    """薄い arm64 の MH_EXECUTE。classes は ObjC の実行時の名前。
    import_format は chained fixups の取り込み表の形（1 = IMPORT、2 = ADDEND、3 = ADDEND64）。
    nlist_imports=False なら取り込む名前を nlist に置かない（chained fixups の表にだけ在る）。"""
    text_secs = [("__text", b"\x1f\x20\x03\xd5", 0x80000400),
                 ("__cstring", b"".join(s + b"\0" for s in cstrings), 2),
                 ("__objc_methname", b"".join(s.encode() + b"\0" for s in methnames), 2),
                 ("__objc_classname", b"".join(s.encode() + b"\0" for s in classes), 2)]
    if simulated is not None:
        text_secs.append(("__entitlements", plistlib.dumps(simulated), 0))
    n = len(classes)
    data_const_secs = [("__objc_classlist", 8 * n)]
    data_secs = [("__objc_data", 40 * n), ("__objc_const", 48 * n)]
    has_sig = entitlements is not None
    ncmds = 4 + (2 if chained else 1) + 1 + (1 if has_sig else 0)
    sizeofcmds = (72 + 80 * len(text_secs)) + (72 + 80) + (72 + 80 * 2) + 72
    sizeofcmds += (16 + 16) if chained else 48
    sizeofcmds += 24 + (16 if has_sig else 0)

    off = align(32 + sizeofcmds, 16)
    text_layout = []
    for name, blob, flags in text_secs:
        text_layout.append((name, off, blob, flags))
        off = align(off + len(blob))
    text_end = align(off, 16)
    dc_start = text_end
    classlist_off = dc_start
    dc_end = align(classlist_off + 8 * n, 16)
    data_start = dc_end
    objc_data_off = data_start
    objc_const_off = align(objc_data_off + 40 * n)
    data_end = align(objc_const_off + 48 * n, 16)
    le = data_end

    def enc(target):
        if not chained:
            return target
        if pointer_format == 6:
            return target - BASE
        return target

    class_name_addr = {}
    cn = next(t for t in text_layout if t[0] == "__objc_classname")
    p = cn[1]
    for c in classes:
        class_name_addr[c] = BASE + p
        p += len(c.encode()) + 1

    body = {}
    for i, c in enumerate(classes):
        cls = BASE + objc_data_off + 40 * i
        ro = BASE + objc_const_off + 48 * i
        body[classlist_off + 8 * i] = struct.pack("<Q", enc(cls))
        body[objc_data_off + 40 * i] = struct.pack("<QQQQQ", 0, 0, 0, 0, enc(ro | 2))  # Swift の印（下位ビット）
        body[objc_const_off + 48 * i] = struct.pack("<IIIIQQQQQ", 0, 0, 0, 0, 0, enc(class_name_addr[c]), 0, 0, 0)[:48]

    link = bytearray()

    def put(blob):
        start = le + len(link)
        link.extend(blob)
        while len(link) % 8:
            link.append(0)
        return start, len(blob)

    chained_range = exports_range = None
    if chained:
        imp_names = list(imports)
        pool = b"".join(x.encode() + b"\0" for x in imp_names)
        starts_off = 32
        seg_count = 4
        seg_infos_len = 4 + 4 * seg_count
        seg_start_size = 24
        dc_info = seg_infos_len
        d_info = dc_info + seg_start_size
        starts = struct.pack("<I", seg_count) + struct.pack("<4I", 0, dc_info, d_info, 0)

        def seg_start(seg_off):
            return struct.pack("<IHHQIHH", seg_start_size, 0x4000, pointer_format, seg_off, 0, 1, 0)
        starts += seg_start(dc_start) + seg_start(data_start)
        imports_off = starts_off + len(starts)
        imps = b""
        name_off = 0
        for x in imp_names:
            if import_format == 1:     # lib_ordinal:8 weak:1 name_offset:23
                imps += struct.pack("<I", 1 | (name_off << 9))
            elif import_format == 2:   # 同じ 32 ビット + int32 addend
                imps += struct.pack("<Ii", 1 | (name_off << 9), 0)
            else:                      # lib_ordinal:16 weak:1 reserved:15 name_offset:32 + uint64 addend
                imps += struct.pack("<QQ", 1 | (name_off << 32), 0)
            name_off += len(x.encode()) + 1
        symbols_off = imports_off + len(imps)
        header = struct.pack("<7I", 0, starts_off, imports_off, symbols_off, len(imp_names), import_format, 0)
        blob = header + b"\0" * (starts_off - len(header)) + starts + imps + pool
        chained_range = put(blob)
        exports_range = put(export_trie(exports))
    else:
        exports_range = put(export_trie(exports))

    strtab = bytearray(b"\0")
    syms = []

    def sym(name, ntype, sect, value):
        idx = len(strtab)
        strtab.extend(name.encode() + b"\0")
        syms.append(struct.pack("<IBBHQ", idx, ntype, sect, 0, value))
    for i in range(locals_count):
        sym("_local_%d" % i, 0x0E, 1, BASE + 0x1000 + i)
    for name in exports:
        sym(name, 0x0F, 1, BASE)
    for name in imports if nlist_imports else ():
        sym(name, 0x01, 0, 0)
    symoff, _ = put(b"".join(syms))
    stroff, strsize = put(bytes(strtab))

    sig_range = None
    if has_sig:
        xml = plistlib.dumps(entitlements)
        cd = struct.pack(">II", 0xFADE0C02, 8)
        ent = struct.pack(">II", 0xFADE7171, 8 + len(xml)) + xml
        head_len = 12 + 8 * 2
        sb = struct.pack(">III", 0xFADE0CC0, head_len + len(cd) + len(ent), 2)
        sb += struct.pack(">II", 0, head_len) + struct.pack(">II", 5, head_len + len(cd))
        sig_range = put(sb + cd + ent)

    total = le + len(link)
    out = bytearray(total)
    cmds = bytearray()

    def segment(name, vmaddr, fileoff, size, sects):
        c = struct.pack("<II16sQQQQiiII", 0x19, 72 + 80 * len(sects), name.encode(), vmaddr, size, fileoff, size,
                        7, 7, len(sects), 0)
        for sname, seg, addr, ssize, soff, flags in sects:
            c += struct.pack("<16s16sQQIIIIIIII", sname.encode(), seg.encode(), addr, ssize, soff, 3, 0, 0, flags,
                             0, 0, 0)
        return c
    cmds += segment("__TEXT", BASE, 0, text_end,
                    [(nm, "__TEXT", BASE + o, len(b), o, f) for nm, o, b, f in text_layout])
    cmds += segment("__DATA_CONST", BASE + dc_start, dc_start, dc_end - dc_start,
                    [("__objc_classlist", "__DATA_CONST", BASE + classlist_off, 8 * n, classlist_off, 0x10000000)])
    cmds += segment("__DATA", BASE + data_start, data_start, data_end - data_start,
                    [("__objc_data", "__DATA", BASE + objc_data_off, 40 * n, objc_data_off, 0),
                     ("__objc_const", "__DATA", BASE + objc_const_off, 48 * n, objc_const_off, 0)])
    cmds += segment("__LINKEDIT", BASE + le, le, len(link), [])
    if chained:
        cmds += struct.pack("<IIII", 0x80000034, 16, *chained_range)
        cmds += struct.pack("<IIII", 0x80000033, 16, *exports_range)
    else:
        cmds += struct.pack("<II10I", 0x80000022, 48, 0, 0, 0, 0, 0, 0, 0, 0, *exports_range)
    cmds += struct.pack("<IIIIII", 0x2, 24, symoff, len(syms), stroff, strsize)
    if has_sig:
        cmds += struct.pack("<IIII", 0x1D, 16, *sig_range)
    assert len(cmds) == sizeofcmds, (len(cmds), sizeofcmds)
    out[0:32] = struct.pack("<IiiIIIII", 0xFEEDFACF, cputype or 0x0100000C, 0, 2, ncmds, sizeofcmds, 0, 0)
    out[32:32 + len(cmds)] = cmds
    for nm, o, b, f in text_layout:
        out[o:o + len(b)] = b
    for o, b in body.items():
        out[o:o + len(b)] = b
    out[le:le + len(link)] = link
    return bytes(out)


def fat(*slices):
    """(cputype, bytes) を並べた fat。"""
    head = struct.pack(">II", 0xCAFEBABE, len(slices))
    off = align(8 + 20 * len(slices), 0x1000)
    entries, blobs = b"", b""
    for cpu, blob in slices:
        entries += struct.pack(">iiIII", cpu, 0, off + len(blobs), len(blob), 12)
        blobs += blob + b"\0" * (align(len(blob), 0x1000) - len(blob))
    return head + entries + b"\0" * (off - 8 - len(entries)) + blobs


# ---------------------------------------------------------------------------
# リポジトリと束を組む
# ---------------------------------------------------------------------------

APP_ENTS = {
    "com.apple.developer.media-device-extension": [],
    "com.apple.security.application-groups": ["group.ai.nemut.effetune"],
    "com.apple.developer.ubiquity-kvstore-identifier": "$(TeamIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)",
    "com.apple.developer.associated-domains": ["applinks:effectdeck.nemut.ai"],
}
DEVICE_ENTS = {
    "com.apple.developer.media-device-extension": ["media-device-protocol.ai.nemut.effetune"],
    "com.apple.security.application-groups": ["group.ai.nemut.effetune"],
}
SHARE_ENTS = {"com.apple.security.application-groups": ["group.ai.nemut.effetune"]}


def signed(ents, role):
    """署名したあとの形（変数を展開し、署名が足す鍵を入れる）。"""
    out = {}
    ident = {"app": "ai.nemut.effetune", "device": "ai.nemut.effetune.extension",
             "share": "ai.nemut.effetune.share"}[role]
    for k, v in ents.items():
        if isinstance(v, str):
            v = v.replace("$(TeamIdentifierPrefix)", "C82ST8T9MN.").replace("$(PRODUCT_BUNDLE_IDENTIFIER)", ident)
        out[k] = v
    out["application-identifier"] = "C82ST8T9MN." + ident
    out["com.apple.developer.team-identifier"] = "C82ST8T9MN"
    return out


# 364f940 の前の AssetUpload.swift（`git show 364f940^:Sources/EffeTuneLive/DSP/AssetUpload.swift` の抜き書き）。
ASSET_UPLOAD_BEFORE = '''import Foundation

enum AssetUpload {
    /// 呼び出し側が自前で書き込み先を用意したいときの差し込み口。
    /// nil のあいだは下の dlsym → 32bit の口、の順に探す。
    static var stagingAddressProvider: ((BeginRequest) -> UnsafeMutableRawPointer?)?

    private static let beginPointer: BeginPointerFunction? = {
        // RTLD_DEFAULT。同じ実行ファイルに入っているので、これで見つかる。
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
                                 "et_instance_asset_begin_ptr") else { return nil }
        return unsafeBitCast(symbol, to: BeginPointerFunction.self)
    }()
}
'''
ASSET_UPLOAD_AFTER = '''import Foundation

enum AssetUpload {
    /// **dlsym で探さない。**以前は `et_instance_asset_begin_ptr` を
    /// `dlsym(RTLD_DEFAULT, ...)` で引いていたが、Release は strip する。
    static var canStage: Bool { true }

    private static func beginStaging(_ request: BeginRequest) throws -> UnsafeMutableRawPointer {
        guard let staging = et_instance_asset_begin_ptr(request.engine) else { throw ETAssetUploadError.beginRejected }
        return UnsafeMutableRawPointer(staging)
    }
}
'''

DEBUG_PRESETS = '''import Foundation

enum ETDebugPresets {
    static let all: [(name: String, json: String)] = [
        ("Reorder · mixed heights", reorder),
    ]

    private static let reorder = """
    [{"nm":"Volume","en":true,"vl":0},
     {"nm":"Spectrogram","en":true}]
    """
}
'''

SAMPLE_A = "desc: EffectDeck DSP Filter Drive\nslider1:0<0,1>Drive\n@sample\nspl0=spl0;\n"
SAMPLE_B = "desc: EffectDeck DSP Stereo Delay\n@sample\nspl1=spl0;\n"


def make_repo(root, asset_upload=ASSET_UPLOAD_AFTER):
    root = pathlib.Path(root)
    write(root / "project.yml", "name: EffeTuneLive\n")
    for rel, ents in (("Sources/EffeTuneLive/EffeTuneLive.entitlements", APP_ENTS),
                      ("Sources/Extension/Extension.entitlements", DEVICE_ENTS),
                      ("Sources/ShareExtension/ShareExtension.entitlements", SHARE_ENTS)):
        (root / rel).parent.mkdir(parents=True, exist_ok=True)
        (root / rel).write_bytes(plistlib.dumps(ents))
    write(root / "Sources/EffeTuneLive/DSP/AssetUpload.swift", asset_upload)
    write(root / "Sources/EffeTuneLive/DSP/DebugPresets.swift", DEBUG_PRESETS)
    write(root / "Sources/EffeTuneLive/App.swift", 'let greeting = "Welcome to EffectDeck, have fun"\n')
    write(root / "Sources/Shared/ETPipeline.h", "int ETPipeline_Publish(void *pipe);\nint ETLinkConsume(void);\n")
    write(root / "Sources/ShareExtension/ShareViewController.swift",
          "import UIKit\nfinal class ShareViewController: UIViewController {}\n")
    write(root / "Patches/abi-begin-ptr.diff",
          "+++ b/dsp/include/effetune/abi.h\n+ET_EXPORT void *et_instance_asset_begin_ptr(uint32_t engine);\n")
    write(root / "Debug/JSFXFactory/A.jsfx", SAMPLE_A)
    write(root / "Debug/JSFXFactory/B.jsfx", SAMPLE_B)
    return root


SHARE_CLASS = "_TtC15EffectDeckShare19ShareViewController"


def make_app(parent, flavor="store", sign=False, app_bin=None, device_bin=None, share_bin=None,
             app_info=None, device_info=None, share_info=None, ents=None, samples=None, name="EffectDeck.app"):
    """EffectDeck.app を組む。*_info は Info.plist へ上書きする dict（値 None は消す）。"""
    app = pathlib.Path(parent) / name
    ents = ents or {}
    icon = {"store": "EffeTuneLive", "beta": "EffectDeckPublicBeta", None: None}[flavor]

    def info(base, extra):
        base = dict(base)
        for k, v in (extra or {}).items():
            if v is None:
                base.pop(k, None)
            else:
                base[k] = v
        return base
    app_plist = info({
        "CFBundleIdentifier": "ai.nemut.effetune", "CFBundleExecutable": "EffectDeck",
        "CFBundleShortVersionString": "2026.09.22", "CFBundleVersion": "26",
        "ITSAppUsesNonExemptEncryption": False, "UIBackgroundModes": ["audio"],
        "NSMicrophoneUsageDescription": "EffectDeck uses playAndRecord.",
    }, app_info)
    if icon:
        app_plist.setdefault("CFBundleIcons", {"CFBundlePrimaryIcon": {"CFBundleIconName": icon}})
    device_plist = info({
        "CFBundleIdentifier": "ai.nemut.effetune.extension", "CFBundleExecutable": "EffeTuneLiveExtension",
        "CFBundleShortVersionString": "2026.09.22", "CFBundleVersion": "26",
        "EXAppExtensionAttributes": {"EXExtensionPointIdentifier": "com.apple.media-device-extension"},
        "UTExportedTypeDeclarations": [{"UTTypeIdentifier": "media-device-protocol.ai.nemut.effetune",
                                        "UTTypeDescription": "48 kHz, 32-bit float",
                                        "UTTypeConformsTo": ["public.media-sharing-protocol"]}],
    }, device_info)
    share_plist = info({
        "CFBundleIdentifier": "ai.nemut.effetune.share", "CFBundleExecutable": "EffectDeckShare",
        "CFBundleShortVersionString": "2026.09.22", "CFBundleVersion": "26",
        "NSExtension": {"NSExtensionPointIdentifier": "com.apple.share-services",
                        "NSExtensionPrincipalClass": "EffectDeckShare.ShareViewController"},
    }, share_info)

    def ents_for(role, default):
        if not sign:
            return None
        return ents.get(role, signed(default, role))

    parts = [
        (app, app_plist, app_bin or build_macho(entitlements=ents_for("app", APP_ENTS),
                                                cstrings=[b"Welcome to EffectDeck, have fun"])),
        (app / "Extensions/EffeTuneLiveExtension.appex", device_plist,
         device_bin or build_macho(entitlements=ents_for("device", DEVICE_ENTS))),
        (app / "PlugIns/EffectDeckShare.appex", share_plist,
         share_bin or build_macho(entitlements=ents_for("share", SHARE_ENTS), classes=[SHARE_CLASS],
                                  methnames=["viewDidLoad"])),
    ]
    for bundle, plist, blob in parts:
        bundle.mkdir(parents=True, exist_ok=True)
        (bundle / "Info.plist").write_bytes(plistlib.dumps(plist))
        exe = plist.get("CFBundleExecutable")
        if exe:
            (bundle / exe).write_bytes(blob)
        if sign:
            write(bundle / "_CodeSignature" / "CodeResources", "<plist/>")
    for rel, text in (samples or {}).items():
        write(app / rel, text)
    return app


def archive_of(app_parent, app):
    arc = pathlib.Path(app_parent) / "EffeTuneLive.xcarchive"
    dest = arc / "Products" / "Applications" / app.name
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.move(str(app), str(dest))
    return arc


def ipa_of(app_parent, app):
    ipa = pathlib.Path(app_parent) / "EffectDeck.ipa"
    with zipfile.ZipFile(ipa, "w") as z:
        for p in sorted(app.rglob("*")):
            if p.is_file():
                z.write(p, "Payload/" + p.relative_to(app.parent).as_posix())
    return ipa


class TempDir:
    def __enter__(self):
        self.path = pathlib.Path(tempfile.mkdtemp(prefix="relcheck-"))
        return self.path

    def __exit__(self, *exc):
        shutil.rmtree(self.path, ignore_errors=True)
        return False


def check(target, repo, *extra, crosscheck=False):
    """(終了値, 出力)。"""
    argv = [str(target), "--repo", str(repo)] + list(extra)
    if not crosscheck:
        argv.append("--no-crosscheck")
    out = io.StringIO()
    try:
        code = CRB.run(CRB.parse_args(argv), out=out)
    except CRB.InputError as e:
        return 2, str(e)
    return code, out.getvalue()


def fails(text, check_name=None):
    return [ln for ln in text.splitlines()
            if ln.startswith("FAIL") and (check_name is None or ln.split()[1] == check_name)]


# ---------------------------------------------------------------------------
# Mach-O の読み取り
# ---------------------------------------------------------------------------

class ReaderTests(unittest.TestCase):
    def test_exports_imports_locals_chained_offset_format(self):
        m = CRB.MachO("x", build_macho(exports=["__mh_execute_header", "_ETPipeline_Publish"],
                                       imports=["_dlsym", "_objc_msgSend"], locals_count=5,
                                       cstrings=[b"hello world, long enough"]))
        self.assertEqual(m.exports(), {"__mh_execute_header", "_ETPipeline_Publish"})
        self.assertEqual(m.imports(), {"_dlsym", "_objc_msgSend"})
        self.assertEqual(len(m.local_defined()), 5)
        self.assertIn(b"hello world, long enough", m.cstrings())
        self.assertEqual(m.pointer_formats(), {1: 6, 2: 6})

    def test_imports_from_the_chained_fixups_table_alone(self):
        """nlist に未定義のシンボルを置かないリンカもある。取り込みは chained fixups の表から読めること。"""
        for fmt in (1, 2, 3):
            with self.subTest(import_format=fmt):
                m = CRB.MachO("x", build_macho(imports=["_dlsym", "_vDSP_fft_zip", "_objc_msgSend"],
                                               import_format=fmt, nlist_imports=False))
                self.assertFalse([s for s in m.symbols() if (s[1] & CRB.N_TYPE) == CRB.N_UNDF], "nlist が空でない")
                self.assertEqual(m.imports(), {"_dlsym", "_vDSP_fft_zip", "_objc_msgSend"})

    def test_objc_classes_through_every_pointer_encoding(self):
        names = ["ETRootProbe", SHARE_CLASS]
        for chained, fmt in ((True, 6), (True, 2), (False, None)):
            with self.subTest(chained=chained, fmt=fmt):
                m = CRB.MachO("x", build_macho(classes=names, methnames=["viewDidLoad", "probe:"],
                                               chained=chained, pointer_format=fmt or 6))
                self.assertEqual(m.objc_classes(), set(names))
                self.assertEqual(m.objc_methnames(), {"viewDidLoad", "probe:"})
                self.assertEqual(m.exports(), {"__mh_execute_header"})

    def test_dyld_info_exports_without_chained_fixups(self):
        m = CRB.MachO("x", build_macho(exports=["__mh_execute_header", "_et_abi_version"], chained=False))
        self.assertEqual(m.exports(), {"__mh_execute_header", "_et_abi_version"})
        self.assertEqual(m.pointer_formats(), {})

    def test_entitlements_from_signature_and_simulated_section(self):
        ents = {"com.apple.security.application-groups": ["group.ai.nemut.effetune"]}
        self.assertEqual(CRB.MachO("x", build_macho(entitlements=ents)).entitlements(), ("signature", ents))
        self.assertEqual(CRB.MachO("x", build_macho(simulated=ents)).entitlements(), ("simulated", ents))
        self.assertEqual(CRB.MachO("x", build_macho()).entitlements(), (None, None))

    def test_fat_picks_arm64_slice(self):
        x86 = build_macho(exports=["__mh_execute_header", "_x86_only"], cputype=0x01000007)
        arm = build_macho(exports=["__mh_execute_header", "_arm_only"])
        m = CRB.MachO("x", fat((0x01000007, x86), (0x0100000C, arm)))
        self.assertEqual(m.exports(), {"__mh_execute_header", "_arm_only"})

    def test_rejects_what_is_not_64bit_macho(self):
        for blob in (b"#!/bin/sh\necho hi\n" * 4, struct.pack("<I", 0xFEEDFACE) + b"\0" * 60):
            with self.assertRaises(CRB.MachOError):
                CRB.MachO("x", blob)

    def test_swift_objc_name(self):
        self.assertEqual(CRB.swift_objc_name("EffectDeckShare.ShareViewController"), SHARE_CLASS)
        self.assertEqual(CRB.swift_objc_name("M.Outer.Inner"), "_TtCC1M5Outer5Inner")
        self.assertEqual(CRB.swift_objc_name("PlainObjC"), "PlainObjC")


# ---------------------------------------------------------------------------
# ソースの読み取り
# ---------------------------------------------------------------------------

class SourceTests(unittest.TestCase):
    def test_strip_comments_keeps_strings_and_line_numbers(self):
        swift = 'let a = "// not a comment" // dlsym(x, "gone")\n/* outer /* inner */ still */ let b = 1\n'
        clean = CRB.strip_comments(swift, True)
        self.assertIn('"// not a comment"', clean)
        self.assertNotIn("gone", clean)
        self.assertNotIn("still", clean)
        self.assertEqual(clean.count("\n"), swift.count("\n"))
        c = 'char q = \'"\'; /* a */ const char *s = "/* kept */"; // dlsym(h, "gone")\n'
        clean = CRB.strip_comments(c, False)
        self.assertIn('"/* kept */"', clean)
        self.assertNotIn("gone", clean)

    def test_scan_finds_the_364f940_lookup(self):
        with TempDir() as d:
            repo = make_repo(d, ASSET_UPLOAD_BEFORE)
            lookups, _silgen, _n = CRB.scan_lookups(repo)
            self.assertEqual(len(lookups), 1)
            lk = lookups[0]
            self.assertEqual((lk.path, lk.call, lk.kind, lk.name), (
                "Sources/EffeTuneLive/DSP/AssetUpload.swift", "dlsym", "symbol", "et_instance_asset_begin_ptr"))
            self.assertEqual(lk.line, 10)
            self.assertEqual(lk.roles, frozenset({"app"}))
            # 直したあとは、注釈に dlsym と書いてあっても拾わない。
            write(repo / "Sources/EffeTuneLive/DSP/AssetUpload.swift", ASSET_UPLOAD_AFTER)
            self.assertEqual(CRB.scan_lookups(repo)[0], [])

    def test_scan_marks_non_literal_arguments(self):
        with TempDir() as d:
            repo = make_repo(d)
            write(repo / "Sources/Shared/Loader.c",
                  'void *f(const char *n) { void *p = dlsym(RTLD_DEFAULT, n); return p; }\n')
            lookups = CRB.scan_lookups(repo)[0]
            self.assertEqual([(lk.call, lk.name, sorted(lk.roles)) for lk in lookups],
                             [("dlsym", None, ["app", "device"])])

    def test_scan_skips_compile_time_selectors_declarations_and_foreign_languages(self):
        with TempDir() as d:
            repo = make_repo(d)
            write(repo / "Sources/EffeTuneLive/Sel.swift",
                  'let a = #selector(fire)\nfunc dlsym(_ h: Int, _ n: String) {}\n'
                  'let s = Selector(("probe:"))\nlet c = Bundle.main.classNamed("Foo")\n'
                  'let d = my_dlsym(1, "nope")\n')
            write(repo / "Sources/Shared/Sel.cpp", 'Selector s = Selector(x);\nvoid *dlsym(void *, const char *);\n')
            got = sorted((lk.call, lk.name) for lk in CRB.scan_lookups(repo)[0])
            self.assertEqual(got, [("Selector", "probe:"), ("classNamed", "Foo")])

    def test_scan_objc_forms(self):
        with TempDir() as d:
            repo = make_repo(d)
            write(repo / "Sources/Extension/Obj.m",
                  'Class a = NSClassFromString(@"ETThing");\nSEL s = NSSelectorFromString(@"go:");\n'
                  'void *f = CFBundleGetFunctionPointerForName(b, CFSTR("ETZeroTimeStamp_Get"));\n'
                  'Class c = [bundle classNamed:@"ETOther"];\n')
            got = sorted((lk.call, lk.kind, lk.name, tuple(sorted(lk.roles))) for lk in CRB.scan_lookups(repo)[0])
            self.assertEqual(got, [
                ("CFBundleGetFunctionPointerForName", "symbol", "ETZeroTimeStamp_Get", ("device",)),
                ("NSClassFromString", "class", "ETThing", ("device",)),
                ("NSSelectorFromString", "selector", "go:", ("device",)),
                ("classNamed:", "class", "ETOther", ("device",)),
            ])

    def test_source_roles_mirror_project_yml(self):
        with TempDir() as d:
            repo = make_repo(d)
            write(repo / "Sources/Shared/ETPipeline.c", "")
            write(repo / "Sources/Shared/LocalLink.m", "")
            write(repo / "Sources/EffeTuneLive/DSP/ETShareInbox.swift", "")
            wdl = repo / "Vendor/ysfx/thirdparty/WDL/source/WDL"
            write(wdl / "eel2/nseel-compiler.c", "")
            write(wdl / "eel2/eel_lice.h", 'objc_getClass("NSApplication");\n')
            write(wdl / "fft.c", "")
            write(repo / "Vendor/effetune/dsp/core/graph_test.cpp", "")
            write(repo / "Vendor/effetune/dsp/core/graph.cpp", "")
            files = CRB.source_files(repo)
            self.assertEqual(files["Sources/Shared/ETPipeline.c"], {"app"})
            self.assertEqual(files["Sources/Shared/LocalLink.m"], {"app", "device"})
            self.assertEqual(files["Sources/EffeTuneLive/DSP/ETShareInbox.swift"], {"app", "share"})
            self.assertIn("Vendor/ysfx/thirdparty/WDL/source/WDL/eel2/nseel-compiler.c", files)
            self.assertIn("Vendor/ysfx/thirdparty/WDL/source/WDL/fft.c", files)
            self.assertNotIn("Vendor/ysfx/thirdparty/WDL/source/WDL/eel2/eel_lice.h", files)
            self.assertNotIn("Vendor/effetune/dsp/core/graph_test.cpp", files)
            self.assertIn("Vendor/effetune/dsp/core/graph.cpp", files)

    def test_abi_names_from_headers_and_patches(self):
        with TempDir() as d:
            repo = make_repo(d)
            names = CRB.abi_names(repo)
            self.assertTrue({"ETPipeline_Publish", "ETLinkConsume", "et_instance_asset_begin_ptr"} <= names)
            self.assertNotIn("ET_EXPORT", names)

    def test_debug_line_flags(self):
        src = "\n".join([
            "a",                              # 0
            "#if DEBUG",                      # 1
            "b",                              # 2 debug
            "#if os(iOS)",                    # 3
            "c",                              # 4 debug（外が DEBUG）
            "#endif",                         # 5
            "#else",                          # 6
            "d",                              # 7
            "#endif",                         # 8
            "#if DEBUG || ET_BETA",           # 9
            "e",                              # 10 TestFlight でも建つ
            "#endif",                         # 11
            "#if !DEBUG",                     # 12
            "f",                              # 13
            "#else",                          # 14
            "g",                              # 15 debug
            "#endif",                         # 16
            "#if DEBUG && targetEnvironment(simulator)",  # 17
            "h",                              # 18 debug
            "#endif",                         # 19
        ])
        flags = CRB.debug_line_flags(src)
        self.assertEqual([i for i, f in enumerate(flags) if f], [2, 4, 15, 18])

    def test_multiline_literal_value(self):
        body = '\n    [{"nm":"Volume"},\n     {"nm":"Level Meter"}] \\\n    tail\n    '
        self.assertEqual(CRB._multiline_value(body), '[{"nm":"Volume"},\n {"nm":"Level Meter"}] tail')
        self.assertIsNone(CRB._unescape_swift('a \\(x) b'))
        self.assertEqual(CRB._unescape_swift('q\\"\\u{B7}\\n'), 'q"·\n')

    def test_debug_only_literals_drop_ones_that_ship_anyway(self):
        with TempDir() as d:
            repo = make_repo(d)
            write(repo / "Sources/EffeTuneLive/Seed.swift",
                  '#if DEBUG\nlet x = "only in debug builds, long"\nlet y = "shared text used in both places"\n'
                  'let z = "short"\n#endif\nlet w = "shared text used in both places"\n')
            write(repo / "Sources/Shared/Log.c", 'const char *m = "only in debug builds, long";\n')
            lits = CRB.debug_only_literals(repo)
            got = {b.decode(): w for b, w in lits.items()}
            self.assertIn("Reorder · mixed heights", got)
            self.assertIn('[{"nm":"Volume","en":true,"vl":0},\n {"nm":"Spectrogram","en":true}]', got)
            self.assertNotIn("shared text used in both places", got)   # 出荷のコードにもある
            self.assertNotIn("only in debug builds, long", got)        # C の側にもある
            self.assertNotIn("short", got)                             # 15 バイトまでは __cstring に出ない
            self.assertEqual(got["Reorder · mixed heights"][0], "Sources/EffeTuneLive/DSP/DebugPresets.swift")

    def test_debug_only_callers_outside_debug(self):
        """DebugPresets.swift はファイルごと囲っていない。呼ぶ側が 1 か所でも囲い忘れれば字は出荷物に残る。"""
        with TempDir() as d:
            repo = make_repo(d)
            self.assertEqual(CRB.debug_only_callers(repo), [])
            write(repo / "Sources/EffeTuneLive/Views/Picker.swift", "\n".join([
                "import SwiftUI",                                         # 1
                "struct Picker {",                                        # 2
                "    func rows() {",                                      # 3
                "        #if DEBUG",                                      # 4
                "        _ = ETDebugPresets.all",                         # 5 囲ってある
                "        #endif",                                         # 6
                "        // ETDebugPresets.all は注釈なので数えない",          # 7
                '        let s = "ETDebugPresets.all"',                   # 8 字も数えない
                "        let n = MyETDebugPresetsLike.count",             # 9 別の名前
                "        _ = ETDebugPresets.all.count",                   # 10 囲っていない
                "        #if DEBUG || ET_BETA",                           # 11
                "        _ = ETDebugPresets.all",                         # 12 TestFlight（Release）でも建つ
                "        #endif",                                         # 13
                "    }",
                "}",
                ""]))
            owner = "Sources/EffeTuneLive/DSP/DebugPresets.swift"
            self.assertEqual(CRB.debug_only_callers(repo), [
                ("Sources/EffeTuneLive/Views/Picker.swift", 10, "ETDebugPresets", owner),
                ("Sources/EffeTuneLive/Views/Picker.swift", 12, "ETDebugPresets", owner),
            ])
            # Debug だけのファイルの中で自分を使うのは数えない。宣言は一番上の段のものだけ拾う。
            code = CRB._blank_swift_strings(CRB.strip_comments(DEBUG_PRESETS, True))
            self.assertEqual(CRB._top_level_names(code), ["ETDebugPresets"])

    def test_covers_signed_values_against_repo_entitlements(self):
        cover = CRB._covers
        kvs = "$(TeamIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)"
        self.assertTrue(cover("C82ST8T9MN.ai.nemut.effetune", kvs, "ai.nemut.effetune"))
        self.assertFalse(cover("C82ST8T9MN.ai.nemut.effetune.share", kvs, "ai.nemut.effetune"))
        self.assertFalse(cover("c82st8t9mn.ai.nemut.effetune", kvs, "ai.nemut.effetune"))
        self.assertFalse(cover(kvs, kvs, "ai.nemut.effetune"))   # 展開されずに残ったもの
        self.assertTrue(cover(["group.a", "group.b"], ["group.a"], "x"))
        self.assertFalse(cover(["group.a"], ["group.a", "group.b"], "x"))
        self.assertFalse(cover("group.a", ["group.a"], "x"))
        self.assertTrue(cover([], [], "x"))
        self.assertTrue(cover({"a": [1], "b": True}, {"a": [1]}, "x"))
        self.assertFalse(cover({"b": True}, {"a": [1]}, "x"))
        self.assertTrue(cover(True, True, "x"))
        self.assertFalse(cover(False, True, "x"))


# ---------------------------------------------------------------------------
# 束ごと
# ---------------------------------------------------------------------------

class BundleTests(unittest.TestCase):
    def test_clean_unsigned_store_archive_passes(self):
        with TempDir() as d:
            repo = make_repo(d / "repo")
            arc = archive_of(d, make_app(d))
            code, text = check(arc, repo)
            self.assertEqual(code, 0, text)
            self.assertIn("店の版", text)
            self.assertIn("署名が無いので Sources/EffeTuneLive/EffeTuneLive.entitlements から読んだ", text)
            self.assertIn("名前で引く口はソースに無い", text)

    def test_364f940_replay_red_then_green(self):
        """直す前のソースと、strip で export を失った実行ファイル → 落ちる。直したもの → 通る。"""
        with TempDir() as d:
            repo = make_repo(d / "repo", ASSET_UPLOAD_BEFORE)
            before = build_macho(cstrings=[b"et_instance_asset_begin_ptr"], imports=["_dlsym"])
            code, text = check(make_app(d / "before", app_bin=before), repo)
            self.assertEqual(code, 1, text)
            self.assertEqual(len(fails(text, "lookup")), 1, text)
            self.assertIn('dlsym("et_instance_asset_begin_ptr") → EffectDeck', fails(text, "lookup")[0])
            self.assertIn("364f940", fails(text, "lookup")[0])
            # ソースを読まなくても、字が残っていることで拾う。
            self.assertEqual(len(fails(text, "abiname")), 1, text)
            # Debug（export trie に残る）では通ってしまう形。これが 5 日見逃した理由。
            debug_like = build_macho(cstrings=[b"et_instance_asset_begin_ptr"], imports=["_dlsym"],
                                     exports=["__mh_execute_header", "_et_instance_asset_begin_ptr"])
            code, text = check(make_app(d / "debuglike", app_bin=debug_like), repo)
            self.assertEqual(fails(text, "lookup"), [], text)
            # 直したもの。
            write(repo / "Sources/EffeTuneLive/DSP/AssetUpload.swift", ASSET_UPLOAD_AFTER)
            code, text = check(make_app(d / "after"), repo)
            self.assertEqual(code, 0, text)

    def test_lookup_resolution_by_kind(self):
        """系の関数は取り込み（chained fixups の表だけに在っても）で、Selector("…") はメソッド名で引ける。"""
        with TempDir() as d:
            repo = make_repo(d / "repo")
            write(repo / "Sources/EffeTuneLive/Probe.swift",
                  'import Foundation\n'
                  'let fft = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "vDSP_fft_zip")\n'
                  'let sel = Selector("probeMethod:")\n')

            def app_bin(imports=("_vDSP_fft_zip",), methnames=("probeMethod:",)):
                return build_macho(imports=list(imports), nlist_imports=False, methnames=list(methnames))
            code, text = check(make_app(d / "ok", app_bin=app_bin()), repo)
            self.assertEqual(code, 0, text)
            self.assertIn('Probe.swift:2 dlsym("vDSP_fft_zip") → EffectDeck: 外の dylib から取り込んでいる', text)
            self.assertIn('Probe.swift:3 Selector("probeMethod:") → EffectDeck: __objc_methname に在る', text)

            code, text = check(make_app(d / "nosel", app_bin=app_bin(methnames=("otherMethod:",))), repo)
            self.assertEqual(code, 1, text)
            self.assertEqual(len(fails(text)), 1, text)
            self.assertIn('Selector("probeMethod:") → EffectDeck: この実行ファイルのメソッド名に無い',
                          fails(text, "lookup")[0])

            code, text = check(make_app(d / "nosym", app_bin=app_bin(imports=())), repo)
            self.assertEqual(code, 1, text)
            self.assertEqual(len(fails(text)), 1, text)
            self.assertIn('dlsym("vDSP_fft_zip") → EffectDeck: export されていない', fails(text, "lookup")[0])

    def test_non_literal_lookup_argument_fails_the_run(self):
        with TempDir() as d:
            repo = make_repo(d / "repo")
            write(repo / "Sources/Shared/Loader.c",
                  'void *f(const char *n) { void *p = dlsym(RTLD_DEFAULT, n); return p; }\n')
            code, text = check(make_app(d, app_bin=build_macho(imports=["_dlsym"])), repo)
            self.assertEqual(code, 1, text)
            self.assertEqual(len(fails(text)), 1, text)
            self.assertIn("Sources/Shared/Loader.c:1: dlsym の引数が字でない", fails(text, "lookup")[0])

    def test_unstripped_binary_fails_unless_allowed(self):
        with TempDir() as d:
            repo = make_repo(d / "repo")
            app = make_app(d, app_bin=build_macho(locals_count=500))
            code, text = check(app, repo)
            self.assertEqual(code, 1)
            self.assertIn("ローカルシンボル 500 個", fails(text, "strip")[0])
            code, text = check(app, repo, "--allow-unstripped")
            self.assertEqual(code, 0, text)
            self.assertIn("--allow-unstripped", text)
            # 決めるのは本体。拡張が strip されていなくても落とさない（出荷もその形）。
            code, text = check(make_app(d / "ext", device_bin=build_macho(locals_count=500)), repo)
            self.assertEqual(code, 0, text)
            self.assertIn("EffeTuneLiveExtension: ローカルシンボル 500 個（strip されていない", text)

    def test_debug_dylib_means_a_debug_build(self):
        with TempDir() as d:
            repo = make_repo(d / "repo")
            app = make_app(d)
            (app / "EffectDeck.debug.dylib").write_bytes(b"x")
            code, text = check(app, repo)
            self.assertEqual(code, 1)
            self.assertIn("EffectDeck.debug.dylib", fails(text, "debugbuild")[0])

    def test_samples_by_flavor(self):
        tracked = {"DebugJSFXFactory/A.jsfx": SAMPLE_A, "DebugJSFXFactory/B.jsfx": SAMPLE_B}
        with TempDir() as d:
            repo = make_repo(d / "repo")
            code, text = check(make_app(d / "s1", samples=tracked), repo)
            self.assertEqual(code, 1)
            self.assertIn("店の版に DebugJSFXFactory/ が在る（2 本）", fails(text, "samples")[0])
            code, text = check(make_app(d / "b1", flavor="beta", samples=tracked), repo)
            self.assertEqual(code, 0, text)
            self.assertIn("TestFlight", text)
            third = dict(tracked, **{"DebugJSFXFactory/Factory/ThirdParty.jsfx": "desc: someone else's\n"})
            code, text = check(make_app(d / "b2", flavor="beta", samples=third), repo)
            self.assertEqual(len(fails(text, "samples")), 1, text)
            self.assertIn("Local/DebugJSFXFactory", fails(text, "samples")[0])
            changed = {"DebugJSFXFactory/A.jsfx": SAMPLE_A + "// edited\n", "DebugJSFXFactory/B.jsfx": SAMPLE_B}
            code, text = check(make_app(d / "b3", flavor="beta", samples=changed), repo)
            self.assertIn("中身が Debug/JSFXFactory と違う", fails(text, "samples")[0])
            code, text = check(make_app(d / "b4", flavor="beta", samples={"DebugJSFXFactory/A.jsfx": SAMPLE_A}),
                               repo)
            self.assertIn("見本が欠けている: B.jsfx", fails(text, "samples")[0])
            code, text = check(make_app(d / "s2", samples={"Fixtures/stray.jsfx": SAMPLE_A}), repo)
            self.assertIn("Fixtures/stray.jsfx", fails(text, "samples")[0])

    def test_signed_entitlements_rules(self):
        cases = {
            "app に中身がある": ("app", dict(signed(APP_ENTS, "app"), **{
                "com.apple.developer.media-device-extension": ["media-device-protocol.ai.nemut.effetune"]}),
                "'!pla'"),
            "app に鍵が無い": ("app", {k: v for k, v in signed(APP_ENTS, "app").items()
                                   if k != "com.apple.developer.media-device-extension"}, "ITMS-91183"),
            "associated domains が無い": ("app", {k: v for k, v in signed(APP_ENTS, "app").items()
                                             if k != "com.apple.developer.associated-domains"},
                                         "applinks:effectdeck.nemut.ai"),
            "開発用の associated domain": ("app", dict(signed(APP_ENTS, "app"), **{
                "com.apple.developer.associated-domains": ["applinks:effectdeck.nemut.ai",
                                                           "applinks:effectdeck.nemut.ai?mode=developer"]}),
                "mode=developer"),
            "KVS が展開されていない": ("app", dict(signed(APP_ENTS, "app"), **{
                "com.apple.developer.ubiquity-kvstore-identifier": "$(TeamIdentifierPrefix)ai.nemut.effetune"}),
                "iCloud KVS"),
            "共有の拡張が持つ": ("share", dict(signed(SHARE_ENTS, "share"), **{
                "com.apple.developer.media-device-extension": []}), "Media Device Extension だけ"),
            "拡張の口が違う": ("device", dict(signed(DEVICE_ENTS, "device"), **{
                "com.apple.developer.media-device-extension": ["media-device-protocol.other"]}), "口"),
            "App Group が無い": ("device", {k: v for k, v in signed(DEVICE_ENTS, "device").items()
                                         if k != "com.apple.security.application-groups"}, "App Group"),
        }
        with TempDir() as d:
            repo = make_repo(d / "repo")
            code, text = check(make_app(d / "good", sign=True), repo)
            self.assertEqual(code, 0, text)
            self.assertIn("の鍵が全部署名に在る（signature）", text)
            for i, (name, (role, ents, needle)) in enumerate(sorted(cases.items())):
                with self.subTest(name):
                    code, text = check(make_app(d / ("c%d" % i), sign=True, ents={role: ents}), repo)
                    self.assertEqual(code, 1, text)
                    self.assertTrue(any(needle in ln for ln in fails(text, "entitle")), text)

    def test_signed_bundle_must_keep_every_repo_entitlement(self):
        """.entitlements に書いた鍵が profile に無いと、書き出しで黙って落ちる。他の決まりが見ない鍵で確かめる。"""
        wifi = "com.apple.developer.networking.wifi-info"
        with TempDir() as d:
            repo = make_repo(d / "repo")
            groups = ["group.ai.nemut.effetune", "group.ai.nemut.effetune.more"]
            (repo / "Sources/EffeTuneLive/EffeTuneLive.entitlements").write_bytes(
                plistlib.dumps(dict(APP_ENTS, **{wifi: True, "com.apple.security.application-groups": groups})))
            good = dict(signed(APP_ENTS, "app"), **{wifi: True, "com.apple.security.application-groups": groups})
            code, text = check(make_app(d / "good", sign=True, ents={"app": good}), repo)
            self.assertEqual(code, 0, text)
            cases = {
                "鍵が無い": ({k: v for k, v in good.items() if k != wifi}, wifi),
                "値が違う": (dict(good, **{wifi: False}), wifi),
                "配列の一部が無い": (dict(good, **{"com.apple.security.application-groups": groups[:1]}),
                                   "com.apple.security.application-groups"),
            }
            for i, (name, (ents, key)) in enumerate(sorted(cases.items())):
                with self.subTest(name):
                    code, text = check(make_app(d / ("c%d" % i), sign=True, ents={"app": ents}), repo)
                    self.assertEqual(code, 1, text)
                    self.assertEqual(len(fails(text)), 1, text)
                    line = fails(text, "entitle")[0]
                    self.assertIn("EffeTuneLive.entitlements に在る %s が署名に無いか値が違う" % key, line)

    def test_signed_bundle_without_entitlements_blob_fails(self):
        with TempDir() as d:
            repo = make_repo(d / "repo")
            app = make_app(d, sign=True, device_bin=build_macho())
            code, text = check(app, repo)
            self.assertIn("署名されているのに entitlements が無い", fails(text, "entitle")[0])

    def test_ipa_rejects_get_task_allow(self):
        with TempDir() as d:
            repo = make_repo(d / "repo")
            ents = dict(signed(APP_ENTS, "app"), **{"get-task-allow": True})
            ipa = ipa_of(d, make_app(d / "a", sign=True, ents={"app": ents}))
            code, text = check(ipa, repo)
            self.assertEqual(code, 1, text)
            self.assertIn("get-task-allow が YES", fails(text, "entitle")[0])
            ipa2 = ipa_of(d / "b", make_app(d / "b", sign=True))
            code, text = check(ipa2, repo)
            self.assertEqual(code, 0, text)
            self.assertIn("ipa", text)

    def test_require_signed(self):
        with TempDir() as d:
            repo = make_repo(d / "repo")
            code, text = check(make_app(d), repo, "--require-signed")
            self.assertEqual(len(fails(text, "entitle")), 3, text)

    def test_plist_rules(self):
        with TempDir() as d:
            repo = make_repo(d / "repo")
            code, text = check(make_app(d / "v", share_info={"CFBundleVersion": "25"}), repo)
            self.assertIn("ITMS-90473", fails(text, "plist")[0])
            code, text = check(make_app(d / "u", app_info={"CFBundleShortVersionString": "$(MARKETING_VERSION)"}),
                               repo)
            self.assertTrue(any("展開されていないビルド変数 $(MARKETING_VERSION)" in ln
                                for ln in fails(text, "plist")), text)
            code, text = check(make_app(d / "p", share_bin=build_macho(classes=["_TtC15EffectDeckShare5Other"])),
                               repo)
            self.assertTrue(any("NSExtensionPrincipalClass" in ln and SHARE_CLASS in ln
                                for ln in fails(text, "plist")), text)
            app = make_app(d / "m")
            shutil.rmtree(app / "Extensions")
            code, text = check(app, repo)
            self.assertTrue(any("Media Device Extension（ai.nemut.effetune.extension）が束に無い" in ln
                                for ln in fails(text, "plist")), text)
            app = make_app(d / "x")
            extra = app / "PlugIns/Widget.appex"
            extra.mkdir(parents=True)
            (extra / "Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "ai.nemut.effetune.widget"}))
            code, text = check(app, repo)
            self.assertTrue(any("予定にない拡張 PlugIns/Widget.appex" in ln for ln in fails(text, "plist")), text)
            code, text = check(make_app(d / "e", app_info={"ITSAppUsesNonExemptEncryption": None}), repo)
            self.assertTrue(any("ITSAppUsesNonExemptEncryption" in ln for ln in fails(text, "plist")), text)

    def test_unexpanded_build_variable_on_a_key_nothing_else_reads(self):
        """版の食い違いなど他の決まりに頼らず、$(…) が残っていること自体で落ちる。入れ子の中でも。"""
        with TempDir() as d:
            repo = make_repo(d / "repo")
            for i, (kw, needle) in enumerate((
                    ({"share_info": {"CFBundleDisplayName": "$(PRODUCT_NAME)"}}, "$(PRODUCT_NAME)"),
                    ({"app_info": {"CFBundleURLTypes": [{"CFBundleURLSchemes": ["$(ET_URL_SCHEME)"]}]}},
                     "$(ET_URL_SCHEME)"))):
                with self.subTest(needle):
                    code, text = check(make_app(d / ("v%d" % i), **kw), repo)
                    self.assertEqual(code, 1, text)
                    self.assertEqual(len(fails(text)), 1, text)
                    self.assertIn("展開されていないビルド変数 " + needle, fails(text, "plist")[0])

    def test_appex_in_the_wrong_directory(self):
        """ExtensionKit の拡張は Extensions/、NSExtension の拡張は PlugIns/。逆だと系が読まない。"""
        with TempDir() as d:
            repo = make_repo(d / "repo")
            app = make_app(d / "a")
            (app / "PlugIns").mkdir(exist_ok=True)
            shutil.move(str(app / "Extensions/EffeTuneLiveExtension.appex"),
                        str(app / "PlugIns/EffeTuneLiveExtension.appex"))
            code, text = check(app, repo)
            self.assertEqual(code, 1, text)
            self.assertEqual(len(fails(text)), 1, text)
            self.assertIn("EffeTuneLiveExtension.appex が Extensions/ でなく PlugIns/ に入っている",
                          fails(text, "plist")[0])
            app = make_app(d / "b")
            (app / "Extensions").mkdir(exist_ok=True)
            shutil.move(str(app / "PlugIns/EffectDeckShare.appex"), str(app / "Extensions/EffectDeckShare.appex"))
            code, text = check(app, repo)
            self.assertEqual(len(fails(text)), 1, text)
            self.assertIn("EffectDeckShare.appex が PlugIns/ でなく Extensions/ に入っている",
                          fails(text, "plist")[0])

    def test_debug_only_literal_in_binary_fails(self):
        with TempDir() as d:
            repo = make_repo(d / "repo")
            leaked = build_macho(cstrings=["Reorder · mixed heights".encode("utf-8")])
            code, text = check(make_app(d, app_bin=leaked), repo)
            self.assertEqual(code, 1)
            self.assertIn("DebugPresets.swift:5", fails(text, "debugonly")[0])

    def test_ungated_debug_caller_fails_before_any_binary_is_read(self):
        """EffectPickerView の形。ETDebugPresets を #if DEBUG の外で使えば、字の無い書庫でも落とす。"""
        with TempDir() as d:
            repo = make_repo(d / "repo")
            view = repo / "Sources/EffeTuneLive/Views/Picker.swift"
            write(view, "struct Picker {\n    var names: [String] { ETDebugPresets.all.map { $0.name } }\n}\n")
            code, text = check(make_app(d / "a"), repo)
            self.assertEqual(code, 1, text)
            self.assertEqual(len(fails(text)), 1, text)
            line = fails(text, "debugonly")[0]
            self.assertIn("Sources/EffeTuneLive/Views/Picker.swift:2: ETDebugPresets", line)
            self.assertIn("#if DEBUG の外で使っている", line)
            # 呼ぶ側が直るまでの CI の逃げ道。
            code, text = check(make_app(d / "b"), repo, "--skip", "debugonly")
            self.assertEqual(code, 0, text)
            # 呼ぶ側を囲えば通る。
            write(view, "struct Picker {\n    #if DEBUG\n    var names: [String] { ETDebugPresets.all.map { $0.name } }\n"
                        "    #endif\n}\n")
            code, text = check(make_app(d / "c"), repo)
            self.assertEqual(code, 0, text)

    def test_flavor_detection_and_input_errors(self):
        with TempDir() as d:
            repo = make_repo(d / "repo")
            app = make_app(d / "n", flavor=None)
            code, text = check(app, repo)
            self.assertEqual(code, 2)
            self.assertIn("--flavor", text)
            self.assertEqual(check(app, repo, "--flavor", "store")[0], 0)
            code, text = check(make_app(d / "b", flavor="beta"), repo, "--flavor", "store")
            self.assertEqual(code, 2)
            self.assertEqual(check(d / "missing.xcarchive", repo)[0], 2)
            self.assertEqual(check(make_app(d / "r"), d)[0], 2)   # project.yml の無い所

    def test_skip_option(self):
        with TempDir() as d:
            repo = make_repo(d / "repo")
            app = make_app(d, app_bin=build_macho(locals_count=500))
            code, text = check(app, repo, "--skip", "strip")
            self.assertEqual(code, 0, text)
            self.assertIn("--skip で外した", text)
            with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
                CRB.parse_args([str(app), "--skip", "nope"])


@unittest.skipIf(os.name == "nt", "偽の nm・codesign を実行ファイルとして置くので POSIX だけ")
class CrossCheckTests(unittest.TestCase):
    def fake_tool(self, d, name, body):
        path = pathlib.Path(d) / name
        path.write_text("#!/bin/sh\n" + body, encoding="utf-8")
        path.chmod(path.stat().st_mode | stat.S_IEXEC)
        return str(path)

    def test_nm_agreement_and_disagreement(self):
        with TempDir() as d:
            repo = make_repo(d / "repo")
            app = make_app(d)
            agree = self.fake_tool(d, "nm-agree", "echo __mh_execute_header\n")
            old = os.environ.get("NM")
            try:
                os.environ["NM"] = agree
                code, text = check(app, repo, crosscheck=True)
                self.assertEqual(code, 0, text)
                self.assertIn("nm の export（1 個）と一致", text)
                os.environ["NM"] = self.fake_tool(d, "nm-extra", "echo __mh_execute_header\necho _et_secret\n")
                code, text = check(app, repo, crosscheck=True)
                self.assertEqual(code, 1)
                self.assertIn("_et_secret", fails(text, "crosscheck")[0])
            finally:
                if old is None:
                    os.environ.pop("NM", None)
                else:
                    os.environ["NM"] = old

    def test_codesign_agreement(self):
        with TempDir() as d:
            repo = make_repo(d / "repo")
            app = make_app(d, sign=True)
            xml = d / "ents.xml"
            xml.write_bytes(plistlib.dumps(signed(SHARE_ENTS, "share")))
            tool = self.fake_tool(d, "codesign", 'case "$5" in *Share*) cat "%s" ;; *) exit 1 ;; esac\n' % xml)
            saved = {k: os.environ.get(k) for k in ("CODESIGN", "NM")}
            try:
                os.environ["CODESIGN"] = tool
                os.environ["NM"] = ""
                code, text = check(app, repo, crosscheck=True)
                self.assertEqual(code, 0, text)
                self.assertIn("codesign -d の entitlements と一致", text)
                self.assertIn("codesign -d が読めない", text)
            finally:
                for k, v in saved.items():
                    if v is None:
                        os.environ.pop(k, None)
                    else:
                        os.environ[k] = v


# ---------------------------------------------------------------------------
# 本物のリンカの出力と llvm の道具で突き合わせる
# ---------------------------------------------------------------------------

PROBE_C = r'''
extern void *dlsym(void *, const char *);
__attribute__((used, visibility("default"))) int ETProbe_exported(void) { return 1; }
__attribute__((used, visibility("default"))) void *et_instance_asset_begin_ptr(void) { return 0; }
static int local_helper(int x) { return x * 3; }
int main(void) { void *p = dlsym((void *)-2, "et_instance_asset_begin_ptr"); return local_helper(p != 0); }
'''
PROBE_M = r'''
__attribute__((objc_root_class)) @interface ETRootProbe
- (void)probeMethod:(int)x;
@end
@implementation ETRootProbe
- (void)probeMethod:(int)x { }
@end
'''


def _find_ld64():
    for cand in filter(None, (os.environ.get("LD64_LLD"), shutil.which("ld64.lld-18"), shutil.which("ld64.lld"))):
        if os.path.isfile(cand):
            yield cand


class RealToolchainTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = pathlib.Path(tempfile.mkdtemp(prefix="relcheck-lld-"))
        cls.bins = {}
        clang, nm = shutil.which("clang"), shutil.which("llvm-nm")
        cls.nm = nm
        cls.strip = shutil.which("llvm-strip") or shutil.which("llvm-strip-18")
        if not (clang and nm) or os.name == "nt":
            return
        t = cls.tmp
        (t / "p.c").write_text(PROBE_C)
        (t / "c.m").write_text(PROBE_M)
        for src, obj in (("p.c", "p.o"), ("c.m", "c.o")):
            r = subprocess.run([clang, "--target=arm64-apple-ios27.0", "-c", str(t / src), "-o", str(t / obj)],
                               capture_output=True)
            if r.returncode:
                return
        for ld in _find_ld64():
            base = [ld, "-arch", "arm64", "-platform_version", "ios", "27.0", "27.0", "-e", "_main",
                    "-undefined", "dynamic_lookup", str(t / "p.o"), str(t / "c.o")]
            variants = {"chained": ["-fixup_chains"], "opcodes": ["-no_fixup_chains"],
                        "noexp": ["-fixup_chains", "-no_exported_symbols"]}
            ok = True
            for name, flags in variants.items():
                r = subprocess.run(base + flags + ["-o", str(t / name)], capture_output=True)
                ok = ok and r.returncode == 0
            if ok:
                cls.bins = {name: t / name for name in variants}
                return

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def setUp(self):
        if not self.bins:
            self.skipTest("clang・iOS を建てられる ld64.lld（LD64_LLD）・llvm-nm が揃っていない")

    def llvm_exports(self, path):
        r = subprocess.run([self.nm, "--dyldinfo-only", "--defined-only", "--extern-only", "-j", str(path)],
                           capture_output=True, text=True, check=True)
        return {ln.strip() for ln in r.stdout.splitlines() if ln.strip() and not ln.startswith("<")}

    def test_reader_agrees_with_llvm_nm(self):
        for name, path in self.bins.items():
            with self.subTest(name):
                m = CRB.MachO(path)
                self.assertEqual(m.exports(), self.llvm_exports(path))
                self.assertIn("_dlsym", m.imports())
                self.assertIn(b"et_instance_asset_begin_ptr", m.cstrings())
                self.assertEqual(m.objc_classes(), {"ETRootProbe"})
                self.assertEqual(m.objc_methnames() >= {"probeMethod:"}, True)
        self.assertIn("_et_instance_asset_begin_ptr", CRB.MachO(self.bins["chained"]).exports())
        self.assertEqual(CRB.MachO(self.bins["noexp"]).exports(), set())
        self.assertEqual(CRB.MachO(self.bins["chained"]).pointer_formats().get(2), 2)
        self.assertEqual(CRB.MachO(self.bins["opcodes"]).pointer_formats(), {})

    def test_strip_count_matches_llvm_strip(self):
        if not self.strip:
            self.skipTest("llvm-strip が無い")
        path = self.bins["chained"]
        before = len(CRB.MachO(path).local_defined())
        r = subprocess.run([self.nm, "--defined-only", str(path)], capture_output=True, text=True, check=True)
        llvm_locals = [ln for ln in r.stdout.splitlines() if ln.split()[1:2] and ln.split()[1].islower()]
        self.assertEqual(before, len(llvm_locals))
        self.assertGreater(before, 0)
        out = self.tmp / "stripped"
        subprocess.run([self.strip, "-o", str(out), str(path)], check=True)
        self.assertEqual(len(CRB.MachO(out).local_defined()), 0)

    def test_whole_check_on_real_linker_output(self):
        """364f940 を本物のリンカの出力で。export の無い版は落ち、在る版は通る。"""
        with TempDir() as d:
            repo = make_repo(d / "repo", ASSET_UPLOAD_BEFORE)
            code, text = check(make_app(d / "a", app_bin=self.bins["noexp"].read_bytes()), repo,
                               "--allow-unstripped", "--skip", "debugonly")
            self.assertEqual(code, 1, text)
            self.assertEqual(len(fails(text, "lookup")), 1, text)
            code, text = check(make_app(d / "b", app_bin=self.bins["chained"].read_bytes()), repo,
                               "--allow-unstripped", "--skip", "debugonly")
            self.assertEqual(fails(text, "lookup"), [], text)
            self.assertEqual(fails(text, "abiname"), [], text)


@unittest.skipIf(os.name == "nt" or not shutil.which("bash"), "bash が要る")
class ShellEntryTests(unittest.TestCase):
    def test_wrapper_passes_arguments_and_exit_code(self):
        with TempDir() as d:
            repo = make_repo(d / "repo")
            app = make_app(d)
            env = dict(os.environ, RELEASE_CHECK_LOG=str(d / "rc.log"), NM="", CODESIGN="")
            script = ROOT / "Scripts" / "check_release_binary.sh"
            r = subprocess.run(["bash", str(script), "--repo", str(repo), str(app)], capture_output=True,
                               text=True, env=env)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertIn("== PASS", (d / "rc.log").read_text(encoding="utf-8"))
            (app / "EffectDeck.debug.dylib").write_bytes(b"x")
            r = subprocess.run(["bash", str(script), "--repo", str(repo), str(app)], capture_output=True,
                               text=True, env=env)
            self.assertEqual(r.returncode, 1, r.stdout)
            r = subprocess.run(["bash", str(script), "--repo", str(repo), str(d / "nothing.ipa")],
                               capture_output=True, text=True, env=env)
            self.assertEqual(r.returncode, 2)


if __name__ == "__main__":
    unittest.main()
