package de.developaway.parley.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import de.developaway.parley.ConnectionStatus
import de.developaway.parley.SessionState

/** Claude's palette (ios/ParleyMobile/Theme.swift `Palette.claude`): warm paper and terracotta. */
data class Colors(
    val dark: Boolean,
    val background: Color,
    val card: Color,
    val raised: Color,
    val text: Color,
    val secondary: Color,
    val stroke: Color,
    val accent: Color = Color(0xFFD97757),
    val waiting: Color = Color(0xFFD9A43B),
    val working: Color = Color(0xFF5B8DEF),
    val purple: Color = Color(0xFF9B87F5),
    val idle: Color = Color(0xFF4EBA65),
    val stopped: Color = Color(0xFF8B8A85),
    val red: Color = Color(0xFFE5484D),
    val green: Color = Color(0xFF4CB963),
) {
    fun state(s: SessionState): Color = when (s) {
        SessionState.speaking, SessionState.listening, SessionState.transcribing -> accent
        SessionState.queued, SessionState.waiting -> waiting
        SessionState.working -> working
        SessionState.background -> purple
        SessionState.parked, SessionState.stopped -> stopped
        SessionState.idle -> idle
    }

    /** A label's colour: a darker shade in light mode, so text stays readable on white. */
    fun ink(c: Color): Color = if (dark) c else Color(c.red * 0.78f, c.green * 0.78f, c.blue * 0.78f)

    fun status(s: ConnectionStatus): Color = when (s) {
        ConnectionStatus.connected -> idle
        ConnectionStatus.connecting -> waiting
        ConnectionStatus.hostOffline, ConnectionStatus.unknownRoom -> stopped
        ConnectionStatus.rejected, ConnectionStatus.unreachable -> red
    }

    companion object {
        val light = Colors(false, Color(0xFFFAF9F5), Color.White, Color(0xFFF0EEE6), Color(0xFF1A1915), Color(0xFF85837D), Color(0x12000000))
        val night = Colors(true, Color(0xFF191918), Color(0xFF262624), Color(0xFF30302E), Color(0xFFF5F4EF), Color(0xFF9D9B95), Color(0x14FFFFFF))
    }
}

val LocalColors = staticCompositionLocalOf { Colors.light }

@Composable
fun ParleyTheme(content: @Composable () -> Unit) {
    val c = if (isSystemInDarkTheme()) Colors.night else Colors.light
    val scheme = (if (c.dark) darkColorScheme() else lightColorScheme()).copy(
        primary = c.accent, onPrimary = Color.White, background = c.background, surface = c.background,
        onBackground = c.text, onSurface = c.text, surfaceVariant = c.raised, onSurfaceVariant = c.secondary,
        surfaceContainerLow = c.background, surfaceContainer = c.card, surfaceContainerHigh = c.card,
        outline = c.stroke, error = c.red,
    )
    CompositionLocalProvider(LocalColors provides c) { MaterialTheme(colorScheme = scheme, content = content) }
}
