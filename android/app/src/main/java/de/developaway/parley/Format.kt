package de.developaway.parley

import android.content.Context
import java.util.Locale
import kotlin.math.roundToInt

// Labels and figures as the iPhone app words them (ios/ParleyMobile/Format.swift).

data class Fact(val label: String, val value: String)

val SessionState.label: String
    get() = when (this) {
        SessionState.speaking -> "spricht"
        SessionState.listening -> "hört zu"
        SessionState.transcribing -> "transkribiert"
        SessionState.queued -> "Warteschlange"
        SessionState.working -> "arbeitet"
        SessionState.background -> "Agent im Hintergrund"
        SessionState.waiting -> "pausiert"
        SessionState.parked -> "geparkt"
        SessionState.idle -> "bereit"
        SessionState.stopped -> "gestoppt"
    }

object Fmt {
    /** "4:12", "1:02:05". */
    fun clock(ms: Double): String {
        val s = maxOf(0, (ms / 1000).toInt())
        val (h, m, sec) = Triple(s / 3600, (s % 3600) / 60, s % 60)
        return if (h > 0) String.format(Locale.ROOT, "%d:%02d:%02d", h, m, sec) else String.format(Locale.ROOT, "%d:%02d", m, sec)
    }

    /** "noch 4:12" (pause countdown), "vor 3 min" (stopped), else "seit 2:14". */
    fun timer(s: Session, at: Double): String = when {
        s.state == SessionState.waiting && s.until != null -> "noch ${clock(s.until - at)}"
        s.state == SessionState.stopped -> "vor ${maxOf(1, ((at - s.since) / 60_000).roundToInt())} min"
        else -> "seit ${clock(at - s.since)}"
    }

    /** The tile's corner: the bare time (a pause counts down). */
    fun cornerTime(s: Session, at: Double): String = when {
        s.state == SessionState.waiting && s.until != null -> clock(s.until - at)
        s.state == SessionState.stopped -> "vor ${maxOf(1, ((at - s.since) / 60_000).roundToInt())} min"
        else -> clock(at - s.since)
    }

    /** "45 min", "1 h 12 min". */
    fun span(ms: Double): String {
        val m = maxOf(0, (ms / 60_000).roundToInt())
        return if (m < 60) "$m min" else "${m / 60} h ${m % 60} min"
    }

    fun money(usd: Double) = String.format(Locale.ROOT, "$%.2f", usd)
    fun percent(p: Double) = "${p.roundToInt()} %"

    /** "Agent im Hintergrund" for subagents/workflows, "Job im Hintergrund" for shells etc. */
    fun stateLabel(s: Session): String {
        if (s.state != SessionState.background) return s.state.label
        val agents = s.tasks.count { it.type == "subagent" || it.type == "workflow" }
        if (s.tasks.isEmpty() || agents == s.tasks.size) return if (agents > 1) "$agents Agents im Hintergrund" else "Agent im Hintergrund"
        return if (s.tasks.size > 1) "${s.tasks.size} Jobs im Hintergrund" else "Job im Hintergrund"
    }

    /** "5-h-Limit" / "Woche" from the rate limits the host reports. */
    fun limits(d: Today): List<Pair<String, Double>> = d.rateLimits.mapNotNull { r ->
        val name = mapOf("five_hour" to "5-h-Limit", "seven_day" to "Woche")[r.kind] ?: return@mapNotNull null
        r.percentUsed?.let { name to it }
    }
}

/** The app's switches (SharedPreferences), as the iPhone's UserDefaults keys. */
object Prefs {
    private fun p(c: Context) = c.getSharedPreferences("parley", Context.MODE_PRIVATE)
    fun autoHangUp(c: Context) = p(c).getBoolean("autoHangUp", false)
    fun speakerByDefault(c: Context) = p(c).getBoolean("speakerByDefault", true)
    fun away(c: Context) = p(c).getBoolean("awayMode", false)
    fun round(c: Context) = p(c).getInt("roundSeconds", 90)
    fun grid(c: Context) = p(c).getBoolean("grid", true)
    fun set(c: Context, key: String, v: Boolean) = p(c).edit().putBoolean(key, v).apply()
    fun set(c: Context, key: String, v: Int) = p(c).edit().putInt(key, v).apply()
}
