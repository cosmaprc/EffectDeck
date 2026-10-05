// ページの文面。英語だけ（2026-09-26 に日本語をやめた。?lang= は来ても無視する）。
// 値は信頼できる定数なので HTML をそのまま書いてよい（外から来た字は worker.js で escape する）。
//
// **文面は短く、平らに。**冗談めいた言い回しは店に出すアプリに合わないと却下された。
// 説明を足すのは FAQ だけ。ほかの節に言い訳や補足を増やさない。
//
// **リリースごとに変わることは書かない。**TestFlight の案内、ベータ、どのビルドに何が入っているか。
// それは GitHub の README と releases に書き、ページからはフッターの Release notes で指す。
// JSFX や共有リンクは機能として書くだけで、どのビルドからかは言わない。
// FOSS（無料・MIT）はリリースで変わらないので書いてよい（トップにも出す）。

import {
  APP_STORE, RELEASES, GITHUB, LICENSE, ISSUES, JSFX_MD, CHAIN_MD, TWITTER, EMAIL, DISCORD,
  EFFETUNE, APPLE_PRIVACY, CLOUDFLARE_PRIVACY, OPENAI_PRIVACY,
} from "./links.js";

const a = (href, label) => `<a href="${href}">${label}</a>`;
const mail = `<a href="mailto:${EMAIL}">${EMAIL}</a>`;

