import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { isTauri } from '@tauri-apps/api/core'
import { listen } from '@tauri-apps/api/event'
import {
  ChevronRight,
  Cloud,
  Menu,
  Pause,
  Play,
  Search,
  X,
} from 'lucide-react'
import './App.css'
import { AlbumArtwork } from './components/AlbumArtwork'
import { PlayerBar } from './components/PlayerBar'
import { QueuePanel } from './components/QueuePanel'
import { Sidebar } from './components/Sidebar'
import { SourceManager } from './components/SourceManager'
import { TrackTable } from './components/TrackTable'
import { WebDavSetup } from './components/WebDavSetup'
import { sourceLabel } from './data/library'
import {
  chooseAndScanLocalFolder,
  forgetLocalFolder,
  readableLocalError,
  refreshLocalFolder,
  restoreLocalFolders,
} from './providers/localProvider'
import {
  forgetWebDav,
  loadCachedWebDavs,
  restoreAndScanWebDavs,
  scanWebDav,
  type ScanStats,
} from './providers/webdavProvider'
import { usePlayerStore } from './stores/playerStore'
import type { MusicSource, Track } from './types/music'

type View = 'library' | 'favorites'

const viewCopy: Record<View, { eyebrow: string; title: string; description: string }> = {
  library: {
    eyebrow: 'YOUR COLLECTION',
    title: '所有声音，都在这里。',
    description: '本地文件夹与 WebDAV，汇成一座完整的私人曲库。',
  },
  favorites: {
    eyebrow: 'HEARTED TRACKS',
    title: '舍不得跳过的歌。',
    description: '你标记过的片刻，我们替你留在手边。',
  },
}

function formatSyncStats(stats: ScanStats) {
  if (stats.added || stats.updated || stats.removed) {
    return `新增 ${stats.added} · 更新 ${stats.updated}`
  }
  return '曲库已是最新'
}

