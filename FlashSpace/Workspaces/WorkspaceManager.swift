//
//  WorkspaceManager.swift
//
//  Created by Wojciech Kulik on 19/01/2025.
//  Copyright © 2025 Wojciech Kulik. All rights reserved.
//

import AppKit
import Combine
import ShortcutRecorder

typealias DisplayName = String

struct ActiveWorkspace {
    let name: String
    let number: String?
    let symbolIconName: String?
    let display: DisplayName
}

final class WorkspaceManager: ObservableObject {
    @Published private(set) var activeWorkspaceDetails: ActiveWorkspace?

    private(set) var lastFocusedApp: [WorkspaceID: String] = [:]
    private(set) var activeWorkspace: [DisplayName: Workspace] = [:]
    private(set) var mostRecentWorkspace: [DisplayName: Workspace] = [:]
    private(set) var lastWorkspaceActivation = Date.distantPast

    private var cancellables = Set<AnyCancellable>()
    private var observeFocusCancellable: AnyCancellable?
    private let hideAgainSubject = PassthroughSubject<Workspace, Never>()

    private let workspaceRepository: WorkspaceRepository
    private let settingsRepository: SettingsRepository

    init(
        workspaceRepository: WorkspaceRepository,
        settingsRepository: SettingsRepository
    ) {
        self.workspaceRepository = workspaceRepository
        self.settingsRepository = settingsRepository

        PermissionsManager.shared.askForAccessibilityPermissions()
        observe()
    }

    private func observe() {
        hideAgainSubject
            .debounce(for: 0.2, scheduler: RunLoop.main)
            .sink { [weak self] in self?.hideApps(in: $0) }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: .profileChanged)
            .sink { [weak self] _ in
                self?.lastFocusedApp = [:]
                self?.activeWorkspace = [:]
                self?.mostRecentWorkspace = [:]
                self?.activeWorkspaceDetails = nil
            }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification)
            .print()
            .sink { [weak self] _ in
                self?.activeWorkspace = [:]
                self?.mostRecentWorkspace = [:]
                self?.activeWorkspaceDetails = nil
            }
            .store(in: &cancellables)

        observeFocus()
    }

    private func observeFocus() {
        observeFocusCancellable = NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didActivateApplicationNotification)
            .compactMap { $0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication }
            .sink { [weak self] application in
                guard let self else { return }

                if let activeWorkspace = activeWorkspace[application.display ?? ""],
                   activeWorkspace.apps.contains(application.localizedName ?? "") {
                    lastFocusedApp[activeWorkspace.id] = application.localizedName
                }
            }
    }

    private func showApps(in workspace: Workspace, setFocus: Bool) {
        let regularApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
        let floatingApps = (settingsRepository.floatingApps ?? [])
        let appsToShow = regularApps
            .filter {
                workspace.apps.contains($0.localizedName ?? "") ||
                    floatingApps.contains($0.localizedName ?? "") &&
                    $0.isOnTheSameScreen(as: workspace)
            }

        observeFocusCancellable = nil
        defer { observeFocus() }

        for app in appsToShow {
            print("SHOW: \(app.localizedName ?? "")")
            app.raise()
        }

        if setFocus {
            let toFocus = findAppToFocus(in: workspace, apps: appsToShow)
            print("FOCUS: \(toFocus?.localizedName ?? "")")
            toFocus?.activate()
            centerCursorIfNeeded(in: toFocus?.frame)
        }
    }

    private func hideApps(in workspace: Workspace) {
        let regularApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
        let workspaceApps = Set(workspace.apps + (settingsRepository.floatingApps ?? []))
        let isAnyWorkspaceAppRunning = regularApps
            .contains { workspaceApps.contains($0.localizedName ?? "") }

        let appsToHide = regularApps
            .filter { !workspaceApps.contains($0.localizedName ?? "") && !$0.isHidden }
            .filter { isAnyWorkspaceAppRunning || $0.bundleURL?.fileName != "Finder" }
            .filter { $0.isOnTheSameScreen(as: workspace) }

        for app in appsToHide {
            print("HIDE: \(app.localizedName ?? "")")
            app.hide()
        }
    }

    private func findAppToFocus(
        in workspace: Workspace,
        apps: [NSRunningApplication]
    ) -> NSRunningApplication? {
        var appToFocus: NSRunningApplication?

        if workspace.appToFocus == nil {
            appToFocus = apps.first { $0.localizedName == lastFocusedApp[workspace.id] }
        } else {
            appToFocus = apps.first { $0.localizedName == workspace.appToFocus }
        }

        let fallbackToLastApp = apps.first { $0.localizedName == workspace.apps.last }
        let fallbackToFinder = NSWorkspace.shared.runningApplications.first { $0.bundleURL?.fileName == "Finder" }

        return appToFocus ?? fallbackToLastApp ?? fallbackToFinder
    }

    private func centerCursorIfNeeded(in frame: CGRect?) {
        guard settingsRepository.centerCursorOnWorkspaceChange, let frame else { return }

        CGWarpMouseCursorPosition(CGPoint(x: frame.midX, y: frame.midY))
    }

    private func updateActiveWorkspace(_ workspace: Workspace) {
        lastWorkspaceActivation = Date()

        // Save the most recent workspace if it's not the current one
        let display = workspace.displayWithFallback
        if activeWorkspace[display]?.id != workspace.id {
            mostRecentWorkspace[display] = activeWorkspace[display]
        }

        activeWorkspace[display] = workspace

        activeWorkspaceDetails = .init(
            name: workspace.name,
            number: workspaceRepository.workspaces
                .firstIndex { $0.id == workspace.id }
                .map { "\($0 + 1)" },
            symbolIconName: workspace.symbolIconName,
            display: display
        )

        Integrations.runOnActivateIfNeeded(workspace: activeWorkspaceDetails!)
    }
}

