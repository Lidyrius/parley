package de.developaway.parley.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.FilterNone
import androidx.compose.material.icons.filled.MoreHoriz
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.PriorityHigh
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import de.developaway.parley.AppModel
import de.developaway.parley.Session
import de.developaway.parley.SessionState
import de.developaway.parley.SnapshotRow
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Locale

/** The overview's top-bar pill, left of the gear. */
@Composable
fun SnapshotsPill(c: Colors, onClick: () -> Unit) {
    Row(Modifier.height(46.dp).clip(Pill).background(c.card).clickable(onClick = onClick).padding(horizontal = 15.dp),
        verticalAlignment = Alignment.CenterVertically) {
        Icon(Icons.Filled.FilterNone, null, tint = c.accent, modifier = Modifier.size(18.dp))
        Spacer(Modifier.width(7.dp))
        Text("Snapshots", color = c.accent, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, maxLines = 1)
    }
}

/** The "Snapshots" sheet (design 50-snapshots, variant A): the list, saving the current state, and what opening did. */
@Composable
fun SnapshotsSheet(m: AppModel, close: () -> Unit) {
    val c = LocalColors.current
    var saving by remember { mutableStateOf(false) }
    var opening by remember { mutableStateOf<SnapshotRow?>(null) }
    val snap = m.relay.snapshot
    Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(bottom = 28.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp)) {
        val open = opening
        when {
            saving -> SaveView(snap?.sessions.orEmpty().filter { it.state != SessionState.stopped }, m.relay.canSend, c,
                cancel = { saving = false }) { name, ids -> m.saveSnapshot(name, ids); saving = false }
            open != null -> OpenedView(m, open, c) { opening = null }
            else -> ListView(snap?.snapshots.orEmpty(), m.relay.skew, m.relay.canSend, c, close, save = { saving = true },
                open = { opening = it; m.openSnapshot(it.id) }, delete = { m.deleteSnapshot(it.id) })
        }
    }
}

@Composable
private fun TitleRow(title: String, c: Colors, action: String, act: () -> Unit) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(title, fontSize = 24.sp, fontWeight = FontWeight.Bold, color = c.text, maxLines = 1, overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f))
        Text(action, fontSize = 17.sp, color = c.secondary, modifier = Modifier.clip(Pill).clickable(onClick = act).padding(8.dp))
    }
}

@Composable
private fun Label(text: String, c: Colors) =
    Text(text.uppercase(), fontSize = 13.sp, fontWeight = FontWeight.Medium, color = c.secondary, modifier = Modifier.padding(start = 4.dp, top = 6.dp))

private fun count(n: Int) = if (n == 1) "1 Session" else "$n Sessions"

@Composable
private fun ListView(list: List<SnapshotRow>, skew: Double, canSend: Boolean, c: Colors, close: () -> Unit, save: () -> Unit,
                     open: (SnapshotRow) -> Unit, delete: (SnapshotRow) -> Unit) {
    var confirm by remember { mutableStateOf<SnapshotRow?>(null) }
    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
        TitleRow("Snapshots", c, "Fertig", close)
        Text("Ein Snapshot merkt sich Name, Session-ID und Ordner jeder Session.", fontSize = 13.sp, color = c.secondary)
    }
    Row(Modifier.fillMaxWidth().height(50.dp).clip(Pill).background(c.accent).clickable(enabled = canSend, onClick = save).alpha(if (canSend) 1f else 0.45f),
        horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
        Icon(Icons.Filled.FilterNone, null, tint = Color.White, modifier = Modifier.size(18.dp))
        Spacer(Modifier.width(8.dp))
        Text("Aktuellen Stand sichern", color = Color.White, fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
    }
    if (list.isEmpty()) {
        Text("Noch keine Snapshots. Sichern Sie den aktuellen Stand, um ihn später mit einem Tipp wieder zu öffnen.",
            fontSize = 15.sp, color = c.secondary, modifier = Modifier.padding(horizontal = 4.dp, vertical = 8.dp))
        return
    }
    Label("Gesichert · ${list.size}", c)
    list.forEach { s -> SnapshotCard(s, skew, canSend, c, { open(s) }) { confirm = s } }

    confirm?.let { s ->
        AlertDialog({ confirm = null },
            title = { Text("„${s.name}“ löschen?") },
            text = { Text("Die Sessions selbst bleiben, wie sie sind.") },
            confirmButton = { TextButton({ confirm = null; delete(s) }) { Text("Löschen", color = c.red) } },
            dismissButton = { TextButton({ confirm = null }) { Text("Abbrechen") } })
    }
}

