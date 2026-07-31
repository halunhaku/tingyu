import {
  addPluginListener,
  invoke,
  isTauri,
  requestPermissions,
} from '@tauri-apps/api/core'

const ANDROID_PLUGIN_NAME = 'android-media-session'

export interface SystemMediaState {
  title: string
  artist: string
  album: string
  artworkUrl?: string
  durationSeconds: number
  positionSeconds: number
  playing: boolean
}

export interface SystemMediaControl {
  action:
    | 'play'
    | 'pause'
    | 'toggle'
    | 'previous'
    | 'next'
    | 'seek'
    | 'seekRelative'
    | 'stop'
  positionMs?: number
  offsetMs?: number
}

let notificationPermissionRequest: Promise<void> | null = null
let macosMetadataKey = ''

function isAndroidApp() {
  return isTauri() && /Android/i.test(navigator.userAgent)
}

function isMacosApp() {
  return isTauri()
    && /Macintosh|Mac OS X/i.test(navigator.userAgent)
    && 'mediaSession' in navigator
}

async function ensureAndroidNotificationPermission() {
  if (!notificationPermissionRequest) {
    notificationPermissionRequest = requestPermissions(ANDROID_PLUGIN_NAME)
      .then(() => undefined)
      .catch((error) => {
        console.warn('Android notification permission was not granted', error)
      })
  }
  await notificationPermissionRequest
}

function nativeState(state: SystemMediaState) {
  return {
    title: state.title,
    artist: state.artist,
    album: state.album,
    artworkUrl: state.artworkUrl ?? null,
    durationMs: Math.max(0, Math.round(state.durationSeconds * 1000)),
    positionMs: Math.max(0, Math.round(state.positionSeconds * 1000)),
    playing: state.playing,
  }
}

function updateMacosMediaSession(state: SystemMediaState) {
  const metadataKey = JSON.stringify([
    state.title,
    state.artist,
    state.album,
    state.artworkUrl ?? '',
  ])
  if (metadataKey !== macosMetadataKey) {
    navigator.mediaSession.metadata = new MediaMetadata({
      title: state.title,
      artist: state.artist,
      album: state.album,
      artwork: state.artworkUrl ? [{ src: state.artworkUrl }] : [],
    })
    macosMetadataKey = metadataKey
  }

  navigator.mediaSession.playbackState = state.playing ? 'playing' : 'paused'
  if (Number.isFinite(state.durationSeconds) && state.durationSeconds > 0) {
    const position = Math.min(
      Math.max(0, state.positionSeconds),
      state.durationSeconds,
    )
    try {
      navigator.mediaSession.setPositionState({
        duration: state.durationSeconds,
        playbackRate: 1,
        position,
      })
    } catch (error) {
      console.warn('Unable to update macOS media position', error)
    }
  }
}

export async function updateSystemMediaSession(state: SystemMediaState) {
  if (isAndroidApp()) {
    if (state.playing) await ensureAndroidNotificationPermission()
    await invoke('android_media_update', { state: nativeState(state) })
  } else if (isMacosApp()) {
    updateMacosMediaSession(state)
  }
}

export async function clearSystemMediaSession() {
  if (isAndroidApp()) {
    await invoke('android_media_clear')
  } else if (isMacosApp()) {
    navigator.mediaSession.metadata = null
    navigator.mediaSession.playbackState = 'none'
    navigator.mediaSession.setPositionState()
    macosMetadataKey = ''
  }
}

function setMacosActionHandler(
  action: MediaSessionAction,
  handler: MediaSessionActionHandler | null,
) {
  try {
    navigator.mediaSession.setActionHandler(action, handler)
  } catch {
    // Older WebKit versions expose only a subset of Media Session actions.
  }
}

export async function listenToSystemMediaControls(
  handler: (control: SystemMediaControl) => void,
) {
  const cleanups: Array<() => void | Promise<void>> = []

  if (isAndroidApp()) {
    const listener = await addPluginListener<SystemMediaControl>(
      ANDROID_PLUGIN_NAME,
      'control',
      handler,
    )
    cleanups.push(() => listener.unregister())
  } else if (isMacosApp()) {
    const handlers: Array<[MediaSessionAction, MediaSessionActionHandler]> = [
      ['play', () => handler({ action: 'play' })],
      ['pause', () => handler({ action: 'pause' })],
      ['previoustrack', () => handler({ action: 'previous' })],
      ['nexttrack', () => handler({ action: 'next' })],
      ['stop', () => handler({ action: 'stop' })],
      ['seekto', (details) => handler({
        action: 'seek',
        positionMs: Math.max(0, Math.round((details.seekTime ?? 0) * 1000)),
      })],
      ['seekbackward', (details) => handler({
        action: 'seekRelative',
        offsetMs: -Math.round((details.seekOffset ?? 10) * 1000),
      })],
      ['seekforward', (details) => handler({
        action: 'seekRelative',
        offsetMs: Math.round((details.seekOffset ?? 10) * 1000),
      })],
    ]
    handlers.forEach(([action, actionHandler]) => {
      setMacosActionHandler(action, actionHandler)
    })
    cleanups.push(() => {
      handlers.forEach(([action]) => setMacosActionHandler(action, null))
    })
  }

  return async () => {
    await Promise.all(cleanups.map((cleanup) => cleanup()))
  }
}
