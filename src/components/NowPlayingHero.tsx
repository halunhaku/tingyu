import { Cloud, FolderOpen, Pause, Play, Shuffle } from 'lucide-react'
import { sourceLabel } from '../data/library'
import type { Track } from '../types/music'
import { AlbumArtwork } from './AlbumArtwork'

interface NowPlayingHeroProps {
  track: Track
  isCurrent: boolean
  isPlaying: boolean
  canShuffle: boolean
  onPlay: () => void
  onShuffle: () => void
}

export function NowPlayingHero({
  track,
  isCurrent,
  isPlaying,
  canShuffle,
  onPlay,
  onShuffle,
}: NowPlayingHeroProps) {
  const SourceIcon = track.source === 'webdav' ? Cloud : FolderOpen

  return (
    <section className="spotlight" aria-label="当前播放">
      <div className="spotlight__art-wrap">
        <span className="spotlight__disc" aria-hidden="true" />
        <AlbumArtwork track={track} size="large" />
      </div>

      <div className="spotlight__copy">
        <span className="spotlight__label">当前播放 <i /> CURRENT TRACK</span>
        <div className="spotlight__title-block">
          <h2 title={track.title}>{track.title}</h2>
          <p title={`${track.artist} · ${track.album}`}>{track.artist} · {track.album}</p>
        </div>
        <div className="spotlight__meta" aria-label="音频信息">
          <span>{track.format}</span>
          <span><SourceIcon size={12} /> {sourceLabel[track.source]}</span>
          {track.year > 0 && <span>{track.year}</span>}
        </div>
        <div className="spotlight__actions">
          <button className="primary-button" type="button" onClick={onPlay}>
            {isCurrent && isPlaying
              ? <Pause size={16} fill="currentColor" />
              : <Play size={16} fill="currentColor" />}
            {isCurrent && isPlaying ? '暂停' : '播放'}
          </button>
          <button className="secondary-button" type="button" onClick={onShuffle} disabled={!canShuffle}>
            <Shuffle size={14} />
            随机来一首
          </button>
        </div>
      </div>

      <span className="spotlight__number" aria-hidden="true">01</span>
    </section>
  )
}
