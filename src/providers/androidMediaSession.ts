import {
  addPluginListener,
  invoke,
  isTauri,
  requestPermissions,
} from '@tauri-apps/api/core'

const PLUGIN_NAME = 'android-media-session'

export interface AndroidMediaState {
  title: string
  artist: string
  album: string
  artworkUrl?: string
  durationSeconds: number
  positionSeconds: number
  playing: boolean
}

export interface AndroidMediaControl {
  action: 'play' | 'pause' | 'previous' | 'next' | 'seek' | 'stop'
  positionMs?: number
}

let notificationPermissionRequest: Promise<void> | null = null

function isAndroidApp() {
  return isTauri() && /Android/i.test(navigator.userAgent)
}

async function ensureNotificationPermission() {
  if (!notificationPermissionRequest) {
    notificationPermissionRequest = requestPermissions(PLUGIN_NAME)
      .then(() => undefined)
      .catch((error) => {
        console.warn('Android notification permission was not granted', error)
      })
  }
  await notificationPermissionRequest
}

export async function updateAndroidMediaSession(state: AndroidMediaState) {
  if (!isAndroidApp()) return
  if (state.playing) await ensureNotificationPermission()

  await invoke('android_media_update', {
    state: {
      title: state.title,
      artist: state.artist,
      album: state.album,
      artworkUrl: state.artworkUrl ?? null,
      durationMs: Math.max(0, Math.round(state.durationSeconds * 1000)),
      positionMs: Math.max(0, Math.round(state.positionSeconds * 1000)),
      playing: state.playing,
    },
  })
}

export async function clearAndroidMediaSession() {
  if (!isAndroidApp()) return
  await invoke('android_media_clear')
}

export async function listenToAndroidMediaControls(
  handler: (control: AndroidMediaControl) => void,
) {
  if (!isAndroidApp()) return async () => undefined
  const listener = await addPluginListener<AndroidMediaControl>(
    PLUGIN_NAME,
    'control',
    handler,
  )
  return () => listener.unregister()
}
