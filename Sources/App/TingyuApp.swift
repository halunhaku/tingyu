import SwiftUI
import SwiftData

@main
struct TingyuApp: App {
    let container: ModelContainer

    init() {
        self.container = CloudSyncManager.createModelContainer()
    }

    var body: some Scene {
        #if os(macOS)
        WindowGroup {
            MacOSContentView()
                .modelContainer(container)
                .frame(minWidth: 900, minHeight: 600)
                .onAppear {
                    AudioPlayerService.shared.configure(container: container)
                }
        }
        .windowStyle(.titleBar)
        .commands {
            CommandMenu("播放控制") {
                Button("播放 / 暂停") {
                    AudioPlayerService.shared.togglePlayPause()
                }
                .keyboardShortcut(.space, modifiers: [])

                Button("下一首") {
                    AudioPlayerService.shared.next()
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command])

                Button("上一首") {
                    AudioPlayerService.shared.previous()
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command])

                Divider()

                Button("切换随机播放") {
                    AudioPlayerService.shared.togglePlayOrder()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])

                Button("切换循环模式") {
                    AudioPlayerService.shared.cycleRepeatMode()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra("听屿", systemImage: "music.note") {
            MacOSMenuBarExtra()
                .modelContainer(container)
        }
        .menuBarExtraStyle(.window)

        #elseif os(iOS)
        WindowGroup {
            IOSContentView()
                .modelContainer(container)
        }
        #endif
    }
}