// MARK: - Workspace Actions
extension WorkspaceManager {
    func activateWorkspace(_ workspace: Workspace, setFocus: Bool) {
        print("\n\nWORKSPACE: \(workspace.name)")
        print("----")

        updateActiveWorkspace(workspace)
        showApps(in: workspace, setFocus: setFocus)
        hideApps(in: workspace)

        // Some apps may not hide properly,
        // so we hide apps in the workspace after a short delay
        hideAgainSubject.send(workspace)
    }

    func assignApp(_ app: String, to workspace: Workspace) {
        workspaceRepository.deleteAppFromAllWorkspaces(app: app)
        workspaceRepository.addApp(to: workspace.id, app: app)

        guard let updatedWorkspace = workspaceRepository.workspaces
            .first(where: { $0.id == workspace.id }) else { return }

        activateWorkspace(updatedWorkspace, setFocus: false)
        NotificationCenter.default.post(name: .appsListChanged, object: nil)
    }
}

// MARK: - Shortcuts
extension WorkspaceManager {
    func getHotKeys() -> [(Shortcut, () -> ())] {
        let shortcuts = [
            getUnassignAppShortcut(),
            getRecentWorkspaceShortcut(),
            getCycleWorkspacesShortcut(next: false),
            getCycleWorkspacesShortcut(next: true),
            getFloatTheFocusedAppShortcut(),
            getUnfloatTheFocusedAppShortcut()
        ] +
            workspaceRepository.workspaces
            .flatMap { [getActivateShortcut(for: $0), getAssignAppShortcut(for: $0)] }

        return shortcuts.compactMap(\.self)
    }

    private func getActivateShortcut(for workspace: Workspace) -> (Shortcut, () -> ())? {
        guard let shortcut = workspace.activateShortcut?.toShortcut() else { return nil }

        let action = { [weak self] in
            guard let updatedWorkspace = self?.workspaceRepository.workspaces
                .first(where: { $0.id == workspace.id }) else { return }

            self?.activateWorkspace(updatedWorkspace, setFocus: true)
        }

        return (shortcut, action)
    }

    private func getAssignAppShortcut(for workspace: Workspace) -> (Shortcut, () -> ())? {
        guard let shortcut = workspace.assignAppShortcut?.toShortcut() else { return nil }

        let action = { [weak self] in
            guard let activeApp = NSWorkspace.shared.frontmostApplication else { return }
            guard let appName = activeApp.localizedName else { return }
            guard activeApp.bundleURL?.bundle?.isAgent != true else {
                showOkAlert(
                    title: appName,
                    message: "This application is an agent (runs in background) and cannot be managed by FlashSpace."
                )
                return
            }

            guard let updatedWorkspace = self?.workspaceRepository.workspaces
                .first(where: { $0.id == workspace.id }) else { return }

            activeApp.centerApp(display: updatedWorkspace.display)
            self?.assignApp(appName, to: updatedWorkspace)
            showFloatingToast(icon: "square.stack.3d.up", message: "App Assigned To \(workspace.name)")
        }

        return (shortcut, action)
    }

