package de.developaway.parley.ui

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Image
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import de.developaway.parley.AppModel
import de.developaway.parley.ChatItem
import de.developaway.parley.Fmt
import kotlinx.coroutines.delay

/** A session's history, laid out like the Claude app's chat (ios SessionView), and a message field. */
@Composable
fun SessionScreen(m: AppModel, id: String, compose: Boolean, back: () -> Unit) {
    val c = LocalColors.current
    val relay = m.relay(id)
    val session = relay.snapshot?.sessions?.firstOrNull { it.id == id }
    // v7: in a shared session every message says who wrote it — mine on the right, others' left.
    val guest = m.guestShare(id)
    val shared = guest != null || m.relay.snapshot?.sessions?.firstOrNull { it.id == id }?.shared?.isNotEmpty() == true
    val items = m.histories[id]
    val pending = m.pending[id] ?: emptyList()
    var text by rememberSaveable { mutableStateOf("") }
    val focus = remember { FocusRequester() }
    val list = rememberLazyListState()
    val rows = remember(items) { rows(items ?: emptyList()) }

    LaunchedEffect(id) { while (true) { m.loadHistory(id); delay(3_000) } }
    LaunchedEffect(compose) { if (compose) { delay(300); runCatching { focus.requestFocus() } } }
    LaunchedEffect(rows.size, pending.size) { if (rows.isNotEmpty()) list.animateScrollToItem(rows.size + pending.size) }

    Column(Modifier.fillMaxSize().background(c.background).imePadding()) {
        Row(Modifier.fillMaxWidth().statusBarsPadding().padding(horizontal = 12.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(44.dp).clip(CircleShape).background(c.card).clickable(onClick = back), contentAlignment = Alignment.Center) {
                Icon(Icons.AutoMirrored.Filled.ArrowBack, "Zurück", tint = c.text)
            }
            Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally) {
                Text(session?.name ?: "Session", fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = c.text, maxLines = 1)
                session?.let { Text(Fmt.stateLabel(it), fontSize = 13.sp, color = c.secondary) }
            }
            Box(Modifier.size(44.dp), contentAlignment = Alignment.Center) {
                session?.let { SessionRing(it, c.state(it.state), relay.hostNow(), 26.dp) }
            }
        }
        LazyColumn(Modifier.weight(1f).fillMaxWidth(), state = list, contentPadding = androidx.compose.foundation.layout.PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp)) {
            if (items == null) item { Text("Lade Verlauf…", color = c.secondary) }
            if (m.hasOlder[id] == true) item {
                Text("Ältere laden", color = c.accent, fontWeight = FontWeight.SemiBold, modifier = Modifier.clickable { m.loadOlder(id) })
            }
            items(rows, key = { it.first().id }) { row ->
                val it0 = row.first()
                when {
                    it0.kind == "tool" -> ToolRow(row, c)
                    it0.kind == "user" || it0.kind == "voice" -> {
                        val mine = guest?.let { it0.by == it.name } ?: (it0.by == null)
                        val author = if (!shared) null else if (mine) "Sie" else it0.by ?: guest?.host?.ifEmpty { null } ?: "Gastgeber"
                        Bubble(it0.text ?: "", if (it0.kind == "voice") "gesprochen" else null, c, mine = mine, author = author,
                            avatar = if (mine) guest?.name ?: "S" else author)
                    }
                    it0.kind == "image" -> ImageItem(m, id, it0, c)
                    it0.kind == "speak" -> Text("„${it0.text ?: ""}“", fontStyle = FontStyle.Italic, color = c.secondary, fontSize = 16.sp)
                    else -> SelectionContainer { Markdown(it0.text ?: "", c) }
                }
            }
            items(pending) { Bubble(it, "wird zugestellt…", c, Modifier.padding(0.dp), faded = true) }
        }
        Row(Modifier.fillMaxWidth().navigationBarsPadding().padding(12.dp).clip(RoundedCornerShape(26.dp)).background(c.card)
            .border(1.dp, c.stroke, RoundedCornerShape(26.dp)).padding(start = 4.dp, end = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            TextField(text, { text = it }, Modifier.weight(1f).focusRequester(focus),
                placeholder = { Text("Nachricht an ${session?.name ?: "die Session"}") }, maxLines = 6,
                colors = TextFieldDefaults.colors(focusedContainerColor = Color.Transparent, unfocusedContainerColor = Color.Transparent,
                    focusedIndicatorColor = Color.Transparent, unfocusedIndicatorColor = Color.Transparent))
            val canSend = text.isNotBlank() && relay.canSend && guest?.listen != true   // "nur zuhören"
            Box(Modifier.size(40.dp).clip(CircleShape).background(if (canSend) c.accent else c.accent.copy(alpha = 0.4f))
                .clickable(enabled = canSend) { m.say(id, text); text = "" }, contentAlignment = Alignment.Center) {
                Icon(Icons.Filled.ArrowUpward, "Senden", tint = Color.White)
            }
        }
    }
}

