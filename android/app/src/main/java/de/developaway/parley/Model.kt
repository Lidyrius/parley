package de.developaway.parley

import org.json.JSONArray
import org.json.JSONObject

// The relay protocol's data (docs/IPHONE.md), as the iPhone app reads it (ios/ParleyMobile/Frames.swift).
// Lenient on purpose: a field the host doesn't send, or sends in a newer shape, falls back.

enum class SessionState { speaking, listening, transcribing, queued, working, waiting, parked, background, idle, stopped;

    companion object {
        fun of(raw: String?): SessionState = entries.firstOrNull { it.name == raw } ?: idle
    }
}

data class BackgroundTask(val type: String = "", val description: String = "")

data class Stats(
    val startedAt: Double? = null,      // epoch ms, host clock
    val contextPercent: Double? = null,
    val costUsd: Double? = null,
    val turns: Int = 0,
    val replies: Int = 0,
    val lastLine: String? = null,
)

data class Session(
    val id: String,
    val label: String = "",
    val project: String = "",
    val state: SessionState = SessionState.idle,
    val since: Double = 0.0,
    val until: Double? = null,           // waiting: when the pause runs out
    val callback: Double? = null,        // its call was put off: rings at (ms), 0 = waits for your call back
    val voice: Boolean = false,          // holds Parley's voice right now
    val resumable: Boolean? = null,
    val tasks: List<BackgroundTask> = emptyList(),
    val stats: Stats? = null,
) {
    val name: String get() = label.ifEmpty { project.ifEmpty { id.take(8) } }
    val canResume: Boolean get() = resumable ?: (state == SessionState.parked)
    val isLive: Boolean get() = voice || state == SessionState.speaking || state == SessionState.listening ||
        state == SessionState.transcribing

    /** Fraction of a pause still left (1 → 0); null unless waiting. */
    fun remaining(at: Double): Double? {
        if (state != SessionState.waiting || until == null) return null
        return ((until - at) / maxOf(1.0, until - since)).coerceIn(0.0, 1.0)
    }
}

data class RateLimit(val kind: String? = null, val percentUsed: Double? = null)

data class Today(
    val costUsd: Double = 0.0,
    val turns: Int = 0,
    val spokenSeconds: Double = 0.0,
    val rateLimits: List<RateLimit> = emptyList(),
)

/** A Wiedervorlage on the host: for whom, what, when (host ms) or once another session is done. */
data class ReminderRow(val id: String, val text: String = "", val to: String = "", val at: Double? = null, val after: String? = null)

data class Snapshot(
    val sessions: List<Session> = emptyList(),
    val today: Today? = null,
    val reminders: List<ReminderRow> = emptyList(),
    val at: Double? = null,
)

/** One entry of a session's history (`history` frame). */
data class ChatItem(
    val id: String,
    val kind: String = "other",          // user, voice, assistant, speak, tool, image, other
    val text: String? = null,
    val fromUser: Boolean = false,
    val at: Double? = null,
    val add: Int? = null,
    val del: Int? = null,
)

data class HistoryPage(val id: String, val before: String?, val more: Boolean, val items: List<ChatItem>)

/** Live captions for one spoken line: its words and when each starts (s), timed against played audio. */
data class Caption(val words: List<String>, val at: List<Double>, val end: Double, val last: Boolean = false) {
    /** The word being spoken `t` seconds in (-1 before the first). */
    fun index(t: Double): Int = at.indexOfLast { it <= t }

    /** Subtitle lines: up to a sentence end, or a comma once there are 7 words, at most 12. */
    val chunks: List<IntRange> by lazy {
        val out = mutableListOf<IntRange>()
        var from = 0
        words.forEachIndexed { i, w ->
            val n = i + 1 - from
            val c = w.lastOrNull()
            if ((c != null && c in ".!?…") || (n >= 7 && c != null && c in ",;:–—") || n >= 12) { out += from..i; from = i + 1 }
        }
        if (from < words.size) out += from until words.size
        out
    }

    /** The chunk being spoken `t` seconds in — the first before it starts. */
    fun chunk(t: Double): IntRange? { val i = maxOf(0, index(t)); return chunks.firstOrNull { i in it } }
}

enum class HostAudio { idle, speaking, listening }

/** What arrives from the relay. */
sealed interface Incoming {
    data class Sessions(val snapshot: Snapshot) : Incoming
    data class Peer(val host: Boolean) : Incoming
    data class Audio(val state: HostAudio, val label: String?) : Incoming
    data class Ring(val label: String?) : Incoming
    data class History(val page: HistoryPage) : Incoming
    data class Image(val key: String, val mime: String?, val data: String?) : Incoming
    data class CaptionFrame(val caption: Caption) : Incoming
    data object Ignored : Incoming
}

object Frames {
    fun parse(text: String): Incoming {
        val o = runCatching { JSONObject(text) }.getOrNull() ?: return Incoming.Ignored
        return when (o.optString("t")) {
            "sessions" -> Incoming.Sessions(snapshot(o))
            "peer" -> Incoming.Peer(o.optBoolean("host", false))
            "audio" -> Incoming.Audio(
                when (o.optString("state")) { "speaking" -> HostAudio.speaking; "listening" -> HostAudio.listening; else -> HostAudio.idle },
                o.str("label"),
            )
            "ring" -> Incoming.Ring(o.str("label"))
            "history" -> Incoming.History(history(o))
            "image" -> Incoming.Image(o.optString("key"), o.str("mime"), o.str("data"))
            "caption" -> caption(o)?.let { Incoming.CaptionFrame(it) } ?: Incoming.Ignored
            else -> Incoming.Ignored
        }
    }

