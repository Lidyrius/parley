package de.developaway.parley

import android.app.Application
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Build
import android.provider.Settings
import android.util.Base64
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import java.util.UUID

class ParleyApp : Application() {
    lateinit var model: AppModel; private set

    override fun onCreate() {
        super.onCreate()
        model = AppModel(this)
    }
}

val Context.model: AppModel get() = (applicationContext as ParleyApp).model

/**
 * The app's state (ios/ParleyMobile/App.swift `AppModel`): the pairing, the relay, the call,
 * the switches, and what the session views loaded. Main thread only.
 */
class AppModel(private val app: Application) {
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val deviceName = Settings.Global.getString(app.contentResolver, "device_name") ?: Build.MODEL
    val relay = Relay(scope, deviceName)
    val call = CallController(app, scope, relay)

    var pairing by mutableStateOf(Pairing.load(app)); private set
    var away by mutableStateOf(Prefs.away(app)); private set
    var roundSeconds by mutableStateOf(Prefs.round(app)); private set
    var asGrid by mutableStateOf(Prefs.grid(app)); private set
    /** The activity is on screen (the ring then shows in the app, not as a notification). */
    var isForeground by mutableStateOf(false)

    val histories = mutableStateMapOf<String, List<ChatItem>>()
    val hasOlder = mutableStateMapOf<String, Boolean>()
    /** Typed messages not yet seen in the history. */
    val pending = mutableStateMapOf<String, List<String>>()
    val images = mutableStateMapOf<String, Bitmap>()
    private val requestedImages = mutableSetOf<String>()
    /** The host's answer to the last "Öffnen" of a snapshot; null while it is on the way. */
    var snapshotOpened by mutableStateOf<SnapshotResult?>(null); private set

    // v7 (Guests.kt): shares of other people's sessions this phone joined, a link waiting to be
    // joined, the invite links Sir made (by session), guests asking Sir to let them in, a message
    // for the guest, and questions for this phone as a guest (the Rückfrage screen shows the first).
    val guests = mutableStateListOf<GuestShare>()
    val guestRelays = mutableMapOf<String, Relay>()
    var pendingJoin by mutableStateOf<JoinLink?>(null)
    /** The share just asked to join: its sheet shows the code for the owner until he lets this phone in. */
    var joining by mutableStateOf<String?>(null)
    val shareLinks = mutableStateMapOf<String, String>()
    val joinRequests = mutableStateListOf<JoinRequest>()
    var guestNotice by mutableStateOf<String?>(null)
    val guestAsks = mutableStateListOf<GuestAsk>()
    /** A session to bring up (MainActivity opens it and clears this): the share this phone was just let into. */
    var showSession by mutableStateOf<String?>(null)

    var demo = false; private set
    /** Just paired from the scanner: it shows "Verbunden, Sir." a moment before the overview. */
    var welcoming by mutableStateOf(false)

    /** Paired with an own host — or a guest somewhere: then the overview shows the shared sessions. */
    val isPaired: Boolean get() = pairing != null || guests.isNotEmpty()

    /** Sample data instead of a relay (Demo.kt). */
    fun startDemo(kind: String) {
        demo = true
        relay.forget()
        pairing = Pairing("https://relay.example", "demo", "demo")
        relay.demo(Frames.snapshot(org.json.JSONObject(Demo.frame(System.currentTimeMillis()))))
        histories["demo-shirts"] = Demo.history
        // `join`: a guest asks to join (the approval sheet); `ask`: a question as a guest.
        // `code`: the guest's code to send the owner after "Beitreten".
        if (kind == "join") JoinRequest("demo-join", "demo-shirts", "Shirts", "Max", "Pixel 9", "4821", "demo-who").let {
            GuestRoles.remember(app, it, "Marketing")
            GuestRoles.remember(app, it, "Texte und Kampagne")
            joinRequests += it
        }
        if (kind == "code") GuestShare.create(Pairing("https://relay.example", "demo-room", "demo"), "Shirts", "Sydney", "Max").let {
            guests += it
            joining = it.id
        }
        if (kind == "ask") guestAsks += GuestAsk("demo-ask", "demo-shirts", "Shirts",
            "Max, für die Überschrift habe ich zwei Varianten. Welche passt zur Kampagne?", listOf("Variante A", "Variante B"), 120)
        if (kind in setOf("speaking", "listening", "idle", "incoming", "connecting")) call.demo(kind)
    }

