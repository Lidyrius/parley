import { evictDurableObject, runInDurableObject } from "cloudflare:test";
import { env, exports } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { PAIR_SCRIPT, QR_LIB } from "../src/pair";

const SECRET = "dGhpcy1pcy1hLXRlc3Qtc2VjcmV0LW9mLTMyLWJ5dGVz";
const OTHER = "c29tZWJvZHktZWxzZS1zLXNlY3JldC0zMi1ieXRlcyE";

// Storage is shared within this file, so every test gets its own room.
const newRoom = () => `t_${crypto.randomUUID().replaceAll("-", "")}`;

function dial(room: string, role: string, secret: string | null = SECRET, init: RequestInit = {}) {
	const headers = new Headers({ Upgrade: "websocket" });
	if (secret !== null) headers.set("Authorization", `Bearer ${secret}`);
	return exports.default.fetch(`https://relay.test/v1/room/${room}?role=${role}`, { headers, ...init });
}

/** A test-side WebSocket that queues incoming frames so tests can await them in order. */
class Peer {
	private inbox: string[] = [];
	private waiting: ((frame: string) => void)[] = [];
	readonly closed: Promise<CloseEvent>;

	constructor(readonly ws: WebSocket) {
		ws.accept();
		ws.addEventListener("message", (e) => {
			const frame = typeof e.data === "string" ? e.data : "<binary>";
			const waiter = this.waiting.shift();
			if (waiter) waiter(frame);
			else this.inbox.push(frame);
		});
		this.closed = new Promise((resolve) => ws.addEventListener("close", resolve));
	}

	next(timeoutMs = 2000): Promise<string> {
		const queued = this.inbox.shift();
		if (queued !== undefined) return Promise.resolve(queued);
		return new Promise((resolve, reject) => {
			const timer = setTimeout(() => reject(new Error("no frame within timeout")), timeoutMs);
			this.waiting.push((frame) => {
				clearTimeout(timer);
				resolve(frame);
			});
		});
	}

	async json(): Promise<unknown> {
		return JSON.parse(await this.next());
	}

	send(frame: unknown): void {
		this.ws.send(typeof frame === "string" ? frame : JSON.stringify(frame));
	}
}

async function connect(room: string, role: "host" | "phone", secret = SECRET): Promise<Peer> {
	const res = await dial(room, role, secret);
	expect(res.status).toBe(101);
	return new Peer(res.webSocket!);
}

/** Claims `room` with a host and leaves again, so phones can join a host-less room. */
async function claim(room: string): Promise<void> {
	const host = await connect(room, "host");
	host.ws.close(1000);
	await host.closed;
}

const sessionsFrame = (n: number) => ({
	t: "sessions",
	sessions: [{ id: "s1", name: "vloude", state: "working" }],
	today: { turns: n },
	at: 1_760_000_000_000 + n,
});

describe("plain HTTP", () => {
	it("answers / with a health line", async () => {
		const res = await exports.default.fetch("https://relay.test/");
		expect(res.status).toBe(200);
		expect(await res.text()).toBe("parley relay ok");
	});

	it("404s unknown paths", async () => {
		expect((await exports.default.fetch("https://relay.test/nope")).status).toBe(404);
	});

	it("serves the pairing page with only the pinned QR library allowed", async () => {
		const res = await exports.default.fetch("https://relay.test/pair");
		expect(res.status).toBe(200);
		expect(res.headers.get("content-type")).toContain("text/html");
		const html = await res.text();
		expect(html).toContain("Mit der Parley-App auf dem iPhone scannen");
		expect(html).toContain(`<script src="${QR_LIB.url}" integrity="${QR_LIB.integrity}"`);
		expect(html).toContain(`<script>${PAIR_SCRIPT}</script>`);

		// The inline script must match the CSP hash, or browsers refuse to run it.
		const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(PAIR_SCRIPT));
		const hash = btoa(String.fromCharCode(...new Uint8Array(digest)));
		const csp = res.headers.get("content-security-policy") ?? "";
		expect(csp).toContain("default-src 'none'");
		expect(csp).toContain(`script-src 'sha256-${hash}' ${QR_LIB.url}`);
		expect(csp).not.toContain("connect-src");
	});
});

