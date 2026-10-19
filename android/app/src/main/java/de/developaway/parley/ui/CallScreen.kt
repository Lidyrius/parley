package de.developaway.parley.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Call
import androidx.compose.material.icons.filled.CallEnd
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.MicOff
import androidx.compose.material.icons.filled.PanTool
import androidx.compose.material.icons.automirrored.filled.VolumeUp
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import de.developaway.parley.CallController
import de.developaway.parley.CallPhase
import de.developaway.parley.Fmt
import de.developaway.parley.HostAudio
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt

private val Ink = Color(0xFFF5F4EF)
private val Dim = Color(0xFF9D9B95)
private val Raised = Color(0xFF2E2C2A)

/** The call (ios CallView): ringing, connecting, Parley speaking, listening, idle — always dark. */
@Composable
fun CallScreen(call: CallController, accent: Color, minimise: () -> Unit) {
    val now by rememberNow(250)
    val t by rememberSeconds()
    val phase = call.phase
    val connecting = phase == CallPhase.dialing || phase == CallPhase.connecting || (phase == CallPhase.active && call.awaitingHost)
    val state = when {
        phase == CallPhase.ringing -> "Eingehender Anruf"
        connecting -> "verbindet…"
        call.hostAudio == HostAudio.speaking -> "spricht"
        call.hostAudio == HostAudio.listening -> "hört zu"
        call.wakeSent -> "ist gleich da"
        else -> "bereit"
    }
    val level = if (phase == CallPhase.active) call.level() else 0f

    Box(Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(Color(0xFF3B2A22), Color(0xFF1C1B1A), Color(0xFF1A1918))))
        .clickable(enabled = false) {}) {
        Column(Modifier.fillMaxSize().safeDrawingPadding().padding(horizontal = 24.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            Box(Modifier.fillMaxWidth().padding(top = 8.dp)) {
                Box(Modifier.size(46.dp).clip(CircleShape).background(Raised).clickable(onClick = minimise), contentAlignment = Alignment.Center) {
                    Icon(Icons.Filled.KeyboardArrowDown, "Verkleinern", tint = Ink)
                }
                Row(Modifier.align(Alignment.Center), verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Filled.GraphicEq, null, tint = Dim, modifier = Modifier.size(20.dp))
                    Spacer(Modifier.width(6.dp))
                    Text("Parley", color = Dim, fontSize = 17.sp, fontWeight = FontWeight.Medium)
                }
            }
            Spacer(Modifier.weight(0.6f))
            Box(Modifier.size(260.dp), contentAlignment = Alignment.Center) {
                if (phase == CallPhase.ringing) {
                    val pulse = (0.5 + 0.5 * sin(t * 3)).toFloat()
                    Canvas(Modifier.fillMaxSize()) {
                        drawCircle(accent.copy(alpha = 0.10f + 0.08f * pulse))
                        drawCircle(accent.copy(alpha = 0.55f), style = Stroke(2.dp.toPx()))
                    }
                }
                Orb(accent, t, level, if (connecting) 0.6f else 1f, Modifier.size(170.dp))
            }
            Spacer(Modifier.height(24.dp))
            // A guest's call says what it is about ("Rückfrage · Website"): smaller, so it fits.
            val name = call.label ?: "Parley"
            Text(name, color = Ink, fontSize = if (name.length > 14) 30.sp else 38.sp, fontWeight = FontWeight.Bold, maxLines = 2,
                textAlign = TextAlign.Center, lineHeight = 36.sp)
            Row {
                Text(state, color = accent, fontSize = 20.sp, fontWeight = FontWeight.Medium)
                if (phase == CallPhase.active && !connecting) Text(" · " + Fmt.clock((now - call.since).toDouble()), color = Dim, fontSize = 20.sp)
                // Muted: said up here, the subtitles below stay readable (as the iPhone).
                if (phase == CallPhase.active && call.muted) Text(" · stumm", color = Color(0xFFE5484D), fontSize = 20.sp)
            }
            Spacer(Modifier.weight(0.4f))
            if (phase == CallPhase.active) {
                Wave(level, accent, Modifier.fillMaxWidth().height(28.dp))
                Spacer(Modifier.height(24.dp))
                Captions(call, Modifier.fillMaxWidth().heightIn(min = 90.dp))
            } else if (phase == CallPhase.ringing) {
                Text(ringText(call.isGuestCall), color = Dim, fontSize = 17.sp, textAlign = TextAlign.Center)
            }
            Spacer(Modifier.weight(0.4f))
            if (phase == CallPhase.ringing) Ringing(call, accent) else InCall(call, accent)
            Spacer(Modifier.height(20.dp))
        }
    }
}

/** Under the caller's name while it rings: an update, or (v7) a question for this phone as a guest. */
fun ringText(guest: Boolean) = if (guest) "Eine Rückfrage für dich." else "Ein Update möchte mit dir sprechen."

@Composable
private fun Ringing(call: CallController, accent: Color) {
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        listOf("In 1 Min." to 60, "In 5 Min." to 300, "Ich rufe zurück" to null).forEach { (label, after) ->
            Text(label, color = Ink, fontSize = 16.sp, modifier = Modifier.clip(CircleShape).background(Raised)
                .border(1.dp, Color(0x22FFFFFF), CircleShape).clickable { call.later(after) }.padding(horizontal = 14.dp, vertical = 9.dp))
        }
    }
    Spacer(Modifier.height(24.dp))
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceEvenly) {
        RoundButton(Icons.Filled.CallEnd, "Ablehnen", Color(0xFFE5484D)) { call.hangUp() }
        RoundButton(Icons.Filled.Call, "Annehmen", Color(0xFF4CB963)) { call.answer() }
    }
}