/** Consecutive tool steps fold into one row, like the Claude app. */
private fun rows(items: List<ChatItem>): List<List<ChatItem>> {
    val out = mutableListOf<List<ChatItem>>()
    for (i in items) {
        if (i.kind == "tool" && out.lastOrNull()?.first()?.kind == "tool") out[out.size - 1] = out.last() + i
        else out += listOf(i)
    }
    return out
}

@Composable
private fun Bubble(text: String, caption: String?, c: Colors, modifier: Modifier = Modifier, faded: Boolean = false, mine: Boolean = true,
                   author: String? = null, avatar: String? = null) {
    Column(modifier.fillMaxWidth().padding(start = if (mine) 44.dp else 0.dp, end = if (mine) 0.dp else 44.dp),
        horizontalAlignment = if (mine) Alignment.End else Alignment.Start) {
        author?.let {
            Row(Modifier.padding(bottom = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                Avatar(avatar ?: it, c, 20.dp)
                Spacer(Modifier.size(6.dp))
                Text(it, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = c.text)
            }
        }
        SelectionContainer {
            Text(text, color = c.text.copy(alpha = if (faded) 0.55f else 1f), fontSize = 16.sp,
                modifier = Modifier.clip(RoundedCornerShape(22.dp)).background(if (mine) c.raised else c.idle.copy(alpha = 0.16f))
                    .padding(horizontal = 16.dp, vertical = 12.dp))
        }
        caption?.let { Text(it, fontSize = 12.sp, color = c.secondary, modifier = Modifier.padding(top = 4.dp)) }
    }
}

private enum class Step(val done: String, val one: String, val many: String) {
    command("Ausgeführt", "einen Befehl ausgeführt", "%d Befehle ausgeführt"),
    read("Gelesen", "eine Datei gelesen", "%d Dateien gelesen"),
    create("Erstellt", "eine Datei erstellt", "%d Dateien erstellt"),
    edit("Bearbeitet", "eine Datei bearbeitet", "%d Dateien bearbeitet"),
    search("Gesucht", "einmal gesucht", "%d-mal gesucht"),
    web("Abgerufen", "eine Seite abgerufen", "%d Seiten abgerufen"),
    tool("Verwendet", "ein Tool verwendet", "%d Tools verwendet");

    companion object {
        fun of(name: String) = when (name) {
            "Bash", "BashOutput", "PowerShell" -> command
            "Read", "NotebookRead" -> read
            "Write" -> create
            "Edit", "MultiEdit", "NotebookEdit" -> edit
            "Grep", "Glob", "LS" -> search
            "WebFetch", "WebSearch" -> web
            else -> tool
        }
    }
}

/** "Ausgeführt npm test" for one step; "Eine Datei erstellt, einen Befehl ausgeführt" for several. Tap: each step. */
@Composable
private fun ToolRow(tools: List<ChatItem>, c: Colors) {
    var open by remember { mutableStateOf(false) }
    fun split(t: ChatItem) = (t.text ?: "").split(" · ").let { it[0] to it.drop(1).joinToString(" · ").ifEmpty { null } }
    val summary = if (tools.size == 1) split(tools[0]).let { (n, d) -> "${Step.of(n).done} ${d ?: n}" } else {
        val counts = linkedMapOf<Step, Int>()
        tools.forEach { counts.merge(Step.of(split(it).first), 1, Int::plus) }
        counts.entries.joinToString(", ") { (s, n) -> if (n == 1) s.one else s.many.format(n) }.replaceFirstChar { it.uppercase() }
    }
    val add = tools.sumOf { it.add ?: 0 }
    val del = tools.sumOf { it.del ?: 0 }
    Column(Modifier.clickable { open = !open }) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(summary, fontSize = 15.sp, color = c.secondary, maxLines = 2, modifier = Modifier.weight(1f, fill = false))
            if (add + del > 0) {
                Spacer(Modifier.size(6.dp))
                Text("+$add", fontSize = 14.sp, color = Color(0xFF1A7F37), modifier = Modifier.background(Color(0x331A7F37)).padding(horizontal = 4.dp))
                Text("−$del", fontSize = 14.sp, color = c.red, modifier = Modifier.background(c.red.copy(alpha = 0.15f)).padding(horizontal = 4.dp))
            }
            Icon(Icons.Filled.ChevronRight, null, tint = c.secondary, modifier = Modifier.size(20.dp))
        }
        if (open) tools.forEach { t ->
            val (n, d) = split(t)
            Text("${Step.of(n).done} ${d ?: n}", fontSize = 13.sp, fontFamily = FontFamily.Monospace, color = c.secondary,
                modifier = Modifier.padding(start = 8.dp, top = 4.dp))
        }
    }
}

