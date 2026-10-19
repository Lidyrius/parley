package de.developaway.parley

import android.content.Context
import android.net.Uri
import org.json.JSONObject
import java.net.URI
import java.net.URLDecoder

/**
 * What the host's QR code carries (docs/IPHONE.md → Pairing): the relay, the room, its secret,
 * and the end-to-end key (v5; null from an older host — then frames go in the clear).
 */
data class Pairing(val relay: String, val room: String, val secret: String, val key: String? = null) {

    /** `wss://<relay>/v1/room/<room>?role=phone` (relay protocol v1). A base path is kept. */
    val socketURL: String
        get() {
            val u = Uri.parse(relay)
            val scheme = if (u.scheme == "http") "ws" else "wss"
            val base = (u.encodedPath ?: "").trimEnd('/')
            val port = if (u.port > 0) ":${u.port}" else ""
            return "$scheme://${u.host}$port$base/v1/room/$room?role=phone"
        }

    class Invalid(message: String) : Exception(message)

    companion object {
        /**
         * Parses `parley://pair?u=<relay>&r=<room>&k=<secret>`. Also takes the relay's
         * `https://<relay>/pair#<link>` page URL, which carries the link in its fragment.
         */
        fun parse(text: String): Pairing {
            val t = text.trim()
            val u = runCatching { Uri.parse(t) }.getOrNull() ?: throw Invalid("Das ist kein Parley-Kopplungslink.")
            val frag = u.fragment
            if (u.scheme.equals("https", true) && frag != null && frag.lowercase().startsWith("parley:")) return parse(frag)
            if (!u.scheme.equals("parley", true) || !u.host.equals("pair", true)) throw Invalid("Das ist kein Parley-Kopplungslink.")

            return check(u.getQueryParameter("u"), u.getQueryParameter("r"), u.getQueryParameter("k"), u.getQueryParameter("e"))
        }

        /** The link's parts, checked (no Android types, so a join link and a share's move test on the JVM). */
        fun check(relay: String?, room: String?, secret: String?, key: String?): Pairing {
            val host = relay?.takeIf { it.startsWith("https://") }?.removePrefix("https://")?.substringBefore('#')?.substringBefore('/')?.substringBefore(':')
            if (relay == null || host.isNullOrEmpty() || '?' in relay.substringBefore('#'))
                throw Invalid("Die Relay-Adresse im Link ist ungültig (https erforderlich).")
            if (room == null || !isBase64URL(room, 16..64)) throw Invalid("Die Raum-ID im Link ist ungültig.")
            if (secret == null || !isBase64URL(secret, 16..128)) throw Invalid("Der Schlüssel im Link fehlt oder ist ungültig.")
            if (key != null && !isBase64URL(key, 43..43)) throw Invalid("Der Schlüssel im Link fehlt oder ist ungültig.")
            return Pairing(relay, room, secret, key)
        }

        private fun isBase64URL(s: String, length: IntRange) =
            s.length in length && s.all { it in 'a'..'z' || it in 'A'..'Z' || it in '0'..'9' || it == '-' || it == '_' }

        // ponytail: plain app-private prefs (no backup, see the manifest); Keystore-wrapped if the threat model asks
        private fun prefs(c: Context) = c.getSharedPreferences("pairing", Context.MODE_PRIVATE)

        fun load(c: Context): Pairing? = prefs(c).getString("relay", null)?.let { s ->
            runCatching { JSONObject(s).let { Pairing(it.getString("relay"), it.getString("room"), it.getString("secret"), it.optString("key").ifEmpty { null }) } }.getOrNull()
        }

        fun save(c: Context, p: Pairing) {
            val s = JSONObject().put("relay", p.relay).put("room", p.room).put("secret", p.secret).put("key", p.key ?: "").toString()
            prefs(c).edit().putString("relay", s).apply()
        }

        fun remove(c: Context) = prefs(c).edit().remove("relay").apply()
    }
}

/**
 * v7: an invite to someone else's session — `parley://join?u&r&k&e` (as a pairing) plus `s`, the
 * session's name, and `h`, who shares it (ios/ParleyMobile/Pairing.swift `JoinLink`).
 */
data class JoinLink(val pairing: Pairing, val label: String, val host: String) {
    companion object {
        /** null unless it is a join link with a valid room — and its end-to-end key: never joined in the clear. */
        fun parse(text: String): JoinLink? {
            val u = runCatching { URI(text.trim()) }.getOrNull() ?: return null
            if (!u.scheme.equals("parley", true) || !u.host.equals("join", true)) return null
            val q = (u.rawQuery ?: "").split("&").mapNotNull { kv ->
                val i = kv.indexOf('=')
                if (i <= 0) null else kv.substring(0, i) to runCatching { URLDecoder.decode(kv.substring(i + 1), "UTF-8") }.getOrDefault("")
            }.toMap()
            val key = q["e"] ?: return null
            val p = runCatching { Pairing.check(q["u"], q["r"], q["k"], key) }.getOrNull() ?: return null
            return JoinLink(p, (q["s"] ?: "").take(60), (q["h"] ?: "").take(60))
        }
    }
}