@Composable
private fun InCall(call: CallController, accent: Color) {
    val active = call.phase == CallPhase.active
    // The iPhone listens for "Hey Parley" and for Sir talking over Parley; here these are buttons.
    when {
        active && call.hostAudio == HostAudio.idle && !call.wakeSent && !call.awaitingHost ->
            Capsule("Sprechen", LocalColors.current) { call.talk() }
        active && call.hostAudio == HostAudio.speaking -> Row(Modifier.clip(CircleShape).background(Raised).clickable { call.interrupt() }
            .padding(horizontal = 16.dp, vertical = 9.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Filled.PanTool, null, tint = Ink, modifier = Modifier.size(16.dp))
            Spacer(Modifier.width(8.dp))
            Text("Unterbrechen", color = Ink, fontSize = 16.sp)
        }
        else -> Spacer(Modifier.height(38.dp))
    }
    Spacer(Modifier.height(24.dp))
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceEvenly) {
        RoundButton(if (call.muted) Icons.Filled.MicOff else Icons.Filled.Mic, "Stumm", if (call.muted) Ink else Raised,
            tint = if (call.muted) Color.Black else Ink) { call.mute(!call.muted) }
        RoundButton(Icons.AutoMirrored.Filled.VolumeUp, "Lautsprecher", if (call.speaker) Ink else Raised,
            tint = if (call.speaker) Color.Black else Ink) { call.useSpeaker(!call.speaker) }
        RoundButton(Icons.Filled.CallEnd, "Auflegen", Color(0xFFE5484D)) { call.hangUp() }
    }
}

@Composable
private fun RoundButton(icon: ImageVector, label: String, fill: Color, tint: Color = Color.White, onClick: () -> Unit) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Box(Modifier.size(80.dp).clip(CircleShape).background(fill).clickable(onClick = onClick), contentAlignment = Alignment.Center) {
            Icon(icon, label, tint = tint, modifier = Modifier.size(32.dp))
        }
        Spacer(Modifier.height(8.dp))
        Text(label, color = Dim, fontSize = 15.sp)
    }
}

/** The spoken line, chunk by chunk: the one being said bright, the next one dim. */
@Composable
private fun Captions(call: CallController, modifier: Modifier) {
    rememberSeconds().value   // re-read the play position every frame
    val cap = call.caption ?: return Spacer(modifier)
    val time = call.captionTime()
    val chunk = cap.chunk(time) ?: return Spacer(modifier)
    val i = cap.chunks.indexOf(chunk)
    Column(modifier, horizontalAlignment = Alignment.CenterHorizontally) {
        Text(cap.words.slice(chunk).joinToString(" "), color = Ink, fontSize = 21.sp, fontWeight = FontWeight.Medium, textAlign = TextAlign.Center)
        cap.chunks.getOrNull(i + 1)?.let { Text(cap.words.slice(it).joinToString(" "), color = Dim, fontSize = 21.sp, textAlign = TextAlign.Center) }
    }
}

/** A row of dots that rise with the level. */
@Composable
private fun Wave(level: Float, color: Color, modifier: Modifier) {
    val t by rememberSeconds()
    val bars = 40
    Canvas(modifier) {
        val w = size.width / bars
        for (i in 0 until bars) {
            val shape = 0.35 + 0.65 * kotlin.math.abs(sin(t * 6 + i * 0.7) * sin(t * 2.3 + i * 0.31))
            val h = maxOf(w * 0.55f, (size.height * level * shape).toFloat())
            drawRoundRect(color.copy(alpha = 0.85f), Offset(i * w, (size.height - h) / 2), Size(w * 0.55f, h), CornerRadius(w * 0.3f))
        }
    }
}

/** Parley's orb: points on a turning sphere that breathes with the voice (ios ParticleOrb, simplified). */
@Composable
private fun Orb(color: Color, t: Double, level: Float, alpha: Float, modifier: Modifier) {
    val points = remember {
        val n = 1100
        val golden = PI * (3 - sqrt(5.0))
        List(n) { i ->
            val y = 1 - (i / (n - 1.0)) * 2
            val r = sqrt(1 - y * y)
            Triple(cos(golden * i) * r, y, sin(golden * i) * r)
        }
    }
    Canvas(modifier) {
        val c = Offset(size.width / 2, size.height / 2)
        val radius = size.minDimension / 2 * (0.86f + 0.14f * level)
        drawCircle(Brush.radialGradient(listOf(color.copy(alpha = 0.22f * alpha), Color.Transparent), c, radius * 1.2f), radius * 1.2f, c)
        val a = t * 0.35
        val (ca, sa) = cos(a) to sin(a)
        val tilt = 0.35
        val (ct, st) = cos(tilt) to sin(tilt)
        for ((x0, y0, z0) in points) {
            val x = x0 * ca + z0 * sa
            val z = -x0 * sa + z0 * ca
            val y = y0 * ct - z * st
            val zz = y0 * st + z * ct
            val wobble = 1 + 0.06 * level * sin(t * 9 + y0 * 6)
            val depth = ((zz + 1) / 2).toFloat()
            drawCircle(color.copy(alpha = (0.2f + 0.8f * depth) * alpha), (0.5f + 0.9f * depth) * density,
                Offset(c.x + (x * radius * wobble).toFloat(), c.y + (y * radius * wobble).toFloat()))
        }
    }
}
