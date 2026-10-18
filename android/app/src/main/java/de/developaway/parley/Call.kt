package de.developaway.parley

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

enum class CallPhase { none, ringing, dialing, connecting, active }

/**
 * The phone's call with Parley (ios/ParleyMobile/Call.swift, docs/IPHONE.md → phone behaviour):
 * its audio runs over the relay. Outgoing ("Anrufen", "Fortsetzen") and incoming (`ring` frame)
 * take the same path: once the relay reaches the host the audio starts and `call start` goes out;
 * `call end` when it ends. No CallKit here: the ringing screen is the app's own (plus a
 * full-screen notification when it is in the background, see ParleyService).
 */
class CallController(private val context: Context, private val scope: CoroutineScope, private val relay: Relay) {
    var phase by mutableStateOf(CallPhase.none); private set
    var since by mutableStateOf(0L); private set
    var hostAudio by mutableStateOf(HostAudio.idle); private set
    var label by mutableStateOf<String?>(null); private set
    var muted by mutableStateOf(false); private set
    var speaker by mutableStateOf(false); private set
    /** Just connected, the host hasn't spoken yet: the screen stays as while connecting. */
    var awaitingHost by mutableStateOf(false); private set
    var caption by mutableStateOf<Caption?>(null); private set
    /** "Sprechen" was tapped while the host was idle; cleared when it leaves idle. */
    var wakeSent by mutableStateOf(false); private set
    var showsScreen by mutableStateOf(false)
    var failure by mutableStateOf<String?>(null)
    var isTest by mutableStateOf(false); private set
    var isDemo = false; private set
    private var demoStart = 0L

    var onConnected: () -> Unit = {}
    /** Phase changed: the service follows (foreground type, notification, ringtone). */
    var onPhase: (CallPhase) -> Unit = {}

    private val audio = CallAudio(context) { relay.sendAudio(it) }
    @Volatile private var live = false
    private var captionBase = 0
    private var beginning = false
    private var ringExpiry: Job? = null
    private var connectTimeout: Job? = null
    private var lossTimeout: Job? = null
    private var awaitingJob: Job? = null
    private var autoHangUp: Job? = null
    private var testJob: Job? = null

    val inCall get() = phase == CallPhase.active
    val isRinging get() = phase == CallPhase.ringing

    init { relay.onAudio = { if (live) audio.play(it) } }

    private fun set(p: CallPhase) { phase = p; onPhase(p) }

    // Outgoing

    fun startOutgoing() {
        if (phase != CallPhase.none) { showsScreen = true; return }
        label = null
        set(CallPhase.dialing)
        showsScreen = true
        dial()
    }

    // Incoming

    fun reportIncoming(label: String?) {
        if (phase != CallPhase.none) return   // already ringing or in a call
        this.label = label
        set(CallPhase.ringing)
        showsScreen = true
        relay.ensure()
        // Not answered in 40 s: stop ringing and tell the host (it gives up at 45 s).
        ringExpiry?.cancel()
        ringExpiry = scope.launch { delay(RING_MS); if (phase == CallPhase.ringing) finish() }
    }

    fun answer() {
        if (phase != CallPhase.ringing) return
        ringExpiry?.cancel()
        if (isTest) {
            since = System.currentTimeMillis()
            set(CallPhase.active)
            hostAudio = HostAudio.speaking
            testJob = scope.launch { delay(6_000); hostAudio = HostAudio.listening; delay(2_500); reset() }
            return
        }
        showsScreen = true
        set(CallPhase.connecting)
        dial()
    }

    /** "Not now" on the ringing screen: ring again in `after` s, or (null) wait for a call back. */
    fun later(after: Int?) {
        if (phase != CallPhase.ringing) return
        if (!isTest) relay.send(Outgoing.later(after))
        hangUp()
    }

    /** Settings → Probeanruf: rings in the app; answering shows Parley speaking, then it ends. */
    fun startTest() {
        if (phase != CallPhase.none) return
        isTest = true
        label = "Probeanruf"
        showsScreen = true
        set(CallPhase.ringing)
    }

    // In call

    fun hangUp() {
        if (phase == CallPhase.none) return
        if (isTest) { reset(); return }
        finish()
    }

    fun mute(on: Boolean) { muted = on; audio.muted = on }

    fun useSpeaker(on: Boolean) { speaker = on; if (!isTest) audio.setSpeaker(on) }

    /** The iPhone's "Hey Parley": Sir wants to talk while the host is idle. */
    fun talk() {
        if (!inCall || hostAudio != HostAudio.idle) return
        wakeSent = true
        relay.send(Outgoing.wake)
        scope.launch { delay(10_000); if (hostAudio == HostAudio.idle) wakeSent = false }
    }

    /** Sir talks over Parley: quiet at once; the host stops the line and listens. */
    fun interrupt() {
        if (!inCall || hostAudio != HostAudio.speaking) return
        audio.silence()
        autoHangUp?.cancel()
        relay.send(Outgoing.barge)
    }

