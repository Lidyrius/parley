package de.developaway.parley

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.security.KeyPairGenerator
import java.security.SecureRandom
import java.security.interfaces.ECPrivateKey
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/** v7 shared sessions, as ios/ParleyMobileTests/FrameTests.swift (keys sorted, like the iPhone's encoder). */
class SharesTest {
    private fun sorted(json: String): String = JSONObject(json).let { o ->
        o.keys().asSequence().sorted().joinToString(",", "{", "}") { "\"$it\":" + JSONObject.valueToString(o.get(it)) }
    }

    @Test fun pastedCodeAndRememberedRoles() {
        assertEquals("4821", codeDigits("Mein Parley-Code für „Shirts“: 4821"))
        assertEquals("1234", codeDigits("12 1234567"))
        assertNull(codeDigits("12 34"))
        assertEquals("w1", GuestRoles.key(JoinRequest("s", "w", "W", "Max", who = "w1")))
        assertEquals("name:max", GuestRoles.key(JoinRequest("s", "w", "W", "Max", who = "")))
        assertEquals(listOf("B", "A"), GuestRoles.add(listOf("A", "B"), "B"))
        assertEquals(6, GuestRoles.add(listOf("1", "2", "3", "4", "5", "6"), "7").size)
    }

    @Test fun shareFramesAndJoinLinks() {
        val link = "parley://join?u=https%3A%2F%2Frelay.example&r=AAAAAAAAAAAAAAAAAAAAAA&k=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB&e=CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC&s=Website&h=Sydney"
        val j = JoinLink.parse(link)!!
        assertEquals("Website", j.label)
        assertEquals("Sydney", j.host)
        assertEquals("AAAAAAAAAAAAAAAAAAAAAA", j.pairing.room)
        assertEquals("https://relay.example", j.pairing.relay)
        assertNull(JoinLink.parse(link.replace("&e=CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC", "")))   // never in the clear
        assertNull(JoinLink.parse("parley://pair?u=x"))
        // As sent: https://<relay>/join#<the link, percent-encoded once more> — a label with spaces survives.
        val app = link.replace("s=Website", "s=Kunde%20M%C3%BCller")
        val sent = "https://relay.example/join#" + java.net.URLEncoder.encode(app, "UTF-8").replace("+", "%20")
        assertEquals("Kunde Müller", JoinLink.parse(sent)?.label)
        assertNull(JoinLink.parse(link.replace("https%3A", "http%3A")))
        assertEquals("Café & Co", JoinLink.parse(link.replace("s=Website", "s=Caf%C3%A9%20%26%20Co"))!!.label)

        val snap = (Frames.parse("""{"t":"sessions","sessions":[{"id":"w","shared":[{"id":"s1","name":"Max","role":"Marketing"},{"name":"no id"}]}]}""")
            as Incoming.Sessions).snapshot
        assertEquals(listOf(ShareTag("s1", "Max", "Marketing")), snap.sessions[0].shared)
        assertEquals(Incoming.Join(JoinRequest("s1", "w", "Website", "Max")),
            Frames.parse("""{"t":"join","id":"s1","session":"w","label":"Website","name":"Max"}"""))
        assertEquals(Incoming.Join(JoinRequest("s1", "w", "Website", "Max", "Pixel 9", "0042")),
            Frames.parse("""{"t":"join","id":"s1","session":"w","label":"Website","name":"Max","device":"Pixel 9","code":"0042"}"""))
        assertEquals(Incoming.Join(JoinRequest("s1", "w", "Website", "Max", "Pixel 9", "0042", "abc")),
            Frames.parse("""{"t":"join","id":"s1","session":"w","label":"Website","name":"Max","device":"Pixel 9","code":"0042","who":"abc"}"""))
        assertEquals(Incoming.Move(ShareMove("s1", "P", "B", "Marketing", true)),
            Frames.parse("""{"t":"move","share":"s1","pub":"P","box":"B","role":"Marketing","listen":true}"""))
        assertEquals(Incoming.ShareEnd, Frames.parse("""{"t":"share-end"}"""))
        assertEquals(Incoming.Notice("Zu viele Nachrichten."), Frames.parse("""{"t":"notice","text":"Zu viele Nachrichten."}"""))
        assertEquals(Incoming.ShareLink("s1", "w", "parley://join?x"), Frames.parse("""{"t":"share","id":"s1","session":"w","link":"parley://join?x"}"""))
        assertEquals(Incoming.Ignored, Frames.parse("""{"t":"move","share":"s1"}"""))

        val item = (Frames.parse("""{"t":"history","id":"w","items":[{"id":"a","k":"user","text":"Hi","by":"Max"},{"id":"b","k":"user","text":"Ja"}]}""")
            as Incoming.History).page.items
        assertEquals("Max", item[0].by)
        assertNull(item[1].by)

        assertEquals("""{"id":"w","op":"create","t":"share"}""", sorted(Outgoing.shareCreate("w")))
        assertEquals("""{"id":"s1","op":"remove","t":"share"}""", sorted(Outgoing.shareRemove("s1")))
        assertEquals("""{"device":"Pixel","name":"Max","pub":"P","t":"join","who":"W"}""", sorted(Outgoing.join("Max", "Pixel", "P", "W")))
        assertEquals("""{"full":true,"id":"s1","listen":false,"mine":"T","op":"approve","role":"M","t":"share"}""",
            sorted(Outgoing.shareApprove("s1", "M", false, true, "T")))
    }

