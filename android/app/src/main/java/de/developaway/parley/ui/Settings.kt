package de.developaway.parley.ui

import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import de.developaway.parley.AppModel
import de.developaway.parley.BuildConfig
import de.developaway.parley.Prefs

private val roundChoices = listOf(0, 30, 60, 90, 120, 180, 300)
private fun roundLabel(s: Int) = if (s == 0) "Aus" else if (s % 60 == 0) "${s / 60} Min." else "$s s"

@Composable
fun SettingsScreen(m: AppModel, close: () -> Unit) {
    val c = LocalColors.current
    val ctx = LocalContext.current
    var tick by remember { mutableIntStateOf(0) }   // re-read prefs after a switch
    var confirmUnpair by remember { mutableStateOf(false) }
    tick.let { }

    Column(Modifier.fillMaxSize().background(c.background).statusBarsPadding().verticalScroll(rememberScrollState()).navigationBarsPadding().padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Einstellungen", fontSize = 28.sp, fontWeight = FontWeight.Bold, color = c.text, modifier = Modifier.weight(1f))
            Box(Modifier.size(40.dp).clip(CircleShape).background(c.card).clickable(onClick = close), contentAlignment = Alignment.Center) {
                Icon(Icons.Filled.Close, "Schließen", tint = c.accent)
            }
        }

        Header("Anrufe", c)
        Group(c) {
            Toggle("Unterwegs", "Updates klingeln als Anruf auf diesem Telefon, statt auf dem Mac gesprochen zu werden.", m.away, c) { m.changeAway(it) }
            Divider(c)
            Toggle("Lautsprecher beim Anrufstart", "Kopfhörer und Auto bleiben, wie sie sind.", Prefs.speakerByDefault(ctx), c) {
                Prefs.set(ctx, "speakerByDefault", it); tick++
            }
            Divider(c)
            Toggle("Nach dem Gespräch auflegen", "Hat Parley zu Ende gesprochen, legt es sofort auf.", Prefs.autoHangUp(ctx), c) {
                Prefs.set(ctx, "autoHangUp", it); tick++
            }
            Divider(c)
            Column(Modifier.padding(16.dp)) {
                Text("Fragerunde", color = c.text, fontSize = 17.sp)
                Text("So lange wartet ein Update auf die anderen, solange noch eine Session arbeitet – dann kommt alles in einem Anruf.",
                    color = c.secondary, fontSize = 13.sp)
                Row(Modifier.padding(top = 10.dp).horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    roundChoices.forEach { s ->
                        val on = m.roundSeconds == s
                        Text(roundLabel(s), color = if (on) Color.White else c.text, fontSize = 15.sp,
                            modifier = Modifier.clip(Pill).background(if (on) c.accent else c.raised).clickable { m.setRound(s) }
                                .padding(horizontal = 12.dp, vertical = 6.dp))
                    }
                }
            }
            Divider(c)
            Action("Probeanruf", c) { close(); m.call.startTest() }
        }
        Text("Während des Anrufs: „Sprechen“ holt Parley, wenn es still ist; „Unterbrechen“ stoppt Parley mitten im Satz.",
            color = c.secondary, fontSize = 13.sp, modifier = Modifier.padding(horizontal = 4.dp))

        Header("Im Hintergrund", c)
        Group(c) {
            val pm = ctx.getSystemService(Context.POWER_SERVICE) as PowerManager
            val free = pm.isIgnoringBatteryOptimizations(ctx.packageName)
            Action(if (free) "Akku-Optimierung: aus ✓" else "Akku-Optimierung ausschalten", c, enabled = !free) {
                @SuppressLint("BatteryLife")
                val i = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:${ctx.packageName}"))
                runCatching { ctx.startActivity(i) }
            }
            if (Build.VERSION.SDK_INT >= 34) {
                Divider(c)
                Action("Anrufe auf dem Sperrbildschirm erlauben", c) {
                    runCatching { ctx.startActivity(Intent(Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT, Uri.parse("package:${ctx.packageName}"))) }
                }
            }
        }
        Text("Unterwegs hält Parley die Verbindung zum Relay offen, damit Anrufe auch bei gesperrtem Bildschirm ankommen.",
            color = c.secondary, fontSize = 13.sp, modifier = Modifier.padding(horizontal = 4.dp))

        Header("Kopplung", c)
        Group(c) {
            Column(Modifier.padding(16.dp)) {
                Text("Relay", color = c.text, fontSize = 17.sp)
                Text(m.pairing?.relay?.removePrefix("https://") ?: "–", color = c.secondary, fontSize = 15.sp)
            }
            Divider(c)
            Action("Entkoppeln", c, color = c.red) { confirmUnpair = true }
        }
        Text("Parley für Android ${BuildConfig.VERSION_NAME}", color = c.secondary, fontSize = 13.sp, modifier = Modifier.padding(4.dp))
    }

    if (confirmUnpair) AlertDialog({ confirmUnpair = false },
        title = { Text("Entkoppeln?") },
        text = { Text("Das Telefon sieht deine Sessions erst wieder, wenn du es neu koppelst.") },
        confirmButton = { TextButton({ confirmUnpair = false; close(); m.unpair() }) { Text("Entkoppeln", color = c.red) } },
        dismissButton = { TextButton({ confirmUnpair = false }) { Text("Abbrechen") } })
}

@Composable
private fun Header(title: String, c: Colors) =
    Text(title.uppercase(), color = c.secondary, fontSize = 13.sp, modifier = Modifier.padding(start = 4.dp, top = 14.dp))

@Composable
private fun Group(c: Colors, content: @Composable () -> Unit) =
    Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp)).background(c.card)) { content() }

@Composable
private fun Divider(c: Colors) = HorizontalDivider(Modifier.padding(start = 16.dp), color = c.stroke)

@Composable
private fun Toggle(title: String, note: String, on: Boolean, c: Colors, enabled: Boolean = true, set: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().clickable(enabled) { set(!on) }.padding(horizontal = 16.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(title, color = if (enabled) c.text else c.secondary, fontSize = 17.sp)
            Text(note, color = c.secondary, fontSize = 13.sp)
        }
        Spacer(Modifier.size(12.dp))
        Switch(on, set, enabled = enabled, colors = SwitchDefaults.colors(checkedTrackColor = c.accent, checkedThumbColor = Color.White))
    }
}

@Composable
private fun Action(title: String, c: Colors, enabled: Boolean = true, color: Color = c.accent, onClick: () -> Unit) =
    Text(title, color = if (enabled) color else c.secondary, fontSize = 17.sp,
        modifier = Modifier.fillMaxWidth().clickable(enabled, onClick = onClick).padding(16.dp))
