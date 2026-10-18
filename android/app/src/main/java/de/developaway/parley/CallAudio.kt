package de.developaway.parley

import android.annotation.SuppressLint
import android.content.Context
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaRecorder
import android.media.audiofx.AcousticEchoCanceler
import android.media.audiofx.NoiseSuppressor
import android.os.Build
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import kotlin.math.sqrt

/**
 * The call's audio (ios/ParleyMobile/CallAudio.swift): mic → 16 kHz PCM16 20 ms frames → `send`;
 * received frames (960 bytes at 24 kHz, or an older host's 640 at 16 kHz) → a 24 kHz track.
 * VOICE_COMMUNICATION + MODE_IN_COMMUNICATION give the platform's echo cancellation.
 */
class CallAudio(context: Context, private val send: (ByteArray) -> Unit) {
    private val am = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    @Volatile var muted = false
    @Volatile var running = false; private set
    /** RMS levels (0…1) for the waveform. */
    @Volatile var micLevel = 0f; private set
    @Volatile var outLevel = 0f; private set
    /** Frames (20 ms) received this run — the captions' clock, with `played`. */
    @Volatile var received = 0; private set

    private var record: AudioRecord? = null
    private var track: AudioTrack? = null
    private var threads = listOf<Thread>()
    private val queue = LinkedBlockingQueue<ShortArray>()
    @Volatile private var silenced = false
    @Volatile private var written = 0L   // samples handed to the track

    /** Frames (20 ms at 24 kHz) played so far. */
    val played: Int get() = ((track?.playbackHeadPosition?.toLong() ?: 0L) and 0xFFFFFFFFL).toInt() / OUT_FRAME

    @SuppressLint("MissingPermission")   // asked before a call starts
    fun start() {
        if (running) return
        am.mode = AudioManager.MODE_IN_COMMUNICATION
        val minIn = AudioRecord.getMinBufferSize(16_000, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        val rec = AudioRecord(MediaRecorder.AudioSource.VOICE_COMMUNICATION, 16_000, AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT, maxOf(minIn, IN_FRAME * 2 * 4))
        if (rec.state != AudioRecord.STATE_INITIALIZED) { rec.release(); am.mode = AudioManager.MODE_NORMAL; error("mic") }
        if (AcousticEchoCanceler.isAvailable()) AcousticEchoCanceler.create(rec.audioSessionId)?.enabled = true
        if (NoiseSuppressor.isAvailable()) NoiseSuppressor.create(rec.audioSessionId)?.enabled = true

        val minOut = AudioTrack.getMinBufferSize(24_000, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT)
        val trk = AudioTrack.Builder()
            .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
            .setAudioFormat(AudioFormat.Builder().setSampleRate(24_000).setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT).build())
            .setTransferMode(AudioTrack.MODE_STREAM)
            .setBufferSizeInBytes(maxOf(minOut, OUT_FRAME * 2 * 10))
            .build()
        record = rec
        track = trk
        received = 0
        written = 0
        queue.clear()
        silenced = false
        running = true
        rec.startRecording()
        trk.play()
        threads = listOf(Thread(::micLoop, "parley-mic"), Thread(::playLoop, "parley-play")).onEach { it.start() }
    }

    fun stop() {
        if (!running) return
        running = false
        threads.forEach { it.interrupt() }
        threads.forEach { runCatching { it.join(500) } }
        threads = emptyList()
        record?.run { runCatching { stop() }; release() }
        track?.run { runCatching { stop() }; release() }
        record = null
        track = null
        queue.clear()
        micLevel = 0f
        outLevel = 0f
        setSpeaker(false)
        am.mode = AudioManager.MODE_NORMAL
    }

    /** One wire frame from the host (any thread). */
    fun play(frame: ByteArray) {
        if (!running || silenced) return
        received++
        val n = frame.size / 2
        val s = ShortArray(n) { i -> ((frame[2 * i].toInt() and 0xFF) or (frame[2 * i + 1].toInt() shl 8)).toShort() }
        queue.offer(if (frame.size == IN_FRAME * 2) upsample(s) else s)
    }

