package de.developaway.parley.ui

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Intent
import android.speech.tts.TextToSpeech
import androidx.activity.compose.BackHandler
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
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.VolumeUp
import androidx.compose.material.icons.filled.AddLink
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.ContentPaste
import androidx.compose.material.icons.filled.GppGood
import androidx.compose.material.icons.filled.GroupAdd
import androidx.compose.material.icons.filled.LooksOne
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.People
import androidx.compose.material.icons.filled.Share
import androidx.compose.material.icons.filled.Timer
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.ModalBottomSheetProperties
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.SheetValue
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.qrcode.QRCodeWriter
import com.google.zxing.qrcode.decoder.ErrorCorrectionLevel
import de.developaway.parley.AppModel
import de.developaway.parley.Fmt
import de.developaway.parley.GuestAsk
import de.developaway.parley.GuestRoles
import de.developaway.parley.GuestShare
import de.developaway.parley.JoinLink
import de.developaway.parley.JoinRequest
import de.developaway.parley.Prefs
import de.developaway.parley.Relay
import de.developaway.parley.Session
import de.developaway.parley.codeDigits
import de.developaway.parley.ShareTag
import java.util.Locale

// Shared sessions (v7, docs/design/screens/ios/60-multiplayer; ios/ParleyMobile/ShareViews.swift):
// the owner's invite and yes/no, the guest's join, his section on the overview and his questions.

