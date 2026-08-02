#!/usr/bin/env node

import {
  copyFileSync,
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  rmSync,
  statSync,
} from 'node:fs'
import { spawnSync } from 'node:child_process'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const projectRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const checkOnly = process.argv.slice(2).includes('--check')

function run(command, args, options = {}) {
  const capture = options.capture ?? false
  const result = spawnSync(command, args, {
    cwd: projectRoot,
    encoding: 'utf8',
    env: { ...process.env, ...options.env },
    stdio: capture ? ['ignore', 'pipe', 'pipe'] : 'inherit',
  })

  if (result.error) throw result.error
  if (result.status !== 0 && !options.allowFailure) {
    const detail = capture ? (result.stderr || result.stdout).trim() : ''
    throw new Error(`${command} ${args.join(' ')} failed${detail ? `: ${detail}` : ''}`)
  }
  return result
}

function output(command, args) {
  return run(command, args, { capture: true }).stdout.trim()
}

function succeeds(command, args) {
  return run(command, args, { capture: true, allowFailure: true }).status === 0
}

function requireFile(path, description) {
  if (!existsSync(path) || statSync(path).size === 0) {
    throw new Error(`${description}不存在或为空：${path}`)
  }
}

function readVersions() {
  const packageJson = JSON.parse(readFileSync(join(projectRoot, 'package.json'), 'utf8'))
  const packageLock = JSON.parse(readFileSync(join(projectRoot, 'package-lock.json'), 'utf8'))
  const tauriConfig = JSON.parse(readFileSync(join(projectRoot, 'src-tauri/tauri.conf.json'), 'utf8'))
  const cargoToml = readFileSync(join(projectRoot, 'src-tauri/Cargo.toml'), 'utf8')
  const cargoLock = readFileSync(join(projectRoot, 'src-tauri/Cargo.lock'), 'utf8')
  const cargoVersion = cargoToml.match(/^version\s*=\s*"([^"]+)"/m)?.[1]
  const cargoLockVersion = cargoLock.match(
    /\[\[package\]\]\nname = "tingyu"\nversion = "([^"]+)"/,
  )?.[1]

  if (!cargoVersion || !cargoLockVersion) throw new Error('无法读取 Rust 包版本')
  const versions = {
    package: packageJson.version,
    packageLock: packageLock.packages?.['']?.version,
    tauri: tauriConfig.version,
    cargo: cargoVersion,
    cargoLock: cargoLockVersion,
  }
  if (new Set(Object.values(versions)).size !== 1) {
    throw new Error(
      `版本不一致：${Object.entries(versions)
        .map(([name, version]) => `${name}=${version ?? '(missing)'}`)
        .join(', ')}`,
    )
  }

  return {
    productName: tauriConfig.productName,
    version: packageJson.version,
  }
}

function releaseState(tag) {
  const result = run('gh', ['release', 'view', tag, '--json', 'isDraft,isPrerelease,url'], {
    capture: true,
    allowFailure: true,
  })
  return result.status === 0 ? JSON.parse(result.stdout) : null
}

function readiness(tag) {
  run('git', ['fetch', '--quiet', 'origin', 'main', '--tags'])

  const branch = output('git', ['branch', '--show-current'])
  const head = output('git', ['rev-parse', 'HEAD'])
  const remoteHead = output('git', ['rev-parse', 'origin/main'])
  const dirty = output('git', ['status', '--porcelain'])
  const localTagExists = succeeds('git', ['rev-parse', '--verify', '--quiet', `refs/tags/${tag}`])
  const remoteTagExists =
    output('git', ['ls-remote', '--tags', 'origin', `refs/tags/${tag}`]).length > 0
  const release = releaseState(tag)
  const blockers = []

  if (branch !== 'main') blockers.push(`当前分支是 ${branch || '(detached)'}，必须为 main`)
  if (head !== remoteHead) blockers.push('本地 HEAD 与 origin/main 不一致，请先提交并推送')
  if (dirty) blockers.push('工作区存在未提交变更')
  if (localTagExists) blockers.push(`本地标签 ${tag} 已存在`)
  if (remoteTagExists) blockers.push(`远端标签 ${tag} 已存在`)
  if (release) blockers.push(`GitHub Release ${tag} 已存在：${release.url}`)

  return { blockers, branch, head, remoteHead, localTagExists, remoteTagExists, release }
}

