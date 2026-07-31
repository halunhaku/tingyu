import { invoke, isTauri } from '@tauri-apps/api/core'
import type { Track } from '../types/music'

export interface WebDavConfig {
  name: string
  baseUrl: string
  username: string
  password: string
  folder: string
  remember: boolean
}

interface WebDavEntry {
  name: string
  href: string
  size: number
  contentType?: string
  modified?: string
  etag?: string
  isDirectory: boolean
  streamUrl?: string
  artworkUrl?: string
  title?: string
  artist?: string
  album?: string
  year?: number
  duration: number
  plainLyrics?: string
  syncedLyrics?: string
  enrichmentVersion: number
}

export interface ConnectionInfo {
  sourceId: string
  name: string
  baseUrl: string
  serverName: string
  folder: string
  restored: boolean
}

export interface ScanStats {
  added: number
  updated: number
  unchanged: number
  removed: number
}

interface CachedLibrary {
  sourceId: string
  name: string
  tracks: WebDavEntry[]
}

interface ScanResult {
  tracks: WebDavEntry[]
  stats: ScanStats
}

export interface WebDavLibrary {
  connection: ConnectionInfo
  tracks: Track[]
  stats: ScanStats
}

const artworks: Track['artwork'][] = ['sunset', 'meadow', 'ember', 'mono', 'lagoon', 'blueprint']
const supportedFormats: Track['format'][] = ['FLAC', 'MP3', 'M4A', 'AAC', 'WAV', 'OGG', 'OPUS']

export async function connectAndScanWebDav(config: WebDavConfig) {
  assertDesktop()
  const connection = await invoke<ConnectionInfo>('webdav_connect', { config })
  const scan = await scanWebDav(connection.sourceId, config.folder)
  return { connection, ...scan }
}

export async function loadCachedWebDavs() {
  if (!isTauri()) return []
  const libraries = await invoke<CachedLibrary[]>('webdav_cached_library')
  return libraries.map((library) => ({
    sourceId: library.sourceId,
    name: library.name,
    tracks: library.tracks.map((entry) => entryToTrack(entry, library.sourceId)),
  }))
}

export async function restoreAndScanWebDavs() {
  if (!isTauri()) return []
  const connections = await invoke<ConnectionInfo[]>('webdav_restore')
  const settled = await Promise.allSettled(
    connections.map(async (connection): Promise<WebDavLibrary> => ({
      connection,
      ...await scanWebDav(connection.sourceId, connection.folder),
    })),
  )
  return settled.flatMap((result) => result.status === 'fulfilled' ? [result.value] : [])
}

export async function scanWebDav(sourceId: string, folder = '') {
  const result = await invoke<ScanResult>('webdav_scan', {
    sourceId,
    folder: folder || null,
    recursive: true,
  })
  return {
    tracks: result.tracks.map((entry) => entryToTrack(entry, sourceId)),
    stats: result.stats,
  }
}

export async function forgetWebDav(sourceId: string) {
  if (!isTauri()) return
  await invoke('webdav_forget', { sourceId })
}

export async function scrapeWebDavTrack(sourceId: string, href: string) {
  if (!isTauri()) return null
  const entry = await invoke<WebDavEntry>('webdav_scrape_track', { sourceId, href })
  return entryToTrack(entry, sourceId)
}

export async function persistWebDavDuration(sourceId: string, href: string, duration: number) {
  if (!isTauri() || !Number.isFinite(duration) || duration <= 0) return
  await invoke('webdav_update_duration', { sourceId, href, duration })
}

function entryToTrack(entry: WebDavEntry, sourceId: string): Track {
  const extension = entry.name.split('.').pop()?.toLocaleUpperCase() ?? 'MP3'
  const format = supportedFormats.includes(extension as Track['format'])
    ? extension as Track['format']
    : 'MP3'
  const filename = entry.name.replace(/\.[^.]+$/, '')
  const separatorIndex = filename.indexOf(' - ')
  const fallbackArtist = separatorIndex > 0 ? filename.slice(0, separatorIndex).trim() : '未知艺术家'
  const fallbackTitle = separatorIndex > 0 ? filename.slice(separatorIndex + 3).trim() : filename
  const artworkIndex = stableIndex(`${sourceId}:${entry.href}`, artworks.length)

  return {
    id: `webdav:${sourceId}:${entry.href}`,
    title: entry.title || fallbackTitle,
    artist: entry.artist || fallbackArtist,
    album: entry.album || 'WebDAV 曲库',
    duration: entry.duration || 0,
    format,
    source: 'webdav',
    sourceId,
    year: entry.year || new Date().getFullYear(),
    artwork: artworks[artworkIndex],
    artworkUrl: entry.artworkUrl,
    plainLyrics: entry.plainLyrics,
    syncedLyrics: entry.syncedLyrics,
    enrichmentVersion: entry.enrichmentVersion,
    remotePath: entry.href,
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

function assertDesktop() {
  if (!isTauri()) throw new Error('真实 WebDAV 连接需要在听屿应用中运行')
}

export function readableWebDavError(error: unknown) {
  if (typeof error === 'string') return error
  if (error instanceof Error) return error.message
  return '连接 WebDAV 时发生未知错误'
}
