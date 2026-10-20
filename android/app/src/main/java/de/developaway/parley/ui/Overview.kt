package de.developaway.parley.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
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
import androidx.compose.material.icons.automirrored.filled.List
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.DirectionsCar
import androidx.compose.material.icons.filled.GridView
import androidx.compose.material.icons.filled.GroupAdd
import androidx.compose.material.icons.filled.Laptop
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Notifications
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.SubdirectoryArrowRight
import androidx.compose.material.icons.filled.WifiOff
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import de.developaway.parley.AppModel
import de.developaway.parley.CallPhase
import de.developaway.parley.ConnectionStatus
import de.developaway.parley.Fmt
import de.developaway.parley.ReminderRow
import de.developaway.parley.Session
import de.developaway.parley.SessionState
import de.developaway.parley.Stats
import de.developaway.parley.Today
import de.developaway.parley.ordered
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Locale

/** The card's one action (ios SessionAction): a put-off call first, else "Fortsetzen". */
private fun action(s: Session): String? = when {
    s.callback != null -> if (s.callback != 0.0) "Jetzt anrufen" else "Rückrufen"
    s.canResume -> "Fortsetzen"
    else -> null
}

/** The state as the card says it — a put-off call first. */
private fun cardState(s: Session, at: Double): String = s.callback?.let {
    if (it == 0.0) "wartet auf Rückruf" else "ruft in ${Fmt.clock(maxOf(0.0, it - at))} an"
} ?: s.asking?.let { "Rückfrage an $it" } ?: Fmt.stateLabel(s)

private fun stateInk(s: Session, c: Colors): Color = when {
    s.callback != null -> c.ink(c.waiting)
    s.state == SessionState.stopped -> c.secondary
    else -> c.ink(c.state(s.state))
}

