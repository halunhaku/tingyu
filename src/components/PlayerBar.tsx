import { useEffect, useRef, useState } from 'react'
import {
  Heart,
  Mic2,
  Pause,
  Play,
  Shuffle,
  SkipBack,
  SkipForward,
  Volume1,
  Volume2,
} from 'lucide-react'
import { formatTime } from '../data/library'
import { scrapeLocalTrack } from '../providers/localProvider'
import { persistWebDavDuration, scrapeWebDavTrack } from '../providers/webdavProvider'
import { usePlayerStore } from '../stores/playerStore'
import { AlbumArtwork } from './AlbumArtwork'
import { LyricsPanel } from './LyricsPanel'

const CURRENT_ENRICHMENT_VERSION = 4

export function PlayerBar() {
  const audioRef = useRef<HTMLAudioElement>(null)
  const scrapedTracksRef = useRef(new Set<string>())
  const [lyricsOpen, setLyricsOpen] = useState(false)
  const library = usePlayerStore((state) => state.library)
  const currentTrackId = usePlayerStore((state) => state.currentTrackId)
  const isPlaying = usePlayerStore((state) => state.isPlaying)
  const progress = usePlayerStore((state) => state.progress)
  const volume = usePlayerStore((state) => state.volume)
  const likedIds = usePlayerStore((state) => state.likedIds)
  const setPlaying = usePlayerStore((state) => state.setPlaying)
  const togglePlayback = usePlayerStore((state) => state.togglePlayback)
  const previous = usePlayerStore((state) => state.previous)
  const next = usePlayerStore((state) => state.next)
  const shuffle = usePlayerStore((state) => state.shuffle)
  const setProgress = usePlayerStore((state) => state.setProgress)
  const setTrackDuration = usePlayerStore((state) => state.setTrackDuration)
  const updateTrack = usePlayerStore((state) => state.updateTrack)
  const setVolume = usePlayerStore((state) => state.setVolume)
  const toggleLike = usePlayerStore((state) => state.toggleLike)

  const track = library.find((item) => item.id === currentTrackId) ?? library[0]
  const duration = track?.duration || 0
  const progressPercentage = duration > 0 ? (progress / duration) * 100 : 0

  useEffect(() => {
    const audio = audioRef.current
    if (!audio || !track?.streamUrl) return
    if (isPlaying) {
      void audio.play().catch(() => setPlaying(false))
    } else {
      audio.pause()
    }
  }, [isPlaying, setPlaying, track?.streamUrl])

  useEffect(() => {
    if (audioRef.current) audioRef.current.volume = volume
  }, [volume])

  useEffect(() => {
    const toggleLyrics = () => setLyricsOpen((open) => !open)
    window.addEventListener('tingyu:toggle-lyrics', toggleLyrics)
    return () => window.removeEventListener('tingyu:toggle-lyrics', toggleLyrics)
  }, [])

  useEffect(() => {
    const href = track?.remotePath
    if (!href || (track.enrichmentVersion ?? 0) >= CURRENT_ENRICHMENT_VERSION) return
    const scrapeKey = `${track.source}:${href}`
    if (scrapedTracksRef.current.has(scrapeKey)) return
    scrapedTracksRef.current.add(scrapeKey)
    const scrape = track.source === 'local' ? scrapeLocalTrack : scrapeWebDavTrack
    void scrape(href).then((scrapedTrack) => {
      if (scrapedTrack) updateTrack(scrapedTrack)
    }).catch(() => {
      // A failed provider lookup is retried after the next app launch or library sync.
    })
  }, [track?.enrichmentVersion, track?.remotePath, track?.source, updateTrack])

  if (!track) return null

  const seek = (seconds: number) => {
    setProgress(seconds)
    if (audioRef.current && track.streamUrl) audioRef.current.currentTime = seconds
  }

  const handlePrevious = () => {
    if (progress > 5) {
      seek(0)
    } else {
      previous()
    }
  }

  return (
    <>
    <footer className="player-bar">
      <audio
        ref={audioRef}
        src={track.streamUrl}
        preload="metadata"
        onTimeUpdate={(event) => setProgress(event.currentTarget.currentTime)}
        onLoadedMetadata={(event) => {
          if (Number.isFinite(event.currentTarget.duration)) {
            const loadedDuration = event.currentTarget.duration
            setTrackDuration(track.id, loadedDuration)
            if (track.source === 'webdav' && track.remotePath) {
              void persistWebDavDuration(track.remotePath, loadedDuration)
            }
          }
        }}
        onEnded={next}
        onError={() => track.streamUrl && setPlaying(false)}
      />
      <div className="player-track">
        <AlbumArtwork track={track} size="small" />
        <div className="player-track__copy">
          <strong>{track.title}</strong>
          <span>{track.artist}</span>
        </div>
        <button
          className={likedIds.includes(track.id) ? 'is-liked' : ''}
          type="button"
          aria-label="喜欢"
          onClick={() => toggleLike(track.id)}
        >
          <Heart size={16} fill={likedIds.includes(track.id) ? 'currentColor' : 'none'} />
        </button>
        <button
          className="lyrics-toggle"
          type="button"
          aria-label="查看歌词"
          onClick={() => setLyricsOpen(true)}
        >
          <Mic2 size={16} />
          <span>歌词</span>
        </button>
      </div>

      <div className="player-center">
        <div className="transport-controls">
          <button type="button" aria-label="随机播放" onClick={shuffle}><Shuffle size={15} /></button>
          <button type="button" aria-label="上一首" onClick={handlePrevious}><SkipBack size={18} fill="currentColor" /></button>
          <button className="play-button" type="button" aria-label={isPlaying ? '暂停' : '播放'} onClick={togglePlayback}>
            {isPlaying ? <Pause size={18} fill="currentColor" /> : <Play size={18} fill="currentColor" />}
          </button>
          <button type="button" aria-label="下一首" onClick={next}><SkipForward size={18} fill="currentColor" /></button>
        </div>
        <div className="progress-row">
          <span>{formatTime(progress)}</span>
          <div className="range-wrap" style={{ '--range-progress': `${progressPercentage}%` } as React.CSSProperties}>
            <input
              aria-label="播放进度"
              disabled={duration <= 0}
              max={duration || 1}
              min="0"
              onChange={(event) => seek(Number(event.target.value))}
              type="range"
              value={Math.min(progress, duration || 1)}
            />
          </div>
          <span>{duration > 0 ? `-${formatTime(Math.max(0, duration - progress))}` : '--:--'}</span>
        </div>
      </div>

      <div className="player-options">
        <button
          className={lyricsOpen ? 'player-lyrics-button is-active' : 'player-lyrics-button'}
          type="button"
          aria-label="查看歌词"
          aria-pressed={lyricsOpen}
          onClick={() => setLyricsOpen((open) => !open)}
        >
          <Mic2 size={15} />
          <span>歌词</span>
        </button>
        <Volume1 size={16} aria-hidden="true" />
        <div className="range-wrap volume-range" style={{ '--range-progress': `${volume * 100}%` } as React.CSSProperties}>
          <input
            aria-label="音量"
            max="1"
            min="0"
            onChange={(event) => setVolume(Number(event.target.value))}
            step="0.01"
            type="range"
            value={volume}
          />
        </div>
        <Volume2 size={16} aria-hidden="true" />
      </div>
    </footer>
    {lyricsOpen && <LyricsPanel track={track} progress={progress} onClose={() => setLyricsOpen(false)} />}
    </>
  )
}
