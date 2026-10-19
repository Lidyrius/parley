// The /join page: an invite to someone's shared session (docs/MULTIPLAYER.md). The `parley://join?…`
// link rides in the URL fragment, which never reaches the relay — so neither does the room key.
// On a phone with Parley the iPhone opens the app directly (universal link) or the button does;
// on a computer the page shows the code to scan.
import { QR_LIB } from "./pair";

// Allowed by hash in the page's CSP, so keep it free of template interpolation. Text goes in via
// textContent only — the invite's names never become markup.
export const JOIN_SCRIPT = `
(function () {
  var raw = location.hash.slice(1);
  var link = "";
  try { link = raw.indexOf("parley:") === 0 ? raw : decodeURIComponent(raw); } catch (e) {}
  var params = null;
  try { params = link.indexOf("parley://join?") === 0 ? new URL(link).searchParams : null; } catch (e) {}
  if (!params || !params.get("u") || !params.get("r") || !params.get("k") || !params.get("e")) {
    document.body.className = "error";
    document.getElementById("title").textContent = "Einladung ungültig";
    document.getElementById("hint").textContent = "Dieser Link ist unvollständig. Bitten Sie um einen neuen.";
    return;
  }
  var who = params.get("h") || "Jemand", what = params.get("s") || "eine Session";
  document.getElementById("title").textContent = who + " lädt Sie ein";
  document.getElementById("hint").textContent = "zur Parley-Session „" + what + "“. Der Link gilt einmal und 24 Stunden.";
  document.getElementById("open").href = link;
  if (typeof qrcode === "function") {
    qrcode.stringToBytes = qrcode.stringToBytesFuncs["UTF-8"];
    var qr = qrcode(0, "M");
    qr.addData(location.href);
    qr.make();
    var n = qr.getModuleCount(), d = "";
    for (var r = 0; r < n; r++) for (var c = 0; c < n; c++) if (qr.isDark(r, c)) d += "M" + c + " " + r + "h1v1h-1z";
    var ns = "http://www.w3.org/2000/svg", svg = document.createElementNS(ns, "svg");
    svg.setAttribute("viewBox", "-4 -4 " + (n + 8) + " " + (n + 8));
    svg.setAttribute("shape-rendering", "crispEdges");
    var path = document.createElementNS(ns, "path");
    path.setAttribute("d", d); path.setAttribute("fill", "#000");
    svg.appendChild(path);
    document.getElementById("qr").appendChild(svg);
  }
})();
`;

export const JOIN_HTML = `<!doctype html>
<html lang="de">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light dark">
<meta name="referrer" content="no-referrer">
<meta name="robots" content="noindex">
<title>Parley – Einladung</title>
<style>
  :root { --bg: #f8f7f3; --fg: #1f1e1c; --muted: #6e6c66; --accent: #dc7a5a; }
  @media (prefers-color-scheme: dark) { :root { --bg: #1b1a18; --fg: #f5f4f0; --muted: #a8a6a0; } }
  * { box-sizing: border-box; }
  body { margin: 0; min-height: 100vh; display: grid; place-items: center; background: var(--bg); color: var(--fg);
    font: 16px/1.45 -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif; }
  main { width: 100%; max-width: 24rem; padding: 2rem 16px; text-align: center; }
  h1 { font-size: 1.5rem; margin: 0 0 .25rem; }
  p { margin: .5rem 0; }
  .muted { color: var(--muted); font-size: .875rem; }
  #open { display: block; margin: 1.5rem 0 1rem; padding: .9rem 1rem; border-radius: 999px; background: var(--accent);
    color: #fff; font-weight: 600; text-decoration: none; }
  #qr { width: min(14rem, 70vw); aspect-ratio: 1; margin: 1rem auto; background: #fff; border-radius: 16px; }
  #qr svg { display: block; width: 100%; height: 100%; }
  .error #qr, .error .ok, .error #open { display: none; }
</style>
</head>
<body>
<main>
  <h1 id="title">Einladung</h1>
  <p id="hint"></p>
  <a id="open" href="#">In Parley öffnen</a>
  <p class="muted ok">Am Computer? Mit dem Handy scannen:</p>
  <div id="qr" class="ok" role="img" aria-label="QR-Code mit der Einladung"></div>
  <p class="muted ok">Noch kein Parley? Bitten Sie die einladende Person um Zugang zur App (iPhone: TestFlight, Android: APK).
    Ende-zu-Ende verschlüsselt — der Schlüssel steht nur in diesem Link, der Relay-Server sieht ihn nie.</p>
  <noscript><p>Für diese Seite wird JavaScript benötigt.</p></noscript>
</main>
<script src="${QR_LIB.url}" integrity="${QR_LIB.integrity}" crossorigin="anonymous" referrerpolicy="no-referrer"></script>
<script>${JOIN_SCRIPT}</script>
</body>
</html>
`;

// iOS universal links: /join on this relay opens the Parley app directly (it reads the fragment).
export const APPLE_APP_SITE_ASSOCIATION = JSON.stringify({
	applinks: { details: [{ appIDs: ["384887N3UL.de.developaway.parley.mobile"], components: [{ "/": "/join" }] }] },
});