    /** "Fortsetzen" while Unterwegs: the call starts first, the resume follows once it is up. */
    private var resumeOnConnect: String? = null

    init {
        relay.onOpened = {
            // Per-connection state, but only what this phone has switched on: a second phone
            // (the iPhone) in the same room keeps its own Unterwegs. (Only a call on this line —
            // a guest's call runs on his share's room, v7.)
            if (away) relay.send(Outgoing.away(true))
            call.opened(relay)
        }
        relay.onClosed = { call.linkChanged(relay) }
        relay.onFrame = ::handle
        call.onConnected = {
            resumeOnConnect?.let { relay.resume(it) }
            resumeOnConnect = null
        }
        call.onPhase = { phase ->
            if (!demo) ParleyService.sync(app)
            // A call that ended in the background: the socket goes too, unless Unterwegs keeps it
            // (a share's room too — a guest's call may have kept it open).
            if (phase == CallPhase.none && !isForeground && !away) {
                relay.disconnect()
                guestRelays.values.forEach { it.disconnect() }
            }
        }
        pairing?.let { relay.use(it) }
        startGuests()
    }

    private fun Relay.resume(id: String) = send(Outgoing.resume(id))

    private fun handle(f: Incoming) {
        if (f is Incoming.ShareLink) { shareLinks[f.session] = f.link; return }
        if (f is Incoming.Join) { joinRequests.removeAll { it.id == f.request.id }; joinRequests += f.request; return }
        toCall(relay, f)
        store(f)
    }

    /** A frame that concerns the call — from the line it runs on only; a share's ring puts it on that line (CallLine). */
    private fun toCall(from: Relay, f: Incoming) {
        when (val s = CallLine.step(f, call.line === from, from !== relay, isForeground || away, call.phase == CallPhase.none)) {
            CallStep.LinkChanged -> call.relayChanged()
            is CallStep.Audio -> call.hostAudioChanged(s.state, s.label)
            is CallStep.Captions -> call.captionReceived(s.caption)
            is CallStep.Ring -> { call.use(from); call.reportIncoming(s.label) }
            null -> {}
        }
    }

    /** The own host's frames — a share's history and images go in here too, the same store (ids don't collide). */
    private fun store(f: Incoming) {
        when (f) {
            is Incoming.History -> {
                val p = f.page
                val old = histories[p.id] ?: emptyList()
                histories[p.id] = merge(old, p.items, p.before)
                if (p.before != null || old.isEmpty() || p.items.firstOrNull()?.id == old.firstOrNull()?.id) hasOlder[p.id] = p.more
                val seen = p.items.filter { it.kind == "user" || it.kind == "voice" }.mapNotNull { it.text }.toSet()
                pending[p.id]?.let { list -> pending[p.id] = list.filter { it !in seen } }
            }
            is Incoming.Image -> {
                val bytes = f.data?.let { runCatching { Base64.decode(it, Base64.DEFAULT) }.getOrNull() } ?: return
                BitmapFactory.decodeByteArray(bytes, 0, bytes.size)?.let { images[f.key] = it }
            }
            is Incoming.SnapshotOpened -> snapshotOpened = f.result
            else -> {}
        }
    }

    // Pairing

    fun pair(p: Pairing) {
        Pairing.save(app, p)
        pairing = p
        relay.use(p)
        relay.reconnect()
    }

    fun unpair() {
        call.hangUp()
        changeAway(false)
        Pairing.remove(app)
        pairing = null
        relay.forget()
        histories.clear()
        pending.clear()
    }

    /** The app came up or went to the background: the socket stays only while Unterwegs or in a call. */
    fun foreground(on: Boolean) {
        isForeground = on
        if (demo) return
        // A share's room too (no push here: while Unterwegs it stays open, as the own one — and
        // while a guest's call runs on it).
        for (r in guestRelays.values) if (on) r.ensure() else if (!away && call.line !== r) r.disconnect()
        if (call.phase != CallPhase.none) ParleyService.sync(app)
        if (pairing == null) return
        if (on) relay.ensure() else if (!away && call.phase == CallPhase.none) relay.disconnect()
    }

    // Switches

    fun changeAway(on: Boolean) {
        if (on == away) return
        away = on
        Prefs.set(app, "awayMode", on)
        relay.send(Outgoing.away(on))
        ParleyService.sync(app)
    }

