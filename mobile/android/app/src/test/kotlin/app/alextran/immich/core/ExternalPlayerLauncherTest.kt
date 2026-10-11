package app.alextran.immich.core

import android.app.Activity
import android.app.Application
import android.content.ComponentName
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ActivityInfo
import android.content.pm.ApplicationInfo
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], manifest = Config.NONE, application = Application::class)
class ExternalPlayerLauncherTest {
  private lateinit var activity: Activity
  private lateinit var launcher: ExternalPlayerLauncher

  @Before
  fun setUp() {
    activity = Robolectric.buildActivity(Activity::class.java).setup().get()
    launcher = ExternalPlayerLauncher(activity) {}
  }

  @Test
  fun prefersJustPlayerAndPassesTheVideoWithoutSessionHeaders() {
    registerPlayer("other.video.player")
    registerPlayer("com.brouken.player")

    open(VIDEO_URL, "video/*", "Holiday.mp4", "Choose a video player")

    val launched = shadowOf(activity).nextStartedActivity
    assertEquals(Intent.ACTION_VIEW, launched.action)
    assertEquals("com.brouken.player", launched.`package`)
    assertEquals(VIDEO_URL, launched.data.toString())
    assertEquals("video/*", launched.type)
    assertEquals("Holiday.mp4", launched.getStringExtra("title"))
    assertEquals("Holiday.mp4", launched.getStringExtra(Intent.EXTRA_TITLE))
    assertEquals(setOf("title", Intent.EXTRA_TITLE), launched.extras!!.keySet())
  }

  @Test
  fun offersOtherVideoPlayersInTheAndroidChooser() {
    registerPlayer("other.video.player")

    open(VIDEO_URL, "video/mp4", "Holiday.mp4", "Choose a video player")

    val chooser = shadowOf(activity).nextStartedActivity
    assertEquals(Intent.ACTION_CHOOSER, chooser.action)
    assertEquals("Choose a video player", chooser.getCharSequenceExtra(Intent.EXTRA_TITLE))
    val target = chooser.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)!!
    assertEquals(Intent.ACTION_VIEW, target.action)
    assertEquals(VIDEO_URL, target.data.toString())
    assertEquals("video/mp4", target.type)
    assertNull(target.`package`)
  }

  @Test
  fun detectsAPlayerThatOnlySupportsHttp() {
    registerPlayer("other.video.player", schemes = listOf("http"))

    assertTrue(launcher.isAvailable())
  }

  @Test
  fun doesNotTreatAWebBrowserAsAVideoPlayer() {
    registerPlayer("browser", mimeType = null)

    assertFalse(launcher.isAvailable())
    val error = assertThrows(ExternalPlayerError::class.java) {
      open(VIDEO_URL, "video/*", "Holiday.mp4", "Choose a video player")
    }
    assertEquals("NO_PLAYER", error.code)
    assertNull(shadowOf(activity).nextStartedActivity)
  }

  @Test
  fun rejectsActivitiesThatCannotBeOpenedByAnotherApp() {
    registerPlayer("private.player", exported = false)
    registerPlayer("disabled.player", enabled = false)
    registerPlayer(activity.packageName)

    assertFalse(launcher.isAvailable())
  }

  @Test
  fun checksPlayersForTheActualUrlWhenOpening() {
    registerPlayer("http.only.player", schemes = listOf("http"))
    assertTrue(launcher.isAvailable())

    val error = assertThrows(ExternalPlayerError::class.java) {
      open(VIDEO_URL, "video/*", "Holiday.mp4", "Choose a video player")
    }
    assertEquals("NO_PLAYER", error.code)
    assertNull(shadowOf(activity).nextStartedActivity)
  }

  @Test
  fun rejectsLocalFilesAndOtherUrlSchemes() {
    registerPlayer("com.brouken.player")
    for (url in listOf("file:///private/video.mp4", "content://media/video/1", "ftp://server/video.mp4", "https:///video")) {
      val error = assertThrows(ExternalPlayerError::class.java) {
        open(url, "video/*", "Holiday.mp4", "Choose a video player")
      }
      assertEquals("UNSAFE_ENDPOINT", error.code)
    }
    assertNull(shadowOf(activity).nextStartedActivity)
  }

  @Test
  fun rejectsNonVideoMimeTypesAndMissingArguments() {
    registerPlayer("com.brouken.player")
    for (mimeType in listOf("application/octet-stream", "image/jpeg", "video/", null)) {
      val error = assertThrows(ExternalPlayerError::class.java) {
        open(VIDEO_URL, mimeType, "Holiday.mp4", "Choose a video player")
      }
      assertEquals("INVALID_ARGUMENT", error.code)
    }
    assertNull(shadowOf(activity).nextStartedActivity)
  }

  @Test
  fun doesNotExposeTheTemporaryKeyWhenAndroidRejectsTheLaunch() {
    val failingActivity = Robolectric.buildActivity(FailingActivity::class.java).setup().get()
    registerPlayer("com.brouken.player")

    val error = assertThrows(ExternalPlayerError::class.java) {
      open(VIDEO_URL, "video/*", "Holiday.mp4", "Choose a video player", ExternalPlayerLauncher(failingActivity) {})
    }

    assertEquals("LAUNCH_FAILED", error.code)
    assertFalse(error.message!!.contains("temporary-test-key"))
    assertNull(error.cause)
  }

  @Test
  fun doesNotLaunchThePlayerWhenNetworkVerificationRejectsTheStream() {
    registerPlayer("com.brouken.player")
    val rejectingLauncher = ExternalPlayerLauncher(activity) {
      throw ExternalPlayerError("UNSAFE_ENDPOINT", "A direct Tailscale video endpoint is required.")
    }

    val error = assertThrows(ExternalPlayerError::class.java) {
      open(VIDEO_URL, "video/*", "Holiday.mp4", "Choose a video player", rejectingLauncher)
    }

    assertEquals("UNSAFE_ENDPOINT", error.code)
    assertNull(shadowOf(activity).nextStartedActivity)
  }

  private fun open(
    url: String?,
    mimeType: String?,
    title: String?,
    chooserTitle: String?,
    targetLauncher: ExternalPlayerLauncher = launcher,
  ) {
    val video = targetLauncher.prepare(url, mimeType, title, chooserTitle)
    targetLauncher.verify(video)
    targetLauncher.launch(video)
  }

  private fun registerPlayer(
    packageName: String,
    schemes: List<String> = listOf("http", "https"),
    mimeType: String? = "video/*",
    exported: Boolean = true,
    enabled: Boolean = true,
  ) {
    val component = ComponentName(packageName, "$packageName.PlayerActivity")
    val activityInfo = ActivityInfo().apply {
      this.packageName = packageName
      name = component.className
      this.exported = exported
      this.enabled = enabled
      applicationInfo = ApplicationInfo().apply {
        this.packageName = packageName
        this.enabled = true
      }
    }
    val packageManager = shadowOf(activity.packageManager)
    packageManager.addOrUpdateActivity(activityInfo)
    packageManager.addIntentFilterForActivity(component, IntentFilter(Intent.ACTION_VIEW).apply {
      addCategory(Intent.CATEGORY_DEFAULT)
      schemes.forEach(::addDataScheme)
      mimeType?.let(::addDataType)
    })
  }

  class FailingActivity : Activity() {
    override fun startActivity(intent: Intent) {
      throw SecurityException("Cannot open $VIDEO_URL")
    }
  }

  companion object {
    private const val VIDEO_URL = "https://immich.tailnet.ts.net/api/assets/video/video/playback?key=temporary-test-key"
  }
}
