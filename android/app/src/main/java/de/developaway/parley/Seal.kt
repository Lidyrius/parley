package de.developaway.parley

import org.json.JSONObject
import java.nio.ByteBuffer
import java.security.SecureRandom
import java.util.Base64
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * End-to-end encryption between the host and the phone (docs/IPHONE.md → v5), as the Mac's
 * Seal.swift: AES-256-GCM under the pairing key, which only travels in the QR code — the relay can
 * neither read nor forge a frame. Sealed bytes: nonce ‖ ciphertext ‖ tag; plaintext: sender clock
 * (8 bytes BE, epoch ms) ‖ payload. Text frames keep their `t` readable outside.
 */
class Seal private constructor(private val key: SecretKeySpec) {

    /** `{"t":"<t>","e":"<sealed>"}`; null for a frame without a string `t`. */
    fun text(json: String, now: Long = System.currentTimeMillis()): String? {
        val t = typeOf(json) ?: return null
        val sealed = seal(json.toByteArray(), "parley1/text/$t", now)
        return JSONObject().put("t", t).put("e", Base64.getEncoder().encodeToString(sealed)).toString()
    }

    fun binary(data: ByteArray, now: Long = System.currentTimeMillis()): ByteArray = seal(data, "parley1/bin", now)

    /** A sealed text frame → its JSON; null unless it opens and matches its `t`. */
    fun openText(wire: String): String? {
        val o = runCatching { JSONObject(wire) }.getOrNull() ?: return null
        val t = o.optString("t").takeIf { it.isNotEmpty() } ?: return null
        val e = o.optString("e").takeIf { it.isNotEmpty() } ?: return null
        val sealed = runCatching { Base64.getDecoder().decode(e) }.getOrNull() ?: return null
        val json = open(sealed, "parley1/text/$t")?.let { String(it) } ?: return null
        return json.takeIf { typeOf(it) == t }
    }

    fun openBinary(sealed: ByteArray): ByteArray? = open(sealed, "parley1/bin")

    private fun seal(payload: ByteArray, aad: String, now: Long): ByteArray {
        val nonce = ByteArray(12).also { random.nextBytes(it) }
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.ENCRYPT_MODE, key, GCMParameterSpec(128, nonce))
        c.updateAAD(aad.toByteArray())
        return nonce + c.doFinal(ByteBuffer.allocate(8 + payload.size).putLong(now).put(payload).array())
    }

    private fun open(sealed: ByteArray, aad: String): ByteArray? {
        if (sealed.size < 12 + 8 + 16) return null
        return runCatching {
            val c = Cipher.getInstance("AES/GCM/NoPadding")
            c.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, sealed, 0, 12))
            c.updateAAD(aad.toByteArray())
            c.doFinal(sealed, 12, sealed.size - 12).copyOfRange(8, sealed.size - 12 - 16)
        }.getOrNull()
    }

    companion object {
        private val random = SecureRandom()

        /** The pairing key (32 bytes, base64url); null when it isn't one. */
        fun of(key: String?): Seal? {
            val bytes = key?.let { runCatching { Base64.getUrlDecoder().decode(it) }.getOrNull() } ?: return null
            return if (bytes.size == 32) Seal(SecretKeySpec(bytes, "AES")) else null
        }

        fun isSealed(text: String): Boolean = runCatching { JSONObject(text).optString("e").isNotEmpty() }.getOrDefault(false)

        private fun typeOf(json: String) = runCatching { JSONObject(json).optString("t") }.getOrNull()?.takeIf { it.isNotEmpty() }
    }
}
