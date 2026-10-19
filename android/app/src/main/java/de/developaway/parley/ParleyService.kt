package de.developaway.parley

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.os.Build
import android.os.IBinder
import android.os.VibrationEffect
import android.os.Vibrator
import androidx.core.app.NotificationCompat
import androidx.core.app.Person
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat

/**
 * Keeps Parley reachable while the app is in the background: the relay socket stays open while
 * Unterwegs is on (the host's `ring` arrives over it — Android has no VoIP push here), and the
 * call keeps its microphone. A ring rings: the ringtone, and a call notification that opens the
 * ringing screen over the lock screen.
 */
class ParleyService : Service() {
    private var ringtone: android.media.Ringtone? = null
    private var vibrator: Vibrator? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val m = model
        when (intent?.action) {
            ACTION_DECLINE -> m.call.hangUp()
            ACTION_HANG_UP -> m.call.hangUp()
        }
        update()
        return START_NOT_STICKY
    }

    /** Foreground with the right type and notification — or gone, when nothing needs it. */
    fun update() {
        val m = model
        val phase = m.call.phase
        val micAllowed = ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
        var type = if (Build.VERSION.SDK_INT >= 34) ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE else 0
        if (phase == CallPhase.active || phase == CallPhase.dialing || phase == CallPhase.connecting) {
            if (micAllowed && Build.VERSION.SDK_INT >= 30) type = type or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
        }
        val n = ongoingNotification(phase, m.call.label)
        try {
            ServiceCompat.startForeground(this, ID, n, type)
        } catch (e: Exception) {
            // Started from the background without the right to: keep going without the mic type.
            ServiceCompat.startForeground(this, ID, n, if (Build.VERSION.SDK_INT >= 34) ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE else 0)
        }
        // Foreground first, always: a service started with startForegroundService must, even to stop.
        if (!m.away && phase == CallPhase.none) {
            stopRinging()
            getSystemService(NotificationManager::class.java).cancel(RING_ID)
            ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
            stopSelf()
            return
        }
        if (phase == CallPhase.ringing) startRinging() else stopRinging()
        // In the app the ringing screen is up already: no call notification on top of it.
        val nm = getSystemService(NotificationManager::class.java)
        if (phase == CallPhase.ringing && !m.isForeground) nm.notify(RING_ID, ringingNotification(m.call.label)) else nm.cancel(RING_ID)
        m.relay.ensure()
        m.guestRelays.values.forEach { it.ensure() }
    }

    private fun ongoingNotification(phase: CallPhase, label: String?): Notification {
        val inCall = phase != CallPhase.none && phase != CallPhase.ringing
        val b = NotificationCompat.Builder(this, CHANNEL_ONGOING)
            .setSmallIcon(R.drawable.ic_stat_parley)
            .setOngoing(true)
            .setSilent(true)
            .setContentIntent(openApp())
            .setContentTitle(if (inCall) "Gespräch mit Parley" else "Parley · Unterwegs")
            .setContentText(if (inCall) label ?: "Parley" else "Updates kommen als Anruf aufs Handy.")
        if (inCall) b.addAction(0, "Auflegen", self(ACTION_HANG_UP))
        return b.build()
    }

    private fun ringingNotification(label: String?): Notification {
        val caller = Person.Builder().setName(label ?: "Parley").setImportant(true).build()
        val answer = PendingIntent.getActivity(this, 2, Intent(this, MainActivity::class.java)
            .setAction(MainActivity.ACTION_ANSWER).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        return NotificationCompat.Builder(this, CHANNEL_CALLS)
            .setSmallIcon(R.drawable.ic_stat_parley)
            .setContentTitle(label ?: "Parley")
            .setContentText("Ein Update möchte mit dir sprechen.")
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setOngoing(true)
            .setFullScreenIntent(openApp(), true)
            .setContentIntent(openApp())
            .setStyle(NotificationCompat.CallStyle.forIncomingCall(caller, self(ACTION_DECLINE), answer))
            .build()
    }

    private fun openApp() = PendingIntent.getActivity(this, 1,
        Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)

    private fun self(action: String) = PendingIntent.getService(this, action.hashCode(),
        Intent(this, ParleyService::class.java).setAction(action), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)

    private fun startRinging() {
        if (ringtone?.isPlaying == true) return
        ringtone = RingtoneManager.getRingtone(this, RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE))?.apply {
            audioAttributes = AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build()
            if (Build.VERSION.SDK_INT >= 28) isLooping = true
            play()
        }
        vibrator = (getSystemService(Context.VIBRATOR_SERVICE) as Vibrator).also {
            it.vibrate(VibrationEffect.createWaveform(longArrayOf(0, 800, 1200), 0))
        }
    }

    private fun stopRinging() {
        ringtone?.stop()
        ringtone = null
        vibrator?.cancel()
        vibrator = null
    }

    override fun onCreate() {
        super.onCreate()
        running = this
    }

    override fun onDestroy() {
        running = null
        getSystemService(NotificationManager::class.java).cancel(RING_ID)
        stopRinging()
        super.onDestroy()
    }

    companion object {
        private const val ID = 7
        private const val RING_ID = 8
        private var running: ParleyService? = null
        const val CHANNEL_ONGOING = "ongoing"
        const val CHANNEL_CALLS = "calls"
        const val CHANNEL_ASKS = "asks"
        const val ACTION_DECLINE = "decline"
        const val ACTION_HANG_UP = "hangup"

        fun channels(c: Context) {
            val nm = c.getSystemService(NotificationManager::class.java)
            nm.createNotificationChannel(NotificationChannel(CHANNEL_ONGOING, "Unterwegs und Gespräche", NotificationManager.IMPORTANCE_LOW))
            nm.createNotificationChannel(NotificationChannel(CHANNEL_CALLS, "Eingehende Anrufe", NotificationManager.IMPORTANCE_HIGH).apply {
                setSound(null, null)   // the service rings itself
                enableVibration(false)
            })
            nm.createNotificationChannel(NotificationChannel(CHANNEL_ASKS, "Rückfragen in geteilten Sessions", NotificationManager.IMPORTANCE_HIGH))
        }

        /**
         * v7: a question for this phone as a guest while the app is in the background (its share's
         * room stays open only while Unterwegs — the iPhone gets it as a push instead).
         */
        fun notifyAsk(c: Context, a: GuestAsk) {
            if (Build.VERSION.SDK_INT >= 33 && ContextCompat.checkSelfPermission(c, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return
            val open = PendingIntent.getActivity(c, 3, Intent(c, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            val n = NotificationCompat.Builder(c, CHANNEL_ASKS)
                .setSmallIcon(R.drawable.ic_stat_parley)
                .setContentTitle("Rückfrage · ${a.label}")
                .setContentText(a.text)
                .setStyle(NotificationCompat.BigTextStyle().bigText(a.text))
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setAutoCancel(true)
                .setContentIntent(open)
                .build()
            c.getSystemService(NotificationManager::class.java).notify(a.id.hashCode(), n)
        }

        /** The model changed (Unterwegs, the call): the service follows. */
        fun sync(c: Context) {
            val m = c.model
            val needed = m.away || m.call.phase != CallPhase.none
            // Running already: update it in place (a second start from the background may be refused).
            running?.let { it.update(); return }
            if (needed) runCatching { ContextCompat.startForegroundService(c, Intent(c, ParleyService::class.java)) }
        }
    }
}
