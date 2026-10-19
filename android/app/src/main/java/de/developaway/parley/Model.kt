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
    val shared: List<ShareTag> = emptyList(),   // v7: the guests it is shared with (Sir's side)
    val asking: String? = null,                 // v7: a question waits for this guest
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

/** v7: one guest of a shared session — the share's id (to remove him), his name and role. */
data class ShareTag(val id: String, val name: String, val role: String = "")

/** v7: a guest asks to join one of Sir's sessions (`join` frame). `code`: four digits the guest sees too. */
data class JoinRequest(val id: String, val session: String, val label: String, val name: String, val device: String? = null, val code: String? = null)

/** v7: Sir let the guest in — the fresh room sealed to the guest's key (`pub`: the host's half, `box`: the room). */
data class ShareMove(val share: String, val pub: String, val box: String, val role: String? = null, val listen: Boolean? = null)

/** v7: a question for this phone's owner as a guest (`ask` frame). */
data class GuestAsk(val id: String, val session: String, val label: String, val text: String, val replies: List<String>? = null, val seconds: Int? = null)

data class RateLimit(val kind: String? = null, val percentUsed: Double? = null)

data class Today(
    val costUsd: Double = 0.0,
    val turns: Int = 0,
    val spokenSeconds: Double = 0.0,
    val rateLimits: List<RateLimit> = emptyList(),
)

/** A Wiedervorlage on the host: for whom, what, when (host ms) or once another session is done. */
data class ReminderRow(val id: String, val text: String = "", val to: String = "", val at: Double? = null, val after: String? = null)

/** A saved set of sessions on the host (docs/IPHONE.md, Protocol v6): its name, when (host ms), each one's name, id and folder. */
data class SnapshotRow(val id: String, val name: String = "", val at: Double = 0.0, val sessions: List<SnapshotItem> = emptyList())
data class SnapshotItem(val id: String, val name: String = "", val cwd: String = "")

/** What opening a snapshot did to each session: running, resumed, started or missing. */
data class SnapshotResult(val id: String, val name: String = "", val results: List<SnapshotOutcome> = emptyList())
data class SnapshotOutcome(val id: String, val name: String = "", val result: String = "")