    /** Barge-in: quiet at once; frames still arriving are dropped until `unsilence()`. */
    fun silence() {
        if (!running) return
        silenced = true
        queue.clear()
        track?.run { pause(); flush(); play() }
        written = 0
        received = 0   // the track's head starts over too
    }

    fun unsilence() { silenced = false }

    /** Loudspeaker on/off; Bluetooth and wired headsets keep their route when off. */
    fun setSpeaker(on: Boolean) {
        if (Build.VERSION.SDK_INT >= 31) {
            if (on) am.availableCommunicationDevices.firstOrNull { it.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER }
                ?.let { am.setCommunicationDevice(it) }
            else am.clearCommunicationDevice()
        } else {
            @Suppress("DEPRECATION")
            am.isSpeakerphoneOn = on
        }
    }

    /** Nothing but the phone itself to talk through: the loudspeaker is the better default. */
    fun hasHeadset(): Boolean = am.getDevices(AudioManager.GET_DEVICES_OUTPUTS).any {
        it.type in setOf(AudioDeviceInfo.TYPE_BLUETOOTH_SCO, AudioDeviceInfo.TYPE_BLUETOOTH_A2DP, AudioDeviceInfo.TYPE_WIRED_HEADSET,
            AudioDeviceInfo.TYPE_WIRED_HEADPHONES, AudioDeviceInfo.TYPE_USB_HEADSET) ||
            (Build.VERSION.SDK_INT >= 31 && it.type == AudioDeviceInfo.TYPE_BLE_HEADSET)
    }

    private fun micLoop() {
        val buf = ShortArray(IN_FRAME)
        val out = ByteArray(IN_FRAME * 2)
        val rec = record ?: return
        while (running) {
            var got = 0
            while (got < IN_FRAME && running) {
                val n = rec.read(buf, got, IN_FRAME - got)
                if (n <= 0) return
                got += n
            }
            micLevel = if (muted) 0f else rms(buf)
            for (i in 0 until IN_FRAME) {
                val v = if (muted) 0 else buf[i].toInt()
                out[2 * i] = v.toByte()
                out[2 * i + 1] = (v shr 8).toByte()
            }
            send(out.copyOf())
        }
    }

    private fun playLoop() {
        val trk = track ?: return
        try {
            while (running) {
                val f = queue.poll(100, TimeUnit.MILLISECONDS)
                if (f == null) { outLevel = 0f; continue }
                // Starting from silence: wait a moment for a few frames, so network jitter doesn't stutter.
                if (written - trk.playbackHeadPosition <= 0) {
                    val until = System.currentTimeMillis() + 80
                    while (queue.size < 2 && System.currentTimeMillis() < until) Thread.sleep(5)
                }
                outLevel = rms(f)
                trk.write(f, 0, f.size)
                written += f.size
            }
        } catch (_: InterruptedException) {}
    }

    companion object {
        const val IN_FRAME = 320    // 20 ms at 16 kHz
        const val OUT_FRAME = 480   // 20 ms at 24 kHz

        fun rms(s: ShortArray): Float {
            var sum = 0.0
            for (x in s) sum += x * x.toDouble()
            return (sqrt(sum / s.size) / 32768.0 * 4).toFloat().coerceIn(0f, 1f)
        }

        /** 16 kHz → 24 kHz, linear (2 → 3 samples). */
        fun upsample(s: ShortArray): ShortArray = ShortArray(s.size * 3 / 2) { i ->
            val pos = i * 2.0 / 3.0
            val a = s[pos.toInt().coerceAtMost(s.size - 1)]
            val b = s[(pos.toInt() + 1).coerceAtMost(s.size - 1)]
            (a + (b - a) * (pos - pos.toInt())).toInt().toShort()
        }
    }
}
