package de.developaway.parley.ui

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.Settings
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
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
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.requiredSize
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CameraAlt
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.ContentPaste
import androidx.compose.material.icons.filled.DesktopMac
import androidx.compose.material.icons.filled.FlashlightOff
import androidx.compose.material.icons.filled.FlashlightOn
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.QrCodeScanner
import androidx.compose.material.icons.filled.WebAsset
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.LifecycleResumeEffect
import com.google.zxing.BarcodeFormat
import com.journeyapps.barcodescanner.BarcodeView
import com.journeyapps.barcodescanner.DefaultDecoderFactory
import de.developaway.parley.AppModel
import de.developaway.parley.R
import kotlinx.coroutines.delay
import kotlin.math.ceil
import kotlin.math.pow

/**
 * Not paired yet (ios PairingView, design A2 "Silhouetten-Echo", docs/design/screens/ios/40-kopplung):
 * the app icon with its outline repeated outwards, "Code scannen", or paste the link. `pair` takes a
 * link and returns the error message, or null once paired.
 */
@Composable
fun PairingScreen(m: AppModel, error: String?, setError: (String?) -> Unit, pair: (String) -> String?) {
    val c = LocalColors.current
    val clip = LocalClipboardManager.current
    var scanning by remember { mutableStateOf(false) }
    fun paste() = setError(clip.getText()?.text?.takeIf { it.isNotBlank() }?.let(pair)
        ?: "In der Zwischenablage ist kein Link. Kopieren Sie ihn am Mac unter „Handy verbinden…“.")

    if (scanning || m.welcoming) {
        BackHandler { scanning = false }
        ScannerScreen(m, pair, ::paste, error) { scanning = false }
        return
    }

    Column(Modifier.fillMaxSize().background(c.background).statusBarsPadding().navigationBarsPadding().padding(horizontal = 24.dp),
        horizontalAlignment = Alignment.CenterHorizontally) {
        // The outlines are drawn outside the icon's box: the outer ones may run over the screen's edge.
        Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
            val alpha = if (c.dark) 1f else 1.5f
            AppIcon(128.dp, Modifier.drawBehind {
                listOf(176 to 0.50f, 232 to 0.34f, 300 to 0.22f, 380 to 0.13f, 470 to 0.07f).forEachIndexed { i, (s, a) ->
                    iconOutline(s.dp.toPx(), c.accent.copy(alpha = (a * alpha).coerceAtMost(1f)), (2f - i * 0.25f).dp.toPx())
                }
            })
        }
        Text("Guten Tag, Sir.", fontSize = 32.sp, fontWeight = FontWeight.Bold, color = c.text, textAlign = TextAlign.Center)
        Spacer(Modifier.height(8.dp))
        Text("Ein Code vom Mac, und Ihre Sessions sind hier.", fontSize = 17.sp, color = c.secondary, textAlign = TextAlign.Center)
        Spacer(Modifier.height(22.dp))
        HintCard(Icons.Filled.DesktopMac, "Auf dem Mac", "Parley-Menü → „Handy verbinden…“")
        Spacer(Modifier.height(22.dp))
        Row(Modifier.fillMaxWidth().height(56.dp).clip(RoundedCornerShape(28.dp)).background(c.accent).clickable { scanning = true },
            horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Filled.QrCodeScanner, null, tint = c.onAccent)
            Spacer(Modifier.width(10.dp))
            Text("Code scannen", color = c.onAccent, fontSize = 18.sp, fontWeight = FontWeight.SemiBold)
        }
        Spacer(Modifier.height(10.dp))
        TextButton(Icons.Filled.ContentPaste, "Link einfügen", c.accent, ::paste)
        error?.let { Text(it, color = c.red, fontSize = 15.sp, textAlign = TextAlign.Center, modifier = Modifier.padding(top = 6.dp)) }
        Spacer(Modifier.height(14.dp))
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Filled.Lock, null, tint = c.secondary, modifier = Modifier.size(14.dp))
            Spacer(Modifier.width(6.dp))
            Text("Verschlüsselt · nur Ihr Mac und Ihr Handy", fontSize = 14.sp, color = c.secondary)
        }
        Spacer(Modifier.height(16.dp))
    }
}

/**
 * The scanner (design B2): the camera in a tile of the icon's shape whose outline runs outwards like
 * the iPhone's call ripples while it searches. Once a code pairs: "Verbunden, Sir." for a moment,
 * then the overview.
 */
