import type { RefObject } from 'react'
import { ChevronRight, Menu, Search } from 'lucide-react'

interface TopToolbarProps {
  currentLocation: string
  query: string
  searchInputRef: RefObject<HTMLInputElement | null>
  syncMessage: string
  onOpenSidebar: () => void
  onQueryChange: (query: string) => void
}

export function TopToolbar({
  currentLocation,
  query,
  searchInputRef,
  syncMessage,
  onOpenSidebar,
  onQueryChange,
}: TopToolbarProps) {
  const syncNeedsAttention = /失败|断开|需要连接/.test(syncMessage)

  return (
    <header className="topbar">
      <button className="mobile-menu" type="button" aria-label="打开菜单" onClick={onOpenSidebar}>
        <Menu size={19} />
      </button>

      <div className="breadcrumb" aria-label="当前位置">
        <span>私人曲库</span>
        <ChevronRight size={13} />
        <strong>{currentLocation}</strong>
      </div>

      <label className="search-box">
        <Search size={16} aria-hidden="true" />
        <input
          ref={searchInputRef}
          type="search"
          value={query}
          onChange={(event) => onQueryChange(event.target.value)}
          placeholder="搜索歌曲、歌手或专辑"
          aria-label="搜索曲库"
        />
        <kbd>⌘K</kbd>
      </label>

      <div className={`sync-status ${syncNeedsAttention ? 'needs-attention' : ''}`} role="status" title={syncMessage}>
        <span aria-hidden="true" />
        <strong>{syncMessage}</strong>
      </div>
    </header>
  )
}
