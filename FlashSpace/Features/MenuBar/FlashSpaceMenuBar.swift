//
//  FlashSpaceMenuBar.swift
//
//  Created by Wojciech Kulik on 13/02/2025.
//  Copyright © 2025 Wojciech Kulik. All rights reserved.
//

import SwiftUI

struct FlashSpaceMenuBar: Scene {
    @Environment(\.openWindow) private var openWindow

    @StateObject private var workspaceManager = AppDependencies.shared.workspaceManager
    @StateObject private var settingsRepository = AppDependencies.shared.settingsRepository
    @StateObject private var profilesRepository = AppDependencies.shared.profilesRepository

    var body: some Scene {
        MenuBarExtra {
            Text("FlashSpace v\(AppConstants.version)")

            Button("Open") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }

            if settingsRepository.enableSpaceControl {
                Button("Space Control") {
                    SpaceControl.show()
                }
            }

            Divider()

            Button("Settings") {
                openWindow(id: "settings")
                NSApp.activate(ignoringOtherApps: true)
            }.keyboardShortcut(",")

            Menu("Profiles") {
                ForEach(profilesRepository.profiles) { profile in
                    Toggle(
                        profile.name,
                        isOn: .init(
                            get: { profilesRepository.selectedProfile == profile },
                            set: {
                                if $0 { profilesRepository.selectedProfile = profile }
                            }
                        )
                    )
                }
            }.hidden(profilesRepository.profiles.count < 2)

            Divider()

            Button("Donate") {
                if let url = URL(string: "https://github.com/sponsors/wojciech-kulik") {
                    NSWorkspace.shared.open(url)
                }
            }

            Button("Project Website") {
                if let url = URL(string: "https://github.com/wojciech-kulik/FlashSpace") {
                    NSWorkspace.shared.open(url)
                }
            }

            Button("Check for Updates") {
                Task { await UpdatesManager.shared.showIfNewReleaseAvailable() }
            }

            Divider()

            Button("Quit") {
                NSApp.terminate(nil)
            }.keyboardShortcut("q")
        } label: {
            HStack {
                Image(systemName: workspaceManager.activeWorkspaceDetails?.symbolIconName ?? .defaultIconSymbol)
                if let title = MenuBarTitle.get() { Text(title) }
            }
            .id(settingsRepository.menuBarTitleTemplate)
        }
    }
}
