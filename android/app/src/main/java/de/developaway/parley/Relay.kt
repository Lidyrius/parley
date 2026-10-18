package de.developaway.parley

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import okio.ByteString.Companion.toByteString
import java.util.concurrent.TimeUnit
import kotlin.math.abs

/** What the header says about the link to the host. */
enum class ConnectionStatus(val label: String) {
    connected("Verbunden"), hostOffline("Mac offline"), connecting("Verbinde…"),
    unknownRoom("Mac offline"), rejected("Kopplung abgelehnt"), unreachable("Keine Verbindung"),
}

/**
 * The phone's side of the relay protocol (ios/ParleyMobile/Relay.swift): one WebSocket to the
 * room, kept alive and redialled. State lives on the main thread; call audio is handed to
 * `onAudio` straight from OkHttp's reader thread.
 */
class Relay(private val scope: CoroutineScope, private val device: String) {
    enum class Link { idle, connecting, connected }
    enum class Failure { unauthorized, unknownRoom, unreachable }

    var link by mutableStateOf(Link.idle); private set
    var failure by mutableStateOf<Failure?>(null); private set
    var hostOnline by mutableStateOf<Boolean?>(null); private set
    var snapshot by mutableStateOf<Snapshot?>(null); private set
    /** Host clock minus phone clock (ms): timers count on the host's clock. */
    var skew by mutableStateOf(0.0); private set

    var onOpened: () -> Unit = {}
    var onClosed: () -> Unit = {}
    var onFrame: (Incoming) -> Unit = {}
    @Volatile var onAudio: (ByteArray) -> Unit = {}

    private val client = OkHttpClient.Builder().readTimeout(0, TimeUnit.MILLISECONDS).build()
    private var pairing: Pairing? = null
    private var loop: Job? = null
    @Volatile private var socket: WebSocket? = null
    @Volatile private var lastHeard = 0L
    private var bestSkew: Double? = null

    val status: ConnectionStatus get() = status(link, hostOnline, failure)
    val canSend: Boolean get() = link == Link.connected && hostOnline == true
    fun hostNow(): Double = System.currentTimeMillis() + skew

    fun use(p: Pairing) {
        disconnect()
        pairing = p
        snapshot = null
        failure = null
    }

    /** Dials right away, dropping any backoff. */
    fun reconnect() {
        val p = pairing ?: return
        loop?.cancel()
        link = Link.connecting
        loop = scope.launch { run(p) }
    }

    /** Dials only when nothing is up or on the way. */
    fun ensure() { if (loop?.isActive != true) reconnect() }

    fun disconnect() {
        loop?.cancel()
        loop = null
        socket?.close(1001, null)
        socket = null
        val wasOpen = link == Link.connected
        link = Link.idle
        hostOnline = null
        if (wasOpen) onClosed()
    }

    /** Demo mode: a snapshot, as if connected. */
    fun demo(s: Snapshot) {
        link = Link.connected
        hostOnline = true
        snapshot = s
    }

    fun forget() {
        disconnect()
        pairing = null
        snapshot = null
        failure = null
    }

    /** Dropped when no socket is open: everything sent is a user action or state resent on open. */
    fun send(text: String) { if (link == Link.connected) socket?.send(text) }

    /** From the mic thread. */
    fun sendAudio(frame: ByteArray) { socket?.send(frame.toByteString()) }

    /** Capped backoff (1 s → 30 s); a socket that was open starts over at 1 s. */
    private suspend fun run(p: Pairing) {
        var wait = 1_000L
        while (scope.isActive) {
            if (connectOnce(p)) wait = 1_000L
            delay(wait)
            wait = minOf(wait * 2, 30_000L)
        }
    }

    private suspend fun connectOnce(p: Pairing): Boolean {
        val done = CompletableDeferred<Int?>()   // the HTTP status of a refused handshake
        var opened = false
        bestSkew = null
        val req = Request.Builder().url(p.socketURL).header("Authorization", "Bearer ${p.secret}").build()
        val ws = client.newWebSocket(req, object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                lastHeard = System.currentTimeMillis()
                webSocket.send(Outgoing.hello(device))
                scope.launch {
                    if (socket !== webSocket) return@launch
                    opened = true
                    link = Link.connected
                    failure = null
                    onOpened()
                }
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                lastHeard = System.currentTimeMillis()
                if (text == "pong") return
                val frame = Frames.parse(text)
                scope.launch { if (socket === webSocket) apply(frame) }
            }

            override fun onMessage(webSocket: WebSocket, bytes: ByteString) {
                lastHeard = System.currentTimeMillis()
                onAudio(bytes.toByteArray())
            }

            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) { webSocket.close(1000, null) }
            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) { done.complete(null) }
            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) { done.complete(response?.code) }
        })
        socket = ws
        link = Link.connecting

        // `ping` every 25 s keeps NAT and the relay happy; 60 s of silence = a half-open socket.
        val pinger = scope.launch {
            while (true) {
                delay(25_000)
                if (System.currentTimeMillis() - lastHeard > 60_000) { ws.cancel(); return@launch }
                ws.send("ping")
            }
        }
        val code = try { done.await() } finally { pinger.cancel(); ws.cancel() }
        if (!opened) failure = when (code) {
            401, 403 -> Failure.unauthorized
            404 -> Failure.unknownRoom
            else -> Failure.unreachable
        }
        if (socket === ws) {
            socket = null
            link = Link.connecting   // the loop dials again after its backoff
            hostOnline = null
            if (opened) onClosed()
        }
        return opened
    }

    private fun apply(frame: Incoming) {
        when (frame) {
            is Incoming.Sessions -> {
                frame.snapshot.at?.let { at ->
                    skew(at - System.currentTimeMillis(), bestSkew)?.let { bestSkew = it; if (it != skew) skew = it }
                }
                snapshot = frame.snapshot
                return
            }
            is Incoming.Peer -> hostOnline = frame.host
            else -> {}
        }
        onFrame(frame)
    }

    companion object {
        fun status(link: Link, hostOnline: Boolean?, failure: Failure?): ConnectionStatus {
            if (link == Link.connected) return when (hostOnline) {
                true -> ConnectionStatus.connected
                false -> ConnectionStatus.hostOffline
                null -> ConnectionStatus.connecting
            }
            return when (failure) {
                Failure.unauthorized -> ConnectionStatus.rejected
                Failure.unknownRoom -> ConnectionStatus.unknownRoom
                Failure.unreachable -> ConnectionStatus.unreachable
                null -> ConnectionStatus.connecting
            }
        }

        /** Latency and a replayed frame only make `at` look early: the largest sample wins. Off by minutes = stale. */
        fun skew(sample: Double, best: Double?): Double? {
            if (abs(sample) >= 120_000) return best
            return maxOf(best ?: sample, sample)
        }
    }
}