/** "geteilt mit Max · Marketing" under a session that has guests. */
@Composable
fun SharedBadge(tags: List<ShareTag>, c: Colors) {
    val first = tags.firstOrNull() ?: return
    val ink = c.ink(c.idle)
    Row(verticalAlignment = Alignment.CenterVertically) {
        Icon(Icons.Filled.People, null, tint = ink, modifier = Modifier.size(15.dp))
        Spacer(Modifier.width(5.dp))
        Text(if (tags.size == 1) "geteilt mit ${first.name}${if (first.role.isEmpty()) "" else " · ${first.role}"}"
             else "geteilt mit ${tags.joinToString(", ") { it.name }}",
            fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = ink, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

/** A round initial in a colour of its own. */
@Composable
fun Avatar(name: String, c: Colors, size: Dp = 30.dp) {
    Box(Modifier.size(size).clip(CircleShape).background(c.idle), contentAlignment = Alignment.Center) {
        Text(name.take(1).uppercase(), color = c.on(c.idle), fontWeight = FontWeight.Bold, fontSize = (size.value * 0.45f).sp)
    }
}

/** A QR code, crisp at any size (ZXing's encoder, which the scanner brings along). */
@Composable
fun QrCode(text: String, modifier: Modifier = Modifier) {
    val matrix = remember(text) {
        runCatching {
            QRCodeWriter().encode(text, BarcodeFormat.QR_CODE, 0, 0,
                mapOf(EncodeHintType.ERROR_CORRECTION to ErrorCorrectionLevel.M, EncodeHintType.MARGIN to 0))
        }.getOrNull()
    } ?: return
    Canvas(modifier.clip(RoundedCornerShape(14.dp)).background(Color.White).padding(10.dp)) {
        val cell = size.width / matrix.width
        for (y in 0 until matrix.height) for (x in 0 until matrix.width) {
            if (matrix[x, y]) drawRect(Color.Black, Offset(x * cell, y * cell), Size(cell + 0.5f, cell + 0.5f))
        }
    }
}

@Composable
private fun Caps(text: String, c: Colors) =
    Text(text.uppercase(), fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = c.secondary, modifier = Modifier.padding(start = 4.dp, top = 6.dp))

@Composable
private fun Field(value: String, set: (String) -> Unit, placeholder: String, c: Colors, modifier: Modifier = Modifier, single: Boolean = false,
                  capitalization: KeyboardCapitalization = KeyboardCapitalization.Sentences) {
    OutlinedTextField(value, set, modifier.fillMaxWidth(), placeholder = { Text(placeholder) }, singleLine = single, maxLines = if (single) 1 else 8,
        keyboardOptions = KeyboardOptions(capitalization = capitalization),
        shape = RoundedCornerShape(14.dp), colors = OutlinedTextFieldDefaults.colors(unfocusedContainerColor = c.card, focusedContainerColor = c.card,
            unfocusedBorderColor = c.stroke, focusedBorderColor = c.accent))
}

@Composable
private fun BigButton(text: String, c: Colors, enabled: Boolean = true, filled: Boolean = true, icon: ImageVector? = null,
                      modifier: Modifier = Modifier.fillMaxWidth(), onClick: () -> Unit) {
    Row(modifier.height(50.dp).alpha(if (enabled) 1f else 0.45f).clip(Pill).background(if (filled) c.accent else c.accent.copy(alpha = 0.14f))
        .clickable(enabled = enabled, onClick = onClick),
        horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
        icon?.let { Icon(it, null, tint = if (filled) c.onAccent else c.accent, modifier = Modifier.size(18.dp)); Spacer(Modifier.width(8.dp)) }
        Text(text, color = if (filled) c.onAccent else c.accent, fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
    }
}

// MARK: the owner's side

/** "Session teilen": a one-time link (QR + share sheet) and who is in already. */
@Composable
fun ShareSessionSheet(m: AppModel, session: Session, close: () -> Unit) {
    val c = LocalColors.current
    val ctx = LocalContext.current
    val link = m.shareLinks[session.id]
    LaunchedEffect(session.id) { if (m.shareLinks[session.id] == null) m.share(session.id) }
    Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(bottom = 28.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Session teilen", fontSize = 24.sp, fontWeight = FontWeight.Bold, color = c.text, modifier = Modifier.weight(1f))
                Text("Fertig", fontSize = 17.sp, color = c.secondary, modifier = Modifier.clip(Pill).clickable(onClick = close).padding(8.dp))
            }
            Text("Wer den Link öffnet, kann dieser einen Session folgen, mitschreiben und Rückfragen zu seinem Bereich bekommen. Sie lassen ihn vorher herein.",
                fontSize = 15.sp, color = c.secondary)
        }
        Column(Modifier.fillMaxWidth().card(c).padding(18.dp), horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(12.dp)) {
            if (link != null) {
                QrCode(link, Modifier.size(190.dp))
                Text(link.take(34) + "…", fontSize = 12.sp, fontFamily = FontFamily.Monospace, color = c.secondary, maxLines = 1)
            } else Box(Modifier.size(190.dp), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(Modifier.size(24.dp), color = c.secondary, strokeWidth = 2.dp)
            }
            Row(horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                listOf(Icons.Filled.Lock to "Ende-zu-Ende", Icons.Filled.LooksOne to "einmal nutzbar", Icons.Filled.Timer to "24 h").forEach { (icon, text) ->
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(icon, null, tint = c.secondary, modifier = Modifier.size(14.dp))
                        Spacer(Modifier.width(4.dp))
                        Text(text, fontSize = 12.sp, color = c.secondary)
                    }
                }
            }
        }
        if (link != null) BigButton("Link teilen …", c, icon = Icons.Filled.Share) {
            val send = Intent(Intent.ACTION_SEND).setType("text/plain")
                .putExtra(Intent.EXTRA_TEXT, "Komm in meine Parley-Session „${session.name}“.\n$link")
            ctx.startActivity(Intent.createChooser(send, null))
        }
        if (session.shared.isNotEmpty()) {
            Caps("Schon dabei", c)
            Column(Modifier.fillMaxWidth().card(c)) {
                session.shared.forEachIndexed { i, g ->
                    if (i > 0) HorizontalDivider(Modifier.padding(start = 56.dp), color = c.stroke)
                    Row(Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 11.dp), verticalAlignment = Alignment.CenterVertically) {
                        Avatar(g.name, c)
                        Spacer(Modifier.width(12.dp))
                        Column(Modifier.weight(1f)) {
                            Text(g.name, fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = c.text)
                            if (g.role.isNotEmpty()) Text(g.role, fontSize = 13.sp, color = c.secondary)
                        }
                        Text("Entfernen", fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = c.red,
                            modifier = Modifier.clip(Pill).clickable { m.removeShare(g.id) }.padding(6.dp))
                    }
                }
            }
        }
    }
}

/** The share code in four boxes — clay while typed or shown, red when wrong, green once it matches. */
@Composable
private fun CodeBoxes(code: String, c: Colors, tint: Color = c.accent) {
    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        for (i in 0 until 4) {
            val digit = code.getOrNull(i)
            Box(Modifier.size(56.dp, 66.dp).clip(RoundedCornerShape(14.dp)).background(c.card)
                .border(2.dp, if (digit != null || i == code.length) tint else c.stroke, RoundedCornerShape(14.dp)),
                contentAlignment = Alignment.Center) {
                Text(digit?.toString() ?: "", fontSize = 30.sp, fontWeight = FontWeight.Bold, fontFamily = FontFamily.Monospace, color = c.text)
            }
        }
    }
}