    private func getUnassignAppShortcut() -> (Shortcut, () -> ())? {
        guard let shortcut = settingsRepository.unassignFocusedApp?.toShortcut() else { return nil }

        let action = { [weak self] in
            guard let activeApp = NSWorkspace.shared.frontmostApplication else { return }
            guard let appName = activeApp.localizedName else { return }

            if self?.workspaceRepository.workspaces.flatMap(\.apps).contains(appName) == true {
                showFloatingToast(icon: "square.stack.3d.up.slash", message: "App Removed From Workspaces")
            }

            self?.workspaceRepository.deleteAppFromAllWorkspaces(app: appName)
            activeApp.hide()
            NotificationCenter.default.post(name: .appsListChanged, object: nil)
        }

        return (shortcut, action)
    }

    private func getCycleWorkspacesShortcut(next: Bool) -> (Shortcut, () -> ())? {
        guard let shortcut =
            next
                ? settingsRepository.switchToNextWorkspace?.toShortcut()
                : settingsRepository.switchToPreviousWorkspace?.toShortcut()
        else { return nil }

        let action = { [weak self] in
            guard let self, let screen = getCursorScreen() else { return }

            var screenWorkspaces = workspaceRepository.workspaces
                .filter { $0.displayWithFallback == screen }

            if !next {
                screenWorkspaces = screenWorkspaces.reversed()
            }

            guard let activeWorkspace = activeWorkspace[screen] ?? screenWorkspaces.first else { return }

            guard let workspace = screenWorkspaces
                .drop(while: { $0.id != activeWorkspace.id })
                .dropFirst()
                .first ?? screenWorkspaces.first
            else { return }

            activateWorkspace(workspace, setFocus: true)
        }

        return (shortcut, action)
    }

    private func getRecentWorkspaceShortcut() -> (Shortcut, () -> ())? {
        guard let shortcut = settingsRepository.switchToRecentWorkspace?.toShortcut() else { return nil }
        let action = { [weak self] in
            guard let self,
                  let screen = getCursorScreen(),
                  let mostRecentWorkspace = mostRecentWorkspace[screen]
            else { return }

            activateWorkspace(mostRecentWorkspace, setFocus: true)
        }

        return (shortcut, action)
    }

    private func getFloatTheFocusedAppShortcut() -> (Shortcut, () -> ())? {
        guard let shortcut = settingsRepository.floatTheFocusedApp?.toShortcut() else { return nil }
        let action = { [weak self] in
            guard let self,
                  let activeApp = NSWorkspace.shared.frontmostApplication,
                  let appName = activeApp.localizedName else { return }

            self.settingsRepository.addFloatingAppIfNeeded(app: appName)
            showFloatingToast(icon: "macwindow.on.rectangle", message: "Added Floating App")
        }
        return (shortcut, action)
    }

    private func getUnfloatTheFocusedAppShortcut() -> (Shortcut, () -> ())? {
        guard let shortcut = settingsRepository.unfloatTheFocusedApp?.toShortcut() else { return nil }
        let action = { [weak self] in
            guard let self,
                  let activeApp = NSWorkspace.shared.frontmostApplication,
                  let appName = activeApp.localizedName else { return }

            if settingsRepository.floatingApps?.contains(appName) == true {
                showFloatingToast(icon: "macwindow", message: "Removed Floating App")
            }

            settingsRepository.deleteFloatingApp(app: appName)

            guard let screen = activeApp.display else { return }

            if activeWorkspace[screen]?.apps.contains(appName) != true {
                activeApp.hide()
            }
        }
        return (shortcut, action)
    }

    private func getCursorScreen() -> DisplayName? {
        let cursorLocation = NSEvent.mouseLocation

        return NSScreen.screens
            .first { NSMouseInRect(cursorLocation, $0.frame, false) }?
            .localizedName
    }
}
