package de.developaway.parley

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.core.content.ContextCompat
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanOptions
import de.developaway.parley.ui.CallScreen
import de.developaway.parley.ui.LocalColors
import de.developaway.parley.ui.Overview
import de.developaway.parley.ui.PairingScreen
import de.developaway.parley.ui.ParleyTheme
import de.developaway.parley.ui.SessionScreen
import de.developaway.parley.ui.SettingsScreen
import de.developaway.parley.ui.ShareOverlays

class MainActivity : ComponentActivity() {
    private var pairError by mutableStateOf<String?>(null)
    private var demoSession by mutableStateOf<String?>(null)

    private val scanner = registerForActivityResult(ScanContract()) { r ->
        r.contents?.let { usePairing(it) }
    }
    private val permissions = registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {}

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge(SystemBarStyle.auto(android.graphics.Color.TRANSPARENT, android.graphics.Color.TRANSPARENT))
        ParleyService.channels(this)
        val m = model
        handle(intent)
        setContent {
            ParleyTheme {
                var session by rememberSaveable { mutableStateOf<String?>(null) }
                LaunchedEffect(demoSession) { demoSession?.let { session = it } }
                var compose by rememberSaveable { mutableStateOf(false) }
                var settings by rememberSaveable { mutableStateOf(false) }
                val call = m.call
                // Over the lock screen only while it rings or talks.
                LaunchedEffect(call.phase) { showOverLock(call.phase != CallPhase.none) }
                // The call screen is always dark: light status bar icons over it.
                val dark = androidx.compose.foundation.isSystemInDarkTheme()
                val callUp = call.showsScreen && call.phase != CallPhase.none
                LaunchedEffect(callUp, dark) {
                    androidx.core.view.WindowCompat.getInsetsController(window, window.decorView).isAppearanceLightStatusBars = !callUp && !dark
                }

                Box(Modifier.fillMaxSize()) {
                    when {
                        !m.isPaired -> PairingScreen(m, ::scan, pairError) { pairError = it }
                        settings -> { BackHandler { settings = false }; SettingsScreen(m) { settings = false } }
                        session != null -> { BackHandler { session = null }; SessionScreen(m, session!!, compose) { session = null } }
                        else -> Overview(m, { id, c -> session = id; compose = c }) { settings = true }
                    }
                    ShareOverlays(m)
                    // A guest's questions reach him as a notification while Unterwegs keeps the share's room open.
                    LaunchedEffect(m.guests.isNotEmpty()) { if (m.guests.isNotEmpty() && !m.demo) askPermissions(mic = m.pairing != null) }
                    AnimatedVisibility(call.showsScreen && call.phase != CallPhase.none,
                        enter = slideInVertically { it }, exit = slideOutVertically { it }) {
                        BackHandler { call.showsScreen = false }
                        CallScreen(call, LocalColors.current.accent) { call.showsScreen = false }
                    }
                }
            }
        }
        // Asked up front, so the prompts never land mid-call.
        if (m.pairing != null && !m.demo) askPermissions()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handle(intent)
    }

    override fun onStart() {
        super.onStart()
        model.foreground(true)
    }

    override fun onStop() {
        super.onStop()
        model.foreground(false)
    }

    private fun handle(intent: Intent?) {
        intent?.getStringExtra("demo")?.let { model.startDemo(it); if (it == "session") demoSession = "demo-shirts" }
        when {
            intent?.action == ACTION_ANSWER -> { model.call.answer() }
            intent?.data?.scheme == "parley" -> usePairing(intent.data.toString())
        }
        if (model.call.phase != CallPhase.none) model.call.showsScreen = true
    }

    private fun usePairing(link: String) {
        // v7: someone shares a session with this phone.
        if (Uri.parse(link.trim()).host.equals("join", true)) {
            JoinLink.parse(link)?.let { model.pendingJoin = it; pairError = null } ?: run { pairError = "Der Einladungslink ist ungültig." }
            return
        }
        try {
            model.pair(Pairing.parse(link))
            pairError = null
            askPermissions()
        } catch (e: Pairing.Invalid) {
            pairError = e.message
        }
    }

    private fun scan() {
        scanner.launch(ScanOptions().setDesiredBarcodeFormats(ScanOptions.QR_CODE).setPrompt("QR-Code aus Parley auf dem Mac")
            .setBeepEnabled(false).setOrientationLocked(false))
    }

    private fun askPermissions(mic: Boolean = true) {
        val want = buildList {
            if (mic) add(Manifest.permission.RECORD_AUDIO)
            if (Build.VERSION.SDK_INT >= 33) add(Manifest.permission.POST_NOTIFICATIONS)
        }.filter { ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED }
        if (want.isNotEmpty()) permissions.launch(want.toTypedArray())
    }

    private fun showOverLock(on: Boolean) {
        if (Build.VERSION.SDK_INT >= 27) { setShowWhenLocked(on); setTurnScreenOn(on) }
    }

    companion object { const val ACTION_ANSWER = "de.developaway.parley.ANSWER" }
}
