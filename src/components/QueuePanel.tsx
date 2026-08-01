import { Play, X } from 'lucide-react'
import { formatTime } from '../data/library'
import { usePlayerStore } from '../stores/playerStore'
import { AlbumArtwork } from './AlbumArtwork'

interface QueuePanelProps {
  isOpen: boolean
  onClose: () => void
}

export function QueuePanel({ isOpen, onClose }: QueuePanelProps) {
  const library = usePlayerStore((state) => state.library)
  const currentTrackId = usePlayerStore((state) => state.currentTrackId)
  const queue = usePlayerStore((state) => state.queue)
  const playTrack = usePlayerStore((state) => state.playTrack)
  const currentIndex = queue.indexOf(currentTrackId)
  const orderedIds = currentIndex >= 0
    ? [...queue.slice(currentIndex), ...queue.slice(0, currentIndex)]
    : queue
  const queuedTracks = orderedIds
    .map((id) => library.find((track) => track.id === id))
    .filter((track) => track !== undefined)

  return (
    <aside className={`queue-panel ${isOpen ? 'is-open' : ''}`} aria-label="播放队列" aria-hidden={!isOpen}>
      <div className="queue-panel__heading">
        <div>
          <span className="eyebrow">PLAYING NEXT</span>
          <h2>接下来播放</h2>
          <small>{queue.length} 首歌曲</small>
        </div>
        <button type="button" aria-label="隐藏播放队列" onClick={onClose}>
          <X size={17} />
        </button>
      </div>

      <div className="queue-list">
        {queuedTracks.length === 0 && (
          <span className="queue-empty">队列还是空的，先从曲库选择一首歌。</span>
        )}
        {queuedTracks.map((track, index) => {
          const isCurrent = track.id === currentTrackId
          return (
            <button
              className={`queue-item ${isCurrent ? 'is-current' : ''}`}
              type="button"
              key={track.id}
              onClick={() => playTrack(track.id)}
            >
              <span className="queue-item__index">
                {isCurrent ? <Play size={10} fill="currentColor" /> : String(index + 1).padStart(2, '0')}
              </span>
              <AlbumArtwork track={track} size="small" />
              <span className="queue-item__copy">
                <strong title={track.title}>{track.title}</strong>
                <small title={track.artist}>{track.artist}</small>
              </span>
              <span className="queue-item__duration">
                {track.duration > 0 ? formatTime(track.duration) : '--:--'}
              </span>
            </button>
          )
        })}
      </div>
    </aside>
  )
}
