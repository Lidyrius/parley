package de.developaway.parley

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** v7 part 3: the guest's phone rings on his share's room; only the call's own line drives the call. */
class CallLineTest {
    private val ring = Frames.parse("""{"t":"ring","label":"Rückfrage · Website"}""")
    private val audio = Frames.parse("""{"t":"audio","state":"speaking","label":"Website"}""")
    private val caption = Frames.parse("""{"t":"caption","words":["Welche","Variante?"],"at":[0,0.4],"end":1.2}""")
    private val peer = Frames.parse("""{"t":"peer","host":true}""")

    @Test fun framesParse() {
        assertEquals(Incoming.Ring("Rückfrage · Website"), ring)
        assertEquals(Incoming.Audio(HostAudio.speaking, "Website"), audio)
        assertEquals(true, caption is Incoming.CaptionFrame)
    }

    @Test fun onlyTheCallsLineDrivesIt() {
        // From the line the call runs on (own or a share's): everything reaches the call.
        for (share in listOf(false, true)) {
            assertEquals(CallStep.Audio(HostAudio.speaking, "Website"), CallLine.step(audio, onLine = true, share = share, canRing = true, idle = false))
            assertEquals(CallStep.LinkChanged, CallLine.step(peer, onLine = true, share = share, canRing = true, idle = false))
            assertEquals(true, CallLine.step(caption, onLine = true, share = share, canRing = true, idle = false) is CallStep.Captions)
        }
        // A guest's call runs on his share's room: the own host's audio, captions and comings don't touch it —
        // and Sir's own call ignores a share's room.
        for (share in listOf(false, true)) {
            assertNull(CallLine.step(audio, onLine = false, share = share, canRing = true, idle = false))
            assertNull(CallLine.step(peer, onLine = false, share = share, canRing = true, idle = false))
            assertNull(CallLine.step(caption, onLine = false, share = share, canRing = true, idle = false))
        }
        assertNull(CallLine.step(Frames.parse("""{"t":"ask-end","id":"q1"}"""), onLine = true, share = true, canRing = true, idle = true))
    }

    @Test fun aSharesRingRingsWhenThePhoneCanAndNoCallIsUp() {
        // In the app, or while Unterwegs keeps the room open: it rings with the frame's label.
        assertEquals(CallStep.Ring("Rückfrage · Website"), CallLine.step(ring, onLine = false, share = true, canRing = true, idle = true))
        // In the background without the service (the room is closed then anyway), or with a call up: not.
        assertNull(CallLine.step(ring, onLine = false, share = true, canRing = false, idle = true))
        assertNull(CallLine.step(ring, onLine = true, share = true, canRing = true, idle = false))
        // The own host's ring always reaches the controller (it ignores it while a call is up).
        assertEquals(CallStep.Ring("Rückfrage · Website"), CallLine.step(ring, onLine = true, share = false, canRing = false, idle = false))
    }
}
