// Read-only access check of the server browser over CDP: opens each service in a NEW tab,
// reports final host, page title and whether a login page shows. Reads no content, clicks
// nothing, closes its own tabs. Usage (in the session container): node access-check.js http://10.252.0.10:9223
const { chromium } = require("playwright-core");
const services = [
  // [name, start url, the host a signed-in user ends up on]
  ["Gmail", "https://mail.google.com/mail/u/0/", /^mail\.google\.com$/],
  ["Kalender", "https://calendar.google.com/calendar/u/0/r", /^calendar\.google\.com$/],
  ["monday", "https://auth.monday.com/", /\.monday\.com$/],
  ["Sanity", "https://www.sanity.io/manage", /^www\.sanity\.io$/],
];
(async () => {
  const b = await chromium.connectOverCDP(process.argv[2] || "http://10.252.0.10:9223");
  const ctx = b.contexts()[0];
  for (const [name, url, home] of services) {
    const p = await ctx.newPage();
    try {
      await p.goto(url, { waitUntil: "domcontentloaded", timeout: 30000 });
      // Gmail and others finish redirecting by script: wait up to 20 s for the signed-in host.
      for (let i = 0; i < 20 && !home.test(new URL(p.url()).host || "x"); i++) await p.waitForTimeout(1000);
      await p.waitForTimeout(2000);
      const u = new URL(p.url());
      const isLogin = !home.test(u.host) || /login|signin|sign_in|auth\//.test(u.pathname)
        || (await p.locator('input[type="password"]').count()) > 0;
      console.log(`${name.padEnd(9)} ${isLogin ? "LOGIN NÖTIG" : "angemeldet"}  ${u.host}${u.pathname.slice(0, 40)}  „${(await p.title()).slice(0, 50)}“`);
    } catch (e) { console.log(`${name.padEnd(9)} FEHLER ${e.message.split("\n")[0]}`); }
    await p.close();
  }
  await b.close();   // disconnects only; the browser keeps running
})();
