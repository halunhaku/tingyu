import { useState } from 'react'
import { Cloud, FolderOpen, Plus, Trash2, X } from 'lucide-react'

interface SourceSummary {
  name: string
  detail: string
}

interface SourceManagerProps {
  webdav?: SourceSummary
  local?: SourceSummary
  onClose: () => void
  onAddWebDav: () => void
  onAddLocal: (name: string) => Promise<void>
  onRemoveWebDav: () => Promise<void>
  onRemoveLocal: () => Promise<void>
}

export function SourceManager({
  webdav,
  local,
  onClose,
  onAddWebDav,
  onAddLocal,
  onRemoveWebDav,
  onRemoveLocal,
}: SourceManagerProps) {
  const [localName, setLocalName] = useState('')
  const [busy, setBusy] = useState<'local' | 'webdav' | ''>('')

  const remove = async (kind: 'local' | 'webdav') => {
    setBusy(kind)
    try {
      await (kind === 'local' ? onRemoveLocal() : onRemoveWebDav())
    } finally {
      setBusy('')
    }
  }

  return (
    <div className="dialog-layer" role="presentation" onMouseDown={(event) => event.target === event.currentTarget && onClose()}>
      <section className="source-dialog" role="dialog" aria-modal="true" aria-labelledby="source-manager-title">
        <header className="source-dialog__header">
          <div>
            <span className="eyebrow">MUSIC SOURCES</span>
            <h2 id="source-manager-title">管理音乐源</h2>
          </div>
          <button type="button" aria-label="关闭" onClick={onClose}><X size={18} /></button>
        </header>

        {(webdav || local) && (
          <div className="source-dialog__section">
            <span className="source-dialog__label">已添加</span>
            <div className="managed-sources">
              {webdav && (
                <div className="managed-source">
                  <span className="managed-source__icon is-webdav"><Cloud size={17} /></span>
                  <span><strong>{webdav.name}</strong><small>{webdav.detail}</small></span>
                  <button disabled={Boolean(busy)} type="button" aria-label={`删除 ${webdav.name}`} onClick={() => { void remove('webdav') }}>
                    <Trash2 size={15} />
                  </button>
                </div>
              )}
              {local && (
                <div className="managed-source">
                  <span className="managed-source__icon is-local"><FolderOpen size={17} /></span>
                  <span><strong>{local.name}</strong><small>{local.detail}</small></span>
                  <button disabled={Boolean(busy)} type="button" aria-label={`删除 ${local.name}`} onClick={() => { void remove('local') }}>
                    <Trash2 size={15} />
                  </button>
                </div>
              )}
            </div>
          </div>
        )}

        {(!webdav || !local) && (
          <div className="source-dialog__section">
            <span className="source-dialog__label">添加音乐源</span>
            <div className="source-add-grid">
              {!webdav && (
                <button className="source-add-card" type="button" onClick={onAddWebDav}>
                  <span className="managed-source__icon is-webdav"><Cloud size={18} /></span>
                  <span><strong>WebDAV</strong><small>连接私人云端曲库</small></span>
                  <Plus size={16} />
                </button>
              )}
              {!local && (
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
                    onClick={() => { setBusy('local'); void onAddLocal(localName.trim()).finally(() => setBusy('')) }}
                  >
                    选择文件夹
                  </button>
                </div>
              )}
            </div>
          </div>
        )}

        {webdav && local && <p className="source-dialog__complete">当前支持一个 WebDAV 和一个本地文件夹音乐源。</p>}
      </section>
    </div>
  )
}