@Composable
private fun ScannerScreen(m: AppModel, pair: (String) -> String?, paste: () -> Unit, error: String?, close: () -> Unit) {
    val c = LocalColors.current
    val context = LocalContext.current
    var granted by remember { mutableStateOf(ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) }
    var asked by remember { mutableStateOf(false) }
    val ask = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted = it; asked = true }
    LaunchedEffect(Unit) { if (!granted) ask.launch(Manifest.permission.CAMERA) }
    // Back from the system settings ("Kamera erlauben"): it may be allowed now.
    LifecycleResumeEffect(Unit) {
        granted = ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED
        onPauseOrDispose {}
    }
    var scanError by remember { mutableStateOf<String?>(null) }
    var torch by remember { mutableStateOf(false) }
    val hasTorch = remember { context.packageManager.hasSystemFeature(PackageManager.FEATURE_CAMERA_FLASH) }
    val found = m.welcoming
    LaunchedEffect(found) { if (found) { delay(1500); m.welcoming = false } }

    var last by remember { mutableStateOf<String?>(null) }
    fun handle(code: String) {
        if (m.welcoming || code == last) return   // the camera reports the same code every frame
        last = code
        m.welcoming = true   // keeps this screen up for "Verbunden, Sir."
        pair(code)?.let { m.welcoming = false; scanError = it }
    }

    Column(Modifier.fillMaxSize().background(c.background).statusBarsPadding().navigationBarsPadding().padding(horizontal = 24.dp, vertical = 12.dp)) {
        Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.CenterEnd) {
            Box(Modifier.size(44.dp).clip(CircleShape).background(c.card).clickable(onClick = close), contentAlignment = Alignment.Center) {
                Icon(Icons.Filled.Close, "Schließen", tint = c.text)
            }
        }
        if (!granted && asked) {
            CameraOff(c, paste, error)
            return@Column
        }
        Text("Code scannen", fontSize = 32.sp, fontWeight = FontWeight.Bold, color = c.text)
        Spacer(Modifier.height(6.dp))
        Text("Halten Sie das Handy auf den Code am Mac.", fontSize = 17.sp, color = c.secondary)

        val tile = 290.dp
        Box(Modifier.fillMaxWidth().height(tile + 70.dp), contentAlignment = Alignment.Center) {
            val waves = rememberSeconds(!found)
            val edge = if (found) c.green else c.accent
            Box(Modifier.size(tile)
                .drawBehind { if (!found) silhouetteWaves(waves.value, size.width, c.accent) }
                .shadow(18.dp, IconShape)
                .clip(IconShape).background(Color(0xFF1C1C1E))
                .border(2.5.dp, edge, IconShape), contentAlignment = Alignment.Center) {
                if (granted) {
                    val onCode by rememberUpdatedState(::handle)
                    AndroidView({ ctx ->
                        BarcodeView(ctx).apply {
                            decoderFactory = DefaultDecoderFactory(listOf(BarcodeFormat.QR_CODE))
                            decodeContinuous { r -> r.text?.let { onCode(it) } }
                            resume()
                        }
                    }, Modifier.fillMaxSize(), update = { it.setTorch(torch) }, onRelease = { it.pause() })
                }
                if (found) Box(Modifier.size(84.dp).clip(CircleShape).background(c.green), contentAlignment = Alignment.Center) {
                    Icon(Icons.Filled.Check, null, tint = Color.White, modifier = Modifier.size(44.dp))
                }
            }
        }

        if (found) {
            val n = m.relay.snapshot?.sessions?.size ?: 0
            Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
                Text("Verbunden, Sir.", fontSize = 24.sp, fontWeight = FontWeight.Bold, color = c.text)
                Text(if (n == 0) "Ihr Mac" else "Ihr Mac · $n ${if (n == 1) "Session" else "Sessions"}", fontSize = 16.sp, color = c.secondary)
            }
        } else {
            HintCard(Icons.Filled.WebAsset, "Kein Code zu sehen?", "Mac: Parley-Menü → „Handy verbinden…“")
            (scanError ?: error)?.let { Text(it, color = c.red, fontSize = 15.sp, modifier = Modifier.padding(top = 10.dp)) }
        }
        Spacer(Modifier.weight(1f))
        if (!found) Row(verticalAlignment = Alignment.CenterVertically) {
            Row(Modifier.weight(1f).height(54.dp).clip(RoundedCornerShape(27.dp)).background(c.card).clickable(onClick = paste),
                horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Filled.ContentPaste, null, tint = c.text)
                Spacer(Modifier.width(10.dp))
                Text("Link einfügen", color = c.text, fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
            }
            if (hasTorch && granted) {
                Spacer(Modifier.width(12.dp))
                Box(Modifier.size(54.dp).clip(CircleShape).background(if (torch) c.accent else c.card).clickable { torch = !torch },
                    contentAlignment = Alignment.Center) {
                    Icon(if (torch) Icons.Filled.FlashlightOn else Icons.Filled.FlashlightOff, if (torch) "Licht aus" else "Licht an",
                        tint = if (torch) c.onAccent else c.text)
                }
            }
        }
    }
}