/**
 * "Max möchte beitreten": first the code Max sends (his phone shows it) — then his role, what he
 * may do, the owner's own role — and yes or no.
 */
@Composable
private fun ApproveJoin(m: AppModel, r: JoinRequest) {
    val c = LocalColors.current
    val ctx = LocalContext.current
    var entered by remember(r.id) { mutableStateOf("") }
    var checked by remember(r.id) { mutableStateOf(r.code == null) }
    var role by remember(r.id) { mutableStateOf("") }
    var listen by remember(r.id) { mutableStateOf(false) }
    var full by remember(r.id) { mutableStateOf(false) }
    var mine by remember(r.id) { mutableStateOf(Prefs.string(ctx, "myShareRole")) }
    val earlier = remember(r.id) { GuestRoles.of(ctx, r) }
    val focus = remember { FocusRequester() }
    fun type(text: String) {
        entered = text.filter { it in '0'..'9' }.take(4)
        if (entered == r.code) checked = true
    }
    val wrong = !checked && entered.length == 4
    Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).imePadding().padding(horizontal = 20.dp).padding(bottom = 28.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Column(Modifier.fillMaxWidth().padding(bottom = 6.dp), horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Avatar(r.name, c, 56.dp)
            Text("${r.name} möchte beitreten", fontSize = 24.sp, fontWeight = FontWeight.Bold, color = c.text, textAlign = TextAlign.Center)
            Text("Session „${r.label}“${r.device?.takeIf { it.isNotEmpty() }?.let { " · $it" } ?: ""}", fontSize = 15.sp, color = c.secondary,
                textAlign = TextAlign.Center)
            r.code?.let { code ->
                if (!checked) {
                    Text("Geben Sie den Code ein, den ${r.name} Ihnen schickt.", fontSize = 15.sp, color = c.text, textAlign = TextAlign.Center,
                        modifier = Modifier.padding(top = 6.dp))
                    BasicTextField(entered, ::type, Modifier.focusRequester(focus),
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.NumberPassword)) {
                        CodeBoxes(entered, c, if (wrong) c.red else c.accent)
                    }
                    LaunchedEffect(Unit) { focus.requestFocus() }
                    if (wrong) Text("Der Code stimmt nicht", fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = c.red)
                    TextButton({
                        val clip = ctx.getSystemService(ClipboardManager::class.java)?.primaryClip
                        clip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.coerceToText(ctx)?.toString()?.let(::codeDigits)?.let(::type)
                    }) {
                        Icon(Icons.Filled.ContentPaste, null, tint = c.accent, modifier = Modifier.size(18.dp))
                        Spacer(Modifier.width(6.dp))
                        Text("Einfügen", color = c.accent, fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
                    }
                    Text("Kein Code bekommen? Fragen Sie kurz nach.", fontSize = 13.sp, color = c.secondary, textAlign = TextAlign.Center)
                } else {
                    CodeBoxes(code, c, c.green)
                    Text("✓ Code stimmt, es ist ${r.name}", fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = c.ink(c.green))
                }
            }
        }
        if (!checked) BigButton("Ablehnen", c, filled = false) { m.removeShare(r.id) }
        else {
            Caps("Wofür ist ${r.name} zuständig?", c)
            Field(role, { role = it }, "z. B. Marketing und Rückfragen zu Texten", c)
            if (earlier.isNotEmpty()) Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("Zuletzt:", fontSize = 13.sp, color = c.secondary, modifier = Modifier.padding(start = 4.dp))
                earlier.forEach { e ->
                    Text(e, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = c.accent, maxLines = 1,
                        modifier = Modifier.clip(Pill).background(c.accent.copy(alpha = 0.12f)).clickable { role = e }
                            .padding(horizontal = 12.dp, vertical = 7.dp))
                }
            }
            Caps("Darf", c)
            Row(Modifier.fillMaxWidth().clip(Pill).background(c.text.copy(alpha = 0.06f)).padding(3.dp)) {
                listOf(false to "Lesen und schreiben", true to "Nur zuhören").forEach { (value, text) ->
                    Box(Modifier.weight(1f).height(36.dp).clip(Pill)
                        .background(if (listen == value) (if (c.dark) Color(0xFF48484A) else Color.White) else Color.Transparent)
                        .clickable { listen = value }, contentAlignment = Alignment.Center) {
                        Text(text, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = if (listen == value) c.text else c.secondary)
                    }
                }
            }
            Row(Modifier.fillMaxWidth().card(c, radius = 14.dp).padding(horizontal = 14.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("Verlauf ab Beitritt", fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = c.text)
                    Text("Ältere Nachrichten bleiben verborgen", fontSize = 13.sp, color = c.secondary)
                }
                Switch(!full, { full = !it }, colors = SwitchDefaults.colors(checkedTrackColor = c.idle, checkedThumbColor = Color.White))
            }
            Caps("Und Ihre Rolle hier?", c)
            Field(mine, { mine = it }, "z. B. Technik und Entscheidungen", c)
            BigButton("${r.name} zulassen", c, modifier = Modifier.fillMaxWidth().padding(top = 8.dp)) {
                Prefs.set(ctx, "myShareRole", mine)
                GuestRoles.remember(ctx, r, role)
                m.approve(r, role, listen, full, mine)
            }
            BigButton("Ablehnen", c, filled = false) { m.removeShare(r.id) }
            Text("Freigaben für Befehle und Dateien kommen immer zu Ihnen.", fontSize = 13.sp, color = c.secondary,
                textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth())
        }
    }
}