@Composable
private fun ImageItem(m: AppModel, session: String, item: ChatItem, c: Colors) {
    val bmp = m.images[item.id]
    LaunchedEffect(item.id) { if (bmp == null) m.loadImage(session, item.id) }
    Box(Modifier.fillMaxWidth(), contentAlignment = if (item.fromUser) Alignment.CenterEnd else Alignment.CenterStart) {
        if (bmp != null) Image(bmp.asImageBitmap(), null, contentScale = ContentScale.Fit,
            modifier = Modifier.widthIn(max = 300.dp).clip(RoundedCornerShape(14.dp)).border(1.dp, c.stroke, RoundedCornerShape(14.dp)))
        else Box(Modifier.widthIn(max = 300.dp).fillMaxWidth().aspectRatio(1.6f).clip(RoundedCornerShape(14.dp)).background(c.card),
            contentAlignment = Alignment.Center) { Icon(Icons.Filled.Image, null, tint = c.secondary.copy(alpha = 0.5f), modifier = Modifier.size(36.dp)) }
    }
}

/** Claude's text: headings, bullets, code blocks, **bold**, `code`. */
// ponytail: a small subset of Markdown; tables and links stay plain text
@Composable
private fun Markdown(text: String, c: Colors) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        val blocks = text.split("```")
        blocks.forEachIndexed { i, block ->
            if (i % 2 == 1) {
                val code = block.substringAfter('\n', block).trimEnd()
                Text(code, fontFamily = FontFamily.Monospace, fontSize = 14.sp, color = c.ink(c.idle),
                    modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(14.dp)).background(c.raised)
                        .horizontalScroll(rememberScrollState()).padding(14.dp))
            } else block.trim('\n').split("\n").filter { it.isNotBlank() }.forEach { line ->
                val t = line.trimStart()
                when {
                    t.startsWith("#") -> Text(inline(t.trimStart('#').trim(), c), fontWeight = FontWeight.Bold, fontSize = 18.sp, color = c.text)
                    t.startsWith("- ") || t.startsWith("* ") -> Row {
                        Text("•", color = c.text, fontSize = 16.sp, modifier = Modifier.padding(start = 6.dp, end = 10.dp))
                        Text(inline(t.drop(2), c), color = c.text, fontSize = 16.sp)
                    }
                    else -> Text(inline(line, c), color = c.text, fontSize = 16.sp, lineHeight = 23.sp)
                }
            }
        }
    }
}

private fun inline(s: String, c: Colors): AnnotatedString = buildAnnotatedString {
    var i = 0
    while (i < s.length) {
        when {
            s.startsWith("**", i) && s.indexOf("**", i + 2) > 0 -> {
                val j = s.indexOf("**", i + 2)
                withStyle(SpanStyle(fontWeight = FontWeight.Bold)) { append(s.substring(i + 2, j)) }
                i = j + 2
            }
            s[i] == '`' && s.indexOf('`', i + 1) > 0 -> {
                val j = s.indexOf('`', i + 1)
                withStyle(SpanStyle(fontFamily = FontFamily.Monospace, color = c.ink(c.working), background = c.raised)) { append(s.substring(i + 1, j)) }
                i = j + 1
            }
            else -> { append(s[i]); i++ }
        }
    }
}