export const TEXT = {
  // <title> と og:title。検索に出る言い回しをそのまま入れる。
  title: "EffectDeck — audio effects for any app on iPhone and iPad",
  description: "EffectDeck puts an effect chain on the audio of any app on iPhone and iPad: built-in effects, AUv3 plug-ins, impulse responses, and JSFX effects you write or have ChatGPT write. Free and open source (MIT). Requires iOS 27.",
  // トップの頭。リリースで変わらないことだけ（何か・App Store・GitHub・FOSS）。
  tagline: "Any effect on the audio of any app on your iPhone or iPad, through the Media Device Extension in iOS 27. Combine the built-in effects, AUv3 plug-ins and impulse responses, or write the effect you want in JSFX.",
  foss: `Free and open source (${a(LICENSE, "MIT")})`,
  howTitle: "How it works",
  home: [
    "Pick EffectDeck as the output in Control Center, and audio from any app that shows up in Now Playing goes through your effect chain, then out through the speaker, headphones or AirPods you were already using.",
    "You choose what goes in the chain. EQ, dynamics, saturation, reverb, spatial effects and analyzers are built in. AUv3 plug-ins on your iPhone or iPad, impulse responses and AutoEQ profiles load into it. An effect that does not exist yet can be written as a JSFX script.",
    "It is built on the Media Device Extension that arrived in iOS 27, so it needs iOS 27 or later.",
  ],
  // スクリーンショットの下の字は名札。説明を書かない。
  shots: [
    { file: "effects", label: "Effects", alt: "Effect chain with Stereo Blend and Multiband Saturation" },
    { file: "analyzers", label: "Analyzers", alt: "Level meter, spectrogram, spectrum analyzer and stereo meter" },
    { file: "routing", label: "Routing", alt: "Effects with bus routing badges" },
  ],
  jsfxTitle: "JSFX",
  jsfx: [
    "EffectDeck loads JSFX, the script format REAPER uses. One text file is one effect.",
    `${a(JSFX_MD, "JSFX.md")} sets out what EffectDeck supports and what it rejects. It is written to be handed to a language model as it is.`,
    // アプリはページを挟まずchatgpt.comを直に開く（EffectPickerView.writeJSFX、61efe19）。
    "In the app, <strong>Write JSFX with ChatGPT</strong> (under Plugins) opens ChatGPT with a short request that points it at JSFX.md. Import the file it returns with <strong>Import JSFX → From Files</strong>, or copy the script and use <strong>From Clipboard</strong>. A paid ChatGPT plan works better, since the free tier may skip the linked file and miss the rules.",
    // 鎖はJSFXと対になるので同じ節に置く。llms.txtはこの1行と同じことだけを書く。
    // 戻し方はCHAIN.mdの「Handing the chain over」と同じ2つ（リンクか、コードブロックを貼る）。
    `<strong>Build with ChatGPT…</strong> (at the top of the effect list) opens ChatGPT the same way to ask for a chain of the built-in effects, following ${a(CHAIN_MD, "CHAIN.md")}. Tap the link it returns, or copy the chain and use <strong>Import from clipboard</strong> in Presets.`,
  ],
  // **ページからChatGPTへは/writeを挟む。**依頼文を見せてコピーもでき、有料版を勧める1行もそこに置く。
  // アプリは2026-09-27から/writeを通らない（依頼文にアプリとDSPの版を入れるため、自分で持つ）。
  jsfxLinks: [a(JSFX_MD, "JSFX.md"), a(CHAIN_MD, "CHAIN.md"), a("/write", "Write JSFX with ChatGPT")],
  shareTitle: "Share links",
  // **内蔵の効果だけの鎖はEffeTuneのWeb版のリンクになる**（ETShareLink.url(for:)）。
  // effectdeck.nemut.aiで作るのはAUかJSFXを含む鎖とJSFXだけ（PresetsView、ETFXDLink）。
  share: [
    "JSFX scripts, and chains that use AUv3 plug-ins or JSFX effects, are shared as links on effectdeck.nemut.ai. With the app installed, they open in the app. A chain of only built-in effects is shared as a link to the EffeTune web app.",
    "A JSFX link carries the whole script after the #. Browsers do not send that part to the server.",
  ],
  supportTitle: "Support",
  support: [
    `In the app, <strong>Settings → Report a problem</strong> fills in the diagnostics and the log for you. You can also ask on ${a(DISCORD, "Discord")}, open an issue on ${a(ISSUES, "GitHub")} or write to ${a(TWITTER, "@ainemut")} on Twitter. Email: ${mail}.`,
  ],
  faqTitle: "FAQ",
  aboutTitle: "An independent project",
  about: [
    `EffectDeck is made by nemut.ai. It is <strong>not affiliated with, endorsed by, or supported by ${a(EFFETUNE, "EffeTune")} or its author, Yoshiyuki Kobayashi (Frieve-A).</strong> It bundles EffeTune's DSP under the MIT license.`,
    "Send anything about EffectDeck to nemut.ai, not to EffeTune.",
    `The source is on ${a(GITHUB, "GitHub")} under the MIT license.`,
  ],

  appStoreAlt: "Download on the App Store",
  chainTitle: "Effect chain",
  // ページからアプリへ渡すボタンは無い（worker.js の頭）。Safari のバナーか、アプリの貼り付けで渡す。
  chainHowTo: "If EffectDeck is installed, Safari shows a banner with <strong>Open</strong> at the top of this page. In another browser, copy this page's address and open EffectDeck. It offers to paste the link.",
  jsfxHowTo: "If EffectDeck is installed, Safari shows a banner with <strong>Open</strong> at the top of this page. Otherwise, copy the script below and use <strong>Import JSFX → From Clipboard</strong> in the app.",
  // /write。依頼文（links.js の CHATGPT_Q）の前後に 1 行ずつ。説明を増やさない。
  writeTitle: "Write a JSFX effect with ChatGPT",
  writePlan: `A paid ChatGPT plan is recommended: it reads the linked ${a(JSFX_MD, "JSFX.md")} and reasons through the code. The free plan often gives scripts that do not load.`,
  openChatGPT: "Open ChatGPT",
  writeOther: "The same text works in other assistants.",
  writeReturn: "In EffectDeck, import the file it returns with <strong>Import JSFX → From Files</strong>, or copy the script and use <strong>From Clipboard</strong>.",
  off: "Off",
  unreadable: "This link could not be read.",
  copy: "Copy",
  copied: "Copied",
  privacy: "Privacy",
  // フッターの名札。説明を足さない。
  releaseNotes: "Release notes",
  betaLink: "Beta (TestFlight)",
  notFound: "Page not found.",
  backHome: "EffectDeck",
  // どのページの下にも出す。長い方は about（トップだけ）。
  disclaimer: "EffectDeck is an independent project by nemut.ai, not affiliated with, endorsed by, or supported by EffeTune or its author.",
};

