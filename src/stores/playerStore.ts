import { create } from 'zustand'
import { persist } from 'zustand/middleware'
import type { Track } from '../types/music'

export type RepeatMode = 'off' | 'all' | 'one'

interface PlayerState {
  library: Track[]
  currentTrackId: string
  isPlaying: boolean
  progress: number
  volume: number
  likedIds: string[]
  queue: string[]
  repeatMode: RepeatMode
  playTrack: (trackId: string) => void
  setPlaying: (isPlaying: boolean) => void
  togglePlayback: () => void
  next: () => void
  previous: () => void
  shuffle: () => void
  cycleRepeatMode: () => void
  playNext: (trackId: string) => void
  addToQueue: (trackId: string) => void
  setProgress: (seconds: number) => void
  setTrackDuration: (trackId: string, duration: number) => void
  updateTrack: (track: Track) => void
  tick: () => void
  setVolume: (volume: number) => void
  toggleLike: (trackId: string) => void
  replaceSourceTracks: (sourceId: string, tracks: Track[]) => void
  removeSource: (sourceId: string) => void
}

export const usePlayerStore = create<PlayerState>()(
  persist(
    (set, get) => ({
      library: [],
      currentTrackId: '',
      isPlaying: false,
      progress: 0,
      volume: 0.72,
      likedIds: [],
      queue: [],
      repeatMode: 'off',

      playTrack: (trackId) =>
        set({ currentTrackId: trackId, progress: 0, isPlaying: true }),

      setPlaying: (isPlaying) => set({ isPlaying }),
      togglePlayback: () => set((state) => ({ isPlaying: !state.isPlaying })),

      next: () => {
        const { currentTrackId, queue, repeatMode } = get()
        if (!queue.length) return
        const currentIndex = Math.max(0, queue.indexOf(currentTrackId))
        if (repeatMode === 'off' && currentIndex === queue.length - 1) {
          set({ isPlaying: false, progress: 0 })
          return
        }
        const nextId = queue[(currentIndex + 1) % queue.length]
        set({ currentTrackId: nextId, progress: 0, isPlaying: true })
      },

      previous: () => {
        const { currentTrackId, progress, queue } = get()
        if (!queue.length) return
        if (progress > 5) {
          set({ progress: 0 })
          window.dispatchEvent(new Event('tingyu:seek-to-start'))
          return
        }
        const currentIndex = Math.max(0, queue.indexOf(currentTrackId))
        const previousIndex = (currentIndex - 1 + queue.length) % queue.length
        set({ currentTrackId: queue[previousIndex], progress: 0, isPlaying: true })
      },

      shuffle: () => {
        const { currentTrackId, queue } = get()
        const candidates = queue.filter((id) => id !== currentTrackId)
        if (!candidates.length) return
        const nextId = candidates[Math.floor(Math.random() * candidates.length)]
        set({ currentTrackId: nextId, progress: 0, isPlaying: true })
      },

      cycleRepeatMode: () =>
        set((state) => {
          const order: RepeatMode[] = ['off', 'all', 'one']
          const current = order.indexOf(state.repeatMode)
          return { repeatMode: order[(current + 1) % order.length] }
        }),

      playNext: (trackId) =>
        set((state) => {
          if (trackId === state.currentTrackId) return state
          const queue = state.queue.filter((id) => id !== trackId)
          const insertAt = Math.max(0, queue.indexOf(state.currentTrackId)) + 1
          queue.splice(insertAt, 0, trackId)
          return { queue }
        }),

      addToQueue: (trackId) =>
        set((state) => {
          if (trackId === state.currentTrackId) return state
          return { queue: [...state.queue.filter((id) => id !== trackId), trackId] }
        }),

      setProgress: (progress) => set({ progress }),

      setTrackDuration: (trackId, duration) =>
        set((state) => ({
          library: state.library.map((track) =>
            track.id === trackId ? { ...track, duration } : track,
          ),
        })),

      updateTrack: (updatedTrack) =>
        set((state) => ({
          library: state.library.map((track) =>
            track.id === updatedTrack.id ? { ...track, ...updatedTrack } : track,
          ),
        })),

      tick: () => {
        const { isPlaying, progress, currentTrackId, library, next } = get()
        if (!isPlaying) return
        const currentTrack = library.find((track) => track.id === currentTrackId)
        if (!currentTrack || currentTrack.streamUrl) return
        if (progress + 1 >= currentTrack.duration) {
          next()
          return
        }
        set({ progress: progress + 1 })
      },

      setVolume: (volume) => set({ volume }),

      toggleLike: (trackId) =>
        set((state) => ({
          likedIds: state.likedIds.includes(trackId)
            ? state.likedIds.filter((id) => id !== trackId)
            : [...state.likedIds, trackId],
        })),

      replaceSourceTracks: (sourceId, incomingTracks) =>
        set((state) => {
          const retained = state.library.filter((track) => track.sourceId !== sourceId)
          const library = [...incomingTracks, ...retained]
          const queue = library.map((track) => track.id)
          const currentStillExists = library.some((track) => track.id === state.currentTrackId)
          return {
            library,
            queue,
            currentTrackId: currentStillExists ? state.currentTrackId : (queue[0] ?? ''),
            progress: currentStillExists ? state.progress : 0,
            isPlaying: currentStillExists ? state.isPlaying : false,
          }
        }),

      removeSource: (sourceId) =>
        set((state) => {
          const library = state.library.filter((track) => track.sourceId !== sourceId)
          const queue = library.map((track) => track.id)
          const currentStillExists = library.some((track) => track.id === state.currentTrackId)
          return {
            library,
            queue,
            currentTrackId: currentStillExists ? state.currentTrackId : (queue[0] ?? ''),
            progress: currentStillExists ? state.progress : 0,
            isPlaying: currentStillExists ? state.isPlaying : false,
          }
        }),
    }),
    {
      name: 'tingyu-player',
      version: 1,
      partialize: (state) => ({
        likedIds: state.likedIds,
        volume: state.volume,
        repeatMode: state.repeatMode,
      }),
    },
  ),
)
