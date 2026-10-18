package de.developaway.parley

import android.content.Context
import android.net.Uri
import org.json.JSONObject

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

            val relay = u.getQueryParameter("u")
            val r = relay?.let { runCatching { Uri.parse(it) }.getOrNull() }
            if (r == null || r.scheme != "https" || r.host.isNullOrEmpty() || r.query != null)
                throw Invalid("Die Relay-Adresse im Link ist ungültig (https erforderlich).")
            val room = u.getQueryParameter("r")
            if (room == null || !isBase64URL(room, 16..64)) throw Invalid("Die Raum-ID im Link ist ungültig.")
            val secret = u.getQueryParameter("k")
            if (secret == null || !isBase64URL(secret, 16..128)) throw Invalid("Der Schlüssel im Link fehlt oder ist ungültig.")
            val key = u.getQueryParameter("e")
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