// トップの FAQ。**同じ中身を JSON-LD の FAQPage にも出す**（worker.js の jsonLd）。
// a は HTML。JSON-LD にはタグを外した字を入れる。
// 書いてよいのは README とプライバシーポリシーで言っていることだけ。
export const FAQ = [
  {
    q: "Can iOS run system-wide audio effects like JamesDSP or ViPER4Android?",
    a: "Since iOS 27, for media playback. The Media Device Extension lets an app appear as an audio output in Control Center. EffectDeck uses it to run an effect chain on audio from any app with a Now Playing transport, such as music and podcast apps and Safari. Games are not covered. No jailbreak is involved.",
  },
  {
    q: "Which iOS version does it need?",
    a: "iOS 27 or later. The Media Device Extension it is built on does not exist in earlier versions.",
  },
  {
    q: "Does it work with AirPods and headphones?",
    a: "Yes. After the chain, audio plays on whatever output was selected before you picked EffectDeck: the speaker, wired headphones or AirPods.",
  },
  {
    q: "Which effects are included?",
    a: `Built in: EQ, dynamics, saturation, reverb, spatial effects and analyzers such as a spectrum analyzer and a spectrogram, ported from EffeTune. It also hosts AUv3 effect plug-ins installed on the device, loads impulse responses and AutoEQ profiles, and runs single-file JSFX effects; ${a(JSFX_MD, "JSFX.md")} lists what is supported.`,
  },
  {
    q: "Is it free?",
    a: `Yes. EffectDeck is free and open source under the MIT license. The source is on ${a(GITHUB, "GitHub")}.`,
  },
  {
    q: "It says Unable to Connect. What is wrong?",
    a: "Usually Spotify with Canvas on. A track with a Canvas plays as video, and iOS does not route it to EffectDeck; turn Canvas off in Spotify's settings, then restart Spotify. Otherwise, restart the player app, then EffectDeck, then the iPhone.",
  },
  {
    q: "Does my audio leave the device?",
    a: `No. Audio is processed and played back on the device, is not recorded, and makes no network connection. See the ${a("/privacy", "privacy policy")}.`,
  },
];