    fun setRound(seconds: Int) {
        roundSeconds = seconds
        Prefs.set(app, "roundSeconds", seconds)
        relay.send(Outgoing.round(seconds))
    }

    fun setGrid(on: Boolean) { asGrid = on; Prefs.set(app, "grid", on) }

    // Actions

    /** "Fortsetzen": Unterwegs, Sir starts the call too (nothing to answer); at the desk it goes at once. */
    fun resume(id: String) {
        if (!away || call.phase != CallPhase.none) { relay.resume(id); return }
        resumeOnConnect = id
        call.startOutgoing()
    }

    fun loadHistory(id: String) = relay(id).send(Outgoing.history(id))

    fun loadOlder(id: String) {
        val first = histories[id]?.firstOrNull()?.id ?: return
        relay(id).send(Outgoing.history(id, before = first))
    }

    fun loadImage(session: String, key: String) {
        if (requestedImages.add(key)) relay(session).send(Outgoing.image(session, key))
    }

    fun say(id: String, text: String) {
        val t = text.trim()
        if (t.isEmpty()) return
        pending[id] = (pending[id] ?: emptyList()) + t
        relay(id).send(Outgoing.say(id, t))
    }

    // Shared sessions, the guest's side (ios/ParleyMobile/Guests.swift).

    private fun startGuests() {
        guests.addAll(GuestStore.load(app))
        guests.forEach(::connect)
    }

    private fun saveGuests() = GuestStore.save(app, guests.toList())

    /** This phone as a guest, the same in every join: the owner's phone remembers the roles it gave it. */
    private val who: String get() = Prefs.string(app, "guestWho").ifEmpty { UUID.randomUUID().toString().also { Prefs.set(app, "guestWho", it) } }

    /** "Beitreten": keep the share, dial its room, say who I am. */
    fun join(link: JoinLink, name: String) {
        val g = GuestShare.create(link.pairing, link.label, link.host, name.trim())
        guests.filter { it.pairing.room == g.pairing.room }.forEach { leave(it.id) }
        guests += g
        saveGuests()
        pendingJoin = null
        joining = g.id
        connect(g)
    }

    /** Leave a share (or give up waiting): the owner's host ends it when told; the room just goes quiet. */
    fun leave(id: String) {
        guestRelays[id]?.let { if (call.line === it) call.hangUp() }   // his call goes with the share
        guestRelays.remove(id)?.forget()
        guests.removeAll { it.id == id }
        saveGuests()
    }

    /** The relay that carries session `id`: a share's, else the own host's. */
    fun relay(id: String): Relay = guests.firstNotNullOfOrNull { g ->
        guestRelays[g.id]?.takeIf { r -> r.snapshot?.sessions?.any { it.id == id } == true }
    } ?: relay

    /** The share a session belongs to, if it is someone else's. */
    fun guestShare(id: String): GuestShare? = guests.firstOrNull { g -> guestRelays[g.id]?.snapshot?.sessions?.any { it.id == id } == true }

    private fun connect(g: GuestShare) {
        val r = guestRelays.getOrPut(g.id) { Relay(scope, deviceName) }
        // Not let in yet: say who I am (and the key the fresh room is sealed to). Let in: nothing —
        // the iPhone sends its push tokens here; Android has no push (its call rings over this room).
        r.onOpened = {
            guests.firstOrNull { it.id == g.id }?.let { if (!it.active) r.send(Outgoing.join(it.name, Build.MODEL ?: "Android", it.pub, who)) }
            call.opened(r)   // a guest's call on this room says so again
        }
        r.onClosed = { call.linkChanged(r) }
        // Part 3: the owner's host calls this phone on the share's room — its voice plays only on that call.
        r.onAudio = { call.play(r, it) }
        r.onFrame = { guestEvent(g.id, it) }
        r.use(g.pairing)
        r.reconnect()
    }