/** The main screen (design C2): status and switches in one row, today's figures, the sessions as grid or list. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun Overview(m: AppModel, openSession: (String, Boolean) -> Unit, openSettings: () -> Unit) {
    val c = LocalColors.current
    val relay = m.relay
    var detail by remember { mutableStateOf<String?>(null) }
    var snapshots by remember { mutableStateOf(false) }
    var sharing by remember { mutableStateOf<String?>(null) }
    // Only a guest somewhere, no own host: just the shared sessions.
    val own = m.pairing != null || m.demo || m.guests.isEmpty()
    var refreshing by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()

    PullToRefreshBox(refreshing, onRefresh = {
        refreshing = true
        if (m.pairing != null) relay.reconnect()
        m.guestRelays.values.forEach { it.reconnect() }
        scope.launch { delay(700); refreshing = false }
    }, Modifier.fillMaxSize().background(c.background)) {
        Column(Modifier.fillMaxSize().statusBarsPadding().verticalScroll(rememberScrollState()).navigationBarsPadding().padding(horizontal = 16.dp)
            .padding(bottom = 32.dp), verticalArrangement = Arrangement.spacedBy(20.dp)) {
            Box(Modifier.fillMaxWidth().padding(top = 8.dp)) {
                Row(Modifier.align(Alignment.TopEnd), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    if (own) SnapshotsPill(c) { snapshots = true }
                    Box(Modifier.size(46.dp).clip(CircleShape).background(c.card).clickable(onClick = openSettings),
                        contentAlignment = Alignment.Center) { Icon(Icons.Filled.Settings, "Einstellungen", tint = c.accent) }
                }
                Text("Parley", fontSize = 34.sp, fontWeight = FontWeight.Bold, color = c.text, modifier = Modifier.padding(top = 48.dp))
            }
            if (own) StatusHeader(m, relay.status, c)
            m.call.failure?.let { f ->
                Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp)).background(c.red.copy(alpha = 0.12f)).padding(14.dp),
                    verticalAlignment = Alignment.CenterVertically) {
                    Text(f, color = c.text, fontSize = 15.sp, modifier = Modifier.weight(1f))
                    Icon(Icons.Filled.Close, "Schließen", tint = c.secondary, modifier = Modifier.clickable { m.call.failure = null })
                }
            }
            if (own) Content(m, c) { detail = it }
            GuestSection(m) { openSession(it, false) }
        }
    }

    val open = detail?.let { id -> relay.snapshot?.sessions?.firstOrNull { it.id == id } }
    if (open != null) {
        val state = rememberModalBottomSheetState(skipPartiallyExpanded = true)
        ModalBottomSheet({ detail = null }, sheetState = state, containerColor = c.background) {
            SessionSheet(open, relay.skew, c,
                close = { detail = null },
                openHistory = { detail = null; openSession(open.id, false) },
                message = { detail = null; openSession(open.id, true) },
                share = { detail = null; sharing = open.id })
        }
    }
    val shared = sharing?.let { id -> relay.snapshot?.sessions?.firstOrNull { it.id == id } }
    if (shared != null) {
        val state = rememberModalBottomSheetState(skipPartiallyExpanded = true)
        ModalBottomSheet({ sharing = null }, sheetState = state, containerColor = c.background) {
            ShareSessionSheet(m, shared) { sharing = null }
        }
    }
    if (snapshots) {
        val state = rememberModalBottomSheetState(skipPartiallyExpanded = true)
        ModalBottomSheet({ snapshots = false }, sheetState = state, containerColor = c.background) {
            SnapshotsSheet(m) { snapshots = false }
        }
    }
}

@Composable
private fun Content(m: AppModel, c: Colors, open: (String) -> Unit) {
    val relay = m.relay
    when (relay.status) {
        ConnectionStatus.hostOffline -> Notice(c, Icons.Filled.Laptop, "Mac offline",
            "Parley auf dem Mac ist gerade nicht mit dem Relay verbunden. Sobald er wieder online ist, erscheinen hier deine Sessions.")
        ConnectionStatus.unknownRoom -> Notice(c, Icons.Filled.Laptop, "Mac noch nicht verbunden",
            "Parley auf dem Mac hat sich noch nicht beim Relay gemeldet. Öffne Parley auf dem Mac – die Verbindung entsteht dann von selbst.")
        ConnectionStatus.rejected -> Notice(c, Icons.Filled.Lock, "Bitte neu koppeln",
            "Das Relay hat die Kopplung abgelehnt, oder sie stammt aus einer älteren Version. Wähle in Parley auf dem Mac „Handy verbinden…“ und koppele neu.") {
            Capsule("Neu koppeln", c) { m.unpair() }
        }
        ConnectionStatus.unreachable -> Notice(c, Icons.Filled.WifiOff, "Keine Verbindung",
            "Das Relay ist gerade nicht erreichbar. Parley versucht es automatisch weiter.") {
            Capsule("Erneut versuchen", c, filled = false) { relay.reconnect() }
        }
        else -> {
            val snap = relay.snapshot
            if (snap == null) {
                Row(Modifier.fillMaxWidth().padding(top = 80.dp), horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
                    CircularProgressIndicator(Modifier.size(20.dp), color = c.secondary, strokeWidth = 2.dp)
                    Spacer(Modifier.width(10.dp))
                    Text("Verbinde mit dem Relay…", color = c.secondary)
                }
                return
            }
            snap.today?.let { TodayCard(it, c) }
            Sessions(m, snap.sessions, c, open)
            if (snap.reminders.isNotEmpty()) Reminders(snap.reminders, relay.skew, c)
        }
    }
}

/** The connection pill and the Unterwegs / Stumm switches, in one row. */
@Composable
private fun StatusHeader(m: AppModel, status: ConnectionStatus, c: Colors) {
    val color = c.status(status)
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        Row(Modifier.clip(Pill).background(color.copy(alpha = 0.14f)).padding(horizontal = 11.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically) {
            Dot(color)
            Spacer(Modifier.width(7.dp))
            Text(status.label, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = c.text, maxLines = 1)
        }
        Spacer(Modifier.weight(1f))
        // ponytail: no "Stumm" here — the host sends its notifications through APNs only (iPhone)
        PillToggle("Unterwegs", Icons.Filled.DirectionsCar, m.away, c) { m.changeAway(it) }
    }
}

@Composable
fun PillToggle(label: String, icon: ImageVector, on: Boolean, c: Colors, set: (Boolean) -> Unit) {
    val fg = if (on) c.onAccent else c.text   // a light accent in the dark too
    Row(Modifier.clip(Pill).background(if (on) c.accent else c.text.copy(alpha = 0.06f)).clickable { set(!on) }
        .padding(horizontal = 11.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, null, tint = fg, modifier = Modifier.size(17.dp))
        Spacer(Modifier.width(5.dp))
        Text(label, color = fg, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, maxLines = 1)
    }
}