    fun captionReceived(c: Caption) {
        caption = c
        captionBase = audio.received   // it arrives just before its line's first frame: time runs once those play
        autoHangUp?.cancel()
        if (c.last && Prefs.autoHangUp(context) && inCall && !isTest) {
            // The talk's last line: the call ends the moment its last word has played.
            autoHangUp = scope.launch {
                while (inCall) {
                    delay(30)
                    if (captionTime() >= c.end - 0.1 && audio.played >= audio.received) { showsScreen = false; hangUp(); return@launch }
                }
            }
        }
    }

    /** Seconds of the caption's line played so far. */
    fun captionTime(): Double = if (isDemo) ((System.currentTimeMillis() - demoStart) / 1000.0) % ((caption?.end ?: 1.0) + 1.5) else if (isTest) ((System.currentTimeMillis() - since) / 1000.0) else maxOf(0, audio.played - captionBase) * 0.02

    fun hostAudioChanged(state: HostAudio, newLabel: String?) {
        if (newLabel != null) label = newLabel
        if (state != HostAudio.idle) autoHangUp?.cancel()
        if (state != HostAudio.speaking) audio.unsilence()
        if (state == hostAudio) return
        if (state == HostAudio.idle && hostAudio != HostAudio.idle && Prefs.autoHangUp(context) && inCall && !isTest) {
            // The talk is over: hang up once the last line has played out (max. 4 s).
            autoHangUp = scope.launch {
                for (i in 0 until 80) { if (audio.played >= audio.received) break; delay(50) }
                if (inCall) { showsScreen = false; hangUp() }
            }
            return
        }
        hostAudio = state
        if (state != HostAudio.idle) { awaitingHost = false; awaitingJob?.cancel(); wakeSent = false }
    }

    /** The relay opened, closed, or the host came or went. */
    fun relayChanged() {
        when (phase) {
            CallPhase.dialing, CallPhase.connecting -> begin()
            CallPhase.active -> if (relay.canSend) { lossTimeout?.cancel(); lossTimeout = null } else if (lossTimeout == null) {
                lossTimeout = scope.launch { delay(25_000); fail("Die Verbindung zu Parley auf dem Mac ist abgebrochen.") }
            }
            else -> {}
        }
    }

    /** The waveform: the host's voice while it speaks, else the mic. */
    fun level(): Float = when {
        isDemo || isTest -> if (hostAudio == HostAudio.speaking) (0.3f + 0.3f * kotlin.math.sin(System.currentTimeMillis() / 90.0).toFloat()) else 0.1f
        hostAudio == HostAudio.speaking -> audio.outLevel
        else -> audio.micLevel
    }

    // Lifecycle

    private fun dial() {
        relay.ensure()
        connectTimeout?.cancel()
        connectTimeout = scope.launch {
            delay(20_000)
            if (phase == CallPhase.dialing || phase == CallPhase.connecting) fail("Parley auf dem Mac ist gerade nicht erreichbar.")
        }
        begin()
    }

    /** Relay ready → audio (off the main thread), `call start`. */
    private fun begin() {
        if ((phase != CallPhase.dialing && phase != CallPhase.connecting) || !relay.canSend || beginning) return
        beginning = true
        connectTimeout?.cancel()
        scope.launch {
            try {
                withContext(Dispatchers.IO) { audio.start() }
            } catch (e: Throwable) {
                beginning = false
                fail("Das Mikrofon ließ sich nicht starten.")
                return@launch
            }
            beginning = false
            if (phase != CallPhase.dialing && phase != CallPhase.connecting) { audio.stop(); return@launch }
            audio.muted = muted
            if (Prefs.speakerByDefault(context) && !audio.hasHeadset()) useSpeaker(true)
            live = true
            relay.send(Outgoing.call(true))
            awaitingHost = true
            awaitingJob?.cancel()
            awaitingJob = scope.launch { delay(4_000); awaitingHost = false }
            since = System.currentTimeMillis()
            set(CallPhase.active)
            onConnected()
        }
    }

    private fun fail(message: String) {
        if (phase == CallPhase.none) return
        failure = message
        finish()
    }

    /** Hung up, declined, failed. */
    private fun finish() {
        if (phase == CallPhase.none) return
        relay.send(Outgoing.call(false))
        reset()
    }

    private fun reset() {
        live = false
        listOf(ringExpiry, connectTimeout, lossTimeout, awaitingJob, autoHangUp, testJob).forEach { it?.cancel() }
        lossTimeout = null
        audio.stop()
        label = null
        hostAudio = HostAudio.idle
        isTest = false
        caption = null
        muted = false
        audio.muted = false
        speaker = false
        awaitingHost = false
        wakeSent = false
        showsScreen = false
        beginning = false
        set(CallPhase.none)
    }

    /** Demo mode: the call screen in one of its states, without a call. */
    fun demo(state: String) {
        isDemo = true
        when (state) {
            "incoming" -> { label = "Tippfrei"; set(CallPhase.ringing) }
            "connecting" -> set(CallPhase.dialing)
            else -> {
                since = System.currentTimeMillis() - 167_000
                set(CallPhase.active)
                hostAudio = HostAudio.valueOf(state)
                wakeSent = state == "listening"
                if (state != "idle") { caption = Demo.caption; demoStart = System.currentTimeMillis() }
            }
        }
        showsScreen = true
    }

    companion object { const val RING_MS = 40_000L }
}
