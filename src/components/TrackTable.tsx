import { useEffect, useState } from 'react'
import { Check, Cloud, FolderOpen, Heart, MoreHorizontal, Pause, Play } from 'lucide-react'
import { formatTime, sourceLabel } from '../data/library'
import { usePlayerStore } from '../stores/playerStore'
import type { Track } from '../types/music'
import { AlbumArtwork } from './AlbumArtwork'

interface TrackTableProps {
  tracks: Track[]
  emptyTitle?: string
  emptyDescription?: string
}

interface TrackMenuState {
  track: Track
  x: number
  y: number
}

export function TrackTable({
  tracks,
  emptyTitle = '没有找到这段声音',
  emptyDescription = '试试搜索歌手、专辑或歌曲名',
}: TrackTableProps) {
  const [menu, setMenu] = useState<TrackMenuState | null>(null)
  const currentTrackId = usePlayerStore((state) => state.currentTrackId)
  const isPlaying = usePlayerStore((state) => state.isPlaying)
  const playTrack = usePlayerStore((state) => state.playTrack)
  const togglePlayback = usePlayerStore((state) => state.togglePlayback)
  const likedIds = usePlayerStore((state) => state.likedIds)
  const toggleLike = usePlayerStore((state) => state.toggleLike)

  useEffect(() => {
    if (!menu) return
    const close = () => setMenu(null)
    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') close()
    }
    window.addEventListener('pointerdown', close)
    window.addEventListener('keydown', handleKeyDown)
    window.addEventListener('scroll', close, true)
    window.addEventListener('blur', close)
    return () => {
      window.removeEventListener('pointerdown', close)
      window.removeEventListener('keydown', handleKeyDown)
      window.removeEventListener('scroll', close, true)
      window.removeEventListener('blur', close)
    }
  }, [menu])

  const openMenu = (track: Track, x: number, y: number) => {
    setMenu({
      track,
      x: Math.min(x, window.innerWidth - 174),
      y: Math.min(y, window.innerHeight - 112),
    })
  }

  if (!tracks.length) {
    return (
      <div className="empty-state">
        <span>{emptyTitle}</span>
        <small>{emptyDescription}</small>
      </div>
    )
  }

  return (
    <>
      <div className="track-table" role="table" aria-label="全部歌曲">
        <div className="track-table__header" role="row">
          <span>#</span>
          <span>标题</span>
          <span>专辑</span>
          <span>来源</span>
          <span>时长</span>
          <span>操作</span>
        </div>
        {tracks.map((track, index) => {
          const isCurrent = track.id === currentTrackId
          const SourceIcon = track.source === 'webdav' ? Cloud : FolderOpen
          return (
            <div
              className={`track-row ${isCurrent ? 'is-current' : ''}`}
              key={track.id}
              role="row"
              onDoubleClick={() => playTrack(track.id)}
              onContextMenu={(event) => {
                event.preventDefault()
                openMenu(track, event.clientX, event.clientY)
              }}
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
                  <strong title={track.title}>{track.title}</strong>
                  <small title={track.artist}>{track.artist}</small>
                </span>
              </div>
              <span className="track-album" title={track.album}>{track.album}</span>
              <span className="track-source">
                <SourceIcon size={13} />
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
                  <Heart size={14} fill={likedIds.includes(track.id) ? 'currentColor' : 'none'} />
                </button>
                <button
                  type="button"
                  aria-label={`打开 ${track.title} 的操作菜单`}
                  aria-haspopup="menu"
                  onClick={(event) => {
                    const rect = event.currentTarget.getBoundingClientRect()
                    openMenu(track, rect.right - 160, rect.bottom + 5)
                  }}
                >
                  <MoreHorizontal size={15} />
                </button>
              </div>
            </div>
          )
        })}
      </div>

      {menu && (
        <div
          className="track-context-menu"
          role="menu"
          style={{ left: menu.x, top: menu.y }}
          onPointerDown={(event) => event.stopPropagation()}
        >
          <button
            type="button"
            role="menuitem"
            onClick={() => {
              if (menu.track.id === currentTrackId) togglePlayback()
              else playTrack(menu.track.id)
              setMenu(null)
            }}
          >
            {menu.track.id === currentTrackId && isPlaying ? <Pause size={14} /> : <Play size={14} />}
            {menu.track.id === currentTrackId && isPlaying ? '暂停' : '立即播放'}
          </button>
          <button
            type="button"
            role="menuitem"
            onClick={() => {
              toggleLike(menu.track.id)
              setMenu(null)
            }}
          >
            {likedIds.includes(menu.track.id) ? <Check size={14} /> : <Heart size={14} />}
            {likedIds.includes(menu.track.id) ? '取消喜欢' : '添加喜欢'}
          </button>
        </div>
      )}
    </>
  )
}