data class Snapshot(
    val sessions: List<Session> = emptyList(),
    val today: Today? = null,
    val reminders: List<ReminderRow> = emptyList(),
    val snapshots: List<SnapshotRow> = emptyList(),
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
    val by: String? = null,              // v7: a guest's name (user / voice), null = the owner
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
    data class SnapshotOpened(val result: SnapshotResult) : Incoming
    /** v7: the link for a new share of `session` (Sir's side). */
    data class ShareLink(val id: String, val session: String, val link: String) : Incoming
    /** v7: a guest asks to join (Sir's side). */
    data class Join(val request: JoinRequest) : Incoming
    /** v7: Sir let us in — move to the fresh room (guest side); the share is over. */
    data class Move(val move: ShareMove) : Incoming
    data object ShareEnd : Incoming
    /** v7: a short message from the host for this phone (e.g. too many messages). */
    data class Notice(val text: String) : Incoming
    /** v7: a question for the guest, and its end (answered, passed on, timed out). */
    data class Ask(val ask: GuestAsk) : Incoming
    data class AskEnd(val id: String) : Incoming
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
            "snapshot" -> o.str("id")?.let { id ->
                Incoming.SnapshotOpened(SnapshotResult(id, o.optString("name"), o.optJSONArray("results").objects().mapNotNull { r ->
                    r.str("id")?.let { SnapshotOutcome(it, r.optString("name"), r.optString("result")) }
                }))
            } ?: Incoming.Ignored
            "share" -> {
                val id = o.s("id"); val session = o.s("session"); val link = o.s("link")
                if (id != null && session != null && link != null) Incoming.ShareLink(id, session, link) else Incoming.Ignored
            }
            "join" -> {
                val id = o.s("id"); val session = o.s("session"); val label = o.s("label"); val name = o.s("name")
                if (id != null && session != null && label != null && name != null)
                    Incoming.Join(JoinRequest(id, session, label, name, o.s("device"), o.s("code"))) else Incoming.Ignored
            }
            "move" -> {
                val share = o.s("share"); val pub = o.s("pub"); val box = o.s("box")
                if (share != null && pub != null && box != null)
                    Incoming.Move(ShareMove(share, pub, box, o.s("role"), o.opt("listen") as? Boolean)) else Incoming.Ignored
            }
            "share-end" -> Incoming.ShareEnd
            "notice" -> o.s("text")?.let { Incoming.Notice(it) } ?: Incoming.Ignored
            "ask" -> {
                val id = o.s("id"); val session = o.s("session"); val label = o.s("label"); val text = o.s("text")
                if (id != null && session != null && label != null && text != null) Incoming.Ask(GuestAsk(id, session, label, text,
                    o.optJSONArray("replies")?.let { a -> (0 until a.length()).mapNotNull { a.opt(it) as? String } },
                    (o.opt("seconds") as? Number)?.toInt())) else Incoming.Ignored
            }
            "ask-end" -> o.s("id")?.let { Incoming.AskEnd(it) } ?: Incoming.Ignored
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
        snapshots = o.optJSONArray("snapshots").objects().mapNotNull { r ->
            val id = r.str("id") ?: return@mapNotNull null
            SnapshotRow(id, r.optString("name"), r.num("at") ?: 0.0, r.optJSONArray("sessions").objects().mapNotNull { i ->
                i.str("id")?.let { SnapshotItem(it, i.optString("name"), i.optString("cwd")) }
            })
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
            shared = o.optJSONArray("shared").objects().mapNotNull { t ->
                val tid = t.s("id") ?: return@mapNotNull null
                ShareTag(tid, t.s("name") ?: return@mapNotNull null, t.s("role") ?: "")
            },
            asking = o.str("asking"),
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
            ChatItem(id, i.optString("k", "other"), i.str("text"), i.optString("who") == "user", i.num("at"), i.ints("add"), i.ints("del"), i.str("by"))
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
    /** Snapshots: keep these sessions under `name`, open one again, or delete it. */
    fun snapshotSave(name: String, ids: List<String>) = obj("t" to "snapshot", "op" to "save", "name" to name, "ids" to JSONArray(ids))
    fun snapshotOpen(id: String) = obj("t" to "snapshot", "op" to "open", "id" to id)
    fun snapshotDelete(id: String) = obj("t" to "snapshot", "op" to "delete", "id" to id)
    /** "Not now" on the ringing screen: ring again in `after` s, or null = I'll call back. */
    fun later(after: Int?) = obj("t" to "later", "after" to after)
    /** v7: share a session (Sir), let a guest in or end a share (Sir), say who I am (guest). */
    fun shareCreate(session: String) = obj("t" to "share", "op" to "create", "id" to session)
    fun shareApprove(id: String, role: String, listen: Boolean, full: Boolean, mine: String) =
        obj("t" to "share", "op" to "approve", "id" to id, "role" to role, "listen" to listen, "full" to full, "mine" to mine)
    fun shareRemove(id: String) = obj("t" to "share", "op" to "remove", "id" to id)
    fun join(name: String, device: String, pub: String) = obj("t" to "join", "name" to name, "device" to device, "pub" to pub)
    /** v7: the guest's answer to a question, or `pass` = give it to the owner. */
    fun answer(id: String, text: String, pass: Boolean = false) =
        if (pass) obj("t" to "answer", "id" to id, "pass" to true) else obj("t" to "answer", "id" to id, "text" to text)
}

private fun JSONObject.str(k: String): String? = if (has(k) && !isNull(k)) optString(k).takeIf { it.isNotEmpty() } else null
/** A string field, empty allowed (a required field of a v7 frame); null when missing or not a string. */
private fun JSONObject.s(k: String): String? = opt(k) as? String
private fun JSONObject.num(k: String): Double? = if (has(k) && !isNull(k)) optDouble(k).takeIf { !it.isNaN() } else null
private fun JSONObject.ints(k: String): Int? = num(k)?.toInt()
private fun JSONArray?.objects(): List<JSONObject> = if (this == null) emptyList() else (0 until length()).mapNotNull { optJSONObject(it) }
