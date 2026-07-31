package com.halunhaku.tingyu

import android.Manifest
import android.app.Activity
import android.content.Intent
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import app.tauri.annotation.Command
import app.tauri.annotation.InvokeArg
import app.tauri.annotation.Permission
import app.tauri.annotation.TauriPlugin
import app.tauri.plugin.Invoke
import app.tauri.plugin.JSObject
import app.tauri.plugin.Plugin

@InvokeArg
class PlaybackUpdateArgs {
  lateinit var title: String
  lateinit var artist: String
  lateinit var album: String
  var artworkUrl: String? = null
  var durationMs: Long = 0
  var positionMs: Long = 0
  var playing: Boolean = false
}

@TauriPlugin(
  permissions = [
    Permission(
      strings = [Manifest.permission.POST_NOTIFICATIONS],
      alias = "notifications",
    ),
  ],
)
class MediaSessionPlugin(private val activity: Activity) : Plugin(activity) {
  init {
    MediaSessionBridge.commandHandler = { action, positionMs ->
      activity.runOnUiThread {
        val payload = JSObject().apply {
          put("action", action)
          if (positionMs != null) put("positionMs", positionMs)
        }
        trigger("control", payload)
      }
    }
  }

  @Command
  fun updatePlayback(invoke: Invoke) {
    try {
      val args = invoke.parseArgs(PlaybackUpdateArgs::class.java)
      val intent = Intent(activity, MediaPlaybackService::class.java).apply {
        action = MediaPlaybackService.ACTION_UPDATE
        putExtra(MediaPlaybackService.EXTRA_TITLE, args.title)
        putExtra(MediaPlaybackService.EXTRA_ARTIST, args.artist)
        putExtra(MediaPlaybackService.EXTRA_ALBUM, args.album)
        putExtra(MediaPlaybackService.EXTRA_ARTWORK_URL, args.artworkUrl)
        putExtra(MediaPlaybackService.EXTRA_DURATION, args.durationMs)
        putExtra(MediaPlaybackService.EXTRA_POSITION, args.positionMs)
        putExtra(MediaPlaybackService.EXTRA_PLAYING, args.playing)
      }
      ContextCompat.startForegroundService(activity, intent)
      invoke.resolve()
    } catch (error: Exception) {
      invoke.reject(error.message ?: "无法启动 Android 媒体会话")
    }
  }

  @Command
  fun clear(invoke: Invoke) {
    activity.stopService(Intent(activity, MediaPlaybackService::class.java))
    invoke.resolve()
  }

  override fun onDestroy(activity: AppCompatActivity) {
    MediaSessionBridge.commandHandler = null
    activity.stopService(Intent(activity, MediaPlaybackService::class.java))
  }
}
