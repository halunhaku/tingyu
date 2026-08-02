import { useRef } from 'react'
import { Cloud, FolderOpen, ListOrdered, Pause, Play, Shuffle } from 'lucide-react'
import { sourceLabel } from '../data/library'
import { gsap, useGSAP } from '../gsap'
import type { PlayOrder } from '../stores/playerStore'
import type { Track } from '../types/music'
import { AlbumArtwork } from './AlbumArtwork'

interface NowPlayingHeroProps {
  track: Track
  isCurrent: boolean
  isPlaying: boolean
  playOrder: PlayOrder
  onPlay: () => void
  onTogglePlayOrder: () => void
}

export function NowPlayingHero({
  track,
  isCurrent,
  isPlaying,
  playOrder,
  onPlay,
  onTogglePlayOrder,
}: NowPlayingHeroProps) {
  const SourceIcon = track.source === 'webdav' ? Cloud : FolderOpen
  const heroRef = useRef<HTMLElement>(null)

  useGSAP(() => {
    const media = gsap.matchMedia()
    media.add(
      {
        motion: '(prefers-reduced-motion: no-preference)',
        reducedMotion: '(prefers-reduced-motion: reduce)',
      },
      (context) => {
        const { reducedMotion } = context.conditions as { reducedMotion: boolean }
        const copyTargets = gsap.utils.toArray<HTMLElement>(
          '.spotlight__label, .spotlight__title-block, .spotlight__meta, .spotlight__actions',
        )

        if (reducedMotion) {
          gsap.fromTo(
            ['.spotlight__art-wrap .album-art', ...copyTargets],
            { autoAlpha: 0.68 },
            {
              autoAlpha: 1,
              duration: 0.18,
              stagger: 0.02,
              ease: 'power1.out',
              clearProps: 'opacity,visibility',
            },
          )
          return
        }

        gsap.timeline({ defaults: { ease: 'power3.out' } })
          .from('.spotlight__disc', {
            autoAlpha: 0,
            scale: 0.92,
            rotation: -7,
            duration: 0.48,
            clearProps: 'transform,opacity,visibility',
          })
          .from('.spotlight__art-wrap .album-art', {
            autoAlpha: 0,
            xPercent: -6,
            rotation: '-=1.5',
            duration: 0.46,
            clearProps: 'transform,opacity,visibility',
          }, '<0.04')
          .from(copyTargets, {
            autoAlpha: 0,
            y: 10,
            duration: 0.34,
            stagger: 0.04,
            clearProps: 'transform,opacity,visibility',
          }, '<0.08')
          .from('.spotlight__number', {
            autoAlpha: 0,
            x: 8,
            duration: 0.3,
            clearProps: 'transform,opacity,visibility',
          }, '<')
      },
      heroRef,
    )

    return () => media.revert()
  }, {
    scope: heroRef,
    dependencies: [track.id],
    revertOnUpdate: true,
  })


  return (
    <section ref={heroRef} className="spotlight" aria-label="当前播放">
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
          <button
            className={`secondary-button spotlight__mode-button ${playOrder === 'shuffle' ? 'is-active' : ''}`}
            type="button"
            aria-label={playOrder === 'shuffle' ? '切换为顺序播放' : '切换为随机播放'}
            aria-pressed={playOrder === 'shuffle'}
            title={playOrder === 'shuffle' ? '当前：随机播放' : '当前：顺序播放'}
            onClick={onTogglePlayOrder}
          >
            {playOrder === 'shuffle' ? <Shuffle size={14} /> : <ListOrdered size={14} />}
            {playOrder === 'shuffle' ? '随机播放' : '顺序播放'}
          </button>
        </div>
      </div>

      <span className="spotlight__number" aria-hidden="true">01</span>
    </section>
  )
}
