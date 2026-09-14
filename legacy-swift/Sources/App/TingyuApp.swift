import SwiftUI
import SwiftData

extension Notification.Name {
    static let tingyuFocusSearch = Notification.Name("tingyu.focusSearch")
    static let tingyuSearchQuery = Notification.Name("tingyu.searchQuery")
}

extension Color {
    public static let appleMusicRed = Color(red: 0.98, green: 0.14, blue: 0.24)
}

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
                .tint(Color.appleMusicRed)
                .frame(minWidth: 900, minHeight: 600)
                .onAppear {
                    AudioPlayerService.shared.configure(container: container)
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
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

            CommandGroup(after: .toolbar) {
                Button("搜索") {
                    NotificationCenter.default.post(name: .tingyuFocusSearch, object: nil)
                }
                .keyboardShortcut("k", modifiers: .command)
            }
        }

        #elseif os(iOS)
        WindowGroup {
            IOSContentView()
                .modelContainer(container)
        }
        #endif
    }
}