    private fun guestEvent(id: String, f: Incoming) {
        val i = guests.indexOfFirst { it.id == id }
        if (i < 0) return
        val g = guests[i]
        when (f) {
            // The owner's host came (back) into the invite room after we did: ask again (one join per link and key).
            is Incoming.Peer -> {
                if (f.host && !g.active) guestRelays[id]?.send(Outgoing.join(g.name, Build.MODEL ?: "Android", g.pub, who))
                guestRelays[id]?.let { toCall(it, f) }
            }
            // Part 3: a call on his own line — the owner's host rings him for a question (in the
            // foreground, or while Unterwegs keeps the room open in the background).
            is Incoming.Ring, is Incoming.Audio, is Incoming.CaptionFrame -> if (g.active) guestRelays[id]?.let { toCall(it, f) }
            is Incoming.Move -> {
                // Let in: the fresh room, sealed to this phone's key — the invite's room is dead from here on.
                if (g.active) return
                val room = g.open(f.move) ?: return
                val moved = runCatching { Pairing.check(g.pairing.relay, room.first, room.second, room.third) }.getOrNull() ?: return
                guests[i] = g.copy(pairing = moved, share = f.move.share, role = f.move.role ?: "", listen = f.move.listen ?: false, active = true)
                saveGuests()
                guestRelays[id]?.let { r ->
                    r.use(moved)
                    r.reconnect()
                    // Just let in: his session opens as soon as the fresh room shows it (the welcome call follows).
                    scope.launch {
                        withTimeoutOrNull(20_000) { snapshotFlow { r.snapshot?.sessions?.firstOrNull()?.id }.filterNotNull().first() }
                            ?.let { showSession = it }
                    }
                }
            }
            is Incoming.ShareEnd -> {
                guestNotice = "${if (g.host.isEmpty()) "Die Freigabe" else g.host + " hat die Freigabe"} für „${g.label}“ beendet."
                leave(id)
            }
            is Incoming.Notice -> guestNotice = f.text
            is Incoming.Ask -> {
                guestAsks.removeAll { it.id == f.ask.id }
                guestAsks += f.ask
                if (!isForeground) ParleyService.notifyAsk(app, f.ask)
            }
            is Incoming.AskEnd -> guestAsks.removeAll { it.id == f.id }
            is Incoming.History, is Incoming.Image -> store(f)
            else -> {}   // the owner's controls aren't a guest's
        }
    }

    /** The guest answers (text, a predicted answer, dictation) or gives the question to the owner. */
    fun answer(a: GuestAsk, text: String, pass: Boolean = false) {
        guestAsks.removeAll { it.id == a.id }
        if (!demo) relay(a.session).send(Outgoing.answer(a.id, text, pass))
    }

    // Shared sessions, the owner's side.

    /** "Teilen": ask the host for a one-time link (it arrives as `shareLinks[session]`). */
    fun share(session: String) {
        shareLinks.remove(session)
        if (demo) {   // a link to look at, nothing behind it
            shareLinks[session] = "parley://join?u=https%3A%2F%2Frelay.example&r=demo-room&k=demo&e=demo&s=Shirts&h=Sydney"
            return
        }
        relay.send(Outgoing.shareCreate(session))
    }

    fun approve(r: JoinRequest, role: String, listen: Boolean, full: Boolean, mine: String) {
        joinRequests.removeAll { it.id == r.id }
        relay.send(Outgoing.shareApprove(r.id, role, listen, full, mine))
    }

    /** Say no to a guest who asks, or remove one who is in. */
    fun removeShare(id: String) {
        joinRequests.removeAll { it.id == id }
        relay.send(Outgoing.shareRemove(id))
    }

    // Snapshots: the host keeps and opens them; the list comes back with the next sessions frame.

    fun saveSnapshot(name: String, ids: List<String>) {
        val n = name.trim()
        if (n.isNotEmpty() && ids.isNotEmpty()) relay.send(Outgoing.snapshotSave(n, ids))
    }

    fun openSnapshot(id: String) {
        snapshotOpened = null
        relay.send(Outgoing.snapshotOpen(id))
        if (demo) scope.launch {
            delay(900)
            relay.snapshot?.snapshots?.firstOrNull { it.id == id }?.let { snapshotOpened = Demo.opened(it) }
        }
    }

    fun deleteSnapshot(id: String) = relay.send(Outgoing.snapshotDelete(id))

    companion object {
        /** A history page into what is loaded: an older page goes in front, the latest replaces the tail. */
        fun merge(old: List<ChatItem>, page: List<ChatItem>, before: String?): List<ChatItem> {
            if (before != null) return if (old.firstOrNull()?.id == before) page + old else old
            val first = page.firstOrNull() ?: return page
            val j = old.indexOfFirst { it.id == first.id }
            return if (j < 0) page else old.subList(0, j) + page
        }
    }
}
