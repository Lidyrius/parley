package de.developaway.parley

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import org.json.JSONArray
import org.json.JSONObject
import java.math.BigInteger
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.MessageDigest
import java.security.interfaces.ECPrivateKey
import java.security.interfaces.ECPublicKey
import java.security.spec.ECFieldFp
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECPoint
import java.security.spec.ECPublicKeySpec
import java.security.spec.PKCS8EncodedKeySpec
import java.util.Base64
import java.util.Locale
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.KeyAgreement
import javax.crypto.KeyGenerator
import javax.crypto.Mac
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * v7 (docs/IPHONE.md, ios/ParleyMobile/Guests.swift): someone else's session this phone joined.
 * Its own room and key — a second relay connection beside (or without) the own Mac's.
 * `secret` is this phone's P-256 key for this share (PKCS#8, base64); `pub` its public half
 * (x9.63, base64url) — the move to the fresh room is sealed to it.
 */
data class GuestShare(
    val pairing: Pairing,
    val label: String,                  // the session's name
    val host: String,                   // who shares it
    val name: String,                   // how this phone's owner introduced himself
    val role: String = "",
    val listen: Boolean = false,        // "nur zuhören"
    val active: Boolean = false,        // let in (false: waits for the owner's yes)
    val share: String = "",             // the share's id on the owner's host (once let in)
    val secret: String,
    val pub: String,
    val id: String = UUID.randomUUID().toString(),
) {
    /** The four digits the owner sees in the request — the same on both sides (Shares.code on the Mac). */
    val code: String get() = code(pub)

    /** The fresh room from a `move`: opened with this phone's key — null if it wasn't sealed to it. */
    fun open(m: ShareMove): Triple<String, String, String>? = runCatching {
        val mine = KeyFactory.getInstance("EC").generatePrivate(PKCS8EncodedKeySpec(Base64.getDecoder().decode(secret))) as ECPrivateKey
        val theirs = publicKey(unb64url(m.pub), mine) ?: return null
        val plain = openBox(moveKey(mine, theirs, m.share), unb64url(m.box)) ?: return null
        val o = JSONObject(String(plain, Charsets.UTF_8))
        Triple(o.getString("r"), o.getString("k"), o.getString("e"))
    }.getOrNull()

    fun toJson(): JSONObject = JSONObject().put("id", id).put("label", label).put("host", host).put("name", name).put("role", role)
        .put("listen", listen).put("active", active).put("share", share).put("secret", secret).put("pub", pub)
        .put("pairing", JSONObject().put("relay", pairing.relay).put("room", pairing.room).put("secret", pairing.secret).put("key", pairing.key ?: ""))

    companion object {
        /** A share with a fresh key of its own. */
        fun create(pairing: Pairing, label: String, host: String, name: String): GuestShare {
            val pair = KeyPairGenerator.getInstance("EC").apply { initialize(ECGenParameterSpec("secp256r1")) }.generateKeyPair()
            return GuestShare(pairing, label, host, name, secret = Base64.getEncoder().encodeToString(pair.private.encoded),
                pub = b64url(x963(pair.public as ECPublicKey)))
        }

        fun fromJson(o: JSONObject): GuestShare? = runCatching {
            val p = o.getJSONObject("pairing")
            GuestShare(Pairing(p.getString("relay"), p.getString("room"), p.getString("secret"), p.optString("key").ifEmpty { null }),
                o.getString("label"), o.getString("host"), o.getString("name"), o.optString("role"), o.optBoolean("listen"),
                o.optBoolean("active"), o.optString("share"), o.getString("secret"), o.getString("pub"), o.getString("id"))
        }.getOrNull()

        /** SHA-256 of the key string, its first 4 bytes as an unsigned big-endian number, mod 10 000. */
        fun code(pub: String): String {
            val d = MessageDigest.getInstance("SHA-256").digest(pub.toByteArray(Charsets.UTF_8))
            val n = d.take(4).fold(0L) { acc, b -> (acc shl 8) or (b.toLong() and 0xff) }
            return String.format(Locale.ROOT, "%04d", n % 10_000)
        }

        fun b64url(d: ByteArray): String = Base64.getUrlEncoder().withoutPadding().encodeToString(d)
        fun unb64url(s: String): ByteArray = Base64.getUrlDecoder().decode(s.trimEnd('='))

        /** 0x04 ‖ X ‖ Y, 32 bytes each. */
        fun x963(k: ECPublicKey): ByteArray = byteArrayOf(4) + fixed(k.w.affineX) + fixed(k.w.affineY)

        private fun fixed(n: BigInteger): ByteArray {
            val b = n.toByteArray().dropWhile { it == 0.toByte() }.toByteArray()
            return ByteArray(32 - b.size) + b
        }

        /** An x9.63 point on the same curve as `like` — checked to lie on it (null otherwise). */
        fun publicKey(raw: ByteArray, like: ECPrivateKey): ECPublicKey? {
            if (raw.size != 65 || raw[0] != 4.toByte()) return null
            val x = BigInteger(1, raw.copyOfRange(1, 33))
            val y = BigInteger(1, raw.copyOfRange(33, 65))
            val curve = like.params.curve
            val p = (curve.field as ECFieldFp).p
            if (x >= p || y >= p || y.modPow(BigInteger.valueOf(2), p) != x.pow(3).add(curve.a.multiply(x)).add(curve.b).mod(p)) return null
            return KeyFactory.getInstance("EC").generatePublic(ECPublicKeySpec(ECPoint(x, y), like.params)) as ECPublicKey
        }

        /** ECDH → HKDF-SHA256 (salt: the share's id, info "parley-share-move") → a 32-byte AES key (Shares.sealMove). */
        fun moveKey(mine: ECPrivateKey, theirs: ECPublicKey, share: String): ByteArray {
            val shared = KeyAgreement.getInstance("ECDH").apply { init(mine); doPhase(theirs, true) }.generateSecret()
            return hkdf(shared, share.toByteArray(Charsets.UTF_8), "parley-share-move".toByteArray(Charsets.UTF_8), 32)
        }

        /** RFC 5869 with HMAC-SHA256. */
        fun hkdf(ikm: ByteArray, salt: ByteArray, info: ByteArray, length: Int): ByteArray {
            fun hmac(key: ByteArray, data: ByteArray) = Mac.getInstance("HmacSHA256").apply {
                init(SecretKeySpec(if (key.isEmpty()) ByteArray(32) else key, "HmacSHA256"))
            }.doFinal(data)
            val prk = hmac(salt, ikm)
            var t = ByteArray(0)
            var out = ByteArray(0)
            var i = 1
            while (out.size < length) { t = hmac(prk, t + info + byteArrayOf(i.toByte())); out += t; i++ }
            return out.copyOf(length)
        }

        /** AES-GCM, nonce (12) ‖ ciphertext ‖ tag (16) — CryptoKit's `combined`. */
        fun openBox(key: ByteArray, box: ByteArray): ByteArray? {
            if (box.size < 12 + 16) return null
            return runCatching {
                Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, box, 0, 12)) }
                    .doFinal(box, 12, box.size - 12)
            }.getOrNull()
        }
    }
}

