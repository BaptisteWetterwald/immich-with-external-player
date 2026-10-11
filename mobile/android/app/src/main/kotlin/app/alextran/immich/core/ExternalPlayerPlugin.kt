package app.alextran.immich.core

import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.net.InetAddress
import java.net.Proxy
import java.util.Locale
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.Dns
import okhttp3.OkHttpClient
import okhttp3.Request

class ExternalPlayerPlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler {
  private var channel: MethodChannel? = null
  private var activity: Activity? = null
  private var scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    channel = MethodChannel(binding.binaryMessenger, "immich/external_player").also {
      it.setMethodCallHandler(this)
    }
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    channel?.setMethodCallHandler(null)
    channel = null
    activity = null
    scope.cancel()
  }

  override fun onAttachedToActivity(binding: ActivityPluginBinding) {
    activity = binding.activity
  }

  override fun onDetachedFromActivityForConfigChanges() {
    activity = null
  }

  override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
    onAttachedToActivity(binding)
  }

  override fun onDetachedFromActivity() {
    activity = null
  }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    if (call.method !in listOf("isAvailable", "validateEndpoint", "open")) {
      result.notImplemented()
      return
    }

    val arguments = call.arguments as? Map<*, *>
    if (call.method == "validateEndpoint") {
      try {
        val uri = TailscaleEndpointVerifier.parseUrl(arguments?.get("url") as? String)
        scope.launch {
          try {
            withContext(Dispatchers.IO) { TailscaleEndpointVerifier().resolve(uri) }
            result.success(null)
          } catch (error: Exception) {
            reportError(error, result)
          }
        }
      } catch (error: Exception) {
        reportError(error, result)
      }
      return
    }

    val currentActivity = activity
    if (currentActivity == null) {
      if (call.method == "isAvailable") {
        result.success(false)
      } else {
        result.error("NO_ACTIVITY", "An active Android activity is required.", null)
      }
      return
    }

    try {
      val launcher = ExternalPlayerLauncher(currentActivity)
      when (call.method) {
        "isAvailable" -> result.success(launcher.isAvailable())
        "open" -> {
          val video = launcher.prepare(
            arguments?.get("url") as? String,
            arguments?.get("mimeType") as? String,
            arguments?.get("title") as? String,
            arguments?.get("chooserTitle") as? String,
          )
          scope.launch {
            try {
              withContext(Dispatchers.IO) { launcher.verify(video) }
              if (activity !== currentActivity || currentActivity.isFinishing || currentActivity.isDestroyed) {
                throw ExternalPlayerError("NO_ACTIVITY", "An active Android activity is required.")
              }
              launcher.launch(video)
              result.success(null)
            } catch (error: Exception) {
              reportError(error, result)
            }
          }
        }
      }
    } catch (error: Exception) {
      reportError(error, result)
    }
  }

  private fun reportError(error: Exception, result: MethodChannel.Result) {
    if (error is CancellationException) throw error
    if (error is ExternalPlayerError) {
      result.error(error.code, error.message, null)
    } else {
      // URLs contain a temporary access key. Never return network or Android exception details.
      result.error("LAUNCH_FAILED", "The external video player could not be opened.", null)
    }
  }
}

internal class ExternalPlayerLauncher(
  private val activity: Activity,
  private val verifyEndpoint: (Uri) -> Unit = TailscaleEndpointVerifier()::verify,
) {
  fun isAvailable(): Boolean {
    return listOf("https", "http").any { scheme ->
      players(Intent(Intent.ACTION_VIEW).setDataAndType(Uri.parse("$scheme://immich.invalid/video"), "video/*"))
        .isNotEmpty()
    }
  }

  fun prepare(url: String?, mimeType: String?, title: String?, chooserTitle: String?): ExternalVideo {
    val uri = TailscaleEndpointVerifier.parseUrl(url)
    if (mimeType == null || title == null || chooserTitle == null) {
      throw ExternalPlayerError("INVALID_ARGUMENT", "Video player arguments are required.")
    }
    if (!mimeType.startsWith("video/") || mimeType.length <= "video/".length) {
      throw ExternalPlayerError("INVALID_ARGUMENT", "An HTTP video URL and video MIME type are required.")
    }

    val video = ExternalVideo(uri, mimeType, title, chooserTitle)
    if (players(video.intent()).isEmpty()) {
      throw ExternalPlayerError("NO_PLAYER", "No external video player is installed.")
    }
    return video
  }

  fun verify(video: ExternalVideo) {
    verifyEndpoint(video.uri)
  }

  fun launch(video: ExternalVideo) {
    val intent = video.intent()
    val candidates = players(intent)
    if (candidates.isEmpty()) {
      throw ExternalPlayerError("NO_PLAYER", "No external video player is installed.")
    }

    val launchIntent = if (JUST_PLAYER_PACKAGE in candidates) {
      intent.setPackage(JUST_PLAYER_PACKAGE)
    } else {
      Intent.createChooser(intent, video.chooserTitle)
    }
    try {
      activity.startActivity(launchIntent)
    } catch (_: RuntimeException) {
      throw ExternalPlayerError("LAUNCH_FAILED", "The external video player could not be opened.")
    }
  }

  private fun players(intent: Intent): Set<String> {
    return activity.packageManager.queryIntentActivities(intent, PackageManager.MATCH_DEFAULT_ONLY)
      .mapNotNull { match ->
        match.activityInfo.takeIf { it.enabled && it.exported && it.packageName != activity.packageName }?.packageName
      }.toSet()
  }

  companion object {
    private const val JUST_PLAYER_PACKAGE = "com.brouken.player"
  }
}