@Composable
private fun SnapshotCard(s: SnapshotRow, skew: Double, canSend: Boolean, c: Colors, open: () -> Unit, delete: () -> Unit) {
    var menu by remember { mutableStateOf(false) }
    Column(Modifier.fillMaxWidth().card(c, radius = 18.dp).padding(start = 16.dp, end = 8.dp, top = 10.dp, bottom = 14.dp),
        verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Row(Modifier.weight(1f), verticalAlignment = Alignment.CenterVertically) {
                Text(s.name, fontSize = 17.sp, fontWeight = FontWeight.Bold, color = c.text, maxLines = 1, overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f, fill = false))
                Spacer(Modifier.width(8.dp))
                Text(count(s.sessions.size), fontSize = 13.sp, color = c.secondary, maxLines = 1)
            }
            Box {
                Box(Modifier.size(36.dp).clip(CircleShape).clickable { menu = true }, contentAlignment = Alignment.Center) {
                    Icon(Icons.Filled.MoreHoriz, "Mehr", tint = c.secondary)
                }
                DropdownMenu(menu, { menu = false }, containerColor = c.card) {
                    DropdownMenuItem({ Text("Löschen", color = c.red) }, { menu = false; delete() })
                }
            }
        }
        Text(s.sessions.joinToString(" · ") { it.name }, fontSize = 13.sp, color = c.secondary, maxLines = 2, overflow = TextOverflow.Ellipsis,
            modifier = Modifier.padding(end = 8.dp))
        Row(Modifier.padding(top = 6.dp, end = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            Row(Modifier.clip(Pill).background(c.accent).clickable(enabled = canSend, onClick = open).alpha(if (canSend) 1f else 0.45f)
                .padding(start = 10.dp, end = 14.dp, top = 7.dp, bottom = 7.dp), verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Filled.PlayArrow, null, tint = Color.White, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(3.dp))
                Text("Öffnen", color = Color.White, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
            }
            Spacer(Modifier.weight(1f))
            Text(savedAt(s.at, skew), fontSize = 13.sp, color = c.secondary)
        }
    }
}

/** "heute 14:02", "gestern", else "12.10.". */
private fun savedAt(at: Double, skew: Double): String {
    val d = Calendar.getInstance().apply { timeInMillis = (at - skew).toLong() }
    val today = Calendar.getInstance()
    val yesterday = Calendar.getInstance().apply { add(Calendar.DAY_OF_YEAR, -1) }
    fun same(a: Calendar, b: Calendar) = a.get(Calendar.YEAR) == b.get(Calendar.YEAR) && a.get(Calendar.DAY_OF_YEAR) == b.get(Calendar.DAY_OF_YEAR)
    return when {
        same(d, today) -> "heute " + SimpleDateFormat("HH:mm", Locale.GERMAN).format(d.time)
        same(d, yesterday) -> "gestern"
        else -> SimpleDateFormat("dd.MM.", Locale.GERMAN).format(d.time)
    }
}

