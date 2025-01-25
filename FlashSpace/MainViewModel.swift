//
//  MainViewModel.swift
//
//  Created by Wojciech Kulik on 19/01/2025.
//  Copyright © 2025 Wojciech Kulik. All rights reserved.
//

import AppKit
import Combine
import ShortcutRecorder
import SwiftUI

final class MainViewModel: ObservableObject {
    @AppStorage("afterFirstLaunch") var afterFirstLaunch = false

    @Published var workspaces: [Workspace] = []
    @Published var workspaceApps: [String]?

    @Published var workspaceName = ""
    @Published var workspaceShortcut: HotKeyShortcut? {
        didSet { saveWorkspace() }
    }

    @Published var workspaceAssignShortcut: HotKeyShortcut? {
        didSet { saveWorkspace() }
    }

    @Published var workspaceDisplay = "" {
        didSet { saveWorkspace() }
    }

    @Published var workspaceAppToFocus: String? {
        didSet { saveWorkspace() }
    }

    @Published var workspaceSymbolIconName: String? {
        didSet { saveWorkspace() }
    }

    @Published var isSymbolPickerPresented = false
    @Published var isInputDialogPresented = false
    @Published var userInput = ""
    @Published var dismissOnLaunch = false

    var selectedApp: String? {
        didSet {
            guard selectedApp != oldValue else { return }

            // To avoid warnings
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self.objectWillChange.send()
            }
        }
    }

    var selectedWorkspace: Workspace? {
        didSet {
            guard selectedWorkspace != oldValue else { return }

            // To avoid warnings
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self.updateSelectedWorkspace()
            }
        }
    }

    var screens: [String] {
        let set = Set<String>(NSScreen.screens.compactMap(\.localizedName))
        let otherScreens = workspaces.map(\.display)
        return Array(set.union(otherScreens))
            .filter { !$0.isEmpty }
            .sorted()
    }

    private var cancellables: Set<AnyCancellable> = []
    private var loadingWorkspace = false

    private let workspaceManager = AppDependencies.shared.workspaceManager
    private let workspaceRepository = AppDependencies.shared.workspaceRepository
    private let hotKeysManager = AppDependencies.shared.hotKeysManager

    init() {
        self.workspaces = workspaceRepository.workspaces
        self.workspaceDisplay = NSScreen.main?.localizedName ?? ""

        hotKeysManager.enableAll()
        observe()
        checkIfFirstLaunch()
    }

    private func checkIfFirstLaunch() {
        if afterFirstLaunch {
            dismissOnLaunch = true
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        afterFirstLaunch = true
    }

    private func observe() {
        NotificationCenter.default
            .publisher(for: .appsListChanged)
            .sink { [weak self] _ in self?.reloadWorkspaces() }
            .store(in: &cancellables)
    }

    private func updateSelectedWorkspace() {
        loadingWorkspace = true
        defer { loadingWorkspace = false }

        workspaceName = selectedWorkspace?.name ?? ""
        workspaceShortcut = selectedWorkspace?.activateShortcut
        workspaceAssignShortcut = selectedWorkspace?.assignAppShortcut
        workspaceDisplay = selectedWorkspace?.display ?? NSScreen.main?.localizedName ?? ""
        workspaceApps = selectedWorkspace?.apps
        workspaceAppToFocus = selectedWorkspace?.appToFocus ?? workspaceApps?.last
        workspaceSymbolIconName = selectedWorkspace?.symbolIconName
        selectedApp = nil
    }

    private func reloadWorkspaces() {
        workspaces = workspaceRepository.workspaces
        selectedWorkspace = workspaces.first { $0.id == selectedWorkspace?.id }
    }
}

extension MainViewModel {
    func saveWorkspace() {
        guard let selectedWorkspace, !loadingWorkspace else { return }

        if workspaceName.trimmingCharacters(in: .whitespaces).isEmpty {
            workspaceName = "(empty)"
        }

        let updatedWorkspace = Workspace(
            id: selectedWorkspace.id,
            name: workspaceName,
            display: workspaceDisplay,
            activateShortcut: workspaceShortcut,
            assignAppShortcut: workspaceAssignShortcut,
            apps: selectedWorkspace.apps,
            appToFocus: workspaceAppToFocus,
            symbolIconName: workspaceSymbolIconName
        )

        workspaceRepository.updateWorkspace(updatedWorkspace)
        workspaces = workspaceRepository.workspaces
        self.selectedWorkspace = workspaces.first { $0.id == selectedWorkspace.id }
    }

    func addWorkspace() {
        userInput = ""
        isInputDialogPresented = true

        $isInputDialogPresented
            .first { !$0 }
            .sink { [weak self] _ in
                guard let self, !self.userInput.isEmpty else { return }

                self.workspaceRepository.addWorkspace(name: self.userInput)
                self.workspaces = self.workspaceRepository.workspaces
                self.selectedWorkspace = self.workspaces.last
            }
            .store(in: &cancellables)
    }

    func deleteWorkspace() {
        guard let selectedWorkspace else { return }

        workspaceRepository.deleteWorkspace(id: selectedWorkspace.id)
        workspaces = workspaceRepository.workspaces
        self.selectedWorkspace = nil
    }

    func addApp() {
        guard let selectedWorkspace else { return }

        let fileChooser = FileChooser()
        let appUrl = fileChooser.runModalOpenPanel(
            allowedFileTypes: [.application],
            directoryURL: URL(filePath: "/Applications")
        )

        guard let appUrl else { return }

        let appName = appUrl.lastPathComponent.replacingOccurrences(of: ".app", with: "")

        guard !selectedWorkspace.apps.contains(appName) else { return }

        workspaceRepository.addApp(
            to: selectedWorkspace.id,
            app: appName
        )

        workspaces = workspaceRepository.workspaces
        self.selectedWorkspace = workspaces.first { $0.id == selectedWorkspace.id }
    }

    func deleteApp() {
        guard let selectedWorkspace, let selectedApp else { return }

        workspaceRepository.deleteApp(
            from: selectedWorkspace.id,
            app: selectedApp
        )

        workspaces = workspaceRepository.workspaces
        self.selectedApp = nil
        self.selectedWorkspace = workspaces.first { $0.id == selectedWorkspace.id }
    }

    func resetWorkspaceSymbolIcon() {
        workspaceSymbolIconName = nil
        saveWorkspace()
    }

    func moveWorkspace(up: Bool) {
        guard let selectedWorkspace else { return }

        if up {
            workspaceRepository.moveUp(workspaceId: selectedWorkspace.id)
        } else {
            workspaceRepository.moveDown(workspaceId: selectedWorkspace.id)
        }

        workspaces = workspaceRepository.workspaces
    }
}
