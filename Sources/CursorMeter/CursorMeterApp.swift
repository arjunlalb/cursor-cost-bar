import AppKit

// MARK: - App Entry Point

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {

    // MARK: - Properties

    private var viewModel = UsageViewModel()
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var settingsWindow: NSWindow?
    private var loginWindow: LoginWindow?
    private var eventMonitor: Any?
    private var popoverDismissMonitor: Any?
    private var jumpCoordinator: JumpEffectCoordinator?
    private let notificationManager = NotificationManager()

    // MARK: - NSApplicationDelegate Entry Point

    nonisolated static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    // MARK: - Application Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        setupStatusItem()
        setupPopover()
        setupKeyboardShortcut()
        setupJumpCoordinator()

        viewModel.checkExistingSession()
        observeStatusItem()
        observePopover()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        removePopoverDismissMonitor()
        jumpCoordinator?.stop()
        jumpCoordinator = nil
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusItem()

        if let button = statusItem.button {
            button.action = #selector(statusItemClicked)
            button.target = self
            // Enable right-click to also toggle popover
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    private func updateStatusItem() {
        // Skip while the jump coordinator is showing an emoji glyph — otherwise
        // a subsequent viewModel mutation (weekly fetch, isLoading flip, etc.)
        // would clobber the emoji before its restore timer fires.
        if jumpCoordinator?.isSwapping == true { return }
        statusItem?.button?.image = currentRingImage()
    }

    /// Builds the ring/idle image that should currently occupy the menu bar slot,
    /// based on the latest `UsageDisplayData` and the user's display-mode setting.
    /// Pure read of view-model state — no side effects. Reused by the
    /// `JumpEffectCoordinator` to restore the slot after an emoji swap.
    private func currentRingImage() -> NSImage {
        guard let data = viewModel.usageData else {
            return CircularProgressIcon.idleImage()
        }
        let mode = data.isPercentOnly ? 2 : viewModel.menuBarDisplayMode
        switch mode {
        case 2:
            return CircularProgressIcon.menuBarImageWithPercent(percent: data.percentUsed)
        case 1:
            return CircularProgressIcon.menuBarImageWithText(
                percent: data.percentUsed,
                usedText: data.menuBarUsedText,
                limitText: data.menuBarLimitText
            )
        default:
            return CircularProgressIcon.menuBarImage(percent: data.percentUsed)
        }
    }

    @objc private func statusItemClicked() {
        if popover.isShown {
            hidePopover()
        } else {
            showPopover()
        }
    }

    // MARK: - Popover

    private func setupPopover() {
        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let popoverVC = MenuBarPopoverViewController(
            viewModel: viewModel,
            onLogin: { [weak self] in self?.showLogin() },
            onSettings: { [weak self] in self?.hidePopover(); self?.openSettings() }
        )
        popoverVC.onContentSizeChange = { [weak self] size in
            guard let self else { return }
            // Clamp to non-zero; fittingSize can briefly report zero pre-layout.
            guard size.width > 0, size.height > 0 else { return }
            self.popover.contentSize = size
        }
        popover.contentViewController = popoverVC
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        installPopoverDismissMonitor()
    }

    private func hidePopover() {
        popover.performClose(nil)
    }

    // .transient on its own doesn't dismiss when the user clicks a system menu
    // extra (Battery, Wi-Fi, etc.) because those clicks land on SystemUIServer's
    // status items rather than a regular window. A global mouse monitor closes
    // the popover for any out-of-app click while it's open.
    private func installPopoverDismissMonitor() {
        guard popoverDismissMonitor == nil else { return }
        popoverDismissMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            self?.hidePopover()
        }
    }

    private func removePopoverDismissMonitor() {
        if let monitor = popoverDismissMonitor {
            NSEvent.removeMonitor(monitor)
            popoverDismissMonitor = nil
        }
    }

    // MARK: - Settings Window

    func openSettings() {
        if let window = settingsWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsVC = SettingsViewController(viewModel: viewModel)
        let window = NSWindow(contentViewController: settingsVC)
        window.title = "Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        settingsWindow = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Login Window

    func showLogin() {
        let window = LoginWindow()
        loginWindow = window
        window.open { [weak self] cookieHeader in
            guard let self else { return }
            if let cookieHeader {
                viewModel.onLoginSuccess(cookieHeader: cookieHeader)
            }
            loginWindow = nil
        }
    }

    // MARK: - Keyboard Shortcut (Cmd+,)

    private func setupKeyboardShortcut() {
        // Local monitor fires when the app is active (e.g., popover is open).
        // .accessory policy apps do not show a menu bar, so we use an event monitor
        // rather than an NSMenuItem to handle Cmd+,.
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // Cmd+, (comma key, key code 43)
            if event.modifierFlags.contains(.command), event.keyCode == 43 {
                hidePopover()
                openSettings()
                return nil // Consume the event
            }
            return event
        }
    }

    // MARK: - Jump Effect Coordinator

    private func setupJumpCoordinator() {
        let coordinator = JumpEffectCoordinator(
            statusItem: statusItem,
            viewModel: viewModel,
            notifier: notificationManager,
            restoreImage: { [weak self] in
                self?.currentRingImage() ?? CircularProgressIcon.idleImage()
            }
        )
        jumpCoordinator = coordinator
        coordinator.start()
    }

    // MARK: - ViewModel Observation

    // Two separate tracking blocks so a weekly-chart-only mutation doesn't
    // force the menu-bar ring to re-rasterize, and a refresh-interval change
    // doesn't redraw the popover for no reason. Each block re-arms itself
    // after onChange because `withObservationTracking` is one-shot.
    private func observeStatusItem() {
        withObservationTracking {
            _ = viewModel.usageData
            _ = viewModel.menuBarDisplayMode
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.updateStatusItem()
                self.observeStatusItem()
            }
        }
    }

    // MARK: - NSPopoverDelegate

    func popoverDidClose(_ notification: Notification) {
        // Covers both explicit hidePopover() and .transient auto-dismiss paths.
        removePopoverDismissMonitor()
    }

    private func observePopover() {
        withObservationTracking {
            _ = viewModel.usageData
            _ = viewModel.isLoading
            _ = viewModel.errorMessage
            _ = viewModel.authState
            _ = viewModel.availableUpdate
            _ = viewModel.refreshInterval
            _ = viewModel.weeklyData
            _ = viewModel.isEnterpriseTeam
            _ = viewModel.weeklyChartEnabled
            _ = viewModel.weeklyChartStyle
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                (self.popover.contentViewController as? MenuBarPopoverViewController)?.updateUI()
                self.observePopover()
            }
        }
    }
}

