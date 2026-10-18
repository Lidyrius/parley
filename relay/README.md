# Parley relay

A small Cloudflare Worker + Durable Object that connects the Parley app (Mac/Windows) with the
Parley iPhone app from any network. Both sides dial **out** to the relay over `wss://`, so the
computer opens no port and the phone needs no VPN. One Durable Object per pairing room keeps the
room's claim (`sha256` of its secret) and the latest `sessions` frame; everything else is relayed
as-is. Protocol and pairing: [`docs/IPHONE.md`](../docs/IPHONE.md).

Parley uses a public instance by default (`https://parley-relay.sydney-d51.workers.dev`); every
frame is end-to-end encrypted, so the relay never sees content (`docs/IPHONE.md` → v5). Your own
runs in your Cloudflare account and fits the Workers free plan (SQLite-backed Durable
Objects, WebSocket hibernation, `ping`/`pong` answered without waking the object).

## Deploy

```bash
cd relay
npm install
npx wrangler login
npx wrangler deploy
```

`wrangler deploy` prints the Worker's URL, `https://parley-relay.<your-subdomain>.workers.dev`.
Put that into the Parley app's settings as `relayUrl`, then use "Handy verbinden…" in the app's
menu to pair the phone.

## Endpoints

| Path | What |
|------|------|
| `GET /` | `parley relay ok` (health check) |
| `GET /pair#<pairing link>` | Static page that draws the `parley://pair?…` link from the URL fragment as a QR code, in the browser. The fragment, and with it the secret, never reaches the relay. |
| `GET /v1/room/<room>?role=host\|phone` | WebSocket, `Authorization: Bearer <secret>` |

Room WebSocket behaviour beyond `docs/IPHONE.md`:

- `400` for a malformed room id (base64url, 16–64 chars) or role, `426` without a WebSocket
  upgrade, `401` without a bearer secret or with the wrong one, `404` for a phone on an unclaimed room.
- A host connection replaced by a newer one is closed with code `4000`.
- Text frames that aren't a JSON object with a string `t`, binary frames, and frames over 256 KB
  are dropped.

## Develop

```bash
npm test            # vitest in the Workers runtime
npm run typecheck
npm run dev         # local relay on http://localhost:8787
```
