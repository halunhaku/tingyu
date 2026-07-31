export type SourceKind = 'webdav' | 'local'

export interface MusicSource {
  id: string
  kind: SourceKind
  name: string
  status: string
  folder?: string
}

export interface Track {
  id: string
  title: string
  artist: string
  album: string
  duration: number
  format: 'FLAC' | 'MP3' | 'M4A' | 'AAC' | 'WAV' | 'OGG' | 'OPUS'
  source: SourceKind
  sourceId: string
  year: number
  artwork: 'ember' | 'meadow' | 'blueprint' | 'sunset' | 'mono' | 'lagoon'
  artworkUrl?: string
  plainLyrics?: string
  syncedLyrics?: string
  enrichmentVersion?: number
  remotePath?: string
  streamUrl?: string
  size?: number
}