// MARK: the guest's side

/** A share link opened on this phone: say who you are, then wait for the owner's yes. */
@Composable
private fun JoinView(m: AppModel, link: JoinLink, close: () -> Unit) {
    val c = LocalColors.current
    val ctx = LocalContext.current
    var name by remember { mutableStateOf(Prefs.string(ctx, "guestName")) }
    val host = link.host.ifEmpty { null }
    Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).imePadding().padding(horizontal = 24.dp).padding(bottom = 28.dp),
        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Row(Modifier.fillMaxWidth()) {
            Text("Abbrechen", fontSize = 17.sp, color = c.secondary, modifier = Modifier.clip(Pill).clickable(onClick = close).padding(8.dp))
        }
        Icon(Icons.Filled.GroupAdd, null, tint = c.accent, modifier = Modifier.size(48.dp))
        Text("${host ?: "Jemand"} lädt Sie ein", fontSize = 24.sp, fontWeight = FontWeight.Bold, color = c.text, textAlign = TextAlign.Center)
        Text("zur Session „${link.label}“. Sie folgen ihr, schreiben mit und bekommen Rückfragen zu Ihrem Bereich.",
            fontSize = 15.sp, color = c.secondary, textAlign = TextAlign.Center)
        Field(name, { name = it }, "Ihr Name", c, single = true, capitalization = KeyboardCapitalization.Words)
        BigButton("Beitreten", c, enabled = name.isNotBlank()) {
            Prefs.set(ctx, "guestName", name.trim())
            m.join(link, name)
        }
        Text("Ende-zu-Ende verschlüsselt. ${host ?: "Der Gastgeber"} lässt Sie herein und kann Sie jederzeit entfernen.",
            fontSize = 13.sp, color = c.secondary, textAlign = TextAlign.Center)
    }
}

/**
 * After "Beitreten": the four digits to send the owner — he types them in before he lets this phone
 * in. Closes by itself once he has; a dead invite says so instead.
 */
@Composable
private fun JoinCodeView(m: AppModel, g: GuestShare, close: () -> Unit) {
    val c = LocalColors.current
    val ctx = LocalContext.current
    val host = g.host.ifEmpty { "den Gastgeber" }
    val dead = m.guestRelays[g.id]?.failure == Relay.Failure.unknownRoom
    Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 24.dp).padding(bottom = 28.dp),
        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Row(Modifier.fillMaxWidth()) {
            Text("Schließen", fontSize = 17.sp, color = c.secondary, modifier = Modifier.clip(Pill).clickable(onClick = close).padding(8.dp))
        }
        Avatar(g.host.ifEmpty { g.label }, c, 56.dp)
        if (dead) {
            Icon(Icons.Filled.AddLink, null, tint = c.secondary, modifier = Modifier.size(28.dp))
            Text("Einladung abgelaufen oder schon benutzt. Bitten Sie um einen neuen Link.", fontSize = 17.sp, color = c.secondary,
                textAlign = TextAlign.Center)
        } else {
            Text("Fast drin, ${g.name}", fontSize = 24.sp, fontWeight = FontWeight.Bold, color = c.text, textAlign = TextAlign.Center)
            Text("Schicken Sie diesen Code an $host. Damit weiß $host, dass wirklich Sie es sind.", fontSize = 15.sp, color = c.secondary,
                textAlign = TextAlign.Center)
            CodeBoxes(g.code, c)
            Text("Session „${g.label}“ · gilt nur für diese Anfrage", fontSize = 13.sp, color = c.secondary, textAlign = TextAlign.Center)
            val text = "Mein Parley-Code für „${g.label}“: ${g.code}"
            BigButton("Code an $host schicken", c, icon = Icons.Filled.Share) {
                ctx.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, text), null))
            }
            TextButton({ ctx.getSystemService(ClipboardManager::class.java)?.setPrimaryClip(ClipData.newPlainText("Parley-Code", g.code)) },
                Modifier.fillMaxWidth()) {
                Icon(Icons.Filled.ContentCopy, null, tint = c.accent, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(6.dp))
                Text("Code kopieren", color = c.accent, fontSize = 17.sp)
            }
        }
    }
}

