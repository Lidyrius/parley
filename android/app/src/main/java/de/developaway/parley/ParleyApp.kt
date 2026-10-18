package de.developaway.parley

import android.app.Application
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Build
import android.provider.Settings
import android.util.Base64
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob

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

    var demo = false; private set

    /** Sample data instead of a relay (Demo.kt). */
    fun startDemo(kind: String) {
        demo = true
        relay.forget()
        pairing = Pairing("https://relay.example", "demo", "demo")
        relay.demo(Frames.snapshot(org.json.JSONObject(Demo.frame(System.currentTimeMillis()))))
        histories["demo-shirts"] = Demo.history
        if (kind in setOf("speaking", "listening", "idle", "incoming", "connecting")) call.demo(kind)
    }

    /** "Fortsetzen" while Unterwegs: the call starts first, the resume follows once it is up. */
    private var resumeOnConnect: String? = null

    init {
        relay.onOpened = {
            // Per-connection state, but only what this phone has switched on: a second phone
            // (the iPhone) in the same room keeps its own Unterwegs.
            if (away) relay.send(Outgoing.away(true))
            if (call.inCall) relay.send(Outgoing.call(true))
            call.relayChanged()
        }
        relay.onClosed = { call.relayChanged() }
        relay.onFrame = ::handle
        call.onConnected = {
            resumeOnConnect?.let { relay.resume(it) }
            resumeOnConnect = null
        }
        call.onPhase = { phase ->
            if (!demo) ParleyService.sync(app)
            // A call that ended in the background: the socket goes too, unless Unterwegs keeps it.
            if (phase == CallPhase.none && !isForeground && !away) relay.disconnect()
        }
        pairing?.let { relay.use(it) }
    }

    private fun Relay.resume(id: String) = send(Outgoing.resume(id))

    private fun handle(f: Incoming) {
        when (f) {
            is Incoming.Peer -> call.relayChanged()
            is Incoming.Audio -> call.hostAudioChanged(f.state, f.label)
            is Incoming.CaptionFrame -> call.captionReceived(f.caption)
            is Incoming.Ring -> call.reportIncoming(f.label)
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
        if (pairing == null || demo) return
        if (call.phase != CallPhase.none) ParleyService.sync(app)
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

    fun loadHistory(id: String) = relay.send(Outgoing.history(id))

    fun loadOlder(id: String) {
        val first = histories[id]?.firstOrNull()?.id ?: return
        relay.send(Outgoing.history(id, before = first))
    }

    fun loadImage(session: String, key: String) {
        if (requestedImages.add(key)) relay.send(Outgoing.image(session, key))
    }

    fun say(id: String, text: String) {
        val t = text.trim()
        if (t.isEmpty()) return
        pending[id] = (pending[id] ?: emptyList()) + t
        relay.send(Outgoing.say(id, t))
    }

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
