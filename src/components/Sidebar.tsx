import { Cloud, Disc3, FolderHeart, FolderOpen, Library, Plus } from 'lucide-react'
import type { SourceKind } from '../types/music'

type View = 'library' | 'favorites'

interface SourceItem {
  name: string
  status: string
}

interface SidebarProps {
  activeView: View
  activeSource: SourceKind | null
  onViewChange: (view: View) => void
  onManageSources: () => void
  onSourceSelect: (source: SourceKind) => void
  webdavSource?: SourceItem
  localSource?: SourceItem
}

const navItems = [
  { id: 'library' as const, label: '曲库', icon: Library },
  { id: 'favorites' as const, label: '我喜欢的', icon: FolderHeart },
]

export function Sidebar({
  activeView,
  activeSource,
  onViewChange,
  onManageSources,
  onSourceSelect,
  webdavSource,
  localSource,
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
              className={!activeSource && activeView === item.id ? 'nav-item is-active' : 'nav-item'}
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
        {(webdavSource || localSource) && (
          <div className="source-list">
            {webdavSource && (
              <button
                className={activeSource === 'webdav' ? 'source-item is-active' : 'source-item'}
                type="button"
                onClick={() => onSourceSelect('webdav')}
              >
                <span className="source-item__icon" style={{ '--source-color': '#d66b43' } as React.CSSProperties}>
                  <Cloud size={15} />
                </span>
                <span className="source-item__copy">
                  <strong>{webdavSource.name}</strong>
                  <small>{webdavSource.status}</small>
                </span>
                <span className="source-item__status" />
              </button>
            )}
            {localSource && (
              <button
                className={activeSource === 'local' ? 'source-item is-active' : 'source-item'}
                type="button"
                onClick={() => onSourceSelect('local')}
              >
                <span className="source-item__icon" style={{ '--source-color': '#729177' } as React.CSSProperties}>
                  <FolderOpen size={15} />
                </span>
                <span className="source-item__copy">
                  <strong>{localSource.name}</strong>
                  <small>{localSource.status}</small>
                </span>
                <span className="source-item__status" />
              </button>
            )}
          </div>
        )}
      </div>

      <span className="sidebar-footnote">LOCAL + WEBDAV · PRIVATE LIBRARY</span>
    </aside>
  )
}