/** On the overview: the sessions others share with this phone, or the wait for their yes. */
@Composable
fun GuestSection(m: AppModel, open: (String) -> Unit) {
    if (m.guests.isEmpty()) return
    val c = LocalColors.current
    val now by rememberNow()
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Text("Geteilt mit Ihnen", fontSize = 21.sp, fontWeight = FontWeight.Bold, color = c.text)
        m.guests.forEach { g ->
            val r = m.guestRelays[g.id]
            val s = r?.snapshot?.sessions?.firstOrNull()
            Column(Modifier.fillMaxWidth().card(c).padding(14.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(if (g.host.isEmpty()) g.label else "${g.host} · ${g.label}", fontSize = 15.sp, fontWeight = FontWeight.SemiBold,
                        color = c.ink(c.idle), maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                    Text(if (g.active) "Verlassen" else "Abbrechen", fontSize = 15.sp, color = c.red,
                        modifier = Modifier.clip(Pill).clickable { m.leave(g.id) }.padding(6.dp))
                }
                when {
                    // B2: the invite's room is gone — expired, already used, or ended.
                    !g.active && r?.failure == Relay.Failure.unknownRoom -> Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Filled.AddLink, null, tint = c.secondary, modifier = Modifier.size(18.dp))
                        Spacer(Modifier.width(8.dp))
                        Text("Einladung abgelaufen oder schon benutzt. Bitten Sie um einen neuen Link.", fontSize = 15.sp, color = c.secondary)
                    }
                    !g.active -> {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            CircularProgressIndicator(Modifier.size(16.dp), color = c.secondary, strokeWidth = 2.dp)
                            Spacer(Modifier.width(10.dp))
                            Text("Warte, bis ${g.host.ifEmpty { "der Gastgeber" }} Sie hereinlässt …", fontSize = 15.sp, color = c.secondary)
                        }
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Filled.GppGood, null, tint = c.ink(c.idle), modifier = Modifier.size(17.dp))
                            Spacer(Modifier.width(5.dp))
                            Text("Prüfcode ${g.code}", fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = c.ink(c.idle))
                        }
                    }
                    s != null -> Row(Modifier.fillMaxWidth().clickable { open(s.id) }, verticalAlignment = Alignment.CenterVertically) {
                        SessionRing(s, c.state(s.state), now + (r?.skew ?: 0.0), 26.dp)
                        Spacer(Modifier.width(12.dp))
                        Column(Modifier.weight(1f)) {
                            Text(s.name, fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = c.text)
                            Text(if (g.role.isEmpty()) Fmt.stateLabel(s) else "Ihre Rolle: ${g.role}", fontSize = 15.sp, color = c.secondary,
                                maxLines = 1, overflow = TextOverflow.Ellipsis)
                        }
                        Icon(Icons.Filled.ChevronRight, null, tint = c.secondary)
                    }
                    else -> Text("Verbinde …", fontSize = 15.sp, color = c.secondary)
                }
            }
        }
    }
}

/**
 * R3: a question for this phone as a guest — read aloud, answered by a predicted answer, typing
 * or the keyboard's dictation; or given to the owner. Unanswered, it goes to him by itself.
 */
