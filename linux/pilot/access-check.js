// Read-only access check of the server browser over CDP: opens each service in a NEW tab,
// reports final host, page title and whether a login page shows. Reads no content, clicks
// nothing, closes its own tabs. Usage (in the session container):
//   node access-check.js <cdp url> [services.json]
// services.json: [["Name", "start url", "regex of the host a signed-in user ends up on"], …];
// without it the agency defaults below. Profile lists with customer systems stay on the server.
const { chromium } = require("playwright-core");
const services = [
  // [name, start url, the host a signed-in user ends up on]
  ["Gmail", "https://mail.google.com/mail/u/0/", /^mail\.google\.com$/],
  ["Kalender", "https://calendar.google.com/calendar/u/0/r", /^calendar\.google\.com$/],
  ["monday", "https://auth.monday.com/", /\.monday\.com$/],
  ["Sanity", "https://www.sanity.io/manage", /^www\.sanity\.io$/],
  ["Vercel", "https://vercel.com/dashboard", /^vercel\.com$/],
];
if (process.argv[3]) services.splice(0, services.length,
  ...JSON.parse(require("fs").readFileSync(process.argv[3], "utf8")).map(([n, u, h]) => [n, u, new RegExp(h)]));
const cdp = process.argv[2] || "http://10.252.0.10:9223";
// A crashed tab ("Oh nein!", e.g. out of memory) answers no CDP call and blocks connectOverCDP:
// find the tabs that don't answer within 4 s and open their address anew in a fresh tab.
async function reopenDeadTabs() {
  const tabs = (await (await fetch(cdp + "/json")).json()).filter(t => t.type === "page");
  for (const t of tabs) {
    const alive = await new Promise(res => {
      const ws = new WebSocket(t.webSocketDebuggerUrl);
      const to = setTimeout(() => { res(false); try { ws.close(); } catch {} }, 4000);
      ws.onopen = () => ws.send(JSON.stringify({ id: 1, method: "Runtime.evaluate", params: { expression: "1" } }));
      ws.onmessage = () => { clearTimeout(to); res(true); ws.close(); };
      ws.onerror = () => { clearTimeout(to); res(false); };
    });
    if (alive) continue;
    await fetch(`${cdp}/json/close/${t.id}`);
    await fetch(`${cdp}/json/new?${t.url}`, { method: "PUT" });
    console.log(`Tab       NEU GEÖFFNET  ${new URL(t.url).host} (antwortete nicht)`);
  }
}
async function connect() {
  try { return await chromium.connectOverCDP(cdp, { timeout: 20000 }); }
  catch (e) { await reopenDeadTabs(); await new Promise(r => setTimeout(r, 15000)); return chromium.connectOverCDP(cdp, { timeout: 30000 }); }
}
(async () => {
  let b;
  try { b = await connect(); }
  catch (e) { console.log(`Browser   FEHLER nicht erreichbar (Container aus oder Volume zu?): ${e.message.split("\n")[0]}`); process.exit(1); }
  const ctx = b.contexts()[0];
  for (const [name, url, home] of services) {
    const p = await ctx.newPage();
    try {
      await p.goto(url, { waitUntil: "domcontentloaded", timeout: 30000 });
      // Teams, Jira, Gmail redirect by script, some only after seconds: let them, then wait up
      // to 20 s more for the signed-in host.
      await p.waitForTimeout(8000);
      for (let i = 0; i < 20 && !home.test(new URL(p.url()).host || "x"); i++) await p.waitForTimeout(1000);
      await p.waitForTimeout(2000);
      const u = new URL(p.url());
      const isLogin = !home.test(u.host) || /login\.microsoftonline|login\.live|id\.atlassian|accounts\.google/.test(u.host) || /login|signin|sign_in|auth\/|\/oauth/.test(u.pathname)
        || (await p.locator('input[type="password"]').count()) > 0;
      console.log(`${name.padEnd(9)} ${isLogin ? "LOGIN NÖTIG" : "angemeldet"}  ${u.host}${u.pathname.slice(0, 40)}  „${(await p.title()).slice(0, 50)}“`);
    } catch (e) { console.log(`${name.padEnd(9)} FEHLER ${e.message.split("\n")[0]}`); }
    await p.close();
  }
  await b.close();   // disconnects only; the browser keeps running
})();