/** Name it, tick the sessions (all running ones by default), Sichern. */
@Composable
private fun SaveView(running: List<Session>, canSend: Boolean, c: Colors, cancel: () -> Unit, save: (String, List<String>) -> Unit) {
    var name by remember { mutableStateOf("") }
    var off by remember { mutableStateOf(setOf<String>()) }   // unticked; a session that turns up meanwhile starts ticked
    val ids = running.map { it.id }.filter { it !in off }
    val ok = name.isNotBlank() && ids.isNotEmpty() && canSend
    val focus = remember { FocusRequester() }
    LaunchedEffect(Unit) { focus.requestFocus() }

    Row(verticalAlignment = Alignment.CenterVertically) {
        Text("Abbrechen", fontSize = 17.sp, color = c.secondary, modifier = Modifier.clip(Pill).clickable(onClick = cancel).padding(vertical = 8.dp))
        Spacer(Modifier.weight(1f))
        Text("Sichern", fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = c.accent,
            modifier = Modifier.alpha(if (ok) 1f else 0.4f).clip(Pill).clickable(enabled = ok) { save(name, ids) }.padding(vertical = 8.dp))
    }
    Text("Snapshot sichern", fontSize = 24.sp, fontWeight = FontWeight.Bold, color = c.text)
    OutlinedTextField(name, { name = it }, Modifier.fillMaxWidth().focusRequester(focus), placeholder = { Text("Name, z. B. Kunde Müller") },
        singleLine = true, keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Sentences, imeAction = ImeAction.Done),
        shape = RoundedCornerShape(14.dp), colors = OutlinedTextFieldDefaults.colors(unfocusedContainerColor = c.card, focusedContainerColor = c.card,
            unfocusedBorderColor = c.stroke, focusedBorderColor = c.accent, cursorColor = c.accent))
    Label("Diese Sessions · ${ids.size} von ${running.size}", c)
    Column(Modifier.fillMaxWidth().card(c, radius = 18.dp)) {
        if (running.isEmpty()) Text("Gerade läuft keine Session.", fontSize = 15.sp, color = c.secondary, modifier = Modifier.padding(16.dp))
        running.forEachIndexed { i, s ->
            if (i > 0) HorizontalDivider(Modifier.padding(start = 52.dp), color = c.stroke)
            val on = s.id !in off
            Row(Modifier.fillMaxWidth().clickable { off = if (on) off + s.id else off - s.id }.padding(horizontal = 14.dp, vertical = 10.dp),
                verticalAlignment = Alignment.CenterVertically) {
                if (on) Box(Modifier.size(24.dp).clip(CircleShape).background(c.accent), contentAlignment = Alignment.Center) {
                    Icon(Icons.Filled.Check, "ausgewählt", tint = Color.White, modifier = Modifier.size(16.dp))
                } else Box(Modifier.size(24.dp).border(1.5.dp, c.secondary.copy(alpha = 0.5f), CircleShape))
                Spacer(Modifier.width(14.dp))
                Column(Modifier.weight(1f)) {
                    Text(s.name, fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = c.text, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    // ponytail: the sessions frame has no folder, so the project stands in for it
                    if (s.project.isNotEmpty()) Text(s.project, fontSize = 12.sp, fontFamily = FontFamily.Monospace, color = c.secondary,
                        maxLines = 1, overflow = TextOverflow.Ellipsis)
                }
            }
        }
    }
    Text("Gemerkt werden Name, Session-ID und Ordner.", fontSize = 13.sp, color = c.secondary, modifier = Modifier.padding(horizontal = 4.dp))
}

/** After "Öffnen": one row per session, a spinner until the host says what it did. */
@Composable
private fun OpenedView(m: AppModel, s: SnapshotRow, c: Colors, done: () -> Unit) {
    val result = m.snapshotOpened?.takeIf { it.id == s.id }
    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
        TitleRow(s.name, c, "Fertig", done)
        Text(if (s.sessions.size == 1) "1 Session öffnet sich auf dem Mac im Hintergrund." else "${s.sessions.size} Sessions öffnen sich auf dem Mac im Hintergrund.",
            fontSize = 13.sp, color = c.secondary)
    }
    Column(Modifier.fillMaxWidth().card(c, radius = 18.dp)) {
        s.sessions.forEachIndexed { i, item ->
            if (i > 0) HorizontalDivider(Modifier.padding(start = 52.dp), color = c.stroke)
            val outcome = result?.results?.firstOrNull { it.id == item.id }?.result
            Row(Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
                val look = outcome?.let { outcomeLook(it, c) }
                if (look == null) Box(Modifier.size(24.dp), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator(Modifier.size(18.dp), color = c.secondary, strokeWidth = 2.dp)
                } else Box(Modifier.size(24.dp).clip(CircleShape).background(look.color), contentAlignment = Alignment.Center) {
                    Icon(look.icon, null, tint = Color.White, modifier = Modifier.size(15.dp))
                }
                Spacer(Modifier.width(14.dp))
                Column(Modifier.weight(1f)) {
                    Text(item.name, fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = c.text, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text(look?.text ?: "wird geöffnet …", fontSize = 13.sp, color = look?.let { c.ink(it.color) } ?: c.secondary)
                }
            }
        }
    }
}

private class Look(val color: Color, val icon: ImageVector, val text: String)

private fun outcomeLook(result: String, c: Colors): Look? = when (result) {
    "running" -> Look(c.idle, Icons.Filled.Check, "läuft schon")
    "resumed" -> Look(c.working, Icons.Filled.Refresh, "wird fortgesetzt")
    "started" -> Look(c.waiting, Icons.Filled.Add, "nicht gefunden – neu im Ordner gestartet")
    "missing" -> Look(c.red, Icons.Filled.PriorityHigh, "Ordner fehlt")
    else -> null
}
