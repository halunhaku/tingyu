import { useCallback, useEffect, useRef, useState } from 'react'
import {
  Heart,
  Pause,
  Play,
  Shuffle,
  SkipBack,
  SkipForward,
  Volume1,
  Volume2,
} from 'lucide-react'
import { formatTime } from '../data/library'
import {
  clearSystemMediaSession,
  listenToSystemMediaControls,
  type SystemMediaControl,
  updateSystemMediaSession,
} from '../providers/systemMediaSession'
import { scrapeLocalTrack } from '../providers/localProvider'
import { persistWebDavDuration, scrapeWebDavTrack } from '../providers/webdavProvider'
import { usePlayerStore } from '../stores/playerStore'
import { AlbumArtwork } from './AlbumArtwork'
import { LyricsPanel } from './LyricsPanel'

const CURRENT_ENRICHMENT_VERSION = 4

export function PlayerBar() {
  const audioRef = useRef<HTMLAudioElement>(null)
  const scrapedTracksRef = useRef(new Set<string>())
  const mediaSessionStartedRef = useRef(false)
  const lastMediaPositionSyncRef = useRef(0)
  const mediaControlHandlerRef = useRef<(control: SystemMediaControl) => void>(() => undefined)
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
  const closeLyrics = useCallback(() => setLyricsOpen(false), [])
  const syncSystemMedia = useCallback((positionSeconds?: number, playingOverride?: boolean) => {
    if (!track?.streamUrl) return
    const playing = playingOverride ?? usePlayerStore.getState().isPlaying
    if (playing) mediaSessionStartedRef.current = true
    if (!mediaSessionStartedRef.current) return

    const audioPosition = audioRef.current?.currentTime
    void updateSystemMediaSession({
      title: track.title,
      artist: track.artist,
      album: track.album,
      artworkUrl: track.artworkUrl,
      durationSeconds: track.duration || 0,
      positionSeconds: positionSeconds
        ?? (typeof audioPosition === 'number' && Number.isFinite(audioPosition)
          ? audioPosition
          : usePlayerStore.getState().progress),
      playing,
    }).catch((error) => console.warn('Unable to update system media controls', error))
  }, [track?.album, track?.artist, track?.artworkUrl, track?.duration, track?.streamUrl, track?.title])

  mediaControlHandlerRef.current = (control) => {
    const audio = audioRef.current
    switch (control.action) {
      case 'play':
        setPlaying(true)
        break
      case 'pause':
        setPlaying(false)
        break
      case 'toggle':
        togglePlayback()
        break
      case 'previous':
        if (audio && audio.currentTime > 5) {
          audio.currentTime = 0
          setProgress(0)
          syncSystemMedia(0)
        } else {
          previous()
        }
        break
      case 'next':
        next()
        break
      case 'seek': {
        const seconds = Math.max(0, (control.positionMs ?? 0) / 1000)
        if (audio?.src) audio.currentTime = seconds
        setProgress(seconds)
        syncSystemMedia(seconds)
        break
      }
      case 'seekRelative': {
        const currentTime = audio?.currentTime ?? usePlayerStore.getState().progress
        const target = currentTime + (control.offsetMs ?? 0) / 1000
        const seconds = Math.max(0, duration > 0 ? Math.min(target, duration) : target)
        if (audio?.src) audio.currentTime = seconds
        setProgress(seconds)
        syncSystemMedia(seconds)
        break
      }
      case 'stop':
        mediaSessionStartedRef.current = false
        setPlaying(false)
        void clearSystemMediaSession()
        break
    }
  }

  useEffect(() => {
    let cancelled = false
    let dispose: (() => Promise<void>) | undefined
    void listenToSystemMediaControls((control) => mediaControlHandlerRef.current(control))
      .then((unlisten) => {
        if (cancelled) void unlisten()
        else dispose = unlisten
      })
      .catch((error) => console.warn('Unable to listen for system media controls', error))

    return () => {
      cancelled = true
      void dispose?.()
      mediaSessionStartedRef.current = false
      void clearSystemMediaSession()
    }
  }, [])

  useEffect(() => {
    syncSystemMedia(undefined, isPlaying)
  }, [isPlaying, syncSystemMedia])

  useEffect(() => {
    const audio = audioRef.current
    if (!audio) return

    audio.pause()
    audio.removeAttribute('src')
    audio.load()
    audio.crossOrigin = 'anonymous'
    if (track?.streamUrl) {
      audio.src = track.streamUrl
      audio.load()
    }
  }, [track?.streamUrl])

  useEffect(() => {
    const audio = audioRef.current
    if (!audio || !track?.streamUrl) return
    if (isPlaying) {
      if (audio.error || audio.networkState === HTMLMediaElement.NETWORK_NO_SOURCE) {
        audio.pause()
        audio.removeAttribute('src')
        audio.load()
        audio.crossOrigin = 'anonymous'
        audio.src = track.streamUrl
        audio.load()
      }
      void audio.play().catch((error) => {
        console.error('Audio playback failed', {
          error,
          source: track.source,
          title: track.title,
        })
        setPlaying(false)
      })
    } else {
      audio.pause()
    }
  }, [isPlaying, setPlaying, track?.source, track?.streamUrl, track?.title])

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
    const scrapeKey = `${track.sourceId}:${href}`
    if (scrapedTracksRef.current.has(scrapeKey)) return
    scrapedTracksRef.current.add(scrapeKey)
    const scrape = track.source === 'local' ? scrapeLocalTrack : scrapeWebDavTrack
    void scrape(track.sourceId, href).then((scrapedTrack) => {
      if (scrapedTrack) updateTrack(scrapedTrack)
    }).catch(() => {
      // A failed provider lookup is retried after the next app launch or library sync.
    })
  }, [track?.enrichmentVersion, track?.remotePath, track?.source, track?.sourceId, updateTrack])

  if (!track) return null

  const seek = (seconds: number) => {
    setProgress(seconds)
    if (audioRef.current && track.streamUrl) audioRef.current.currentTime = seconds
    syncSystemMedia(seconds)
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
        crossOrigin="anonymous"
        ref={audioRef}
        preload="none"
        onTimeUpdate={(event) => {
          const currentTime = event.currentTarget.currentTime
          setProgress(currentTime)
          const now = Date.now()
          if (mediaSessionStartedRef.current && now - lastMediaPositionSyncRef.current >= 5_000) {
            lastMediaPositionSyncRef.current = now
            syncSystemMedia(currentTime)
          }
        }}
        onLoadedMetadata={(event) => {
          if (Number.isFinite(event.currentTarget.duration)) {
            const loadedDuration = event.currentTarget.duration
            setTrackDuration(track.id, loadedDuration)
            if (track.source === 'webdav' && track.remotePath) {
              void persistWebDavDuration(track.sourceId, track.remotePath, loadedDuration)
            }
          }
        }}
        onEnded={next}
        onError={(event) => {
          if (!track.streamUrl) return
          console.error('Audio source failed', {
            code: event.currentTarget.error?.code,
            message: event.currentTarget.error?.message,
            networkState: event.currentTarget.networkState,
            readyState: event.currentTarget.readyState,
            source: track.source,
            title: track.title,
          })
          setPlaying(false)
        }}
      />
      <div className="player-track">
        <button
          className="player-track__lyrics-trigger"
          type="button"
          aria-label={`查看 ${track.title} 的歌词`}
          aria-expanded={lyricsOpen}
          aria-haspopup="dialog"
          onClick={() => setLyricsOpen(true)}
        >
          <AlbumArtwork track={track} size="small" />
          <span className="player-track__copy">
            <strong>{track.title}</strong>
            <span>{track.artist}</span>
          </span>
        </button>
        <button
          className={likedIds.includes(track.id) ? 'is-liked' : ''}
          type="button"
          aria-label="喜欢"
          onClick={() => toggleLike(track.id)}
        >
          <Heart size={16} fill={likedIds.includes(track.id) ? 'currentColor' : 'none'} />
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
    {lyricsOpen && <LyricsPanel track={track} progress={progress} onClose={closeLyrics} />}
    </>
  )
}