    @Test fun guestQuestionFrames() {
        assertEquals(Incoming.Ask(GuestAsk("q1", "w", "Website", "Welche?", listOf("A", "B"), 120)),
            Frames.parse("""{"t":"ask","id":"q1","session":"w","label":"Website","text":"Welche?","replies":["A","B"],"seconds":120}"""))
        assertEquals(Incoming.AskEnd("q1"), Frames.parse("""{"t":"ask-end","id":"q1"}"""))
        assertEquals("""{"id":"q1","t":"answer","text":"B"}""", sorted(Outgoing.answer("q1", "B")))
        assertEquals("""{"id":"q1","pass":true,"t":"answer"}""", sorted(Outgoing.answer("q1", "", pass = true)))
        val s = (Frames.parse("""{"t":"sessions","sessions":[{"id":"w","asking":"Max"}]}""") as Incoming.Sessions).snapshot.sessions[0]
        assertEquals("Max", s.asking)
    }

    private val pairing = Pairing("https://relay.example", "AAAAAAAAAAAAAAAAAAAAAA", "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB", "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC")

    /** The move sealed like the Mac does (Shares.sealMove): only the guest's own key opens it. */
    @Test fun guestOpensOnlyItsOwnMove() {
        val g = GuestShare.create(pairing, "W", "H", "Max")
        val other = GuestShare.create(pairing, "W", "H", "Mallory")
        val host = KeyPairGenerator.getInstance("EC").apply { initialize(ECGenParameterSpec("secp256r1")) }.generateKeyPair()
        val hostKey = host.private as ECPrivateKey
        val key = GuestShare.moveKey(hostKey, GuestShare.publicKey(GuestShare.unb64url(g.pub), hostKey)!!, "share1")
        val nonce = ByteArray(12).also { SecureRandom().nextBytes(it) }
        val box = nonce + Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce)) }
            .doFinal("""{"r":"NEWROOM","k":"NEWSECRET","e":"NEWKEY"}""".toByteArray())
        val m = ShareMove("share1", GuestShare.b64url(GuestShare.x963(host.public as ECPublicKey)), GuestShare.b64url(box), "M", false)
        assertEquals(Triple("NEWROOM", "NEWSECRET", "NEWKEY"), g.open(m))
        assertNull(other.open(m))
        assertNull(g.open(m.copy(share = "share2")))   // the share's id is in the key
        assertEquals(65, GuestShare.unb64url(g.pub).size)
        assertEquals(4, g.code.length)
        assertEquals("6299", GuestShare.code("test-pub"))   // same vector as the Mac's SharesTests
        assertEquals(g, GuestShare.fromJson(JSONObject(g.toJson().toString())))
    }

    /** A move sealed by CryptoKit (as the Mac's Shares.sealMove), opened here. */
    @Test fun opensAMoveSealedByCryptoKit() {
        val g = GuestShare(pairing, "W", "H", "Max",
            secret = "MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgHwM4HHAeHpcxUbCPBQrp/q/GtosW0bWReg9PcH5ISZGhRANCAASu0n7MN6ZhFxrm6yzPOa2NFOSFdkgmxkr+8AaiZnUiSGQMy0s8LJE8K4ALB0wEOu5Vgp9/WXPgBhDUkwqbqkgv",
            pub = "BK7Sfsw3pmEXGubrLM85rY0U5IV2SCbGSv7wBqJmdSJIZAzLSzwskTwrgAsHTAQ67lWCn39Zc-AGENSTCpuqSC8")
        val m = ShareMove("share1", "BMfGNlXAojSWUKQHhjlIGtla6Yv82WOdQyjWPwviLNC2yFnwCn8r7lcQPyUZXUs4yhkgLE8dHYfhz6i6jJbryRk",
            "tev1j3y-4lSvowvaDxTLsZ4OlIsoB05IziAcwo5f9jlJY3OOxcE3svoJfH8DE_FdMhw7-jE8tHqvrdKr1UK19ir38vQCAm3p56TqYkzOWdDk0x9ImZsIEV1LKUJZh83Qs0zGeUODO9sKkcWUuE6Agj31pSSZ2ABzaoiXW9XVygWBThLw")
        val room = g.open(m)
        assertNotNull(room)
        assertEquals("NEWROOMNEWROOMNEWROOM", room!!.first)
        // The fresh room becomes the share's pairing (Pairing.check) — with its end-to-end key.
        val moved = Pairing.check(pairing.relay, room.first, room.second, room.third)
        assertEquals("CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC", moved.key)
        // A point off the curve is refused, not used.
        val bad = GuestShare.unb64url(m.pub).also { it[64] = (it[64] + 1).toByte() }
        assertNull(g.open(m.copy(pub = GuestShare.b64url(bad))))
        assertTrue(GuestShare.hkdf(ByteArray(22) { 0x0b }, ByteArray(13) { it.toByte() }, ByteArray(10) { (0xf0 + it).toByte() }, 42)
            .joinToString("") { "%02x".format(it) }
            .startsWith("3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865"))   // RFC 5869 A.1
    }
}
