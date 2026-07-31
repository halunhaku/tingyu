import { RadioTower } from 'lucide-react'
import { usePlayerStore } from '../stores/playerStore'
import { AlbumArtwork } from './AlbumArtwork'

export function QueuePanel() {
  const library = usePlayerStore((state) => state.library)
  const currentTrackId = usePlayerStore((state) => state.currentTrackId)
  const queue = usePlayerStore((state) => state.queue)
  const playTrack = usePlayerStore((state) => state.playTrack)
  const currentIndex = queue.indexOf(currentTrackId)
  const upcomingIds = [...queue.slice(currentIndex + 1), ...queue.slice(0, currentIndex)].slice(0, 4)
  const upcoming = upcomingIds
    .map((id) => library.find((track) => track.id === id))
    .filter((track) => track !== undefined)

  return (
    <aside className="queue-panel">
      <div className="queue-panel__heading">
        <div>
          <span className="eyebrow">PLAYING NEXT</span>
          <h2>接下来播放</h2>
        </div>
      </div>

      <div className="queue-list">
        {upcoming.length === 0 && <span className="queue-empty">队列中没有更多歌曲</span>}
        {upcoming.map((track, index) => (
          <button className="queue-item" type="button" key={track.id} onClick={() => playTrack(track.id)}>
            <span className="queue-item__index">{String(index + 1).padStart(2, '0')}</span>
            <AlbumArtwork track={track} size="small" />
            <span className="queue-item__copy">
              <strong>{track.title}</strong>
              <small>{track.artist}</small>
            </span>
          </button>
        ))}
      </div>

      <div className="sync-card">
        <span className="sync-card__icon"><RadioTower size={18} /></span>
        <div>
          <strong>曲库已同步</strong>
          <span>来自云端音乐源的 {library.length} 首歌</span>
        </div>
        <span className="sync-card__pulse" />
      </div>
    </aside>
  )
}
