"""Tools/asc.py のうち release.yml が使う部分（next-build・train-check・add-internal・wait-build）。

App Store Connect には繋がない。asc.call を偽物に差し替えて、返事を決めて走らせる。
"""
import contextlib
import io
import unittest.mock

from tools_support import load_tool, unittest


def version(vs, state, platform="IOS", legacy=None):
    a = {"versionString": vs, "appVersionState": state, "platform": platform}
    if legacy:
        a["appStoreState"] = legacy
    return {"id": "v-" + vs, "attributes": a}


class Fake:
    """GET/POST を (メソッド, ? より前のパス) で引く。同じ鍵は先頭から順に 1 つずつ返す。"""

    def __init__(self, replies):
        self.replies = {k: list(v) for k, v in replies.items()}
        self.calls = []

    def __call__(self, method, path, body=None):
        self.calls.append((method, path, body))
        key = (method, path.split("?", 1)[0])
        if key not in self.replies:
            raise AssertionError("返事を決めていない: %s %s" % key)
        r = self.replies[key]
        return r.pop(0) if len(r) > 1 else r[0]


def run(asc, fake, *argv):
    asc.call = fake
    asc.sys.argv = ["asc.py", *argv]
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        try:
            rc = asc.main()
        except SystemExit as e:
            rc = e.code
    return rc, out.getvalue(), err.getvalue()


