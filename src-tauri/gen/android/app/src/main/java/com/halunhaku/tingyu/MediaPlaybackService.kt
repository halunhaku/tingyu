package com.halunhaku.tingyu

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import androidx.core.app.NotificationCompat
import androidx.media.app.NotificationCompat.MediaStyle
import androidx.media.session.MediaButtonReceiver
import android.support.v4.media.MediaMetadataCompat
import android.support.v4.media.session.MediaSessionCompat
import android.support.v4.media.session.PlaybackStateCompat
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors

internal object MediaSessionBridge {
  @Volatile
  var commandHandler: ((String, Long?) -> Unit)? = null

  fun dispatch(action: String, positionMs: Long? = null) {
    commandHandler?.invoke(action, positionMs)
  }
}

private data class PlaybackSnapshot(
  val title: String = "听屿",
  val artist: String = "",
  val album: String = "",
  val artworkUrl: String? = null,
  val durationMs: Long = 0,
  val positionMs: Long = 0,
  val playing: Boolean = false,
)

class MediaPlaybackService : Service() {
  companion object {
    const val ACTION_UPDATE = "com.halunhaku.tingyu.media.UPDATE"
    const val ACTION_COMMAND = "com.halunhaku.tingyu.media.COMMAND"
    const val ACTION_CLEAR = "com.halunhaku.tingyu.media.CLEAR"

    const val EXTRA_TITLE = "title"
    const val EXTRA_ARTIST = "artist"
    const val EXTRA_ALBUM = "album"
    const val EXTRA_ARTWORK_URL = "artworkUrl"
    const val EXTRA_DURATION = "durationMs"
    const val EXTRA_POSITION = "positionMs"
    const val EXTRA_PLAYING = "playing"
    const val EXTRA_COMMAND = "command"

    private const val CHANNEL_ID = "tingyu_playback"
    private const val NOTIFICATION_ID = 2107
  }

  private lateinit var mediaSession: MediaSessionCompat
  private val mainHandler = Handler(Looper.getMainLooper())
  private val artworkExecutor = Executors.newSingleThreadExecutor()
  private var snapshot = PlaybackSnapshot()
  private var artwork: Bitmap? = null
  private var requestedArtworkUrl: String? = null
  private var foregroundStarted = false

  override fun onCreate() {
    super.onCreate()
    createNotificationChannel()
    mediaSession = MediaSessionCompat(this, "TingyuMediaSession").apply {
      setFlags(
        MediaSessionCompat.FLAG_HANDLES_MEDIA_BUTTONS or
          MediaSessionCompat.FLAG_HANDLES_TRANSPORT_CONTROLS,
      )
      setCallback(object : MediaSessionCompat.Callback() {
        override fun onPlay() = MediaSessionBridge.dispatch("play")
        override fun onPause() = MediaSessionBridge.dispatch("pause")
        override fun onSkipToPrevious() = MediaSessionBridge.dispatch("previous")
        override fun onSkipToNext() = MediaSessionBridge.dispatch("next")
        override fun onSeekTo(pos: Long) = MediaSessionBridge.dispatch("seek", pos)
        override fun onStop() = MediaSessionBridge.dispatch("stop")
      })
      isActive = true
    }
  }