/** Camera permission denied: a dashed tile, a plain request, and the link as the way around. */
@Composable
private fun CameraOff(c: Colors, paste: () -> Unit, error: String?) {
    val context = LocalContext.current
    Column(Modifier.fillMaxSize(), horizontalAlignment = Alignment.CenterHorizontally) {
        Spacer(Modifier.weight(1f))
        Box(Modifier.size(180.dp).drawBehind {
            drawRoundRect(c.accent.copy(alpha = 0.6f), cornerRadius = CornerRadius(size.width * 0.225f),
                style = Stroke(2.dp.toPx(), pathEffect = PathEffect.dashPathEffect(floatArrayOf(6.dp.toPx(), 5.dp.toPx()))))
        }, contentAlignment = Alignment.Center) {
            Icon(Icons.Filled.CameraAlt, null, tint = c.accent, modifier = Modifier.size(44.dp))
        }
        Spacer(Modifier.height(18.dp))
        Text("Kamera ist aus", fontSize = 24.sp, fontWeight = FontWeight.Bold, color = c.text)
        Spacer(Modifier.height(6.dp))
        Text("Parley braucht sie nur für diesen einen Code.", fontSize = 16.sp, color = c.secondary, textAlign = TextAlign.Center)
        error?.let { Text(it, color = c.red, fontSize = 15.sp, textAlign = TextAlign.Center, modifier = Modifier.padding(top = 10.dp)) }
        Spacer(Modifier.weight(1f))
        Box(Modifier.fillMaxWidth().height(56.dp).clip(RoundedCornerShape(28.dp)).background(c.accent).clickable {
            context.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", context.packageName, null)))
        }, contentAlignment = Alignment.Center) {
            Text("Kamera erlauben", color = c.onAccent, fontSize = 18.sp, fontWeight = FontWeight.SemiBold)
        }
        Spacer(Modifier.height(10.dp))
        TextButton(Icons.Filled.ContentPaste, "Stattdessen Link einfügen", c.accent, paste)
    }
}

/** The app icon's outline: a rounded square, 22.5 % corners. */
private val IconShape = RoundedCornerShape(percent = 22)   // ponytail: 22 %, Compose takes whole percents (iOS 22.5)

private fun DrawScope.iconOutline(side: Float, color: Color, width: Float) {
    drawRoundRect(color, Offset(center.x - side / 2, center.y - side / 2), Size(side, side), CornerRadius(side * 0.225f), style = Stroke(width))
}

/**
 * The tile's outline sent outwards: the iPhone's call ripples (ios Ringing.swift `.ripples`, its
 * default knobs) in the icon's shape — two beats per 2.4 s cycle, each lives 2 s, eases out to ~1.6×, fades.
 */
private fun DrawScope.silhouetteWaves(t: Double, side: Float, color: Color) {
    val cycle = 2.4; val life = 2.0; val reach = 0.6; val ease = 2.2; val fade = 1.6
    val phase = t % cycle
    for (back in 0..ceil(life / cycle).toInt()) for (launch in listOf(0.2, 0.62)) {
        val age = phase - launch + back * cycle
        if (age < 0 || age >= life) continue
        val p = age / life
        val s = side * (1 + reach * (1 - (1 - p).pow(ease))).toFloat()
        val a = (1 - p).pow(fade).toFloat()
        val tl = Offset(center.x - s / 2, center.y - s / 2)
        drawRoundRect(color.copy(alpha = a * 0.18f * 0.5f), tl, Size(s, s), CornerRadius(s * 0.225f))
        drawRoundRect(color.copy(alpha = a * 0.5f), tl, Size(s, s), CornerRadius(s * 0.225f), style = Stroke(1.5.dp.toPx()))
    }
}

/** The launcher icon (its adaptive layers), as the home screen shows it. */
@Composable
private fun AppIcon(size: Dp, modifier: Modifier = Modifier) {
    Box(modifier.size(size).shadow(size * 0.14f, IconShape).clip(IconShape), contentAlignment = Alignment.Center) {
        // Adaptive layers are 108 dp with a 72 dp visible middle.
        Image(painterResource(R.drawable.ic_launcher_background), null, Modifier.requiredSize(size * 1.5f), contentScale = ContentScale.FillBounds)
        Image(painterResource(R.drawable.ic_launcher_foreground), null, Modifier.requiredSize(size * 1.5f), contentScale = ContentScale.FillBounds)
    }
}

/** One line of help as a card: a symbol on an accent tile, a title, a detail. */
@Composable
private fun HintCard(icon: ImageVector, title: String, detail: String) {
    val c = LocalColors.current
    Row(Modifier.fillMaxWidth().card(c).padding(14.dp), verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(44.dp).clip(RoundedCornerShape(12.dp)).background(c.accent.copy(alpha = 0.18f)), contentAlignment = Alignment.Center) {
            Icon(icon, null, tint = c.accent)
        }
        Spacer(Modifier.width(14.dp))
        Column {
            Text(title, fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = c.text)
            Text(detail, fontSize = 15.sp, color = c.secondary)
        }
    }
}

@Composable
private fun TextButton(icon: ImageVector, text: String, color: Color, onClick: () -> Unit) {
    Row(Modifier.clip(RoundedCornerShape(12.dp)).clickable(onClick = onClick).padding(horizontal = 12.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, null, tint = color, modifier = Modifier.size(20.dp))
        Spacer(Modifier.width(8.dp))
        Text(text, color = color, fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
    }
}