// プライバシーポリシー。元は nemut.ai/effetune-live/privacy の 2026-09-18 版。
// 2026-09-26: このサイト（共有リンクの ?p= が届く）、リンク、JSFX を足し、
// EffeTune を「改変せずに」としていたのを直した（Patches/effetune-*.diff を当てている）。
// 2026-09-27: 正はここ（effectdeck.nemut.ai/privacy）。旧URLはnemut.aiのWorkerが301でここへ送る。
// Linksにアプリが取りに行く先と開く先を全部書いた（From Linkの音、gistのapi.github.com、
// 共有の拡張、ChatGPTの2つの口、frieveのリンク）。Report a problemの節を足した。
// **アプリが取りに行く先や開く先を増やしたら、ここも足す。**
// **中身を変えたら updated も変える。**
export const PRIVACY = {
  title: "Privacy Policy",
  updated: "Last updated 2026-09-27",
  body: `
<p>
  nemut.ai does not collect or store any of your data. There is no account to sign
  up for, no analytics, and no advertising. The app sends nothing to nemut.ai on its
  own. What it sends elsewhere is described under <a href="#presets">Settings and presets</a>,
  <a href="#links">Links</a> and <a href="#report">Reporting a problem</a>. What this
  website receives is described under <a href="#website">This website</a>.
</p>

<h2>Audio</h2>
<p>
  When you select <strong>EffectDeck</strong> as the output in Control Center, audio from
  other apps is handed to the app's media device extension and passed to the app over a
  loopback connection on your device (127.0.0.1). The audio is processed and played
  back on the same device.
</p>
<ul>
  <li>Audio never leaves the device.</li>
  <li>Audio is not recorded or written to storage.</li>
  <li>Handling audio makes no network connection at all.</li>
</ul>

<h2>Files you add</h2>
<p>
  Impulse response files and JSFX scripts you import stay in the app's own storage on
  your device. They are not uploaded anywhere. Impulse response files are in the app's
  Documents folder, and you can remove them from inside the app or with the Files app.
  JSFX scripts can be removed from inside the app.
</p>

<h2 id="links">Links</h2>
<p>
  The app downloads a file only when you ask it to:
</p>
<ul>
  <li><strong>Import JSFX → From Link</strong> downloads the JSFX script or impulse
    response at the address you enter.</li>
  <li>When you share a link to EffectDeck from another app and tap <strong>Add</strong>,
    the EffectDeck share extension downloads it the same way. Files and text you share
    are copied on the device, and nothing is downloaded.</li>
</ul>
<p>
  The request goes to the site in the address, not to nemut.ai. That site sees your IP
  address, as with any download. For a GitHub page, the app downloads the file from
  raw.githubusercontent.com instead. For a gist, it may first read the gist's list of
  files from api.github.com to find the file, then download that file from GitHub.
</p>
<p>
  <strong>Write JSFX with ChatGPT</strong> and <strong>Build with ChatGPT</strong>
  open chatgpt.com, or the ChatGPT app if it is installed, with a short request in the
  address. The request names the versions of EffectDeck and its EffeTune DSP and links
  to JSFX.md or CHAIN.md on GitHub. It reaches OpenAI when ChatGPT opens. The app sends
  nothing else to OpenAI. What you do in ChatGPT is covered by the
  <a href="${OPENAI_PRIVACY}">OpenAI Privacy Policy</a>.
</p>
<p>
  Sharing a JSFX script, or a chain that uses AUv3 plug-ins or JSFX effects, makes a link
  on effectdeck.nemut.ai. Sharing a chain of only built-in effects, or exporting a chain to
  EffeTune, makes a link to the EffeTune web app on effetune.frieve.com, which nemut.ai
  does not run. The chain or the script is carried in the link itself. Nothing is
  uploaded when the link is made. When EffectDeck opens an effectdeck.nemut.ai link, it
  reads the link on the device and contacts no server.
</p>
<p>
  Other links in the app, such as those to GitHub issues, Discord and Twitter, only open the page
  and carry nothing from the app.
</p>

<h2 id="report">Reporting a problem</h2>
<p>
  <strong>Report a problem</strong> in Settings opens an email to ${EMAIL} or a new
  GitHub issue with a report filled in: the app version, the device model and iOS
  version, the app's audio settings and output, and the end of the app's log. You can
  change or delete any of it first. The email goes only when you send it. For GitHub,
  the report is part of the page's address, so it reaches GitHub when the page opens;
  it is published only when you submit the issue. <strong>Attach log</strong> hands the
  whole log to the share sheet, and you choose where it goes.
</p>

<h2 id="presets">Settings and presets</h2>
<p>
  Three things are mirrored to your own iCloud so that your other devices running
  EffectDeck can read them: the effect chain you have now, the chains you have saved
  as presets, and the presets you have saved per effect. This uses Apple's iCloud
  key-value storage.
</p>
<ul>
  <li>It goes to your iCloud account, not to a nemut.ai server. We cannot read it.</li>
  <li>Apple's handling of what is in your iCloud is covered by the
    <a href="${APPLE_PRIVACY}">Apple Privacy Policy</a>.</li>
  <li>Nothing is mirrored if you are not signed in to iCloud. Turning EffectDeck off
    under iCloud in the Settings app stops it, and what is already on the device
    stays there.</li>
</ul>
<p>
  Everything else stays on the device: the processing rate, the buffer size, and the
  rest of the settings in the app. Impulse response files are not mirrored either —
  a chain restored on another device refers to the file by name, so you import the
  file there yourself.
</p>

<h2 id="website">This website</h2>
<p>
  effectdeck.nemut.ai and fxd.nemut.ai (a short address that redirects to it) run on
  Cloudflare Workers. The site sets no
  cookies and runs no analytics, and nemut.ai keeps no request logs. Cloudflare
  processes each request, including your IP address, to deliver the page; see the
  <a href="${CLOUDFLARE_PRIVACY}">Cloudflare Privacy Policy</a>.
</p>
<p>
  When a chain link is opened in a browser, the chain after <code>?p=</code> reaches
  the server so that the page can list it. It is not stored. A JSFX link keeps the
  script after the <code>#</code>, and browsers do not send that part to the server.
</p>

<h2>Third-party code</h2>
<p>
  The built-in audio effects come from
  <a href="${EFFETUNE}">EffeTune</a> by Yoshiyuki Kobayashi
  (MIT), with small patches that connect it to the app. The third-party code in the
  app performs no networking. Full license texts are included in the app under About.
</p>

<h2>Children</h2>
<p>
  This app is not directed at children and collects nothing from anyone.
</p>

<h2>Changes</h2>
<p>
  If this policy changes, the date below changes with it.
</p>

<h2>Contact</h2>
<p>${mail}</p>
`,
};

