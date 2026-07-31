import { Music2 } from 'lucide-react'
import type { Track } from '../types/music'

interface AlbumArtworkProps {
  track: Track
  size?: 'small' | 'medium' | 'large'
}

export function AlbumArtwork({ track, size = 'medium' }: AlbumArtworkProps) {
  return (
    <div
      className={`album-art album-art--${track.artwork} album-art--${size}`}
      aria-label={`${track.album} 专辑封面`}
      role="img"
    >
      {track.artworkUrl && <img className="album-art__image" src={track.artworkUrl} alt="" loading="lazy" />}
      <span className="album-art__grain" />
      <span className="album-art__mark">
        {track.artwork === 'mono' ? <Music2 size={16} /> : track.artist.charAt(0)}
      </span>
      <span className="album-art__title">{track.album}</span>
    </div>
  )
}
