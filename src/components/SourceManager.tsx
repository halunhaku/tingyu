import { useRef, useState } from 'react'
import { Cloud, FolderOpen, Plus, Trash2, X } from 'lucide-react'
import { useDialogFocus } from '../hooks/useDialogFocus'
import type { MusicSource } from '../types/music'

interface SourceManagerProps {
  sources: MusicSource[]
  supportsLocalFolders?: boolean
  onClose: () => void
  onAddWebDav: () => void
  onAddLocal: (name: string) => Promise<void>
  onRemove: (source: MusicSource) => Promise<void>
}

interface RemoveSourceDialogProps {
  source: MusicSource
  busy: boolean
  onCancel: () => void
  onConfirm: () => void
}

function RemoveSourceDialog({
  source,
  busy,
  onCancel,
  onConfirm,
}: RemoveSourceDialogProps) {
  const dialogRef = useRef<HTMLElement>(null)
  useDialogFocus(dialogRef, onCancel)

  return (
    <div className="dialog-layer" role="presentation" onMouseDown={(event) => event.target === event.currentTarget && !busy && onCancel()}>
      <section
        ref={dialogRef}
        className="confirm-dialog"
        role="alertdialog"
        aria-modal="true"
        aria-labelledby="remove-source-title"
        aria-describedby="remove-source-description"
        tabIndex={-1}
      >
        <span className="confirm-dialog__icon"><Trash2 size={19} /></span>
        <div>
          <span className="eyebrow">REMOVE MUSIC SOURCE</span>
          <h2 id="remove-source-title">删除“{source.name}”？</h2>
          <p id="remove-source-description">
            将移除此连接、凭据和本地缓存，不会删除原始音乐文件。
          </p>
        </div>
        <footer className="confirm-dialog__actions">
          <button type="button" disabled={busy} onClick={onCancel}>取消</button>
          <button className="is-destructive" type="button" disabled={busy} onClick={onConfirm}>
            {busy ? '正在删除…' : '删除音乐源'}
          </button>
        </footer>
      </section>
    </div>
  )
}

export function SourceManager({
  sources,
  supportsLocalFolders = true,
  onClose,
  onAddWebDav,
  onAddLocal,
  onRemove,
}: SourceManagerProps) {
  const dialogRef = useRef<HTMLElement>(null)
  useDialogFocus(dialogRef, onClose)
  const [localName, setLocalName] = useState('')
  const [busy, setBusy] = useState('')
  const [pendingRemoval, setPendingRemoval] = useState<MusicSource | null>(null)

  const remove = async (source: MusicSource) => {
    setBusy(source.id)
    try {
      await onRemove(source)
      setPendingRemoval(null)
    } finally {
      setBusy('')
    }
  }

  const addLocal = async () => {
    const name = localName.trim()
    if (!name) return
    setBusy('new-local')
    try {
      await onAddLocal(name)
      setLocalName('')
    } finally {
      setBusy('')
    }
  }

  return (
    <>
    <div className="dialog-layer" role="presentation" onMouseDown={(event) => event.target === event.currentTarget && onClose()}>
      <section
        ref={dialogRef}
        className="source-dialog"
        role="dialog"
        aria-modal="true"
        aria-labelledby="source-manager-title"
        tabIndex={-1}
      >
        <header className="source-dialog__header">
          <div>
            <span className="eyebrow">MUSIC SOURCES</span>
            <h2 id="source-manager-title">管理音乐源</h2>
          </div>
          <button type="button" aria-label="关闭" onClick={onClose}><X size={18} /></button>
        </header>

        {sources.length > 0 && (
          <div className="source-dialog__section">
            <span className="source-dialog__label">已添加 · {sources.length}</span>
            <div className="managed-sources">
              {sources.map((source) => {
                const Icon = source.kind === 'webdav' ? Cloud : FolderOpen
                return (
                  <div className="managed-source" key={source.id}>
                    <span className={`managed-source__icon is-${source.kind}`}><Icon size={17} /></span>
                    <span><strong>{source.name}</strong><small>{source.status}</small></span>
                    <button
                      disabled={Boolean(busy)}
                      type="button"
                      aria-label={`删除 ${source.name}`}
                      onClick={() => setPendingRemoval(source)}
                    >
                      <Trash2 size={15} />
                    </button>
                  </div>
                )
              })}
            </div>
          </div>
        )}

        <div className="source-dialog__section">
          <span className="source-dialog__label">添加音乐源</span>
          <div className="source-add-grid">
            <button className="source-add-card" type="button" onClick={onAddWebDav} disabled={Boolean(busy)}>
              <span className="managed-source__icon is-webdav"><Cloud size={18} /></span>
              <span><strong>WebDAV</strong><small>连接另一个私人云端曲库</small></span>
              <Plus size={16} />
            </button>
            {supportsLocalFolders && (
              <div className="source-add-local">
                <span className="managed-source__icon is-local"><FolderOpen size={18} /></span>
                <label>
                  <strong>本地文件夹</strong>
                  <input
                    type="text"
                    value={localName}
                    placeholder="给这个音乐源起个名字"
                    onChange={(event) => setLocalName(event.target.value)}
                  />
                </label>
                <button
                  type="button"
                  disabled={!localName.trim() || Boolean(busy)}
                  onClick={() => { void addLocal() }}
                >
                  选择文件夹
                </button>
              </div>
            )}
          </div>
        </div>

        <p className="source-dialog__complete">可以添加多个 WebDAV 和本地文件夹，它们会合并到完整曲库中。</p>
      </section>
    </div>
    {pendingRemoval && (
      <RemoveSourceDialog
        source={pendingRemoval}
        busy={busy === pendingRemoval.id}
        onCancel={() => {
          if (!busy) setPendingRemoval(null)
        }}
        onConfirm={() => { void remove(pendingRemoval) }}
      />
    )}
    </>
  )
}
