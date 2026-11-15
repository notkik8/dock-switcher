import AppKit
import CoreGraphics
import OSLog

private enum DockMode: Equatable {
    case externalDisplay
    case builtInDisplay

    static func forDisplays(builtIn: [Bool]) -> Self? {
        guard !builtIn.isEmpty else { return nil }
        return builtIn.allSatisfy { $0 } ? .builtInDisplay : .externalDisplay
    }

    static func current() -> Self? {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return nil }
        return forDisplays(builtIn: displays.prefix(Int(count)).map { CGDisplayIsBuiltin($0) != 0 })
    }

    var autohide: Bool { self == .builtInDisplay }
    var status: String {
        switch self {
        case .externalDisplay: return "Внешний экран · Dock виден"
        case .builtInDisplay: return "Встроенный экран · Dock скрывается"
        }
    }
}

private struct CommandFailure: LocalizedError {
    let path: String
    let status: Int32
    var errorDescription: String? { "\(path) завершилась с кодом \(status)" }
}

private final class DockSwitcher: NSObject, NSApplicationDelegate {
    private let logger = Logger(subsystem: "com.dockswitcher.local", category: "Dock")
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let stateItem = NSMenuItem(title: "Проверяю экраны…", action: nil, keyEquivalent: "")
    private var updateTimer: Timer?
    private var needsDockRestart = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        menu.addItem(stateItem)
        menu.addItem(.separator())
        let refresh = NSMenuItem(title: "Обновить сейчас", action: #selector(applyMode), keyEquivalent: "")
        refresh.target = self
        menu.addItem(refresh)
        let quit = NSMenuItem(title: "Выйти из Dock Switcher", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        statusItem.menu = menu

        if let button = statusItem.button {
            if let symbol = NSImage(systemSymbolName: "dock.rectangle", accessibilityDescription: "Dock Switcher") {
                button.image = symbol
            } else {
                button.title = "D"
            }
            button.toolTip = "Dock Switcher"
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(displaysChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(displaysChanged),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )
        displaysChanged()
    }

    @objc private func displaysChanged() {
        updateTimer?.invalidate()
        // Closing the lid can produce several notifications as the displays settle.
        updateTimer = Timer.scheduledTimer(timeInterval: 1, target: self, selector: #selector(applyMode), userInfo: nil, repeats: false)
    }

    @objc private func applyMode() {
        guard let mode = DockMode.current() else {
            stateItem.title = "Ожидаю активный экран…"
            return
        }

        do {
            CFPreferencesAppSynchronize("com.apple.dock" as CFString)
            let current = CFPreferencesCopyAppValue("autohide" as CFString, "com.apple.dock" as CFString) as? NSNumber
            if (current?.boolValue ?? false) != mode.autohide {
                try run("/usr/bin/defaults", ["write", "com.apple.dock", "autohide", "-bool", mode.autohide ? "true" : "false"])
                needsDockRestart = true
            }
            if needsDockRestart {
                try run("/usr/bin/killall", ["-u", NSUserName(), "Dock"])
                needsDockRestart = false
            }
            stateItem.title = mode.status
        } catch {
            stateItem.title = "Не удалось обновить Dock"
            logger.error("\(error.localizedDescription, privacy: .public)")
        }
    }

    private func run(_ path: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CommandFailure(path: path, status: process.terminationStatus)
        }
    }
}

if CommandLine.arguments.contains("--self-test") {
    precondition(DockMode.forDisplays(builtIn: []) == nil)
    precondition(DockMode.forDisplays(builtIn: [true])?.autohide == true)
    precondition(DockMode.forDisplays(builtIn: [false])?.autohide == false)
    precondition(DockMode.forDisplays(builtIn: [true, false])?.autohide == false)
    print("Display policy checks passed.")
} else if CommandLine.arguments.contains("--check-displays") {
    print(DockMode.current()?.status ?? "No active display available in this session.")
} else {
    let app = NSApplication.shared
    let delegate = DockSwitcher()
    app.delegate = delegate
    app.run()
}