function stageArtifacts(productName, version) {
  const architecture = process.arch === 'arm64' ? 'aarch64' : process.arch
  const bundleRoot = join(projectRoot, 'src-tauri/target/release/bundle')
  const macApp = join(bundleRoot, 'macos', `${productName}.app`)
  const dmgDirectory = join(bundleRoot, 'dmg')
  const dmgName = readdirSync(dmgDirectory).find(
    (name) => name.includes(`_${version}_`) && name.endsWith('.dmg'),
  )
  const unsignedApk = join(
    projectRoot,
    'src-tauri/gen/android/app/build/outputs/apk/universal/release/app-universal-release-unsigned.apk',
  )

  if (!dmgName) throw new Error(`未找到 ${version} 的 macOS DMG：${dmgDirectory}`)
  if (!existsSync(macApp)) throw new Error(`未找到 macOS App：${macApp}`)
  requireFile(unsignedApk, 'Android unsigned APK')

  const artifactDirectory = join(projectRoot, 'release-artifacts', `v${version}`)
  const appArchive = join(artifactDirectory, `Tingyu_${version}_${architecture}.app.tar.gz`)
  const dmg = join(artifactDirectory, `Tingyu_${version}_${architecture}.dmg`)
  const stagedUnsignedApk = join(
    artifactDirectory,
    `Tingyu_${version}_android_arm64_unsigned.apk`,
  )

  rmSync(artifactDirectory, { recursive: true, force: true })
  mkdirSync(artifactDirectory, { recursive: true })
  copyFileSync(join(dmgDirectory, dmgName), dmg)
  copyFileSync(unsignedApk, stagedUnsignedApk)
  run(
    'tar',
    ['-czf', appArchive, '-C', join(bundleRoot, 'macos'), `${productName}.app`],
    { env: { COPYFILE_DISABLE: '1' } },
  )

  requireFile(appArchive, 'macOS App 压缩包')
  requireFile(dmg, 'macOS DMG')
  requireFile(stagedUnsignedApk, '暂存 Android unsigned APK')
  return { appArchive, dmg, stagedUnsignedApk, artifactDirectory }
}

function findJava17Home() {
  const javaHomeResult = run('/usr/libexec/java_home', ['-v', '17'], {
    capture: true,
    allowFailure: true,
  })
  const candidates = [
    process.env.JAVA_HOME,
    javaHomeResult.status === 0 ? javaHomeResult.stdout.trim() : null,
    '/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home',
    '/usr/local/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home',
  ].filter(Boolean)

  for (const candidate of new Set(candidates)) {
    const java = join(candidate, 'bin/java')
    if (!existsSync(java)) continue
    const versionResult = run(java, ['-version'], { capture: true, allowFailure: true })
    const versionBanner = `${versionResult.stdout}\n${versionResult.stderr}`
    if (versionResult.status === 0 && /version "17(?:\.|")/.test(versionBanner)) {
      return candidate
    }
  }
  throw new Error('未找到 JDK 17；请安装 Homebrew openjdk@17')
}

function main() {
  if (process.platform !== 'darwin') throw new Error('本地发布必须在 macOS 上运行')
  if (process.arch !== 'arm64') throw new Error(`当前架构 ${process.arch} 不受支持，需要 arm64 Mac`)

  run('gh', ['auth', 'status'])
  const { productName, version } = readVersions()
  const javaHome = findJava17Home()
  const tag = `v${version}`
  const state = readiness(tag)

  console.log(`\nRelease 检查：${productName} ${tag}`)
  console.log(`- 分支：${state.branch}`)
  console.log(`- HEAD：${state.head.slice(0, 12)}`)
  console.log(`- origin/main：${state.remoteHead.slice(0, 12)}`)
  console.log(`- JDK 17：${javaHome}`)
  if (state.blockers.length) {
    state.blockers.forEach((blocker) => console.log(`- 阻止项：${blocker}`))
  } else {
    console.log('- 状态：可以开始本地构建')
  }

  if (checkOnly) return
  if (state.blockers.length) {
    throw new Error('发布前检查失败；修复以上阻止项后重试')
  }

  run('npm', ['ci'])
  run('npm', ['run', 'desktop:build', '--', '--bundles', 'app,dmg'], {
    env: { CI: 'false' },
  })
  run('npm', ['run', 'android:build', '--', '--ci'], {
    env: { CI: 'false', JAVA_HOME: javaHome },
  })

  const artifacts = stageArtifacts(productName, version)
  run('git', ['tag', '-a', tag, '-m', `${productName} ${tag}`])
  run('git', ['push', 'origin', tag])

  const releaseNotes = [
    '听屿跨平台音乐播放器。',
    '',
    '- macOS：`.app` / `.dmg`',
    '- Android：arm64 APK',
    '',
    'macOS 未签名版本首次打开时，请在 Finder 中右键应用并选择“打开”。',
  ].join('\n')

  run('gh', [
    'release',
    'create',
    tag,
    '--verify-tag',
    '--draft',
    '--title',
    `${productName} ${tag}`,
    '--notes',
    releaseNotes,
    artifacts.appArchive,
    artifacts.dmg,
    artifacts.stagedUnsignedApk,
  ])
  run('gh', ['workflow', 'run', 'release.yml', '--ref', 'main', '-f', `release_tag=${tag}`])

  console.log(`\n本地产物：${artifacts.artifactDirectory}`)
  console.log(`Draft Release：https://github.com/halunhaku/tingyu/releases/tag/${tag}`)
  console.log('Android 签名 Action 已触发；签名成功后 Release 会自动发布。')
}

try {
  main()
} catch (error) {
  console.error(`\n发布失败：${error instanceof Error ? error.message : String(error)}`)
  process.exitCode = 1
}
