// リクエストから読むもの。Worker の外（test.mjs）でも動くように import を持たない。
//
// 2026-09-26 に日本語をやめた。**?lang= と Accept-Language は読まない。**
// 古いリンクに付いた ?lang=ja はそのまま英語のページになる。

// 共有リンクの p（base64 の JSON、ETShareLink 参照）から名前だけ拾う。
// 読めなければ null。**ここで読めないものはアプリでも読めない**ので、バナーに app-argument も付けない。
// そのためアプリ（ETChainText.json(from:)）と同じ幅で読む。ChatGPT に作らせたリンクは
// base64url（- と _）や = の無いもの、途中で折り返したもので来ることがあり、
// JSFX を名前で指す段（{"jsfx":"<desc:の名前>"}、CHAIN.md）も持つ。ロング形式も受ける。
export function chainEntries(p) {
  try {
    // URLSearchParams は生の + を空白にする。アプリは %2B で書くが、手で貼られたものに備える。
    // 改行やタブは折り返しなので外す。末尾の = が無くても atob は読む。
    const b64 = p.trim()
      .replace(/ /g, "+")
      .replace(/[\t\r\n]/g, "")
      .replace(/-/g, "+")
      .replace(/_/g, "/");
    const bin = atob(b64);
    const bytes = Uint8Array.from(bin, (c) => c.charCodeAt(0));
    const json = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
    const list = Array.isArray(json) ? json : Array.isArray(json?.pipeline) ? json.pipeline : null;
    if (!list) return null;
    const out = [];
    for (const o of list.slice(0, 500)) {
      if (!o || typeof o !== "object") continue;
      const off = (o.enabled ?? o.en) === false;
      if (typeof o.jsfx === "string" && o.jsfx !== "") {
        out.push({ section: false, name: o.jsfx, off });
        continue;
      }
      const nm = o.name ?? o.nm;
      if (typeof nm !== "string" || nm === "") continue;
      if (nm === "Section") {
        const cm = o.parameters?.cm ?? o.cm;
        out.push({ section: true, name: typeof cm === "string" && cm ? `${cm} Section` : "Section" });
      } else {
        out.push({ section: false, name: nm, off });
      }
    }
    return out.length ? out : null;
  } catch {
    return null;
  }
}
