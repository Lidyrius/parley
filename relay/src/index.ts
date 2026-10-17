// Parley relay: connects the Parley host app (Mac/Windows) and its paired iPhones from any
// network. Both sides dial out to a per-room Durable Object. Protocol: docs/IPHONE.md.
import { DurableObject } from "cloudflare:workers";
import { PAIR_HTML, PAIR_SCRIPT, QR_LIB } from "./pair";

type Role = "host" | "phone";

// Room ids are base64url without padding (16 random bytes → 22 chars; leave some room).
const ROOM_ID = /^[A-Za-z0-9_-]{16,64}$/;
// A `sessions` frame is a few KB; anything near this is a sender bug, not data worth relaying.
const MAX_FRAME_BYTES = 256 * 1024;
const MAX_AUDIO_BYTES = 64 * 1024;
// Close code for a host connection that a newer host connection replaced (private range).
const CLOSE_REPLACED = 4000;

export default {
	async fetch(request, env): Promise<Response> {
		const url = new URL(request.url);
		if (url.pathname === "/") return text("parley relay ok");
		if (url.pathname === "/pair") return pairPage();

		const room = /^\/v1\/room\/([^/]+)$/.exec(url.pathname)?.[1];
		if (room === undefined) return text("not found", 404);
		if (!ROOM_ID.test(room)) return text("bad room id", 400);
		const role = url.searchParams.get("role");
		if (role !== "host" && role !== "phone") return text("role must be host or phone", 400);
		if (request.method !== "GET" || request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
			return text("expected a websocket upgrade", 426);
		}
		if (bearer(request) === null) return text("missing bearer secret", 401);
		// The room's Durable Object checks the secret itself: it owns the claim.
		return env.ROOM.get(env.ROOM.idFromName(room)).fetch(request);
	},
} satisfies ExportedHandler<Env>;

/** One pairing room: at most one host, any number of phones. */
export class Room extends DurableObject<Env> {
	constructor(ctx: DurableObjectState, env: Env) {
		super(ctx, env);
		// Keep-alive pings are answered by the runtime without waking the object.
		ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
	}

	async fetch(request: Request): Promise<Response> {
		const role: Role = new URL(request.url).searchParams.get("role") === "host" ? "host" : "phone";
		const hash = await sha256Hex(bearer(request) ?? "");

		// Sync storage between read and write: two racing hosts can't both claim the room.
		const claim = this.ctx.storage.kv.get<string>("claim");
		if (claim === undefined) {
			if (role === "phone") return text("room not claimed", 404);
			this.ctx.storage.kv.put("claim", hash);
		} else if (!sameHash(claim, hash)) {
			return text("wrong secret", 401);
		}

		const [client, server] = Object.values(new WebSocketPair());
		if (role === "host") {
			for (const old of this.open("host")) old.close(CLOSE_REPLACED, "replaced by a newer host connection");
			this.ctx.acceptWebSocket(server, ["host"]);
			this.toPhones(peerFrame(true));
		} else {
			this.ctx.acceptWebSocket(server, ["phone"]);
			server.send(peerFrame(this.open("host").length > 0));
			// The phone shows the last known state right away instead of waiting up to 10 s.
			const latest = this.ctx.storage.kv.get<string>("sessions");
			if (latest !== undefined) server.send(latest);
		}
		return new Response(null, { status: 101, webSocket: client });
	}

	webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): void {
		// A replaced host may still be draining.
		if (ws.readyState !== WebSocket.OPEN) return;
		const fromHost = this.ctx.getTags(ws).includes("host");
		// Binary frames are call audio (PCM16 16 kHz, 20 ms): forwarded as they are, never stored.
		if (typeof message !== "string") {
			if (message.byteLength > MAX_AUDIO_BYTES) return;
			if (fromHost) this.toPhones(message);
			else for (const host of this.open("host")) trySend(host, message);
			return;
		}
		const bytes = new TextEncoder().encode(message).byteLength;
		if (bytes > MAX_FRAME_BYTES) {
			console.warn(JSON.stringify({ msg: "frame too large, dropped", bytes }));
			return;
		}
		const t = frameType(message);
		if (t === undefined) return;

		if (fromHost) {
			if (t === "sessions") this.ctx.storage.kv.put("sessions", message);
			this.toPhones(message);
		} else {
			for (const host of this.open("host")) trySend(host, message);
		}
	}

	webSocketClose(ws: WebSocket, code: number, reason: string): void {
		// Finish the close handshake ourselves: not every runtime auto-replies (local workerd doesn't).
		// 1005/1006/1015 only describe a missing or broken close frame and can't be sent back.
		ws.close([1005, 1006, 1015].includes(code) ? 1000 : code, reason);
		this.left(ws);
	}

	webSocketError(ws: WebSocket): void {
		this.left(ws);
	}

	/** Tells the phones when the last host is gone (a replaced host leaving changes nothing). */
	private left(ws: WebSocket): void {
		if (this.ctx.getTags(ws).includes("host") && this.open("host", ws).length === 0) {
			this.toPhones(peerFrame(false));
		}
	}

	private open(role: Role, except?: WebSocket): WebSocket[] {
		return this.ctx
			.getWebSockets(role)
			.filter((ws) => ws !== except && ws.readyState === WebSocket.OPEN);
	}

	private toPhones(frame: string | ArrayBuffer): void {
		for (const phone of this.open("phone")) trySend(phone, frame);
	}
}

async function pairPage(): Promise<Response> {
	const scriptHash = await sha256Base64(PAIR_SCRIPT);
	return new Response(PAIR_HTML, {
		headers: {
			"content-type": "text/html; charset=utf-8",
			// Only the pinned QR library and the page's own script may run; nothing may be fetched.
			"content-security-policy": [
				"default-src 'none'",
				`script-src 'sha256-${scriptHash}' ${QR_LIB.url}`,
				"style-src 'unsafe-inline'",
				"base-uri 'none'",
				"form-action 'none'",
				"frame-ancestors 'none'",
			].join("; "),
			"referrer-policy": "no-referrer",
			"cache-control": "public, max-age=3600",
		},
	});
}

function text(body: string, status = 200): Response {
	return new Response(body, { status, headers: { "content-type": "text/plain; charset=utf-8" } });
}

function bearer(request: Request): string | null {
	return /^Bearer\s+(\S+)$/i.exec(request.headers.get("Authorization") ?? "")?.[1] ?? null;
}

function peerFrame(host: boolean): string {
	return JSON.stringify({ t: "peer", host });
}

/** The frame's `t`, or undefined if it isn't a JSON object with a string `t`. */
function frameType(frame: string): string | undefined {
	try {
		const t: unknown = (JSON.parse(frame) as { t?: unknown } | null)?.t;
		return typeof t === "string" ? t : undefined;
	} catch {
		return undefined;
	}
}

function trySend(ws: WebSocket, frame: string | ArrayBuffer): void {
	try {
		ws.send(frame);
	} catch {
		// Closed underneath us; its close handler does the bookkeeping.
	}
}

async function sha256Hex(s: string): Promise<string> {
	const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s)));
	return Array.from(digest, (b) => b.toString(16).padStart(2, "0")).join("");
}

async function sha256Base64(s: string): Promise<string> {
	const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s)));
	return btoa(String.fromCharCode(...digest));
}

function sameHash(a: string, b: string): boolean {
	const x = new TextEncoder().encode(a);
	const y = new TextEncoder().encode(b);
	return x.byteLength === y.byteLength && crypto.subtle.timingSafeEqual(x, y);
}