internal data class ExternalVideo(val uri: Uri, val mimeType: String, val title: String, val chooserTitle: String) {
  fun intent(): Intent = Intent(Intent.ACTION_VIEW).setDataAndType(uri, mimeType).apply {
    putExtra(Intent.EXTRA_TITLE, title)
    putExtra("title", title)
  }
}

internal class TailscaleEndpointVerifier(
  private val dns: Dns = Dns.SYSTEM,
  private val preflight: (Uri, List<InetAddress>) -> Int = ::requestStatus,
) {
  fun resolve(uri: Uri): List<InetAddress> {
    val host = normalizeHost(uri.host.orEmpty())
    if (!isAllowedHost(host)) throw unsafeEndpoint()
    val addresses = dns.lookup(host)
    if (addresses.isEmpty() || addresses.any { !isTailscaleAddress(it) }) throw unsafeEndpoint()
    return addresses
  }

  fun verify(uri: Uri) {
    val status = preflight(uri, resolve(uri))
    if (status in 300..399) throw unsafeEndpoint()
    if (status !in 200..299) {
      throw ExternalPlayerError("LAUNCH_FAILED", "The video stream is not available.")
    }
  }

  companion object {
    fun parseUrl(url: String?): Uri {
      if (url == null) throw ExternalPlayerError("INVALID_ARGUMENT", "A video URL is required.")
      val uri = Uri.parse(url)
      if (uri.scheme !in listOf("http", "https") || uri.userInfo != null ||
        !isAllowedHost(normalizeHost(uri.host.orEmpty()))) {
        throw unsafeEndpoint()
      }
      return uri
    }

    private fun normalizeHost(host: String): String = host.removeSurrounding("[", "]").lowercase(Locale.ROOT)

    private fun isAllowedHost(host: String): Boolean {
      if (host.endsWith(".ts.net") && host.length > ".ts.net".length && !host.contains('%')) return true
      if (host.startsWith("fd7a:115c:a1e0:") && !host.contains('%')) return true
      val parts = host.split('.')
      val bytes = parts.map { it.toIntOrNull() }
      return parts.size == 4 && bytes.all { it != null && it in 0..255 } &&
        bytes[0] == 100 && bytes[1]?.let { it in 64..127 } == true
    }

    private fun isTailscaleAddress(address: InetAddress): Boolean {
      val bytes = address.address.map { it.toInt() and 0xff }
      return when (bytes.size) {
        4 -> bytes[0] == 100 && bytes[1] in 64..127
        16 -> bytes.take(6) == listOf(0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0)
        else -> false
      }
    }

    private fun requestStatus(uri: Uri, addresses: List<InetAddress>): Int {
      val expectedHost = normalizeHost(uri.host.orEmpty())
      val client = OkHttpClient.Builder()
        .dns(object : Dns {
          override fun lookup(hostname: String): List<InetAddress> {
            if (normalizeHost(hostname) != expectedHost) throw unsafeEndpoint()
            return addresses
          }
        })
        .proxy(Proxy.NO_PROXY)
        .followRedirects(false)
        .followSslRedirects(false)
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(10, TimeUnit.SECONDS)
        .callTimeout(15, TimeUnit.SECONDS)
        .build()
      val request = Request.Builder().url(uri.toString()).header("Range", "bytes=0-0").build()
      // Read only the response headers. No account authorization is passed to the player or preflight.
      return client.newCall(request).execute().use { it.code }
    }

    private fun unsafeEndpoint() = ExternalPlayerError("UNSAFE_ENDPOINT", "A direct Tailscale video endpoint is required.")
  }
}

internal class ExternalPlayerError(val code: String, message: String) : RuntimeException(message)
