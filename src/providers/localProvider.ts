import { invoke, isTauri } from '@tauri-apps/api/core'
import { open } from '@tauri-apps/plugin-dialog'
import type { Track } from '../types/music'

interface LocalEntry {
  path: string
  name: string
  title: string
  artist: string
  album: string
  year?: number
  duration: number
  size: number
  streamUrl: string
  artworkUrl?: string
  plainLyrics?: string
  syncedLyrics?: string
  enrichmentVersion: number
}

interface LocalScanResult {
  sourceName: string
  folderPath: string
  folderName: string
  tracks: LocalEntry[]
}

interface AndroidFolder {
  uri: string
  name: string
}

const artworks: Track['artwork'][] = ['sunset', 'meadow', 'ember', 'mono', 'lagoon', 'blueprint']
const supportedFormats: Track['format'][] = ['FLAC', 'MP3', 'M4A', 'AAC', 'WAV', 'OGG', 'OPUS']

export async function chooseAndScanLocalFolder(name: string) {
  if (!isTauri()) throw new Error('本地文件夹需要在听屿桌面应用中打开')
  if (/Android/i.test(navigator.userAgent)) {
    const picked = await invoke<AndroidFolder | null>('android_local_folder_pick')
    if (!picked) return null
    const result = await invoke<LocalScanResult>('local_library_scan_android', {
      name,
      folder: picked.uri,
    })
    return resultToLibrary(result)
  }
  const folder = await open({
    directory: true,
    multiple: false,
    title: '选择本地音乐文件夹',
  })
  if (!folder) return null
  const result = await invoke<LocalScanResult>('local_library_scan', { name, folder })
  return resultToLibrary(result)
}

export async function restoreLocalFolder() {
  if (!isTauri()) return null
  const result = await invoke<LocalScanResult | null>('local_library_restore')
  return result ? resultToLibrary(result) : null
}

export async function forgetLocalFolder() {
  if (!isTauri()) return
  await invoke('local_library_forget')
}

export async function scrapeLocalTrack(path: string) {
  if (!isTauri()) return null
  const entry = await invoke<LocalEntry>('local_library_scrape_track', { path })
  return entryToTrack(entry)
}

function resultToLibrary(result: LocalScanResult) {
  return {
    sourceName: result.sourceName,
    folderPath: result.folderPath,
    folderName: result.folderName,
    tracks: result.tracks.map(entryToTrack),
  }
}

function entryToTrack(entry: LocalEntry): Track {
  const extension = entry.name.split('.').pop()?.toLocaleUpperCase() ?? 'MP3'
  const format = supportedFormats.includes(extension as Track['format'])
    ? extension as Track['format']
    : 'MP3'
  return {
    id: `local:${entry.path}`,
    title: entry.title,
    artist: entry.artist,
    album: entry.album,
    duration: entry.duration || 0,
    format,
    source: 'local',
    year: entry.year || new Date().getFullYear(),
    artwork: artworks[stableIndex(entry.path, artworks.length)],
    artworkUrl: entry.artworkUrl,
    plainLyrics: entry.plainLyrics,
    syncedLyrics: entry.syncedLyrics,
    enrichmentVersion: entry.enrichmentVersion,
    remotePath: entry.path,
    streamUrl: entry.streamUrl,
    size: entry.size,
  }
}

function stableIndex(value: string, length: number) {
  let hash = 0
  for (let index = 0; index < value.length; index += 1) {
    hash = ((hash << 5) - hash + value.charCodeAt(index)) | 0
  }
  return Math.abs(hash) % length
}

export function readableLocalError(error: unknown) {
  if (typeof error === 'string') return error
  if (error instanceof Error) return error.message
  return '读取本地音乐文件夹时发生未知错误'
}
