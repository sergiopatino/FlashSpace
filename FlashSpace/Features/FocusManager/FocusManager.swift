//
//  FocusManager.swift
//
//  Created by Wojciech Kulik on 23/01/2025.
//  Copyright © 2025 Wojciech Kulik. All rights reserved.
//

import AppKit
import Foundation

final class FocusManager {
    var visibleApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isHidden }
    }

    var focusedApp: NSRunningApplication? { NSWorkspace.shared.frontmostApplication }
    var focusedAppFrame: CGRect? { focusedApp?.frame }

    private let workspaceRepository: WorkspaceRepository
    private let workspaceManager: WorkspaceManager
    private let settingsRepository: SettingsRepository

    init(
        workspaceRepository: WorkspaceRepository,
        workspaceManager: WorkspaceManager,
        settingsRepository: SettingsRepository
    ) {
        self.workspaceRepository = workspaceRepository
        self.workspaceManager = workspaceManager
        self.settingsRepository = settingsRepository
    }

    func getHotKeys() -> [(AppHotKey, () -> ())] {
        let settings = settingsRepository

        guard settings.enableFocusManagement else { return [] }

        return [
            settings.focusLeft.flatMap { ($0, focusLeft) },
            settings.focusRight.flatMap { ($0, focusRight) },
            settings.focusUp.flatMap { ($0, focusUp) },
            settings.focusDown.flatMap { ($0, focusDown) },
            settings.focusNextWorkspaceApp.flatMap { ($0, nextWorkspaceApp) },
            settings.focusPreviousWorkspaceApp.flatMap { ($0, previousWorkspaceApp) },
            settings.focusNextWorkspaceWindow.flatMap { ($0, nextWorkspaceWindow) },
            settings.focusPreviousWorkspaceWindow.flatMap { ($0, previousWorkspaceWindow) }
        ].compactMap { $0 }
    }

    func nextWorkspaceWindow() {
        guard let focusedApp else { return nextWorkspaceApp() }
        guard let (_, apps) = getFocusedAppIndex() else { return }

        let runningWorkspaceApps = getRunningAppsWithSortedWindows(apps: apps)
        let focusedAppWindows = runningWorkspaceApps
            .first { $0.bundleIdentifier == focusedApp.bundleIdentifier }?
            .windows ?? []
        let isLastWindowFocused = focusedAppWindows.last?.axWindow.isMain == true

        if isLastWindowFocused {
            let nextApps = runningWorkspaceApps.drop(while: { $0.bundleIdentifier != focusedApp.bundleIdentifier }).dropFirst() +
                runningWorkspaceApps.prefix(while: { $0.bundleIdentifier != focusedApp.bundleIdentifier })
            let nextApp = nextApps.first

            nextApp?.app.activate()
            nextApp?
                .windows
                .first?
                .axWindow
                .focus()
        } else {
            focusedAppWindows
                .drop(while: { !$0.axWindow.isMain })
                .dropFirst()
                .first?
                .axWindow
                .focus()
        }
    }

    func previousWorkspaceWindow() {
        guard let focusedApp else { return previousWorkspaceApp() }
        guard let (_, apps) = getFocusedAppIndex() else { return }

        let runningWorkspaceApps = getRunningAppsWithSortedWindows(apps: apps)
        let focusedAppWindows = runningWorkspaceApps
            .first { $0.bundleIdentifier == focusedApp.bundleIdentifier }?
            .windows ?? []
        let isFirstWindowFocused = focusedAppWindows.first?.axWindow.isMain == true

        if isFirstWindowFocused {
            let prevApps = runningWorkspaceApps.drop(while: { $0.bundleIdentifier != focusedApp.bundleIdentifier }).dropFirst() +
                runningWorkspaceApps.prefix(while: { $0.bundleIdentifier != focusedApp.bundleIdentifier })
            let prevApp = prevApps.last

            prevApp?.app.activate()
            prevApp?
                .windows
                .last?
                .axWindow
                .focus()
        } else {
            focusedAppWindows
                .prefix(while: { !$0.axWindow.isMain })
                .last?
                .axWindow
                .focus()
        }
    }

    func nextWorkspaceApp() {
        guard let (index, apps) = getFocusedAppIndex() else { return }

        let appsQueue = apps.dropFirst(index + 1) + apps.prefix(index)
        let runningApps = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let nextApp = appsQueue.first { app in runningApps.contains(app.bundleIdentifier) }

        NSWorkspace.shared.runningApplications
            .find(nextApp)?
            .activate()
    }

    func previousWorkspaceApp() {
        guard let (index, apps) = getFocusedAppIndex() else { return }

        let runningApps = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let prefixApps = apps.prefix(index).reversed()
        let suffixApps = apps.suffix(apps.count - index - 1).reversed()
        let appsQueue = prefixApps + Array(suffixApps)
        let previousApp = appsQueue.first { app in runningApps.contains(app.bundleIdentifier) }

        NSWorkspace.shared.runningApplications
            .find(previousApp)?
            .activate()
    }

    func focusRight() {
        focus { focusedAppFrame, other in
            other.maxX > focusedAppFrame.maxX &&
                other.verticalIntersect(with: focusedAppFrame)
        }
    }

    func focusLeft() {
        focus { focusedAppFrame, other in
            other.minX < focusedAppFrame.minX &&
                other.verticalIntersect(with: focusedAppFrame)
        }
    }

    func focusDown() {
        focus { focusedAppFrame, other in
            other.maxY > focusedAppFrame.maxY &&
                other.horizontalIntersect(with: focusedAppFrame)
        }
    }

    func focusUp() {
        focus { focusedAppFrame, other in
            other.minY < focusedAppFrame.minY &&
                other.horizontalIntersect(with: focusedAppFrame)
        }
    }

    /// Predicate compares two frames using window coordinates.
    /// (0,0) is top left corner. Y-axis is pointing down.
    private func focus(predicate: (CGRect, CGRect) -> Bool) {
        guard let focusedAppFrame else { return }

        let toFocus = visibleApps
            .flatMap { app in
                app.allWindows.map {
                    (app: app, window: $0.window, frame: $0.frame)
                }
            }
            .filter { predicate(focusedAppFrame, $0.frame) }
            .min { $0.frame.distance(to: focusedAppFrame) < $1.frame.distance(to: focusedAppFrame) }

        toFocus?.window.focus()
        toFocus?.app.activate()
        centerCursorIfNeeded(in: toFocus?.frame)
    }

    private func centerCursorIfNeeded(in frame: CGRect?) {
        guard settingsRepository.centerCursorOnFocusChange, let frame else { return }

        CGWarpMouseCursorPosition(CGPoint(x: frame.midX, y: frame.midY))
    }

    private func getFocusedAppIndex() -> (Int, [MacApp])? {
        guard let focusedApp else { return nil }

        let workspace = workspaceManager.activeWorkspace[NSScreen.main?.localizedName ?? ""]
            ?? workspaceRepository.workspaces.first { $0.apps.containsApp(focusedApp) }

        guard let apps = workspace?.apps else { return nil }

        let index = apps.firstIndex(of: focusedApp) ?? 0

        return (index, apps)
    }

    private func getRunningAppsWithSortedWindows(apps: [MacApp]) -> [MacAppWithWindows] {
        let order = apps
            .enumerated()
            .reduce(into: [String: Int]()) {
                $0[$1.element.bundleIdentifier] = $1.offset
            }

        return NSWorkspace.shared.runningApplications
            .filter { !$0.isHidden && apps.containsApp($0) }
            .map { MacAppWithWindows(app: $0) }
            .sorted { order[$0.bundleIdentifier] ?? 0 < order[$1.bundleIdentifier] ?? 0 }
    }
}
