package app.alextran.immich.core

import android.app.Application
import android.net.Uri
import java.net.InetAddress
import okhttp3.Dns
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], manifest = Config.NONE, application = Application::class)
class TailscaleEndpointVerifierTest {
  @Test
  fun allowsTailscaleIpv4AndIpv6AndMagicDnsUrls() {
    for (url in listOf(
      "http://100.64.0.1:2283/api",
      "http://100.127.255.254:2283/api",
      "https://immich.tailnet.ts.net/api",
      "http://[fd7a:115c:a1e0::1]:2283/api",
    )) {
      assertEquals(url, TailscaleEndpointVerifier.parseUrl(url).toString())
    }
  }

  @Test
  fun rejectsPublicAndLanUrlsAndEmbeddedCredentials() {
    for (url in listOf(
      "https://immich.example/api",
      "https://immich.ts.net.example/api",
      "http://127.0.0.1/api",
      "http://192.168.1.10/api",
      "http://100.63.255.255/api",
      "http://100.128.0.0/api",
      "http://[fd00::1]/api",
      "https://user:password@immich.tailnet.ts.net/api",
      "ftp://100.64.0.1/api",
    )) {
      val error = assertThrows(ExternalPlayerError::class.java) { TailscaleEndpointVerifier.parseUrl(url) }
      assertEquals("UNSAFE_ENDPOINT", error.code)
      assertFalse(error.message!!.contains(url))
    }
  }

  @Test
  fun validatesAllDnsResultsBeforeSendingTheStreamRequest() {
    var requested = false
    val verifier = verifier(listOf(ipv4(100, 64, 0, 1), ipv4(203, 0, 113, 2))) { _, _ ->
      requested = true
      206
    }

    val error = assertThrows(ExternalPlayerError::class.java) { verifier.verify(PRIVATE_URL) }

    assertEquals("UNSAFE_ENDPOINT", error.code)
    assertFalse(requested)
  }

  @Test
  fun rejectsMagicDnsResolvingOnlyToLanOrNoAddresses() {
    for (addresses in listOf(emptyList(), listOf(ipv4(192, 168, 1, 10)))) {
      val verifier = verifier(addresses) { _, _ -> throw AssertionError("Preflight must not run") }
      val error = assertThrows(ExternalPlayerError::class.java) { verifier.verify(PRIVATE_URL) }
      assertEquals("UNSAFE_ENDPOINT", error.code)
    }
  }

  @Test
  fun acceptsIpv6OnlyWithinTheTailscalePrefix() {
    val tailnet = InetAddress.getByAddress(byteArrayOf(
      0xfd.toByte(), 0x7a, 0x11, 0x5c, 0xa1.toByte(), 0xe0.toByte(), 0, 0, 0, 0, 0, 0, 0, 0, 0, 1,
    ))
    val public = InetAddress.getByAddress(byteArrayOf(
      0x20, 0x01, 0x0d, 0xb8.toByte(), 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1,
    ))
    assertEquals(listOf(tailnet), verifier(listOf(tailnet)).resolve(PRIVATE_URL))
    val error = assertThrows(ExternalPlayerError::class.java) { verifier(listOf(public)).resolve(PRIVATE_URL) }
    assertEquals("UNSAFE_ENDPOINT", error.code)
  }

  @Test
  fun endpointValidationDoesNotRequestAnyVideoBytes() {
    val verifier = verifier(listOf(ipv4(100, 64, 0, 1))) { _, _ -> throw AssertionError("Preflight must not run") }
    assertEquals(1, verifier.resolve(PRIVATE_URL).size)
  }

  @Test
  fun rejectsRedirectsWithoutOpeningTheRedirectTarget() {
    for (status in listOf(301, 302, 307, 308)) {
      var requests = 0
      val verifier = verifier(listOf(ipv4(100, 64, 0, 1))) { _, _ ->
        requests++
        status
      }
      val error = assertThrows(ExternalPlayerError::class.java) { verifier.verify(PRIVATE_URL) }
      assertEquals("UNSAFE_ENDPOINT", error.code)
      assertEquals(1, requests)
    }
  }

  @Test
  fun usesOnlyVettedAddressesForThePreflight() {
    val address = ipv4(100, 64, 0, 1)
    var requested = false
    val verifier = verifier(listOf(address)) { uri, addresses ->
      assertEquals(PRIVATE_URL, uri)
      assertEquals(listOf(address), addresses)
      requested = true
      206
    }
    verifier.verify(PRIVATE_URL)
    assertTrue(requested)
  }

  private fun verifier(
    addresses: List<InetAddress>,
    preflight: (Uri, List<InetAddress>) -> Int = { _, _ -> 206 },
  ): TailscaleEndpointVerifier {
    return TailscaleEndpointVerifier(object : Dns {
      override fun lookup(hostname: String): List<InetAddress> = addresses
    }, preflight)
  }

  private fun ipv4(vararg bytes: Int): InetAddress = InetAddress.getByAddress(bytes.map(Int::toByte).toByteArray())

  companion object {
    private val PRIVATE_URL = Uri.parse("https://immich.tailnet.ts.net/api/assets/video/video/playback?key=test-temporary-key")
  }
}