// /llms.txt。言語モデルのクローラー向けの素の字。ページと同じことだけを書く。
export const LLMS_TXT = `# EffectDeck

> EffectDeck is an iPhone and iPad app that runs an effect chain on audio from other apps. It requires iOS 27 or later. It is free and open source (MIT). It is an independent project by nemut.ai, not affiliated with, endorsed by, or supported by EffeTune or its author.

## How it works

- EffectDeck uses the Media Device Extension added in iOS 27. It appears as an audio output in Control Center.
- When EffectDeck is picked as the output, audio from any app with a Now Playing transport (music and podcast apps, Safari) goes through the user's effect chain, then plays on the output that was selected before (speaker, wired headphones, AirPods).
- Games and other apps without a Now Playing transport are not covered. No jailbreak is involved.
- Audio is processed on the device. It is not recorded and not sent over the network.
- Built-in effects: EQ, dynamics, saturation, reverb, spatial effects and analyzers, ported from EffeTune (MIT license). The chain also takes AUv3 plug-ins installed on the device, impulse responses and AutoEQ profiles.
- EffectDeck also loads JSFX, the script format REAPER uses. One text file is one effect. JSFX.md describes what is supported and is written to be given to a language model.
- In the app, Write JSFX with ChatGPT (under Plugins) opens ChatGPT with a short request that points it at JSFX.md. https://effectdeck.nemut.ai/write has the same kind of request to paste into ChatGPT or another assistant. The returned file is imported with Import JSFX → From Files, or the copied script with From Clipboard.
- CHAIN.md describes how a language model writes a chain of the built-in effects that EffectDeck imports. In the app, Build with ChatGPT… (at the top of the effect list) opens ChatGPT the same way to ask for one. The chain comes back as a link to tap, or is copied and imported with Import from clipboard in Presets.
- EffectDeck is free on the App Store and its source is on GitHub under the MIT license.
- JSFX scripts, and chains that use AUv3 plug-ins or JSFX effects, are shared as links on https://effectdeck.nemut.ai/ . A JSFX link carries the script after the #. A chain of only built-in effects is shared as a link to the EffeTune web app.

## Links

- Website: https://effectdeck.nemut.ai/
- App Store: ${APP_STORE}
- Source (MIT): ${GITHUB}
- README: ${GITHUB}#readme
- Release notes: ${RELEASES}
- JSFX.md: ${JSFX_MD}
- CHAIN.md: ${CHAIN_MD}
- Write a JSFX effect with ChatGPT: https://effectdeck.nemut.ai/write
- Issues: ${ISSUES}
- Discord: ${DISCORD}
- Privacy policy: https://effectdeck.nemut.ai/privacy
- Contact: ${EMAIL}
`;
