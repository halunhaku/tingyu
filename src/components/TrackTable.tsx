import { Cloud, Heart, Pause, Play } from 'lucide-react'
import { formatTime, sourceLabel } from '../data/library'
import { usePlayerStore } from '../stores/playerStore'
import type { Track } from '../types/music'
import { AlbumArtwork } from './AlbumArtwork'

interface TrackTableProps {
  tracks: Track[]
  emptyTitle?: string
  emptyDescription?: string
}

export function TrackTable({
  tracks,
  emptyTitle = '没有找到这段声音',
  emptyDescription = '试试搜索歌手、专辑或歌曲名',
}: TrackTableProps) {
  const currentTrackId = usePlayerStore((state) => state.currentTrackId)
  const isPlaying = usePlayerStore((state) => state.isPlaying)
  const playTrack = usePlayerStore((state) => state.playTrack)
  const togglePlayback = usePlayerStore((state) => state.togglePlayback)
  const likedIds = usePlayerStore((state) => state.likedIds)
  const toggleLike = usePlayerStore((state) => state.toggleLike)

  if (!tracks.length) {
    return (
      <div className="empty-state">
        <span>{emptyTitle}</span>
        <small>{emptyDescription}</small>
      </div>
    )
  }

  return (
    <div className="track-table" role="table" aria-label="最近播放">
      <div className="track-table__header" role="row">
        <span>#</span>
        <span>标题</span>
        <span>专辑</span>
        <span>来源</span>
        <span>时长</span>
        <span />
      </div>
      {tracks.map((track, index) => {
        const isCurrent = track.id === currentTrackId
        return (
          <div
            className={`track-row ${isCurrent ? 'is-current' : ''}`}
            key={track.id}
            role="row"
            onDoubleClick={() => playTrack(track.id)}
          >
            <button
              className="track-index"
              type="button"
              aria-label={isCurrent && isPlaying ? `暂停 ${track.title}` : `播放 ${track.title}`}
              onClick={() => (isCurrent ? togglePlayback() : playTrack(track.id))}
            >
              <span className="track-index__number">{String(index + 1).padStart(2, '0')}</span>
              <span className="track-index__play">
                {isCurrent && isPlaying ? <Pause size={14} fill="currentColor" /> : <Play size={14} fill="currentColor" />}
              </span>
            </button>
            <div className="track-title-cell">
              <AlbumArtwork track={track} size="small" />
              <span>
                <strong>{track.title}</strong>
                <small>{track.artist}</small>
              </span>
            </div>
            <span className="track-album">{track.album}</span>
            <span className="track-source">
              <Cloud size={13} />
              {sourceLabel[track.source]}
            </span>
            <span className="track-duration">{track.duration > 0 ? formatTime(track.duration) : '--:--'}</span>
            <div className="track-actions">
              <button
                className={likedIds.includes(track.id) ? 'is-liked' : ''}
                type="button"
                aria-label={likedIds.includes(track.id) ? '取消喜欢' : '添加喜欢'}
                onClick={() => toggleLike(track.id)}
              >
                <Heart size={15} fill={likedIds.includes(track.id) ? 'currentColor' : 'none'} />
              </button>
            </div>
          </div>
        )
      })}
    </div>
  )
}
