import AppKit
import SwiftUI

@main
struct InsightKitApp: App {
    @StateObject private var coordinator = WorkflowCoordinator()

    var body: some Scene {
        WindowGroup("InsightKit") {
            ContentView(coordinator: coordinator)
                .font(.system(size: 16, weight: .regular, design: .default))
        }
        .defaultSize(width: 1360, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建会话") {
                    coordinator.resetLiveSession()
                    coordinator.openHome()
                }
                .keyboardShortcut("n", modifiers: [.command])
            }

            CommandGroup(after: .newItem) {
                Button("打开实时语音总结") {
                    coordinator.openLive()
                }
                .keyboardShortcut("1", modifiers: [.command, .shift])
                .disabled(coordinator.route == .live)

                Button("打开转写总结") {
                    coordinator.openTranscription()
                }
                .keyboardShortcut("2", modifiers: [.command, .shift])
                .disabled(coordinator.route == .transcription)
            }

            CommandGroup(after: .sidebar) {
                Button(coordinator.route == .home ? "返回首页" : "显示首页") {
                    coordinator.openHome()
                }
                .keyboardShortcut("h", modifiers: [.command, .option])

                Button("显示/隐藏边栏") {
                    NSApp.keyWindow?.firstResponder?.tryToPerform(#selector(NSSplitViewController.toggleSidebar(_:)), with: nil)
                }
                .keyboardShortcut("s", modifiers: [.command, .control])

                Divider()

                Button(coordinator.liveViewModel.readingMode ? "关闭阅读模式" : "开启阅读模式") {
                    switch coordinator.route {
                    case .live:
                        coordinator.liveViewModel.readingMode.toggle()
                    case .transcription:
                        coordinator.transcriptionViewModel.readingMode.toggle()
                    case .home, .importMedia, .records:
                        break
                    }
                }
                .keyboardShortcut("1", modifiers: [.command, .option])
                .disabled(coordinator.route == .home)

                Button(coordinator.liveViewModel.focusMode ? "关闭聚焦模式" : "开启聚焦模式") {
                    switch coordinator.route {
                    case .live:
                        coordinator.liveViewModel.focusMode.toggle()
                    case .transcription:
                        coordinator.transcriptionViewModel.focusMode.toggle()
                    case .home, .importMedia, .records:
                        break
                    }
                }
                .keyboardShortcut("2", modifiers: [.command, .option])
                .disabled(coordinator.route == .home)

                Button("显示/隐藏执行面板") {
                    switch coordinator.route {
                    case .live:
                        coordinator.liveViewModel.isExecutionPanelVisible.toggle()
                    case .transcription:
                        coordinator.transcriptionViewModel.isExecutionPanelVisible.toggle()
                    case .home, .importMedia, .records:
                        break
                    }
                }
                .keyboardShortcut("3", modifiers: [.command, .option])
                .disabled(coordinator.route == .home)
            }

            CommandMenu("会话") {
                Button("开始直播洞察") {
                    coordinator.startLiveSession()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!coordinator.canStartLive)

                Button("停止直播") {
                    coordinator.stopLiveSession()
                }
                .keyboardShortcut(".", modifiers: [.command])
                .disabled(!coordinator.canStopLive)

                Divider()

                Button("刷新 Sidecar 状态") {
                    coordinator.liveViewModel.refreshSidecarStatus()
                    coordinator.transcriptionViewModel.refreshStatus()
                }
                .keyboardShortcut("r", modifiers: [.command, .option])
            }

            CommandMenu("洞察") {
                Button("生成实时流定稿") {
                    coordinator.liveViewModel.buildFinalInsight()
                }
                .keyboardShortcut("b", modifiers: [.command, .shift])
                .disabled(!coordinator.canBuildLiveFinal)

                Button("生成转写流定稿") {
                    coordinator.transcriptionViewModel.buildFinalInsight()
                }
                .keyboardShortcut("b", modifiers: [.command, .option])
                .disabled(!coordinator.canBuildTranscriptionFinal)

                Divider()

                Button("导出实时流 Markdown") {
                    coordinator.liveViewModel.exportDocument(format: "markdown")
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!coordinator.canExportLive)

                Button("导出转写流 Markdown") {
                    coordinator.transcriptionViewModel.exportDocument(format: "markdown")
                }
                .keyboardShortcut("e", modifiers: [.command, .option])
                .disabled(!coordinator.canExportTranscription)
            }

            CommandMenu("转写") {
                Button("导入音视频文件") {
                    coordinator.openTranscription()
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])

                Button(coordinator.transcriptionViewModel.watcherState.isRunning ? "停止目录监听" : "启动目录监听") {
                    if coordinator.transcriptionViewModel.watcherState.isRunning {
                        coordinator.transcriptionViewModel.stopWatcher()
                    } else {
                        coordinator.transcriptionViewModel.startWatcher(dirs: [
                            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop").path,
                            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").path,
                        ])
                    }
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])
            }

            CommandGroup(after: .help) {
                Button("打开麦克风设置") {
                    coordinator.liveViewModel.openMicrophonePrivacySettings()
                }
                Button("打开屏幕录制设置") {
                    coordinator.liveViewModel.openScreenRecordingSettings()
                }
            }
        }

        Settings {
            SettingsView()
        }
    }
}