/** Today's figures as one card: cost · updates · spoken, then the 5-h limit and the week as bars. */
@Composable
private fun TodayCard(d: Today, c: Colors) {
    Column(Modifier.fillMaxWidth().card(c).padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            Figure(Fmt.money(d.costUsd), "Kosten heute", c)
            Figure("${d.turns}", "Updates", c)
            Column(horizontalAlignment = Alignment.End) {
                Text("${Math.round(d.spokenSeconds / 60)} min", fontSize = 24.sp, fontWeight = FontWeight.Bold, color = c.text)
                Text("gesprochen", fontSize = 13.sp, color = c.secondary)
            }
        }
        Fmt.limits(d).forEach { (name, p) ->
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(name, fontSize = 13.sp, color = c.secondary, modifier = Modifier.width(72.dp))
                ProgressBar(p / 100, c.accent, c, Modifier.weight(1f))
                Text(Fmt.percent(p), fontSize = 13.sp, fontWeight = FontWeight.Medium, color = c.text, textAlign = TextAlign.End,
                    modifier = Modifier.width(48.dp))
            }
        }
    }
}

@Composable
private fun Sessions(m: AppModel, list: List<Session>, c: Colors, open: (String) -> Unit) {
    val now by rememberNow()
    val at = now + m.relay.skew
    val canSend = m.relay.canSend
    val act: (Session) -> Unit = { s -> if (s.callback != null) m.call.startOutgoing() else m.resume(s.id) }
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Sessions", fontSize = 21.sp, fontWeight = FontWeight.Bold, color = c.text)
            Spacer(Modifier.width(6.dp))
            Text("${list.count { it.state != SessionState.stopped }}", fontSize = 21.sp, color = c.secondary)
            Spacer(Modifier.width(10.dp))
            Row(Modifier.clip(Pill).background(c.text.copy(alpha = 0.06f)).padding(3.dp)) {
                Choice(Icons.Filled.GridView, "Raster", m.asGrid, c) { m.setGrid(true) }
                Choice(Icons.AutoMirrored.Filled.List, "Liste", !m.asGrid, c) { m.setGrid(false) }
            }
            Spacer(Modifier.weight(1f))
            val busy = m.call.phase != CallPhase.none
            Capsule(if (busy) "Zum Anruf" else "Anrufen", c, enabled = canSend || busy) {
                if (busy) m.call.showsScreen = true else m.call.startOutgoing()
            }
        }
        when {
            list.isEmpty() -> Notice(c, Icons.Filled.Notifications, "Keine Sessions",
                "Sobald eine Claude-Code- oder Codex-Session über Parley spricht, erscheint sie hier.")
            m.asGrid -> list.ordered().chunked(2).forEach { row ->
                Row(Modifier.fillMaxWidth().height(IntrinsicSize.Max), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    row.forEach { s -> Tile(s, at, c, canSend, Modifier.weight(1f).fillMaxHeight(), { open(s.id) }) { act(s) } }
                    if (row.size == 1) Spacer(Modifier.weight(1f))
                }
            }
            else -> list.ordered().groupBy { it.group }.forEach { (g, rows) ->
                Text(GROUPS[g], fontSize = 13.sp, color = c.secondary, modifier = Modifier.padding(start = 4.dp, top = 4.dp))
                Column(Modifier.fillMaxWidth().card(c)) {
                    rows.forEachIndexed { i, s ->
                        if (i > 0) HorizontalDivider(Modifier.padding(start = 54.dp), color = c.stroke)
                        ListRow(s, at, c, canSend, { open(s.id) }) { act(s) }
                    }
                }
            }
        }
    }
}

private val GROUPS = listOf("BRAUCHT INPUT", "ARBEITET", "ANGEHALTEN", "BEENDET")

@Composable
private fun Choice(icon: ImageVector, name: String, on: Boolean, c: Colors, pick: () -> Unit) {
    Box(Modifier.size(width = 34.dp, height = 26.dp).clip(Pill).background(if (on) (if (c.dark) Color(0xFF48484A) else Color.White) else Color.Transparent)
        .clickable(onClick = pick), contentAlignment = Alignment.Center) {
        Icon(icon, name, tint = if (on) c.text else c.secondary, modifier = Modifier.size(17.dp))
    }
}