function App() {
  const [activeView, setActiveView] = useState<View>('library')
  const [query, setQuery] = useState('')
  const [sidebarOpen, setSidebarOpen] = useState(false)
  const [webdavSetupOpen, setWebdavSetupOpen] = useState(false)
  const [sourceManagerOpen, setSourceManagerOpen] = useState(false)
  const [activeSourceId, setActiveSourceId] = useState<string | null>(null)
  const [sources, setSources] = useState<MusicSource[]>([])
  const [syncMessage, setSyncMessage] = useState('本地曲库')
  const searchInputRef = useRef<HTMLInputElement>(null)
  const restoreStartedRef = useRef(false)
  const refreshInProgressRef = useRef(false)
  const library = usePlayerStore((state) => state.library)
  const currentTrackId = usePlayerStore((state) => state.currentTrackId)
  const isPlaying = usePlayerStore((state) => state.isPlaying)
  const likedIds = usePlayerStore((state) => state.likedIds)
  const playTrack = usePlayerStore((state) => state.playTrack)
  const togglePlayback = usePlayerStore((state) => state.togglePlayback)
  const shuffle = usePlayerStore((state) => state.shuffle)
  const tick = usePlayerStore((state) => state.tick)
  const replaceSourceTracks = usePlayerStore((state) => state.replaceSourceTracks)
  const removeSource = usePlayerStore((state) => state.removeSource)

  const upsertSource = useCallback((source: MusicSource) => {
    setSources((current) => {
      const exists = current.some((item) => item.id === source.id)
      return exists
        ? current.map((item) => item.id === source.id ? { ...item, ...source } : item)
        : [...current, source]
    })
  }, [])

  const currentTrack = library.find((track) => track.id === currentTrackId) ?? library[0]
  const selectedSource = sources.find((source) => source.id === activeSourceId)
  const copy = selectedSource
    ? {
        eyebrow: selectedSource.kind === 'webdav' ? 'WEBDAV SOURCE' : 'LOCAL SOURCE',
        title: selectedSource.name,
        description: selectedSource.status,
      }
    : viewCopy[activeView]

  const visibleTracks = useMemo(() => {
    const normalized = query.trim().toLocaleLowerCase()
    let result = activeView === 'favorites'
      ? library.filter((track) => likedIds.includes(track.id))
      : library

    if (activeSourceId) {
      result = result.filter((track) => track.sourceId === activeSourceId)
    }
    if (normalized) {
      result = result.filter((track) =>
        [track.title, track.artist, track.album].some((value) =>
          value.toLocaleLowerCase().includes(normalized),
        ),
      )
    }
    return result
  }, [activeSourceId, activeView, library, likedIds, query])

  const spotlightTrack = currentTrack && (!activeSourceId || currentTrack.sourceId === activeSourceId)
    ? currentTrack
    : visibleTracks[0]

  useEffect(() => {
    const timer = window.setInterval(tick, 1000)
    return () => window.clearInterval(timer)
  }, [tick])

  useEffect(() => {
    if (restoreStartedRef.current) return
    restoreStartedRef.current = true
    let cancelled = false

    const restoreLocalLibraries = async () => {
      try {
        const restored = await restoreLocalFolders()
        if (cancelled) return
        for (const source of restored) {
          replaceSourceTracks(source.sourceId, source.tracks)
          upsertSource({
            id: source.sourceId,
            kind: 'local',
            name: source.sourceName,
            status: `${source.tracks.length} 首 · ${source.folderName}`,
            folder: source.folderPath,
          })
        }
      } catch (error) {
        if (!cancelled) setSyncMessage(readableLocalError(error))
      }
    }

    const restoreLibraries = async () => {
      void restoreLocalLibraries()
      const cachedLibraries = await loadCachedWebDavs()
      if (cancelled) return
      for (const cached of cachedLibraries) {
        replaceSourceTracks(cached.sourceId, cached.tracks)
        upsertSource({
          id: cached.sourceId,
          kind: 'webdav',
          name: cached.name,
          status: `${cached.tracks.length} 首 · 本地缓存`,
        })
      }
      if (cachedLibraries.length) setSyncMessage('正在增量同步')
      try {
        const restored = await restoreAndScanWebDavs()
        if (cancelled) return
        for (const source of restored) {
          replaceSourceTracks(source.connection.sourceId, source.tracks)
          upsertSource({
            id: source.connection.sourceId,
            kind: 'webdav',
            name: source.connection.name,
            status: `${source.tracks.length} 首 · ${source.connection.serverName}`,
            folder: source.connection.folder,
          })
        }
        setSyncMessage(restored.length ? '曲库已同步' : cachedLibraries.length ? '使用本地缓存' : '本地曲库')
      } catch {
        if (!cancelled) setSyncMessage(cachedLibraries.length ? '使用本地缓存' : '需要连接')
      }
    }

    void restoreLibraries()
    return () => { cancelled = true }
  }, [replaceSourceTracks, upsertSource])

  useEffect(() => {
    const handleShortcut = (event: KeyboardEvent) => {
      if ((event.metaKey || event.ctrlKey) && event.key.toLocaleLowerCase() === 'k') {
        event.preventDefault()
        searchInputRef.current?.focus()
      }
    }
    window.addEventListener('keydown', handleShortcut)
    return () => window.removeEventListener('keydown', handleShortcut)
  }, [])

  const handleViewChange = (view: View) => {
    setActiveView(view)
    setActiveSourceId(null)
    setSidebarOpen(false)
  }

  const handleSourceSelect = (sourceId: string) => {
    setActiveSourceId(sourceId)
    setActiveView('library')
    setSidebarOpen(false)
  }

  const handleWebDavConnected = (
    sourceId: string,
    webdavTracks: Track[],
    sourceName: string,
    serverName: string,
    folder: string,
    stats: ScanStats,
  ) => {
    replaceSourceTracks(sourceId, webdavTracks)
    upsertSource({
      id: sourceId,
      kind: 'webdav',
      name: sourceName,
      status: `${webdavTracks.length} 首 · ${serverName}`,
      folder,
    })
    setSyncMessage(formatSyncStats(stats))
    setWebdavSetupOpen(false)
    setSourceManagerOpen(false)
    setActiveSourceId(sourceId)
    setActiveView('library')
  }

  const handleAddLocal = async (name: string) => {
    try {
      const result = await chooseAndScanLocalFolder(name)
      if (!result) return
      replaceSourceTracks(result.sourceId, result.tracks)
      upsertSource({
        id: result.sourceId,
        kind: 'local',
        name: result.sourceName,
        status: `${result.tracks.length} 首 · ${result.folderName}`,
        folder: result.folderPath,
      })
      setSyncMessage(`已导入 ${result.tracks.length} 首本地歌曲`)
      setSourceManagerOpen(false)
      setActiveSourceId(result.sourceId)
      setActiveView('library')
    } catch (error) {
      setSyncMessage(readableLocalError(error))
    }
  }

  const handleRemoveSource = async (source: MusicSource) => {
    try {
      if (source.kind === 'webdav') {
        await forgetWebDav(source.id)
      } else {
        await forgetLocalFolder(source.id)
      }
      removeSource(source.id)
      setSources((current) => current.filter((item) => item.id !== source.id))
      if (activeSourceId === source.id) setActiveSourceId(null)
    } catch (error) {
      setSyncMessage(typeof error === 'string' ? error : `无法删除 ${source.name}`)
    }
  }

  const handleRefreshLibraries = useCallback(async () => {
    if (refreshInProgressRef.current) return
    if (!sources.length) {
      setSyncMessage('请先添加音乐源')
      return
    }
    refreshInProgressRef.current = true
    setSyncMessage('正在刷新曲库')
    const tasks = sources.map(async (source) => {
      if (source.kind === 'local') {
        const result = await refreshLocalFolder(source.id)
        replaceSourceTracks(source.id, result.tracks)
        upsertSource({
          ...source,
          status: `${result.tracks.length} 首 · ${result.folderName}`,
          folder: result.folderPath,
        })
      } else {
        const result = await scanWebDav(source.id, source.folder)
        replaceSourceTracks(source.id, result.tracks)
        upsertSource({ ...source, status: `${result.tracks.length} 首 · 已同步` })
      }
    })
    const results = await Promise.allSettled(tasks)
    const failed = results.filter((result) => result.status === 'rejected').length
    setSyncMessage(failed ? `${failed} 个音乐源刷新失败` : '曲库已刷新')
    refreshInProgressRef.current = false
  }, [replaceSourceTracks, sources, upsertSource])

  useEffect(() => {
    if (!isTauri()) return
    let unlisten: (() => void) | undefined
    void listen<string>('macos-menu-action', (event) => {
      switch (event.payload) {
        case 'sources.manage':
          setSourceManagerOpen(true)
          break
        case 'library.refresh':
          void handleRefreshLibraries()
          break
        case 'playback.toggle':
          if (usePlayerStore.getState().library.length) usePlayerStore.getState().togglePlayback()
          break
        case 'playback.previous':
          usePlayerStore.getState().previous()
          break
        case 'playback.next':
          usePlayerStore.getState().next()
          break
        case 'playback.shuffle':
          usePlayerStore.getState().shuffle()
          break
        case 'lyrics.toggle':
          if (usePlayerStore.getState().library.length) {
            window.dispatchEvent(new Event('tingyu:toggle-lyrics'))
          }
          break
        case 'view.library':
          setActiveSourceId(null)
          setActiveView('library')
          break
        case 'view.favorites':
          setActiveSourceId(null)
          setActiveView('favorites')
          break
        case 'view.search':
          searchInputRef.current?.focus()
          break
      }
    }).then((dispose) => { unlisten = dispose })
    return () => { unlisten?.() }
  }, [handleRefreshLibraries])

  const emptyTitle = selectedSource
    ? `${selectedSource.name} 中没有歌曲`
    : activeView === 'favorites'
      ? '还没有喜欢的歌曲'
      : query.trim() ? '没有找到这段声音' : '曲库里还没有歌曲'
  const emptyDescription = activeView === 'favorites'
    ? '点击歌曲旁的爱心，它就会出现在这里'
    : query.trim()
      ? '试试搜索歌手、专辑或歌曲名'
      : '添加本地文件夹或 WebDAV 后，音乐会自动出现在这里'

  const sidebarProps = {
    activeView,
    activeSourceId,
    onViewChange: handleViewChange,
    onManageSources: () => setSourceManagerOpen(true),
    onSourceSelect: handleSourceSelect,
    sources,
  }

  return (
    <div className={currentTrack ? 'app-shell' : 'app-shell app-shell--empty'}>
      <div className={sidebarOpen ? 'mobile-sidebar is-open' : 'mobile-sidebar'}>
        <button className="mobile-sidebar__close" type="button" aria-label="关闭菜单" onClick={() => setSidebarOpen(false)}>
          <X size={19} />
        </button>
        <Sidebar {...sidebarProps} />
      </div>
      {sidebarOpen && <button className="scrim" aria-label="关闭菜单" onClick={() => setSidebarOpen(false)} />}

      <div className="desktop-sidebar">
        <Sidebar {...sidebarProps} />
      </div>

      <main className="main-content">
        <header className="topbar">
          <button className="mobile-menu" type="button" aria-label="打开菜单" onClick={() => setSidebarOpen(true)}>
            <Menu size={19} />
          </button>
          <div className="breadcrumb">
            <span>私人曲库</span>
            <ChevronRight size={13} />
            <strong>{selectedSource?.name || (activeView === 'library' ? '曲库' : '我喜欢的')}</strong>
          </div>
          <label className="search-box">
            <Search size={16} />
            <input
              ref={searchInputRef}
              type="search"
              value={query}
              onChange={(event) => setQuery(event.target.value)}
              placeholder="搜索歌曲、歌手或专辑"
              aria-label="搜索曲库"
            />
            <kbd>⌘ K</kbd>
          </label>
          <div className="sync-status" role="status">
            <span />
            {syncMessage}
          </div>
        </header>

        <div className="content-grid">
          <section className="page-content">
            <div className="intro-row">
              <div>
                <span className="eyebrow">{copy.eyebrow}</span>
                <h1>{copy.title}</h1>
                <p>{copy.description}</p>
              </div>
            </div>

            {sources.length ? (
              <>
                {spotlightTrack && (
                  <section className="spotlight" aria-label="当前歌曲">
                    <div className="spotlight__art-wrap">
                      <span className="spotlight__disc" />
                      <AlbumArtwork track={spotlightTrack} size="large" />
                    </div>
                    <div className="spotlight__copy">
                      <span className="spotlight__label">CURRENT TRACK · 当前歌曲</span>
                      <div>
                        <h2>{spotlightTrack.title}</h2>
                        <p>{spotlightTrack.artist} · {spotlightTrack.album}</p>
                      </div>
                      <div className="spotlight__meta">
                        <span>{spotlightTrack.format}</span>
                        <span><Cloud size={12} /> {sourceLabel[spotlightTrack.source].toLocaleUpperCase()}</span>
                      </div>
                      <div className="spotlight__actions">
                        <button
                          className="primary-button"
                          type="button"
                          onClick={() => spotlightTrack.id === currentTrackId ? togglePlayback() : playTrack(spotlightTrack.id)}
                        >
                          {spotlightTrack.id === currentTrackId && isPlaying
                            ? <Pause size={17} fill="currentColor" />
                            : <Play size={17} fill="currentColor" />}
                          {spotlightTrack.id === currentTrackId && isPlaying ? '暂停' : '播放'}
                        </button>
                        <button
                          className="secondary-button"
                          type="button"
                          onClick={() => {
                            if (!activeSourceId) {
                              shuffle()
                              return
                            }
                            const candidates = visibleTracks.filter((track) => track.id !== currentTrackId)
                            const nextTrack = candidates[Math.floor(Math.random() * candidates.length)]
                            if (nextTrack) playTrack(nextTrack.id)
                          }}
                        >
                          随机来一首
                        </button>
                      </div>
                    </div>
                    <span className="spotlight__number">01</span>
                  </section>
                )}

                <section className="library-section">
                  <div className="section-heading">
                    <div>
                      <span className="eyebrow">TRACKS</span>
                      <h2>{activeView === 'favorites' ? '喜欢的歌' : '全部歌曲'}</h2>
                    </div>
                  </div>
                  <TrackTable
                    tracks={visibleTracks}
                    emptyTitle={emptyTitle}
                    emptyDescription={emptyDescription}
                  />
                </section>
              </>
            ) : (
              <section className="empty-library">
                <span className="empty-library__icon"><Cloud size={28} /></span>
                <span className="eyebrow">YOUR PRIVATE LIBRARY</span>
                <h2>加入你的音乐曲库</h2>
                <p>选择设备上的音乐文件夹，或连接 WebDAV 私人曲库。</p>
                <div className="empty-library__actions">
                  <button className="primary-button" type="button" onClick={() => setSourceManagerOpen(true)}>
                    添加音乐源
                  </button>
                </div>
              </section>
            )}
          </section>

          {currentTrack && <QueuePanel />}
        </div>
      </main>

      {currentTrack && <PlayerBar />}
      {sourceManagerOpen && (
        <SourceManager
          sources={sources}
          supportsLocalFolders
          onClose={() => setSourceManagerOpen(false)}
          onAddWebDav={() => {
            setSourceManagerOpen(false)
            setWebdavSetupOpen(true)
          }}
          onAddLocal={handleAddLocal}
          onRemove={handleRemoveSource}
        />
      )}
      {webdavSetupOpen && (
        <WebDavSetup
          onClose={() => setWebdavSetupOpen(false)}
          onConnected={handleWebDavConnected}
        />
      )}
    </div>
  )
}

export default App
