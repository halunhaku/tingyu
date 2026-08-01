import { Cloud, Disc3, FolderHeart, FolderOpen, Library, Plus, Settings } from 'lucide-react'
import type { MusicSource } from '../types/music'

type View = 'library' | 'favorites'

interface SidebarProps {
  activeView: View
  activeSourceId: string | null
  onViewChange: (view: View) => void
  onManageSources: () => void
  onSourceSelect: (sourceId: string) => void
  onOpenSettings: () => void
  sources: MusicSource[]
}

const navItems = [
  { id: 'library' as const, label: '曲库', icon: Library },
  { id: 'favorites' as const, label: '我喜欢的', icon: FolderHeart },
]

export function Sidebar({
  activeView,
  activeSourceId,
  onViewChange,
  onManageSources,
  onSourceSelect,
  onOpenSettings,
  sources,
}: SidebarProps) {
  return (
    <aside className="sidebar">
      <div className="brand" aria-label="听屿首页">
        <span className="brand__symbol">
          <Disc3 size={19} strokeWidth={1.7} />
        </span>
        <div>
          <strong>听屿</strong>
          <span>TINGYU</span>
        </div>
      </div>

      <nav className="primary-nav" aria-label="主导航">
        {navItems.map((item) => {
          const Icon = item.icon
          return (
            <button
              className={!activeSourceId && activeView === item.id ? 'nav-item is-active' : 'nav-item'}
              key={item.id}
              onClick={() => onViewChange(item.id)}
              type="button"
            >
              <Icon size={17} />
              <span>{item.label}</span>
            </button>
          )
        })}
      </nav>

      <div className="sidebar-section">
        <div className="sidebar-section__title">
          <span>音乐源</span>
          <button type="button" aria-label="管理音乐源" title="管理音乐源" onClick={onManageSources}>
            <Plus size={15} />
          </button>
        </div>
        {sources.length > 0 && (
          <div className="source-list">
            {sources.map((source) => {
              const Icon = source.kind === 'webdav' ? Cloud : FolderOpen
              const needsAttention = /失败|断开|需要连接|本地缓存/.test(source.status)
              return (
                <button
                  className={activeSourceId === source.id ? 'source-item is-active' : 'source-item'}
                  key={source.id}
                  type="button"
                  onClick={() => onSourceSelect(source.id)}
                >
                  <span
                    className="source-item__icon"
                    style={{ '--source-color': source.kind === 'webdav' ? '#d66b43' : '#729177' } as React.CSSProperties}
                  >
                    <Icon size={15} />
                  </span>
                  <span className="source-item__copy">
                    <strong>{source.name}</strong>
                    <small>{source.status}</small>
                  </span>
                  <span
                    className={`source-item__status ${needsAttention ? 'needs-attention' : ''}`}
                    title={needsAttention ? '连接需要检查' : '连接正常'}
                  />
                </button>
              )
            })}
          </div>
        )}
      </div>

      <div className="sidebar-footer">
        <span className="sidebar-footnote">LOCAL · WEBDAV · PRIVATE LIBRARY</span>
        <button className="settings-button" type="button" onClick={onOpenSettings}>
          <Settings size={16} />
          <span>设置</span>
        </button>
      </div>
    </aside>
  )
}
