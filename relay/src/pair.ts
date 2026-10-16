// The /pair page: draws the `parley://pair?…` link from the URL fragment as a QR code, entirely
// in the browser. The fragment never reaches the relay, so neither does the room secret.

// Pinned and integrity-checked; the only thing the page loads from elsewhere.
export const QR_LIB = {
	url: "https://cdnjs.cloudflare.com/ajax/libs/qrcode-generator/1.5.2/qrcode.min.js",
	integrity: "sha512-c3HC2N32Up+KwxhFN2dZkoDWSdxWqwzDJCnroUffjS/HBQHf5Ou1uFpqIT0rOIJ5fW8TxHmUpCDndH2A6xNhpQ==",
};

// Allowed by hash in the page's CSP, so keep it free of template interpolation.
export const PAIR_SCRIPT = `
(function () {
  var raw = location.hash.slice(1);
  var link = "";
  try {
    // The app percent-encodes the link; tolerate one pasted as-is.
    link = raw.indexOf("parley:") === 0 ? raw : decodeURIComponent(raw);
  } catch (e) {}
  var params = null;
  try {
    params = link.indexOf("parley://pair?") === 0 ? new URL(link).searchParams : null;
  } catch (e) {}
  if (!params || !params.get("u") || !params.get("r") || !params.get("k") || typeof qrcode !== "function") {
    document.body.className = "error";
    document.getElementById("hint").textContent = raw
      ? "Dieser Kopplungslink ist ungültig. Öffne die Seite erneut über „iPhone verbinden…“ in Parley."
      : "Kein Kopplungslink gefunden. Öffne die Seite über „iPhone verbinden…“ in Parley.";
    return;
  }

  qrcode.stringToBytes = qrcode.stringToBytesFuncs["UTF-8"];
  var qr = qrcode(0, "M");
  qr.addData(link);
  qr.make();
  var n = qr.getModuleCount();
  var d = "";
  for (var r = 0; r < n; r++) {
    for (var c = 0; c < n; c++) {
      if (qr.isDark(r, c)) d += "M" + c + " " + r + "h1v1h-1z";
    }
  }
  var ns = "http://www.w3.org/2000/svg";
  var svg = document.createElementNS(ns, "svg");
  // 4-module quiet zone around the code, as scanners expect.
  svg.setAttribute("viewBox", "-4 -4 " + (n + 8) + " " + (n + 8));
  svg.setAttribute("shape-rendering", "crispEdges");
  var path = document.createElementNS(ns, "path");
  path.setAttribute("d", d);
  path.setAttribute("fill", "#000");
  svg.appendChild(path);
  document.getElementById("qr").appendChild(svg);
  document.getElementById("open").href = link;
})();
`;

export const PAIR_HTML = `<!doctype html>
<html lang="de">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light dark">
<meta name="referrer" content="no-referrer">
<meta name="robots" content="noindex">
<title>Parley – iPhone verbinden</title>
<style>
  :root { --bg: #f5f5f7; --fg: #1d1d1f; --muted: #6e6e73; }
  @media (prefers-color-scheme: dark) { :root { --bg: #000; --fg: #f5f5f7; --muted: #98989d; } }
  * { box-sizing: border-box; }
  body {
    margin: 0; min-height: 100vh; display: grid; place-items: center;
    background: var(--bg); color: var(--fg);
    font: 16px/1.45 -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif;
  }
  main { width: 100%; max-width: 24rem; padding: 2rem 16px; text-align: center; }
  h1 { font-size: 1.5rem; margin: 0 0 .25rem; }
  p { margin: .5rem 0; }
  .muted { color: var(--muted); font-size: .875rem; }
  a { color: inherit; }
  /* Always dark-on-white: inverted codes trip up some scanners. */
  #qr { width: min(18rem, 80vw); aspect-ratio: 1; margin: 1.5rem auto; background: #fff; border-radius: 16px; }
  #qr svg { display: block; width: 100%; height: 100%; }
  .error #qr, .error .ok { display: none; }
</style>
</head>
<body>
<main>
  <h1>iPhone verbinden</h1>
  <p id="hint">Mit der Parley-App auf dem iPhone scannen.</p>
  <div id="qr" role="img" aria-label="QR-Code mit dem Parley-Kopplungslink"></div>
  <p class="muted ok">Der Code enthält den Schlüssel für deinen Parley-Raum. Er bleibt in diesem Browser – der Relay-Server bekommt ihn nie zu sehen. Zeig ihn niemandem sonst.</p>
  <p class="muted ok"><a id="open" href="#">Schon auf dem iPhone? In Parley öffnen</a></p>
  <noscript><p>Für den QR-Code wird JavaScript benötigt.</p></noscript>
</main>
<script src="${QR_LIB.url}" integrity="${QR_LIB.integrity}" crossorigin="anonymous" referrerpolicy="no-referrer"></script>
<script>${PAIR_SCRIPT}</script>
</body>
</html>
`;