class AscReleaseTest(unittest.TestCase):
    def setUp(self):
        self.asc = load_tool("asc")
        # time は標準のモジュールそのものなので、試験が終わったら戻す。
        patch = unittest.mock.patch.object(self.asc.time, "sleep", lambda s: None)
        patch.start()
        self.addCleanup(patch.stop)

    def test_vtuple_orders_numerically(self):
        v = self.asc.vtuple
        self.assertGreater(v("2026.10.03"), v("2026.09.28"))
        self.assertGreater(v("2026.09.28"), v("2.9.0"))
        self.assertLess(v("2.9.0"), v("2.10.0"))
        self.assertEqual(v("beta"), "beta")

    def test_train_check_closed_when_same_or_newer_is_released(self):
        fake = Fake({("GET", "/v1/apps/%s/appStoreVersions" % self.asc.APP): [{"data": [
            version("2026.09.28", "READY_FOR_DISTRIBUTION"),
            version("2.9.0", "READY_FOR_DISTRIBUTION"),
        ]}]})
        rc, _, err = run(self.asc, fake, "train-check", "2026.09.28")
        self.assertEqual(rc, 3)
        self.assertIn("gen_version.py --today", err)
        self.assertIn("2026.09.28", err)

    def test_train_check_open_for_newer_version_and_old_notarization(self):
        fake = Fake({("GET", "/v1/apps/%s/appStoreVersions" % self.asc.APP): [{"data": [
            version("2026.09.28", "READY_FOR_DISTRIBUTION"),
            version("2.9.0", "READY_FOR_DISTRIBUTION"),
        ]}]})
        rc, out, _ = run(self.asc, fake, "train-check", "2026.10.03")
        self.assertEqual(rc, 0)
        self.assertIn("開いている", out)

    def test_train_check_ignores_unapproved_states_and_uses_legacy_name(self):
        base = ("GET", "/v1/apps/%s/appStoreVersions" % self.asc.APP)
        rc, _, _ = run(self.asc, Fake({base: [{"data": [version("2026.10.03", "PREPARE_FOR_SUBMISSION")]}]}),
                       "train-check", "2026.10.03")
        self.assertEqual(rc, 0)
        legacy = {"id": "x", "attributes": {"versionString": "2026.10.03", "appStoreState": "READY_FOR_SALE"}}
        rc, _, _ = run(self.asc, Fake({base: [{"data": [legacy]}]}), "train-check", "2026.10.03")
        self.assertEqual(rc, 3)

    def test_next_build_counts_gaps_failed_uploads_and_floor(self):
        app = self.asc.APP
        builds = {"data": [{"attributes": {"version": "31"}}, {"attributes": {"version": "26"}}]}
        uploads = {"data": [{"attributes": {"cfBundleVersion": "33", "state": {"state": "FAILED"}}},
                            {"attributes": {"cfBundleVersion": "4"}}]}
        replies = {("GET", "/v1/builds"): [builds],
                   ("GET", "/v1/apps/%s/buildUploads" % app): [uploads]}
        rc, out, _ = run(self.asc, Fake(replies), "next-build")
        self.assertEqual((rc, out.strip()), (0, "34"))
        rc, out, _ = run(self.asc, Fake(replies), "next-build", "--floor", "40")
        self.assertEqual((rc, out.strip()), (0, "41"))

    def test_next_build_follows_pagination(self):
        app = self.asc.APP
        first = {"data": [{"attributes": {"version": "5"}}],
                 "links": {"next": self.asc.BASE + "/v1/builds?cursor=2"}}
        second = {"data": [{"attributes": {"version": "50"}}]}
        fake = Fake({("GET", "/v1/builds"): [first, second],
                     ("GET", "/v1/apps/%s/buildUploads" % app): [{"data": []}]})
        rc, out, _ = run(self.asc, fake, "next-build")
        self.assertEqual((rc, out.strip()), (0, "51"))

    def test_add_internal_posts_only_to_the_internal_group(self):
        app = self.asc.APP
        groups = {"data": [{"id": "g-int", "attributes": {"name": "Internal", "isInternalGroup": True}}]}
        fake = Fake({("GET", "/v1/apps/%s/betaGroups" % app): [groups],
                     ("POST", "/v1/betaGroups/g-int/relationships/builds"): [{}]})
        rc, _, _ = run(self.asc, fake, "add-internal", "b-1")
        self.assertEqual(rc, 0)
        post = [c for c in fake.calls if c[0] == "POST"]
        self.assertEqual(len(post), 1)
        self.assertEqual(post[0][2], {"data": [{"type": "builds", "id": "b-1"}]})

    def test_add_internal_refuses_external_or_ambiguous_group(self):
        app = self.asc.APP
        ext = {"data": [{"id": "g-ext", "attributes": {"name": "Internal", "isInternalGroup": False}}]}
        fake = Fake({("GET", "/v1/apps/%s/betaGroups" % app): [ext]})
        rc, _, err = run(self.asc, fake, "add-internal", "b-1")
        self.assertEqual(rc, 1)
        self.assertIn("内部グループではない", err)
        self.assertFalse([c for c in fake.calls if c[0] == "POST"])
        two = {"data": [{"id": "a", "attributes": {"name": "Internal", "isInternalGroup": True}},
                        {"id": "b", "attributes": {"name": "Internal", "isInternalGroup": True}}]}
        fake = Fake({("GET", "/v1/apps/%s/betaGroups" % app): [two]})
        rc, _, _ = run(self.asc, fake, "add-internal", "b-1")
        self.assertEqual(rc, 1)
        self.assertFalse([c for c in fake.calls if c[0] == "POST"])

    def test_wait_build_valid_invalid_and_timeout(self):
        key = ("GET", "/v1/builds")
        processing = {"data": [{"id": "b-9", "attributes": {"processingState": "PROCESSING"}}]}
        valid = {"data": [{"id": "b-9", "attributes": {"processingState": "VALID"}}]}
        invalid = {"data": [{"id": "b-9", "attributes": {"processingState": "INVALID"}}]}
        rc, out, _ = run(self.asc, Fake({key: [{"data": []}, processing, valid]}), "wait-build", "2026.10.03", "32", "3600")
        self.assertEqual((rc, out.strip()), (0, "b-9"))
        rc, _, _ = run(self.asc, Fake({key: [processing, invalid]}), "wait-build", "2026.10.03", "32", "3600")
        self.assertEqual(rc, 1)
        rc, _, err = run(self.asc, Fake({key: [processing]}), "wait-build", "2026.10.03", "32", "0")
        self.assertEqual(rc, 4)


if __name__ == "__main__":
    unittest.main()