    fun snapshot(o: JSONObject): Snapshot = Snapshot(
        sessions = o.optJSONArray("sessions").objects().mapNotNull(::session),
        today = o.optJSONObject("today")?.let(::today),
        reminders = o.optJSONArray("reminders").objects().mapNotNull { r ->
            val id = r.str("id") ?: return@mapNotNull null
            ReminderRow(id, r.optString("text"), r.optString("to"), r.num("at"), r.str("after"))
        },
        at = o.num("at"),
    )

    private fun session(o: JSONObject): Session? {
        val id = o.str("id") ?: return null
        val stats = o.optJSONObject("stats")?.let { s ->
            Stats(s.num("startedAt"), s.num("contextPercent"), s.num("costUsd"), s.optInt("turns", 0), s.optInt("replies", 0), s.str("lastLine"))
        }
        return Session(
            id = id,
            label = o.optString("label"),
            project = o.optString("project"),
            state = SessionState.of(o.str("state")),
            since = o.num("since") ?: 0.0,
            until = o.num("until"),
            callback = o.num("callback"),
            voice = o.optBoolean("voice", false),
            resumable = if (o.has("resumable") && !o.isNull("resumable")) o.optBoolean("resumable") else null,
            tasks = o.optJSONArray("tasks").objects().map { BackgroundTask(it.optString("type"), it.optString("description")) },
            stats = stats,
        )
    }

    private fun today(o: JSONObject) = Today(
        costUsd = o.num("costUsd") ?: 0.0,
        turns = o.optInt("turns", 0),
        spokenSeconds = o.num("spokenSeconds") ?: 0.0,
        rateLimits = o.optJSONArray("rateLimits").objects().map { RateLimit(it.str("kind"), it.num("percentUsed")) },
    )

    private fun history(o: JSONObject) = HistoryPage(
        id = o.optString("id"),
        before = o.str("before"),
        more = o.optBoolean("more", false),
        items = o.optJSONArray("items").objects().mapNotNull { i ->
            val id = i.str("id") ?: return@mapNotNull null
            ChatItem(id, i.optString("k", "other"), i.str("text"), i.optString("who") == "user", i.num("at"), i.ints("add"), i.ints("del"))
        },
    )

    private fun caption(o: JSONObject): Caption? {
        val words = o.optJSONArray("words") ?: return null
        val at = o.optJSONArray("at") ?: return null
        val w = (0 until words.length()).map { words.optString(it) }
        val a = (0 until at.length()).map { at.optDouble(it) }
        if (w.isEmpty() || w.size != a.size) return null
        return Caption(w, a, o.num("end") ?: (a.last() + 1), o.optBoolean("last", false))
    }
}

/** Phone → host (ios/ParleyMobile/Frames.swift `Outgoing`). */
object Outgoing {
    private fun obj(vararg pairs: Pair<String, Any?>) = JSONObject().apply { pairs.forEach { (k, v) -> if (v != null) put(k, v) } }.toString()

    fun hello(device: String) = obj("t" to "hello", "device" to device)
    fun resume(id: String) = obj("t" to "resume", "id" to id)
    /** A started call asks for Parley's voice at 24 kHz; the mic stays 16 kHz. */
    fun call(started: Boolean) = if (started) obj("t" to "call", "state" to "start", "down" to 24_000) else obj("t" to "call", "state" to "end")
    fun away(on: Boolean) = obj("t" to "away", "on" to on)
    fun silent(on: Boolean) = obj("t" to "silent", "on" to on)
    fun round(seconds: Int) = obj("t" to "round", "seconds" to seconds)
    fun history(id: String, before: String? = null) = obj("t" to "history", "id" to id, "before" to before)
    fun image(id: String, key: String) = obj("t" to "image", "id" to id, "key" to key)
    fun say(id: String, text: String) = obj("t" to "say", "id" to id, "text" to text)
    /** Sir wants to talk while the host is idle (the iPhone's "Hey Parley"; here a button). */
    val wake = obj("t" to "wake")
    /** Sir talks over Parley: stop the line and listen. */
    val barge = obj("t" to "barge")
    /** "Not now" on the ringing screen: ring again in `after` s, or null = I'll call back. */
    fun later(after: Int?) = obj("t" to "later", "after" to after)
}

private fun JSONObject.str(k: String): String? = if (has(k) && !isNull(k)) optString(k).takeIf { it.isNotEmpty() } else null
private fun JSONObject.num(k: String): Double? = if (has(k) && !isNull(k)) optDouble(k).takeIf { !it.isNaN() } else null
private fun JSONObject.ints(k: String): Int? = num(k)?.toInt()
private fun JSONArray?.objects(): List<JSONObject> = if (this == null) emptyList() else (0 until length()).mapNotNull { optJSONObject(it) }