describe("room request validation", () => {
	it("rejects malformed room ids", async () => {
		expect((await dial("short", "host")).status).toBe(400);
		expect((await dial("not+base64url+room+id", "host")).status).toBe(400);
		expect((await dial("x".repeat(65), "host")).status).toBe(400);
	});

	it("rejects unknown roles", async () => {
		expect((await dial(newRoom(), "admin")).status).toBe(400);
		expect((await dial(newRoom(), "")).status).toBe(400);
	});

	it("requires a websocket upgrade", async () => {
		const res = await exports.default.fetch(`https://relay.test/v1/room/${newRoom()}?role=host`, {
			headers: { Authorization: `Bearer ${SECRET}` },
		});
		expect(res.status).toBe(426);
	});

	it("requires a bearer secret", async () => {
		expect((await dial(newRoom(), "host", null)).status).toBe(401);
	});
});

describe("claiming a room", () => {
	it("lets the first host claim it and stores only the secret's hash", async () => {
		const room = newRoom();
		const host = await connect(room, "host");

		const stub = env.ROOM.get(env.ROOM.idFromName(room));
		const stored = await runInDurableObject(stub, (_, state) => state.storage.kv.get<string>("claim"));
		const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(SECRET));
		const hex = Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
		expect(stored).toBe(hex);
		host.ws.close(1000);
	});

	it("401s a wrong secret for hosts and phones once claimed", async () => {
		const room = newRoom();
		const host = await connect(room, "host");
		expect((await dial(room, "host", OTHER)).status).toBe(401);
		expect((await dial(room, "phone", OTHER)).status).toBe(401);
		host.ws.close(1000);
	});

	it("404s a phone on an unclaimed room without claiming it", async () => {
		const room = newRoom();
		expect((await dial(room, "phone")).status).toBe(404);
		// The phone's secret didn't stick: a host with a different one still claims the room.
		const host = await connect(room, "host", OTHER);
		expect((await dial(room, "phone")).status).toBe(401);
		host.ws.close(1000);
	});

	it("lets the right secret back in after the host left", async () => {
		const room = newRoom();
		await claim(room);
		const host = await connect(room, "host");
		const phone = await connect(room, "phone");
		expect(await phone.json()).toEqual({ t: "peer", host: true });
		host.ws.close(1000);
		phone.ws.close(1000);
	});
});

describe("forwarding", () => {
	it("forwards host frames to every phone", async () => {
		const room = newRoom();
		const host = await connect(room, "host");
		const a = await connect(room, "phone");
		const b = await connect(room, "phone");
		expect(await a.json()).toEqual({ t: "peer", host: true });
		expect(await b.json()).toEqual({ t: "peer", host: true });

		host.send(sessionsFrame(1));
		expect(await a.json()).toEqual(sessionsFrame(1));
		expect(await b.json()).toEqual(sessionsFrame(1));
		for (const p of [host, a, b]) p.ws.close(1000);
	});

	it("forwards phone frames to the host", async () => {
		const room = newRoom();
		const host = await connect(room, "host");
		const phone = await connect(room, "phone");
		await phone.next(); // peer

		phone.send({ t: "hello", device: "iPhone" });
		phone.send({ t: "resume", id: "abc" });
		expect(await host.json()).toEqual({ t: "hello", device: "iPhone" });
		expect(await host.json()).toEqual({ t: "resume", id: "abc" });
		host.ws.close(1000);
		phone.ws.close(1000);
	});

	it("forwards call audio (binary) both ways and drops oversized audio", async () => {
		const room = newRoom();
		const host = await connect(room, "host");
		const phone = await connect(room, "phone");
		await phone.next(); // peer

		host.ws.send(new Uint8Array(640)); // one 20 ms PCM16 frame, host → phone
		expect(await phone.next()).toBe("<binary>");
		phone.ws.send(new Uint8Array(70 * 1024)); // oversized: dropped
		phone.ws.send(new Uint8Array(640)); // phone → host
		phone.send({ t: "wake" });
		expect(await host.next()).toBe("<binary>");
		expect(await host.json()).toEqual({ t: "wake" }); // the oversized one never arrived
		host.ws.close(1000);
		phone.ws.close(1000);
	});

	it("forwards unknown types but drops non-JSON, typeless and oversized text frames", async () => {
		const room = newRoom();
		const host = await connect(room, "host");
		const phone = await connect(room, "phone");
		await phone.next(); // peer

		host.send("not json");
		host.send({ no: "type" });
		host.send({ t: "sessions", pad: "x".repeat(300 * 1024) });
		host.send({ t: "future-thing", v: 2 });
		// Frames arrive in order, so the first one through proves the others were dropped.
		expect(await phone.json()).toEqual({ t: "future-thing", v: 2 });
		host.ws.close(1000);
		phone.ws.close(1000);
	});

	it("gives a newly connected phone the latest sessions frame right after peer", async () => {
		const room = newRoom();
		const host = await connect(room, "host");
		const watcher = await connect(room, "phone");
		await watcher.next(); // peer
		host.send(sessionsFrame(1));
		host.send({ t: "something-else" });
		host.send(sessionsFrame(2));
		// Once the watcher has all three, the relay has processed them.
		expect(await watcher.json()).toEqual(sessionsFrame(1));
		expect(await watcher.json()).toEqual({ t: "something-else" });
		expect(await watcher.json()).toEqual(sessionsFrame(2));

		const phone = await connect(room, "phone");
		expect(await phone.json()).toEqual({ t: "peer", host: true });
		expect(await phone.json()).toEqual(sessionsFrame(2));

		// Still there once the host is gone, so the phone can show the last known state.
		host.ws.close(1000);
		expect(await watcher.json()).toEqual({ t: "peer", host: false });
		const late = await connect(room, "phone");
		expect(await late.json()).toEqual({ t: "peer", host: false });
		expect(await late.json()).toEqual(sessionsFrame(2));
		for (const p of [watcher, phone, late]) p.ws.close(1000);
	});
});

