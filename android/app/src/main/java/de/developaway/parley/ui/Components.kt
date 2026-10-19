package de.developaway.parley.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.State
import androidx.compose.runtime.getValue
import androidx.compose.runtime.produceState
import androidx.compose.runtime.withFrameMillis
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import de.developaway.parley.Session
import de.developaway.parley.SessionState
import kotlinx.coroutines.delay
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.sin

/** Wall clock (ms), ticking every `everyMs` — for timers on screen. */
@Composable
fun rememberNow(everyMs: Long = 1000): State<Long> = produceState(System.currentTimeMillis()) {
    while (true) { delay(everyMs - System.currentTimeMillis() % everyMs); value = System.currentTimeMillis() }
}

/** Seconds, every frame while `animated` (0 when not). */
@Composable
fun rememberSeconds(animated: Boolean = true): State<Double> = produceState(0.0, animated) {
    if (!animated) return@produceState
    while (true) withFrameMillis { value = it / 1000.0 }
}

/** A card's surface: tinted and outlined in the accent while the session holds the voice. */
fun Modifier.card(c: Colors, live: Boolean = false, radius: Dp = 20.dp): Modifier {
    val shape = RoundedCornerShape(radius)
    return this.clip(shape).background(c.card).background(if (live) c.accent.copy(alpha = 0.10f) else Color.Transparent)
        .border(1.dp, if (live) c.accent.copy(alpha = 0.55f) else c.stroke, shape)
}

/** The accent capsule (Fortsetzen, Anrufen, …). */
@Composable
fun Capsule(text: String, c: Colors, enabled: Boolean = true, filled: Boolean = true, modifier: Modifier = Modifier, onClick: () -> Unit) {
    Box(
        modifier.clip(RoundedCornerShape(50)).background(if (filled) c.accent else c.accent.copy(alpha = 0.14f))
            .clickable(enabled = enabled, onClick = onClick).alpha(if (enabled) 1f else 0.45f)
            .padding(horizontal = 14.dp, vertical = 7.dp),
        contentAlignment = Alignment.Center,
    ) { Text(text, color = if (filled) c.onAccent else c.accent, fontWeight = FontWeight.SemiBold, fontSize = 15.sp) }
}

/** A slim bar for a share (context, the limits). */
@Composable
fun ProgressBar(fraction: Double, color: Color, c: Colors, modifier: Modifier = Modifier) {
    Canvas(modifier.fillMaxWidth().height(6.dp)) {
        val r = CornerRadius(size.height / 2)
        drawRoundRect(c.text.copy(alpha = 0.08f), cornerRadius = r)
        drawRoundRect(color, size = Size(size.width * fraction.coerceIn(0.0, 1.0).toFloat(), size.height), cornerRadius = r)
    }
}

/** The animated ring per state (ios RingView): geometry in a 40-unit box, track r 15, stroke 3. */
@Composable
fun SessionRing(s: Session, color: Color, at: Double, size: Dp = 30.dp) {
    val animated = s.isLive || s.state in setOf(SessionState.working, SessionState.queued, SessionState.background, SessionState.waiting)
    val t by rememberSeconds(animated)
    val left = s.remaining(at) ?: 0.0
    Canvas(Modifier.size(size).alpha(if (s.state == SessionState.stopped) 0.7f else 1f)) {
        val u = this.size.width / 40f
        val c = Offset(this.size.width / 2, this.size.height / 2)
        fun arc(fraction: Double, alpha: Float = 1f) = drawArc(color.copy(alpha = alpha), -90f, (360 * fraction).toFloat(), false,
            topLeft = Offset(c.x - 15 * u, c.y - 15 * u), size = Size(30 * u, 30 * u), style = Stroke(3 * u, cap = StrokeCap.Round))
        drawCircle(color.copy(alpha = 0.18f), 15 * u, c, style = Stroke(3 * u))
        fun cycle(period: Double) = ((t / period) % 1.0).toFloat()
        when {
            s.isLive -> { arc(1.0); drawCircle(color, (6 + 3 * (0.5 - 0.5 * cos(2 * PI * t / 1.4))).toFloat() * u, c) }
            s.state == SessionState.working -> rotate(360 * cycle(1.6), c) { arc(0.28) }
            s.state == SessionState.queued -> rotate(360 * cycle(4.0), c) { arc(0.12) }
            s.state == SessionState.background -> {
                arc(1.0, 0.35f)
                rotate(360 * cycle(2.4), c) { drawCircle(color, 3.5f * u, Offset(c.x, 5 * u)) }
                drawCircle(color, 4 * u, c)
            }
            s.state == SessionState.waiting && s.until != null -> arc(left)
            s.state == SessionState.parked -> {
                drawRoundRect(color, Offset(c.x - 6 * u, c.y - 7 * u), Size(4 * u, 14 * u), CornerRadius(1.5f * u))
                drawRoundRect(color, Offset(c.x + 2 * u, c.y - 7 * u), Size(4 * u, 14 * u), CornerRadius(1.5f * u))
            }
            s.state == SessionState.idle -> { arc(1.0, 0.45f); drawCircle(color, 5 * u, c) }
            else -> drawRoundRect(color, Offset(c.x - 5 * u, c.y - 5 * u), Size(10 * u, 10 * u), CornerRadius(2 * u))
        }
    }
}

/** A small speech-like waveform for a speaking session. */
@Composable
fun MiniWave(color: Color, modifier: Modifier) {
    val t by rememberSeconds()
    Canvas(modifier) { wave(color, t) }
}

private fun DrawScope.wave(color: Color, t: Double, bars: Int = 15) {
    val w = size.width / bars
    for (i in 0 until bars) {
        val phase = i * 0.9
        val level = 0.25 + 0.75 * abs(sin(t * 5.3 + phase) * sin(t * 2.1 + phase * 0.6))
        val h = maxOf(3f, (size.height * level).toFloat())
        drawRoundRect(color, Offset(i * w, (size.height - h) / 2), Size(w * 0.55f, h), CornerRadius(w * 0.3f))
    }
}

/** Value over label, as in the today card and the sheet. */
@Composable
fun Figure(value: String, label: String, c: Colors, big: Boolean = true) {
    androidx.compose.foundation.layout.Column {
        Text(value, fontSize = if (big) 24.sp else 20.sp, fontWeight = FontWeight.Bold, color = c.text, maxLines = 1)
        Text(label, fontSize = 13.sp, color = c.secondary, maxLines = 1)
    }
}

@Composable
fun Dot(color: Color, size: Dp = 8.dp) = Box(Modifier.size(size).clip(RoundedCornerShape(50)).background(color))

@Composable
fun RowCenter(modifier: Modifier = Modifier, content: @Composable androidx.compose.foundation.layout.RowScope.() -> Unit) =
    Row(modifier, verticalAlignment = Alignment.CenterVertically, content = content)

val Pill: Shape = RoundedCornerShape(50)
