import { useRef, useState, type FormEvent } from 'react'
import { Check, Cloud, Eye, EyeOff, LoaderCircle, LockKeyhole, X } from 'lucide-react'
import {
  connectAndScanWebDav,
  readableWebDavError,
  type ScanStats,
  type WebDavConfig,
} from '../providers/webdavProvider'
import { useDialogFocus } from '../hooks/useDialogFocus'
import type { Track } from '../types/music'

interface WebDavSetupProps {
  onClose: () => void
  onConnected: (sourceId: string, tracks: Track[], sourceName: string, serverName: string, folder: string, stats: ScanStats) => void
}

export function WebDavSetup({ onClose, onConnected }: WebDavSetupProps) {
  const dialogRef = useRef<HTMLElement>(null)
  const nameInputRef = useRef<HTMLInputElement>(null)
  useDialogFocus(dialogRef, onClose, nameInputRef)
  const isAndroid = /Android/i.test(navigator.userAgent)
  const [config, setConfig] = useState<WebDavConfig>({
    name: '',
    baseUrl: '',
    username: '',
    password: '',
    folder: '',
    remember: true,
  })
  const [showPassword, setShowPassword] = useState(false)
  const [isConnecting, setIsConnecting] = useState(false)
  const [error, setError] = useState('')

  const update = <Key extends keyof WebDavConfig>(key: Key, value: WebDavConfig[Key]) => {
    setConfig((current) => ({ ...current, [key]: value }))
  }

  const handleSubmit = async (event: FormEvent) => {
    event.preventDefault()
    setError('')
    setIsConnecting(true)
    try {
      const result = await connectAndScanWebDav(config)
      onConnected(
        result.connection.sourceId,
        result.tracks,
        result.connection.name,
        result.connection.serverName,
        result.connection.folder,
        result.stats,
      )
    } catch (connectionError) {
      setError(readableWebDavError(connectionError))
    } finally {
      setIsConnecting(false)
    }
  }

  return (
    <div className="dialog-layer" role="presentation" onMouseDown={(event) => event.target === event.currentTarget && onClose()}>
      <section
        ref={dialogRef}
        className="webdav-dialog"
        role="dialog"
        aria-modal="true"
        aria-labelledby="webdav-title"
        tabIndex={-1}
      >
        <header className="webdav-dialog__header">
          <span className="webdav-dialog__icon"><Cloud size={20} /></span>
          <div>
            <span className="eyebrow">ADD MUSIC SOURCE</span>
            <h2 id="webdav-title">连接 WebDAV</h2>
          </div>
          <button type="button" aria-label="关闭" onClick={onClose}><X size={18} /></button>
        </header>

        <form onSubmit={handleSubmit}>
          <label className="field">
            <span>音乐源名称</span>
            <input
              ref={nameInputRef}
              autoFocus
              type="text"
              required
              placeholder="例如：坚果云曲库"
              value={config.name}
              onChange={(event) => update('name', event.target.value)}
            />
          </label>
          <label className="field">
            <span>服务器地址</span>
            <input
              type="url"
              required
              placeholder="https://dav.example.com/music/"
              value={config.baseUrl}
              onChange={(event) => update('baseUrl', event.target.value)}
            />
            <small>填写 WebDAV 根目录，以 / 结尾</small>
          </label>
          <div className="field-row">
            <label className="field">
              <span>用户名</span>
              <input
                type="text"
                autoComplete="username"
                required
                placeholder="name@example.com"
                value={config.username}
                onChange={(event) => update('username', event.target.value)}
              />
            </label>
            <label className="field">
              <span>应用密码</span>
              <span className="password-field">
                <input
                  type={showPassword ? 'text' : 'password'}
                  autoComplete="current-password"
                  required
                  placeholder="••••••••"
                  value={config.password}
                  onChange={(event) => update('password', event.target.value)}
                />
                <button type="button" aria-label={showPassword ? '隐藏密码' : '显示密码'} onClick={() => setShowPassword((visible) => !visible)}>
                  {showPassword ? <EyeOff size={15} /> : <Eye size={15} />}
                </button>
              </span>
            </label>
          </div>
          <label className="field">
            <span>音乐子目录 <em>可选</em></span>
            <input
              type="text"
              placeholder="Music / Lossless"
              value={config.folder}
              onChange={(event) => update('folder', event.target.value)}
            />
          </label>

          <label className="remember-option">
            <input
              type="checkbox"
              checked={config.remember}
              onChange={(event) => update('remember', event.target.checked)}
            />
            <span>
              <strong>记住此连接</strong>
              <small>
                {isAndroid
                  ? '连接信息保存在 Android 应用私有目录'
                  : '密码安全保存在系统凭据库，地址和目录保存在本机'}
              </small>
            </span>
          </label>

          <div className="security-note">
            <LockKeyhole size={15} />
            <span>
              {isAndroid
                ? '连接信息仅保存在本应用沙盒中，不会发送到听屿服务器。建议使用 WebDAV 应用专用密码。'
                : '密码保存在操作系统凭据库，不会写入配置文件。建议使用 WebDAV 应用专用密码。'}
            </span>
          </div>

          {error && <div className="connection-error" role="alert">{error}</div>}

          <footer className="webdav-dialog__footer">
            <button className="dialog-cancel" type="button" onClick={onClose}>取消</button>
            <button className="dialog-submit" type="submit" disabled={isConnecting}>
              {isConnecting ? <LoaderCircle className="spinner" size={16} /> : <Check size={16} />}
              {isConnecting ? '正在扫描曲库…' : '连接并扫描'}
            </button>
          </footer>
        </form>
      </section>
    </div>
  )
}
