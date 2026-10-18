package de.developaway.parley

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ProtocolTest {
    @Test fun decodesTheDemoSnapshot() {
        val f = Frames.parse(Demo.frame(1_000_000_000_000)) as Incoming.Sessions
        val s = f.snapshot
        assertEquals(8, s.sessions.size)
        assertEquals(SessionState.speaking, s.sessions[0].state)
        assertEquals(0.0, s.sessions.first { it.id == "demo-website" }.callback)
        assertEquals("Durable Object gegen das Protokoll testen", s.sessions.first { it.id == "demo-relay" }.tasks[0].description)
        assertEquals(listOf("5-h-Limit" to 42.0, "Woche" to 18.0), Fmt.limits(s.today!!))
        assertEquals("Shirts", s.reminders[1].after)
    }

    @Test fun encodesWhatThePhoneSends() {
        assertEquals("""{"t":"call","state":"start","down":24000}""", Outgoing.call(true))
        assertEquals("later", JSONObject(Outgoing.later(null)).getString("t"))
        assertTrue(!JSONObject(Outgoing.later(null)).has("after"))
        assertEquals(60, JSONObject(Outgoing.later(60)).getInt("after"))
        assertTrue(!JSONObject(Outgoing.history("a")).has("before"))
    }

    @Test fun mergesHistoryPages() {
        fun items(vararg ids: String) = ids.map { ChatItem(it) }
        assertEquals(items("a", "b", "c", "d"), AppModel.merge(items("c", "d"), items("a", "b"), before = "c"))
        assertEquals(items("a", "b", "c", "x"), AppModel.merge(items("a", "b", "c"), items("c", "x"), before = null))
        assertEquals(items("y"), AppModel.merge(items("a"), items("y"), before = null))
    }

    @Test fun skewTakesTheLargestSaneSample() {
        assertEquals(50.0, Relay.skew(50.0, 20.0)!!, 0.0)
        assertEquals(20.0, Relay.skew(-10.0, 20.0)!!, 0.0)
        assertEquals(20.0, Relay.skew(500_000.0, 20.0)!!, 0.0)
    }

    @Test fun captionChunksEndAtSentences() {
        val c = Demo.caption
        assertEquals("Gern, Sir, der Tagesbericht als Folien.", c.words.slice(c.chunks[0]).joinToString(" "))
        assertEquals(c.chunks[1], c.chunk(4.5))
        assertEquals(c.chunks[0], c.chunk(0.0))
    }

    @Test fun upsamplesSixteenToTwentyFourKilohertz() {
        assertEquals(480, CallAudio.upsample(ShortArray(320) { 100 }).size)
    }
}
