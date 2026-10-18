package de.developaway.parley.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ContentPaste
import androidx.compose.material.icons.filled.QrCodeScanner
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import de.developaway.parley.AppModel
import de.developaway.parley.Pairing

/** Not paired yet (ios PairingView): the steps, "QR-Code scannen", or paste the link. */
@Composable
fun PairingScreen(m: AppModel, scan: () -> Unit, error: String?, setError: (String?) -> Unit) {
    val c = LocalColors.current
    val clip = LocalClipboardManager.current
    var link by remember { mutableStateOf("") }
    fun use(text: String) = try { m.pair(Pairing.parse(text)); setError(null) } catch (e: Pairing.Invalid) { setError(e.message) }

    Column(Modifier.fillMaxSize().background(c.background).statusBarsPadding().imePadding().verticalScroll(rememberScrollState()).navigationBarsPadding()
        .padding(horizontal = 20.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        Spacer(Modifier.height(56.dp))
        AppMark(c.accent, Modifier.size(96.dp))
        Spacer(Modifier.height(24.dp))
        Text("Parley auf dem Handy", fontSize = 32.sp, fontWeight = FontWeight.Bold, color = c.text, textAlign = TextAlign.Center)
        Spacer(Modifier.height(10.dp))
        Text("Alle Sessions deines Macs im Blick – und mit einem Tipp fortgesetzt.", fontSize = 17.sp, color = c.secondary, textAlign = TextAlign.Center)
        Spacer(Modifier.height(28.dp))
        Column(Modifier.fillMaxWidth().card(c).padding(20.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
            listOf("Öffne Parley auf dem Mac.", "Wähle im Menü „Handy verbinden…“.", "Scanne den QR-Code – oder füge den Link hier ein.")
                .forEachIndexed { i, s ->
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Box(Modifier.size(30.dp).clip(CircleShape).background(c.accent), contentAlignment = Alignment.Center) {
                            Text("${i + 1}", color = Color.White, fontWeight = FontWeight.SemiBold)
                        }
                        Spacer(Modifier.width(14.dp))
                        Text(s, fontSize = 17.sp, color = c.text)
                    }
                }
        }
        Spacer(Modifier.height(24.dp))
        Row(Modifier.fillMaxWidth().height(56.dp).clip(RoundedCornerShape(28.dp)).background(c.accent).clickable(onClick = scan),
            horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Filled.QrCodeScanner, null, tint = Color.White)
            Spacer(Modifier.width(10.dp))
            Text("QR-Code scannen", color = Color.White, fontSize = 18.sp, fontWeight = FontWeight.SemiBold)
        }
        Spacer(Modifier.height(14.dp))
        Row(verticalAlignment = Alignment.CenterVertically) {
            OutlinedTextField(link, { link = it }, Modifier.weight(1f), placeholder = { Text("parley://pair?…") }, singleLine = true,
                shape = RoundedCornerShape(14.dp), colors = OutlinedTextFieldDefaults.colors(unfocusedContainerColor = c.card, focusedContainerColor = c.card,
                    unfocusedBorderColor = c.stroke, focusedBorderColor = c.accent))
            Spacer(Modifier.width(10.dp))
            Box(Modifier.size(52.dp).clip(RoundedCornerShape(14.dp)).background(c.accent.copy(alpha = 0.18f))
                .clickable { val t = link.ifBlank { clip.getText()?.text ?: "" }; link = t; use(t) }, contentAlignment = Alignment.Center) {
                Icon(Icons.Filled.ContentPaste, "Einfügen und koppeln", tint = c.accent)
            }
        }
        error?.let { Text(it, color = c.red, fontSize = 15.sp, textAlign = TextAlign.Center, modifier = Modifier.padding(top = 14.dp)) }
    }
}

/** The app mark: the waveform on a terracotta tile. */
@Composable
fun AppMark(accent: Color, modifier: Modifier) {
    Canvas(modifier) {
        drawRoundRect(Brush.verticalGradient(listOf(Color(0xFFE38D70), accent)), cornerRadius = CornerRadius(size.width * 0.26f))
        val heights = listOf(0.22f, 0.4f, 0.62f, 0.4f, 0.22f)
        val w = size.width * 0.045f
        heights.forEachIndexed { i, h ->
            val x = size.width * (0.32f + i * 0.09f)
            drawRoundRect(Color.White, Offset(x - w / 2, size.height * (0.5f - h / 2)), Size(w, size.height * h), CornerRadius(w / 2))
        }
    }
}
