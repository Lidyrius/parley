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

    @Test fun decodesSnapshotsLeniently() {
        val s = (Frames.parse("""{"t":"sessions","sessions":[],"snapshots":[
            {"id":"a","name":"Kunde Müller","at":1760000000000,"sessions":[{"id":"x","name":"Website","cwd":"/k/web"},{"name":"no id"}]},
            {"name":"no id"},
            {"id":"b","name":"Leer"}]}""") as Incoming.Sessions).snapshot
        assertEquals(listOf("a", "b"), s.snapshots.map { it.id })
        assertEquals(1_760_000_000_000.0, s.snapshots[0].at, 0.0)
        assertEquals(listOf(SnapshotItem("x", "Website", "/k/web")), s.snapshots[0].sessions)
        assertEquals(emptyList<SnapshotItem>(), s.snapshots[1].sessions)
        assertEquals(emptyList<SnapshotRow>(), (Frames.parse("""{"t":"sessions","sessions":[]}""") as Incoming.Sessions).snapshot.snapshots)
        assertEquals(3, (Frames.parse(Demo.frame(1_000_000_000_000)) as Incoming.Sessions).snapshot.snapshots.size)
    }

    @Test fun decodesTheSnapshotOpenReply() {
        val f = Frames.parse("""{"t":"snapshot","id":"a","name":"Kunde Müller","results":[
            {"id":"x","name":"Website","result":"running"},{"id":"y","name":"Shop","result":"started"},{"result":"missing"}]}""")
        assertEquals(SnapshotResult("a", "Kunde Müller", listOf(SnapshotOutcome("x", "Website", "running"), SnapshotOutcome("y", "Shop", "started"))),
            (f as Incoming.SnapshotOpened).result)
        assertEquals(Incoming.Ignored, Frames.parse("""{"t":"snapshot","results":[]}"""))
    }

    @Test fun encodesTheSnapshotFrames() {
        fun fields(s: String) = JSONObject(s).let { o -> o.keys().asSequence().associateWith { o.get(it).toString() } }
        assertEquals(mapOf("t" to "snapshot", "op" to "save", "name" to "Kunde Müller", "ids" to """["x","y"]"""),
            fields(Outgoing.snapshotSave("Kunde Müller", listOf("x", "y"))))
        assertEquals(mapOf("t" to "snapshot", "op" to "open", "id" to "a"), fields(Outgoing.snapshotOpen("a")))
        assertEquals(mapOf("t" to "snapshot", "op" to "delete", "id" to "a"), fields(Outgoing.snapshotDelete("a")))
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