/** A grid card: symbol + time, the last line (or a waveform while it speaks), name, state, at most one action. */
@Composable
private fun Tile(s: Session, at: Double, c: Colors, canSend: Boolean, modifier: Modifier, open: () -> Unit, act: () -> Unit) {
    Column(modifier.heightIn(min = 184.dp).card(c, live = s.voice).clickable(onClick = open).padding(14.dp)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.Top) {
            SessionRing(s, c.state(s.state), at)
            Spacer(Modifier.weight(1f))
            Text(Fmt.cornerTime(s, at), fontSize = 13.sp, color = c.secondary)
        }
        Spacer(Modifier.weight(1f).heightIn(min = 8.dp))
        val line = s.stats?.lastLine
        if (s.isLive) MiniWave(c.state(s.state), Modifier.fillMaxWidth().height(22.dp).padding(bottom = 6.dp))
        else if (!line.isNullOrEmpty()) Text("„$line“", fontSize = 13.sp, fontStyle = FontStyle.Italic, color = c.secondary, maxLines = 2,
            overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(bottom = 6.dp))
        Text(s.name, fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = if (s.state == SessionState.stopped) c.secondary else c.text,
            maxLines = 1, overflow = TextOverflow.Ellipsis)
        Text(cardState(s, at), fontSize = 15.sp, color = stateInk(s, c), maxLines = 1, overflow = TextOverflow.Ellipsis)
        SharedBadge(s.shared, c)
        action(s)?.let { Spacer(Modifier.height(8.dp)); Capsule(it, c, enabled = canSend, onClick = act) }
    }
}

/** A list row: symbol, name and state, time; the last line in one line; an action only when needed. */
@Composable
private fun ListRow(s: Session, at: Double, c: Colors, canSend: Boolean, open: () -> Unit, act: () -> Unit) {
    Row(Modifier.fillMaxWidth().background(if (s.voice) c.accent.copy(alpha = 0.08f) else Color.Transparent).clickable(onClick = open)
        .padding(horizontal = 14.dp, vertical = 12.dp)) {
        SessionRing(s, c.state(s.state), at, 28.dp)
        Spacer(Modifier.width(12.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(s.name, fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = if (s.state == SessionState.stopped) c.secondary else c.text, maxLines = 1)
                Spacer(Modifier.width(8.dp))
                Text(cardState(s, at), fontSize = 15.sp, color = stateInk(s, c), maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                Text(Fmt.cornerTime(s, at), fontSize = 13.sp, color = c.secondary)
            }
            val line = s.stats?.lastLine
            if (s.isLive) MiniWave(c.state(s.state), Modifier.width(96.dp).height(16.dp))
            else if (!line.isNullOrEmpty()) Text("„$line“", fontSize = 15.sp, fontStyle = FontStyle.Italic, color = c.secondary, maxLines = 1, overflow = TextOverflow.Ellipsis)
            SharedBadge(s.shared, c)
            action(s)?.let { Capsule(it, c, enabled = canSend, modifier = Modifier.padding(top = 2.dp), onClick = act) }
        }
    }
}

/** Tapping a card: figures, the agent's task, what it said last, and the way to its history or a message. */
@Composable
private fun SessionSheet(s: Session, skew: Double, c: Colors, close: () -> Unit, openHistory: () -> Unit, message: () -> Unit, share: () -> Unit) {
    val now by rememberNow()
    val at = now + skew
    Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp).padding(bottom = 24.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            SessionRing(s, c.state(s.state), at, 46.dp)
            Spacer(Modifier.width(14.dp))
            Column(Modifier.weight(1f)) {
                Text(s.name, fontSize = 22.sp, fontWeight = FontWeight.Bold, color = c.text, maxLines = 1)
                Text(cardState(s, at) + " · " + Fmt.timer(s, at), fontSize = 15.sp, color = stateInk(s, c))
            }
            Box(Modifier.size(40.dp).clip(CircleShape).background(c.card).border(1.dp, c.stroke, CircleShape).clickable(onClick = close),
                contentAlignment = Alignment.Center) { Icon(Icons.Filled.Close, "Schließen", tint = c.accent) }
        }
        if (s.tasks.isNotEmpty()) Section("Agent", c) { Text(s.tasks.joinToString("\n") { it.description }, color = c.ink(c.purple), fontSize = 17.sp) }
        s.stats?.let { st -> figures(st, at).chunked(2).forEach { pair ->
            Row(Modifier.fillMaxWidth().height(IntrinsicSize.Max), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                pair.forEach { (value, label, bar) ->
                    Column(Modifier.weight(1f).fillMaxHeight().card(c, radius = 18.dp).padding(14.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Text(value, fontSize = 22.sp, fontWeight = FontWeight.Bold, color = c.text, maxLines = 1)
                        bar?.let { ProgressBar(it, c.purple, c) }
                        Text(label, fontSize = 15.sp, color = c.secondary, maxLines = 1)
                    }
                }
                if (pair.size == 1) Spacer(Modifier.weight(1f))
            }
        } }
        s.stats?.lastLine?.takeIf { it.isNotEmpty() }?.let { Section("Zuletzt gesagt", c) { Text("„$it“", fontStyle = FontStyle.Italic, color = c.text, fontSize = 17.sp) } }
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp), modifier = Modifier.padding(top = 4.dp)) {
            Capsule("Verlauf öffnen", c, modifier = Modifier.weight(1f).height(50.dp), onClick = openHistory)
            Capsule("Nachricht", c, filled = false, modifier = Modifier.weight(1f).height(50.dp), onClick = message)
        }
        // v7: share one of the owner's own sessions (a guest's sessions open their history directly).
        Row(Modifier.fillMaxWidth().height(46.dp).clip(Pill).clickable(onClick = share), horizontalArrangement = Arrangement.Center,
            verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Filled.GroupAdd, null, tint = c.accent, modifier = Modifier.size(20.dp))
            Spacer(Modifier.width(8.dp))
            Text(if (s.shared.isEmpty()) "Teilen …" else "Geteilt mit ${s.shared.joinToString(", ") { it.name }}",
                color = c.accent, fontSize = 17.sp, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
    }
}

