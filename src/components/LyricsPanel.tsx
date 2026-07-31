import { useEffect, useMemo, useRef } from 'react'
import { Music2, X } from 'lucide-react'
import type { Track } from '../types/music'
import { AlbumArtwork } from './AlbumArtwork'

interface LyricsPanelProps {
  track: Track
  progress: number
  onClose: () => void
}

interface LyricLine {
  time: number
  text: string
}

export function LyricsPanel({ track, progress, onClose }: LyricsPanelProps) {
  const activeLineRef = useRef<HTMLParagraphElement>(null)
  const syncedLines = useMemo(() => parseLrc(track.syncedLyrics), [track.syncedLyrics])
  const plainLines = useMemo(
    () => track.plainLyrics?.split(/\r?\n/).map((line) => line.trim()).filter(Boolean) ?? [],
    [track.plainLyrics],
  )
  const activeIndex = syncedLines.findLastIndex((line) => line.time <= progress + 0.08)

  useEffect(() => {
    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') onClose()
    }
    window.addEventListener('keydown', handleKeyDown)
    return () => window.removeEventListener('keydown', handleKeyDown)
  }, [onClose])

  useEffect(() => {
    activeLineRef.current?.scrollIntoView({
      block: 'center',
      behavior: window.matchMedia('(prefers-reduced-motion: reduce)').matches ? 'auto' : 'smooth',
    })
  }, [activeIndex])

  return (
    <div
      className="lyrics-layer"
      role="presentation"
      onMouseDown={(event) => event.target === event.currentTarget && onClose()}
    >
      <section className="lyrics-panel" role="dialog" aria-modal="true" aria-label={`${track.title} 的歌词`}>
        <header className="lyrics-panel__header">
          <span>NOW SINGING</span>
          <button type="button" aria-label="关闭歌词" onClick={onClose}><X size={19} /></button>
        </header>

        <div className="lyrics-panel__record">
          <div className="lyrics-panel__art">
            <AlbumArtwork track={track} size="large" />
          </div>
          <div>
            <span className="eyebrow">{track.album}</span>
            <h2>{track.title}</h2>
            <p>{track.artist}</p>
          </div>
        </div>

        <div className="lyrics-panel__scroll" aria-live="off">
          {syncedLines.length > 0 ? syncedLines.map((line, index) => (
            <p
              className={index === activeIndex ? 'is-active' : index < activeIndex ? 'is-past' : ''}
              key={`${line.time}-${index}`}
              ref={index === activeIndex ? activeLineRef : undefined}
            >
              {line.text || '♪'}
            </p>
          )) : plainLines.length > 0 ? plainLines.map((line, index) => (
            <p key={`${line}-${index}`}>{line}</p>
          )) : (
            <div className="lyrics-panel__empty">
              <Music2 size={24} strokeWidth={1.4} />
              <strong>这一首还没有找到歌词</strong>
              <span>尚未在 LRCLIB 匹配到结果，可检查歌曲标签中的标题与艺术家。</span>
            </div>
          )}
        </div>

        <footer className="lyrics-panel__source">
          {syncedLines.length > 0 ? '逐字流动 · LRCLIB' : plainLines.length > 0 ? '歌词 · LRCLIB' : 'INSTRUMENTAL / NOT FOUND'}
        </footer>
      </section>
    </div>
  )
}

function parseLrc(value?: string): LyricLine[] {
  if (!value) return []
  const lines: LyricLine[] = []
  for (const rawLine of value.split(/\r?\n/)) {
    const timestamps = [...rawLine.matchAll(/\[(\d{1,3}):(\d{2}(?:\.\d{1,3})?)\]/g)]
    if (!timestamps.length) continue
    const text = rawLine.replace(/\[[^\]]+\]/g, '').trim()
    for (const timestamp of timestamps) {
      lines.push({
        time: Number(timestamp[1]) * 60 + Number(timestamp[2]),
        text,
      })
    }
  }
  return lines.sort((left, right) => left.time - right.time)
}