  override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
    when (intent?.action) {
      ACTION_UPDATE -> applyUpdate(intent)
      ACTION_COMMAND -> intent.getStringExtra(EXTRA_COMMAND)?.let {
        MediaSessionBridge.dispatch(it)
      }
      ACTION_CLEAR -> stopPlaybackService()
      Intent.ACTION_MEDIA_BUTTON -> MediaButtonReceiver.handleIntent(mediaSession, intent)
    }
    return START_NOT_STICKY
  }

  override fun onBind(intent: Intent?): IBinder? = null

  override fun onDestroy() {
    artworkExecutor.shutdownNow()
    mediaSession.isActive = false
    mediaSession.release()
    super.onDestroy()
  }

  private fun applyUpdate(intent: Intent) {
    val previous = snapshot
    val next = PlaybackSnapshot(
      title = intent.getStringExtra(EXTRA_TITLE).orEmpty().ifBlank { "听屿" },
      artist = intent.getStringExtra(EXTRA_ARTIST).orEmpty(),
      album = intent.getStringExtra(EXTRA_ALBUM).orEmpty(),
      artworkUrl = intent.getStringExtra(EXTRA_ARTWORK_URL)?.takeIf(String::isNotBlank),
      durationMs = intent.getLongExtra(EXTRA_DURATION, 0).coerceAtLeast(0),
      positionMs = intent.getLongExtra(EXTRA_POSITION, 0).coerceAtLeast(0),
      playing = intent.getBooleanExtra(EXTRA_PLAYING, false),
    )
    val metadataChanged = previous.title != next.title ||
      previous.artist != next.artist ||
      previous.album != next.album ||
      previous.artworkUrl != next.artworkUrl ||
      previous.durationMs != next.durationMs
    val playbackChanged = previous.playing != next.playing
    snapshot = next

    if (metadataChanged) {
      loadArtwork(snapshot.artworkUrl)
      updateMetadata()
    }
    updatePlaybackState()
    if (metadataChanged || playbackChanged || !foregroundStarted) refreshNotification()
  }

  private fun updateMetadata() {
    val metadata = MediaMetadataCompat.Builder()
      .putString(MediaMetadataCompat.METADATA_KEY_TITLE, snapshot.title)
      .putString(MediaMetadataCompat.METADATA_KEY_ARTIST, snapshot.artist)
      .putString(MediaMetadataCompat.METADATA_KEY_ALBUM, snapshot.album)
      .putLong(MediaMetadataCompat.METADATA_KEY_DURATION, snapshot.durationMs)

    artwork?.let {
      metadata.putBitmap(MediaMetadataCompat.METADATA_KEY_ALBUM_ART, it)
      metadata.putBitmap(MediaMetadataCompat.METADATA_KEY_DISPLAY_ICON, it)
    }
    mediaSession.setMetadata(metadata.build())
  }

  private fun updatePlaybackState() {
    val actions = PlaybackStateCompat.ACTION_PLAY or
      PlaybackStateCompat.ACTION_PAUSE or
      PlaybackStateCompat.ACTION_PLAY_PAUSE or
      PlaybackStateCompat.ACTION_SKIP_TO_PREVIOUS or
      PlaybackStateCompat.ACTION_SKIP_TO_NEXT or
      PlaybackStateCompat.ACTION_SEEK_TO or
      PlaybackStateCompat.ACTION_STOP
    val state = if (snapshot.playing) {
      PlaybackStateCompat.STATE_PLAYING
    } else {
      PlaybackStateCompat.STATE_PAUSED
    }
    mediaSession.setPlaybackState(
      PlaybackStateCompat.Builder()
        .setActions(actions)
        .setState(
          state,
          snapshot.positionMs,
          if (snapshot.playing) 1f else 0f,
          SystemClock.elapsedRealtime(),
        )
        .build(),
    )
  }

  private fun refreshNotification() {
    val notification = buildNotification()
    foregroundStarted = true
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
      startForeground(
        NOTIFICATION_ID,
        notification,
        ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK,
      )
    } else {
      startForeground(NOTIFICATION_ID, notification)
    }
  }

  private fun buildNotification(): Notification {
    val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
    val contentIntent = launchIntent?.let {
      PendingIntent.getActivity(
        this,
        0,
        it.addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
      )
    }

    val previous = commandAction(
      "previous",
      android.R.drawable.ic_media_previous,
      "上一首",
      1,
    )
    val playPause = commandAction(
      if (snapshot.playing) "pause" else "play",
      if (snapshot.playing) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play,
      if (snapshot.playing) "暂停" else "播放",
      2,
    )
    val next = commandAction(
      "next",
      android.R.drawable.ic_media_next,
      "下一首",
      3,
    )

    return NotificationCompat.Builder(this, CHANNEL_ID)
      .setSmallIcon(R.drawable.ic_stat_music_note)
      .setContentTitle(snapshot.title)
      .setContentText(snapshot.artist.ifBlank { snapshot.album })
      .setSubText(snapshot.album.takeIf(String::isNotBlank))
      .setLargeIcon(artwork)
      .setContentIntent(contentIntent)
      .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
      .setCategory(NotificationCompat.CATEGORY_TRANSPORT)
      .setOnlyAlertOnce(true)
      .setSilent(true)
      .setOngoing(snapshot.playing)
      .addAction(previous)
      .addAction(playPause)
      .addAction(next)
      .setStyle(
        MediaStyle()
          .setMediaSession(mediaSession.sessionToken)
          .setShowActionsInCompactView(0, 1, 2),
      )
      .build()
  }

  private fun commandAction(
    command: String,
    icon: Int,
    title: String,
    requestCode: Int,
  ): NotificationCompat.Action {
    val intent = Intent(this, MediaPlaybackService::class.java).apply {
      action = ACTION_COMMAND
      putExtra(EXTRA_COMMAND, command)
    }
    val pendingIntent = PendingIntent.getService(
      this,
      requestCode,
      intent,
      PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )
    return NotificationCompat.Action(icon, title, pendingIntent)
  }

  private fun loadArtwork(url: String?) {
    if (url == requestedArtworkUrl) return
    requestedArtworkUrl = url
    artwork = null
    if (url == null) return

    artworkExecutor.execute {
      val loaded = try {
        val connection = URL(url).openConnection() as HttpURLConnection
        connection.connectTimeout = 5_000
        connection.readTimeout = 8_000
        connection.inputStream.use(BitmapFactory::decodeStream)
      } catch (_: Exception) {
        null
      }
      mainHandler.post {
        if (requestedArtworkUrl != url || loaded == null) return@post
        artwork = loaded
        updateMetadata()
        refreshNotification()
      }
    }
  }

  private fun createNotificationChannel() {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
    val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    val channel = NotificationChannel(
      CHANNEL_ID,
      "播放控制",
      NotificationManager.IMPORTANCE_LOW,
    ).apply {
      description = "显示正在播放的歌曲和媒体控制"
      setShowBadge(false)
      lockscreenVisibility = Notification.VISIBILITY_PUBLIC
    }
    manager.createNotificationChannel(channel)
  }

  private fun stopPlaybackService() {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
      stopForeground(STOP_FOREGROUND_REMOVE)
    } else {
      @Suppress("DEPRECATION")
      stopForeground(true)
    }
    stopSelf()
  }
}
