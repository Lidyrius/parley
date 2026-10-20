package de.developaway.parley

import org.junit.Assert.assertEquals
import org.junit.Test

/** The overview's status groups and their order (same spec on every platform). */
class OrderTest {
    private fun s(id: String, state: SessionState, since: Double = 0.0, label: String = id,
                  voice: Boolean = false, callback: Double? = null) =
        Session(id, label = label, state = state, since = since, voice = voice, callback = callback)

    @Test fun groups() {
        assertEquals(3, s("a", SessionState.stopped, voice = true).group)
        assertEquals(0, s("a", SessionState.parked, voice = true).group)
        assertEquals(0, s("a", SessionState.queued).group)
        assertEquals(0, s("a", SessionState.listening).group)
        assertEquals(0, s("a", SessionState.working, callback = 0.0).group)
        assertEquals(1, s("a", SessionState.working).group)
        assertEquals(1, s("a", SessionState.background).group)
        assertEquals(2, s("a", SessionState.waiting).group)
        assertEquals(2, s("a", SessionState.parked).group)
        assertEquals(2, s("a", SessionState.idle).group)
    }

    @Test fun order() {
        val list = listOf(
            s("stop", SessionState.stopped, since = 9.0),
            s("old", SessionState.working, since = 1.0),
            s("new", SessionState.background, since = 5.0),
            s("b", SessionState.parked, since = 3.0, label = "beta"),
            s("a", SessionState.parked, since = 3.0, label = "Alpha"),
            s("talk", SessionState.speaking, since = 0.0),
        )
        assertEquals(listOf("talk", "new", "old", "a", "b", "stop"), list.ordered().map { it.id })
    }
}
