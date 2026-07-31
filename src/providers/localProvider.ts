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
  sourceId: string
  sourceName: string
  folderPath: string
  folderName: string
  tracks: LocalEntry[]
}

interface AndroidFolder {
  uri: string
  name: string
}

export interface LocalLibrary {
  sourceId: string
  sourceName: string
  folderPath: string
  folderName: string
  tracks: Track[]
}

const artworks: Track['artwork'][] = ['sunset', 'meadow', 'ember', 'mono', 'lagoon', 'blueprint']
const supportedFormats: Track['format'][] = ['FLAC', 'MP3', 'M4A', 'AAC', 'WAV', 'OGG', 'OPUS']

export async function chooseAndScanLocalFolder(name: string) {
  if (!isTauri()) throw new Error('本地文件夹需要在听屿应用中打开')
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

export async function restoreLocalFolders() {
  if (!isTauri()) return []
  const results = await invoke<LocalScanResult[]>('local_library_restore')
  return results.map(resultToLibrary)
}

export async function refreshLocalFolder(sourceId: string) {
  const result = await invoke<LocalScanResult>('local_library_refresh', { sourceId })
  return resultToLibrary(result)
}

export async function forgetLocalFolder(sourceId: string) {
  if (!isTauri()) return
  await invoke('local_library_forget', { sourceId })
}

export async function scrapeLocalTrack(sourceId: string, path: string) {
  if (!isTauri()) return null
  const entry = await invoke<LocalEntry>('local_library_scrape_track', { sourceId, path })
  return entryToTrack(entry, sourceId)
}

function resultToLibrary(result: LocalScanResult): LocalLibrary {
  return {
    sourceId: result.sourceId,
    sourceName: result.sourceName,
    folderPath: result.folderPath,
    folderName: result.folderName,
    tracks: result.tracks.map((entry) => entryToTrack(entry, result.sourceId)),
  }
}

function entryToTrack(entry: LocalEntry, sourceId: string): Track {
  const extension = entry.name.split('.').pop()?.toLocaleUpperCase() ?? 'MP3'
  const format = supportedFormats.includes(extension as Track['format'])
    ? extension as Track['format']
    : 'MP3'
  return {
    id: `local:${sourceId}:${entry.path}`,
    title: entry.title,
    artist: entry.artist,
    album: entry.album,
    duration: entry.duration || 0,
    format,
    source: 'local',
    sourceId,
    year: entry.year || new Date().getFullYear(),
    artwork: artworks[stableIndex(`${sourceId}:${entry.path}`, artworks.length)],
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
