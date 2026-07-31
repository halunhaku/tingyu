import type { Track } from '../types/music'

export const sourceLabel: Record<Track['source'], string> = {
  webdav: 'WebDAV',
  local: '本地',
}

export function formatTime(seconds: number) {
  if (!Number.isFinite(seconds)) return '0:00'
  const minutes = Math.floor(seconds / 60)
  const remainder = Math.floor(seconds % 60)
  return `${minutes}:${remainder.toString().padStart(2, '0')}`
}