/**
 * The shares this phone joined, with their rooms and keys: app-private and, unlike the own
 * pairing, sealed with an AES key that never leaves the Android Keystore (the iPhone keeps them
 * in the Keychain, this device only).
 */
object GuestStore {
    private const val ALIAS = "parley-guests"
    private fun prefs(c: Context) = c.getSharedPreferences("guests", Context.MODE_PRIVATE)

    private fun key(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256).build())
        }.generateKey()
    }

    fun load(c: Context): List<GuestShare> = runCatching {
        val blob = Base64.getDecoder().decode(prefs(c).getString("list", null) ?: return emptyList())
        val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, blob, 0, 12)) }
        val list = JSONArray(String(cipher.doFinal(blob, 12, blob.size - 12), Charsets.UTF_8))
        (0 until list.length()).mapNotNull { list.optJSONObject(it)?.let(GuestShare::fromJson) }
    }.getOrDefault(emptyList())

    fun save(c: Context, list: List<GuestShare>) {
        if (list.isEmpty()) { prefs(c).edit().remove("list").apply(); return }
        runCatching {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, key()) }
            val sealed = cipher.iv + cipher.doFinal(JSONArray(list.map { it.toJson() }).toString().toByteArray(Charsets.UTF_8))
            prefs(c).edit().putString("list", Base64.getEncoder().encodeToString(sealed)).apply()
        }
    }
}