@Composable
private fun GuestAskScreen(m: AppModel, ask: GuestAsk) {
    val c = LocalColors.current
    val ctx = LocalContext.current
    val share = m.guestShare(ask.session)
    val host = share?.host?.ifEmpty { null } ?: "den Gastgeber"
    var text by remember(ask.id) { mutableStateOf("") }
    val opened = remember(ask.id) { System.currentTimeMillis() }
    val now by rememberNow()
    val voice = remember { arrayOfNulls<TextToSpeech>(1) }
    fun read() { voice[0]?.let { it.stop(); it.speak(ask.text, TextToSpeech.QUEUE_FLUSH, null, ask.id) } }
    DisposableEffect(ask.id) {
        lateinit var tts: TextToSpeech
        tts = TextToSpeech(ctx) { status ->
            if (status == TextToSpeech.SUCCESS) { tts.language = Locale.GERMANY; voice[0] = tts; read() }
        }
        onDispose { voice[0] = null; tts.stop(); tts.shutdown() }
    }
    BackHandler {}   // answered, passed on or timed out — not swiped away
    Column(Modifier.fillMaxSize().background(c.background).statusBarsPadding().navigationBarsPadding().imePadding()
        .verticalScroll(rememberScrollState()).padding(20.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Row(verticalAlignment = Alignment.Top) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text("RÜCKFRAGE · ${ask.label.uppercase()}", fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = c.secondary)
                share?.role?.takeIf { it.isNotEmpty() }?.let { Text("für Sie · $it", fontSize = 15.sp, color = c.ink(c.idle)) }
            }
            Box(Modifier.size(44.dp).clip(CircleShape).background(c.card).clickable { read() }, contentAlignment = Alignment.Center) {
                Icon(Icons.AutoMirrored.Filled.VolumeUp, "Vorlesen", tint = c.accent)
            }
        }
        Text(ask.text, fontSize = 21.sp, fontWeight = FontWeight.SemiBold, color = c.text, lineHeight = 28.sp)
        ask.seconds?.let { seconds ->
            val left = maxOf(0L, seconds - (now - opened) / 1000)
            Text(if (left > 0) "Geht in $left s an $host, wenn Sie nicht antworten." else "Geht jetzt an $host.", fontSize = 13.sp, color = c.secondary)
        }
        ask.replies?.takeIf { it.isNotEmpty() }?.let { replies ->
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                replies.forEach { r ->
                    Text(r, fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = c.accent,
                        modifier = Modifier.clip(Pill).background(c.accent.copy(alpha = 0.12f)).clickable { m.answer(ask, r) }
                            .padding(horizontal = 14.dp, vertical = 10.dp))
                }
            }
        }
        Field(text, { text = it }, "Antwort – tippen oder per Diktat (Mikrofon auf der Tastatur)", c, Modifier.heightIn(min = 72.dp))
        BigButton("Antworten", c, enabled = text.isNotBlank()) { m.answer(ask, text.trim()) }
        TextButton({ m.answer(ask, "", pass = true) }, Modifier.fillMaxWidth()) { Text("An $host abgeben", color = c.accent, fontSize = 17.sp) }
    }
}

/**
 * Everything of a share that comes up by itself, over whatever is on screen: the join sheet for an
 * opened link, a guest asking to be let in, a message from a share's host, a question as a guest.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ShareOverlays(m: AppModel) {
    val c = LocalColors.current
    // The join sheet turns into the code to send once "Beitreten" is tapped — gone when he is let in.
    val joining = m.joining?.let { id -> m.guests.firstOrNull { it.id == id && !it.active } }
    if (m.joining != null && joining == null) LaunchedEffect(m.joining) { m.joining = null }
    if (m.pendingJoin != null || joining != null) {
        val state = rememberModalBottomSheetState(skipPartiallyExpanded = true)
        ModalBottomSheet({ m.pendingJoin = null; m.joining = null }, sheetState = state, containerColor = c.background) {
            if (joining != null) JoinCodeView(m, joining) { m.joining = null }
            else m.pendingJoin?.let { link -> JoinView(m, link) { m.pendingJoin = null } }
        }
    }
    m.joinRequests.firstOrNull()?.let { r ->
        // A yes or a no — not swiped away.
        val state = rememberModalBottomSheetState(skipPartiallyExpanded = true, confirmValueChange = { it != SheetValue.Hidden })
        ModalBottomSheet({}, sheetState = state, containerColor = c.background,
            properties = ModalBottomSheetProperties(shouldDismissOnBackPress = false)) { ApproveJoin(m, r) }
    }
    m.guestNotice?.let { text ->
        AlertDialog({ m.guestNotice = null }, title = { Text("Parley") }, text = { Text(text) },
            confirmButton = { TextButton({ m.guestNotice = null }) { Text("OK") } })
    }
    // Steps aside while a call rings or runs — the owner's host may be asking it on the phone right now.
    if (!m.call.isBusy) m.guestAsks.firstOrNull()?.let { GuestAskScreen(m, it) }
}
