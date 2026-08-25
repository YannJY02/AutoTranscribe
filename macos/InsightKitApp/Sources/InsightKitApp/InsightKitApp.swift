import AppKit
import SwiftUI

@main
final class AppLifecycleDelegate: NSObject, NSApplicationDelegate {
    private let coordinator = WorkflowCoordinator()
    private var mainWindow: NSWindow?
    private var settingsWindow: NSWindow?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppLifecycleDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) {
            app.run()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        showMainWindow()
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showMainWindow()
        }
        sender.activate(ignoringOtherApps: true)
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        showMainWindow()
        for url in urls {
            coordinator.handleIncomingURL(url)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.shutdown()
        SettingsView.shutdownSharedSidecar()
        SidecarManager.bestEffortShutdownSocketOwner(timeoutSec: 1)
    }

    private func showMainWindow() {
        if let mainWindow {
            mainWindow.makeKeyAndOrderFront(nil)
            return
        }

        installMainMenu()

        let rootView = ContentView(coordinator: coordinator)
            .font(.system(size: 16, weight: .regular, design: .default))
        let hostingView = NSHostingView(rootView: rootView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1360, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "InsightKit"
        window.contentView = hostingView
        window.setFrameAutosaveName("InsightKitMainWindow")
        window.center()
        window.makeKeyAndOrderFront(nil)
        mainWindow = window
    }

    private func installMainMenu() {
        guard NSApp.mainMenu == nil else { return }

        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "InsightKit")
        appMenu.addItem(
            withTitle: "关于 InsightKit",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(
            withTitle: "设置...",
            action: #selector(showSettingsWindow(_:)),
            keyEquivalent: ","
        ).target = self
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(
            withTitle: "退出 InsightKit",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "文件")
        fileMenu.addItem(withTitle: "新建会话", action: #selector(newSession(_:)), keyEquivalent: "n").target = self
        fileMenu.addItem(withTitle: "打开实时语音总结", action: #selector(openLive(_:)), keyEquivalent: "1").target = self
        fileMenu.addItem(withTitle: "打开转写总结", action: #selector(openTranscription(_:)), keyEquivalent: "2").target = self
        fileMenu.addItem(withTitle: "打开记录", action: #selector(openRecords(_:)), keyEquivalent: "3").target = self
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        NSApp.mainMenu = mainMenu
    }

    @objc private func showSettingsWindow(_ sender: Any?) {
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "InsightKit 设置"
        window.contentView = NSHostingView(rootView: SettingsView())
        window.center()
        window.makeKeyAndOrderFront(nil)
        settingsWindow = window
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func newSession(_ sender: Any?) {
        coordinator.resetLiveSession()
        coordinator.openHome()
        showMainWindow()
    }

    @objc private func openLive(_ sender: Any?) {
        coordinator.openLive()
        showMainWindow()
    }

    @objc private func openTranscription(_ sender: Any?) {
        coordinator.openTranscription()
        showMainWindow()
    }

    @objc private func openRecords(_ sender: Any?) {
        coordinator.openRecords()
        showMainWindow()
    }
}