private fun figures(st: Stats, at: Double): List<Triple<String, String, Double?>> = buildList {
    st.startedAt?.let { add(Triple(Fmt.span(at - it), "Laufzeit", null)) }
    st.costUsd?.let { add(Triple(Fmt.money(it), "Kosten", null)) }
    add(Triple("${st.turns} · ${st.replies}", "Updates · Antworten", null))
    st.contextPercent?.let { add(Triple(Fmt.percent(it), "Kontext", it / 100)) }
}

@Composable
private fun Section(title: String, c: Colors, content: @Composable () -> Unit) {
    Column(Modifier.fillMaxWidth().card(c, radius = 18.dp).padding(16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Text(title.uppercase(), fontSize = 13.sp, color = c.secondary)
        content()
    }
}

/** The host's Wiedervorlagen, soonest first. */
@Composable
private fun Reminders(list: List<ReminderRow>, skew: Double, c: Colors) {
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text("Wiedervorlagen", fontSize = 21.sp, fontWeight = FontWeight.Bold, color = c.text)
        Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(20.dp)).background(c.card).padding(16.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            list.forEach { r ->
                Row {
                    Icon(if (r.to == "Sir") Icons.Filled.Notifications else if (r.after == null) Icons.Filled.Schedule else Icons.Filled.SubdirectoryArrowRight,
                        null, tint = c.accent, modifier = Modifier.size(20.dp))
                    Spacer(Modifier.width(10.dp))
                    Column(Modifier.weight(1f)) {
                        Row {
                            Text(if (r.to == "Sir") "Für dich" else r.to, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = c.text, modifier = Modifier.weight(1f))
                            Text(whenText(r, skew), fontSize = 15.sp, color = c.secondary)
                        }
                        Text(r.text, fontSize = 15.sp, color = c.secondary, maxLines = 3, overflow = TextOverflow.Ellipsis)
                    }
                }
            }
        }
    }
}

/** "heute 17:00", "morgen 09:00", "Mo., 20.10. 09:00" — or "wenn Shirts fertig ist". */
private fun whenText(r: ReminderRow, skew: Double): String {
    val at = r.at ?: return "wenn ${r.after ?: "es"} fertig ist"
    val d = Calendar.getInstance().apply { timeInMillis = (at - skew).toLong() }
    val time = SimpleDateFormat("HH:mm", Locale.GERMAN).format(d.time)
    val today = Calendar.getInstance()
    val tomorrow = Calendar.getInstance().apply { add(Calendar.DAY_OF_YEAR, 1) }
    fun same(a: Calendar, b: Calendar) = a.get(Calendar.YEAR) == b.get(Calendar.YEAR) && a.get(Calendar.DAY_OF_YEAR) == b.get(Calendar.DAY_OF_YEAR)
    return when {
        same(d, today) -> "heute $time"
        same(d, tomorrow) -> "morgen $time"
        else -> SimpleDateFormat("EE, dd.MM. HH:mm", Locale.GERMAN).format(d.time)
    }
}

/** Empty, offline and error states. */
@Composable
fun Notice(c: Colors, icon: ImageVector, title: String, text: String, actions: @Composable () -> Unit = {}) {
    Column(Modifier.fillMaxWidth().padding(top = 40.dp, start = 12.dp, end = 12.dp), horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Icon(icon, null, tint = c.secondary, modifier = Modifier.size(44.dp))
        Text(title, fontSize = 21.sp, fontWeight = FontWeight.Bold, color = c.text)
        Text(text, fontSize = 15.sp, color = c.secondary, textAlign = TextAlign.Center)
        actions()
    }
}