describe("peer presence", () => {
	it("tells phones when the host comes and goes", async () => {
		const room = newRoom();
		await claim(room);
		const phone = await connect(room, "phone");
		expect(await phone.json()).toEqual({ t: "peer", host: false });

		const host = await connect(room, "host");
		expect(await phone.json()).toEqual({ t: "peer", host: true });

		host.ws.close(1000);
		expect(await phone.json()).toEqual({ t: "peer", host: false });
		phone.ws.close(1000);
	});

	it("replaces an older host connection without announcing the host as gone", async () => {
		const room = newRoom();
		const oldHost = await connect(room, "host");
		const phone = await connect(room, "phone");
		expect(await phone.json()).toEqual({ t: "peer", host: true });

		const newHost = await connect(room, "host");
		const closed = await oldHost.closed;
		expect(closed.code).toBe(4000);
		expect(await phone.json()).toEqual({ t: "peer", host: true });

		// Only the new host's frames reach the phone, and phone frames reach only the new host.
		newHost.send(sessionsFrame(7));
		expect(await phone.json()).toEqual(sessionsFrame(7));
		phone.send({ t: "resume", id: "s1" });
		expect(await newHost.json()).toEqual({ t: "resume", id: "s1" });

		newHost.ws.close(1000);
		expect(await phone.json()).toEqual({ t: "peer", host: false });
		phone.ws.close(1000);
	});

	it("keeps working after the room hibernates", async () => {
		const room = newRoom();
		const host = await connect(room, "host");
		const phone = await connect(room, "phone");
		await phone.next(); // peer

		await evictDurableObject(env.ROOM.get(env.ROOM.idFromName(room)));

		host.send(sessionsFrame(3));
		expect(await phone.json()).toEqual(sessionsFrame(3));
		host.ws.close(1000);
		expect(await phone.json()).toEqual({ t: "peer", host: false });
		phone.ws.close(1000);
	});
});

describe("keep-alive", () => {
	it("answers ping with pong for hosts and phones without forwarding it", async () => {
		const room = newRoom();
		const host = await connect(room, "host");
		const phone = await connect(room, "phone");
		await phone.next(); // peer

		host.send("ping");
		expect(await host.next()).toBe("pong");
		phone.send("ping");
		expect(await phone.next()).toBe("pong");

		// Neither ping was relayed to the other side.
		host.send({ t: "marker" });
		expect(await phone.json()).toEqual({ t: "marker" });
		phone.send({ t: "marker" });
		expect(await host.json()).toEqual({ t: "marker" });
		host.ws.close(1000);
		phone.ws.close(1000);
	});
});
