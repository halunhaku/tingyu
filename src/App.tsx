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
  restoreLocalFolder,
} from './providers/localProvider'
import {
  forgetWebDav,
  loadCachedWebDav,
  restoreAndScanWebDav,
  type ScanStats,
} from './providers/webdavProvider'
import { usePlayerStore } from './stores/playerStore'
import type { SourceKind } from './types/music'

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
  const [activeSource, setActiveSource] = useState<SourceKind | null>(null)
  const [webdavName, setWebdavName] = useState('')
  const [webdavStatus, setWebdavStatus] = useState('')
  const [localName, setLocalName] = useState('')
  const [localStatus, setLocalStatus] = useState('')
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

  const currentTrack = library.find((track) => track.id === currentTrackId) ?? library[0]
  const selectedSourceName = activeSource === 'webdav' ? webdavName : activeSource === 'local' ? localName : ''
  const copy = selectedSourceName
    ? {
        eyebrow: activeSource === 'webdav' ? 'WEBDAV SOURCE' : 'LOCAL SOURCE',
        title: selectedSourceName,
        description: activeSource === 'webdav' ? webdavStatus : localStatus,
      }
    : viewCopy[activeView]

  const visibleTracks = useMemo(() => {
    const normalized = query.trim().toLocaleLowerCase()
    let result = activeView === 'favorites'
      ? library.filter((track) => likedIds.includes(track.id))
      : library

    if (activeSource) {
      result = result.filter((track) => track.source === activeSource)
    }
    if (normalized) {
      result = result.filter((track) =>
        [track.title, track.artist, track.album].some((value) =>
          value.toLocaleLowerCase().includes(normalized),
        ),
      )
    }
    return result
  }, [activeSource, activeView, library, likedIds, query])

  const spotlightTrack = currentTrack && (!activeSource || currentTrack.source === activeSource)
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

    const restoreLocalLibrary = async () => {
      try {
        const restored = await restoreLocalFolder()
        if (!restored || cancelled) return
        replaceSourceTracks('local', restored.tracks)
        setLocalName(restored.sourceName)
        setLocalStatus(`${restored.tracks.length} 首 · ${restored.folderName}`)
      } catch (error) {
        if (!cancelled) setLocalStatus(readableLocalError(error))
      }
    }

    const restoreLibrary = async () => {
      void restoreLocalLibrary()
      const cachedLibrary = await loadCachedWebDav()
      if (cancelled) return
      if (cachedLibrary.name) {
        setWebdavName(cachedLibrary.name)
        setWebdavStatus(`${cachedLibrary.tracks.length} 首 · 本地缓存`)
        replaceSourceTracks('webdav', cachedLibrary.tracks)
        setSyncMessage('正在增量同步')
      }
      try {
        const restored = await restoreAndScanWebDav()
        if (!restored || cancelled) {
          setSyncMessage(cachedLibrary.tracks.length ? '使用本地缓存' : '本地曲库')
          return
        }
        replaceSourceTracks('webdav', restored.tracks)
        setWebdavName(restored.connection.name)
        setWebdavStatus(`${restored.tracks.length} 首 · ${restored.connection.serverName}`)
        setSyncMessage(formatSyncStats(restored.stats))
      } catch {
        if (!cancelled) setSyncMessage(cachedLibrary.tracks.length ? '使用本地缓存' : '需要连接')
      }
    }

    void restoreLibrary()
    return () => { cancelled = true }
  }, [replaceSourceTracks])

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
    setActiveSource(null)
    setSidebarOpen(false)
  }

  const handleSourceSelect = (source: SourceKind) => {
    setActiveSource(source)
    setActiveView('library')
    setSidebarOpen(false)
  }

  const handleWebDavConnected = (
    webdavTracks: typeof library,
    sourceName: string,
    serverName: string,
    stats: ScanStats,
  ) => {
    replaceSourceTracks('webdav', webdavTracks)
    setWebdavName(sourceName)
    setWebdavStatus(`${webdavTracks.length} 首 · ${serverName}`)
    setSyncMessage(formatSyncStats(stats))
    setWebdavSetupOpen(false)
    setSourceManagerOpen(false)
    setActiveSource('webdav')
    setActiveView('library')
  }

  const handleAddLocal = async (name: string) => {
    try {
      const result = await chooseAndScanLocalFolder(name)
      if (!result) return
      replaceSourceTracks('local', result.tracks)
      setLocalName(result.sourceName)
      setLocalStatus(`${result.tracks.length} 首 · ${result.folderName}`)
      setSyncMessage(`已导入 ${result.tracks.length} 首本地歌曲`)
      setSourceManagerOpen(false)
      setActiveSource('local')
      setActiveView('library')
    } catch (error) {
      setSyncMessage(readableLocalError(error))
    }
  }

  const handleRemoveWebDav = async () => {
    try {
      await forgetWebDav()
      removeSource('webdav')
      setWebdavName('')
      setWebdavStatus('')
      if (activeSource === 'webdav') setActiveSource(null)
    } catch (error) {
      setSyncMessage(typeof error === 'string' ? error : '无法删除 WebDAV 音乐源')
    }
  }

  const handleRemoveLocal = async () => {
    try {
      await forgetLocalFolder()
      removeSource('local')
      setLocalName('')
      setLocalStatus('')
      if (activeSource === 'local') setActiveSource(null)
    } catch (error) {
      setSyncMessage(readableLocalError(error))
    }
  }

  const handleRefreshLibraries = useCallback(async () => {
    if (refreshInProgressRef.current) return
    if (!webdavName && !localName) {
      setSyncMessage('请先添加音乐源')
      return
    }
    refreshInProgressRef.current = true
    setSyncMessage('正在刷新曲库')
    const tasks: Promise<void>[] = []
    if (localName) {
      tasks.push(restoreLocalFolder().then((result) => {
        if (!result) return
        replaceSourceTracks('local', result.tracks)
        setLocalStatus(`${result.tracks.length} 首 · ${result.folderName}`)
      }))
    }
    if (webdavName) {
      tasks.push(restoreAndScanWebDav().then((result) => {
        if (!result) return
        replaceSourceTracks('webdav', result.tracks)
        setWebdavStatus(`${result.tracks.length} 首 · ${result.connection.serverName}`)
      }))
    }
    const results = await Promise.allSettled(tasks)
    const failed = results.filter((result) => result.status === 'rejected').length
    setSyncMessage(failed ? `${failed} 个音乐源刷新失败` : '曲库已刷新')
    refreshInProgressRef.current = false
  }, [localName, replaceSourceTracks, webdavName])

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
          setActiveSource(null)
          setActiveView('library')
          break
        case 'view.favorites':
          setActiveSource(null)
          setActiveView('favorites')
          break
        case 'view.search':
          searchInputRef.current?.focus()
          break
      }
    }).then((dispose) => { unlisten = dispose })
    return () => { unlisten?.() }
  }, [handleRefreshLibraries])

  const emptyTitle = selectedSourceName
    ? `${selectedSourceName} 中没有歌曲`
    : activeView === 'favorites'
      ? '还没有喜欢的歌曲'
      : query.trim() ? '没有找到这段声音' : '曲库里还没有歌曲'
  const emptyDescription = activeView === 'favorites'
    ? '点击歌曲旁的爱心，它就会出现在这里'
    : query.trim() ? '试试搜索歌手、专辑或歌曲名' : '添加本地文件夹或 WebDAV 后，音乐会自动出现在这里'

  return (
    <div className={currentTrack ? 'app-shell' : 'app-shell app-shell--empty'}>
      <div className={sidebarOpen ? 'mobile-sidebar is-open' : 'mobile-sidebar'}>
        <button className="mobile-sidebar__close" type="button" aria-label="关闭菜单" onClick={() => setSidebarOpen(false)}>
          <X size={19} />
        </button>
        <Sidebar
          activeView={activeView}
          activeSource={activeSource}
          onViewChange={handleViewChange}
          onManageSources={() => setSourceManagerOpen(true)}
          onSourceSelect={handleSourceSelect}
          webdavSource={webdavName ? { name: webdavName, status: webdavStatus } : undefined}
          localSource={localName ? { name: localName, status: localStatus } : undefined}
        />
      </div>
      {sidebarOpen && <button className="scrim" aria-label="关闭菜单" onClick={() => setSidebarOpen(false)} />}

      <div className="desktop-sidebar">
        <Sidebar
          activeView={activeView}
          activeSource={activeSource}
          onViewChange={handleViewChange}
          onManageSources={() => setSourceManagerOpen(true)}
          onSourceSelect={handleSourceSelect}
          webdavSource={webdavName ? { name: webdavName, status: webdavStatus } : undefined}
          localSource={localName ? { name: localName, status: localStatus } : undefined}
        />
      </div>

      <main className="main-content">
        <header className="topbar">
          <button className="mobile-menu" type="button" aria-label="打开菜单" onClick={() => setSidebarOpen(true)}>
            <Menu size={19} />
          </button>
          <div className="breadcrumb">
            <span>私人曲库</span>
            <ChevronRight size={13} />
            <strong>{selectedSourceName || (activeView === 'library' ? '曲库' : '我喜欢的')}</strong>
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

            {(webdavName || localName) ? (
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
                      if (!activeSource) {
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
                <p>选择电脑上的音乐文件夹，或连接 WebDAV 私人曲库。</p>
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
          webdav={webdavName ? { name: webdavName, detail: webdavStatus } : undefined}
          local={localName ? { name: localName, detail: localStatus } : undefined}
          onClose={() => setSourceManagerOpen(false)}
          onAddWebDav={() => {
            setSourceManagerOpen(false)
            setWebdavSetupOpen(true)
          }}
          onAddLocal={handleAddLocal}
          onRemoveWebDav={handleRemoveWebDav}
          onRemoveLocal={handleRemoveLocal}
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
