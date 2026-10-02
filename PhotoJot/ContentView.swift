import SwiftUI

struct ContentView: View {
    let update: LibraryUpdateController
    let connection: ConnectionSettingsController
    let timelineRepository: TimelineRepository
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            if let settings = connection.savedSettings {
                TimelineView(repository: timelineRepository, settings: settings, update: update)
                    .id(settings)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("設定", systemImage: "gearshape") {
                                if connection.beginEditing() { showingSettings = true }
                            }
                        }
                    }
            } else {
                settingsView
            }
        }
        .sheet(isPresented: $showingSettings, onDismiss: { connection.endEditing() }) {
            NavigationStack {
                settingsView
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("閉じる") { showingSettings = false }
                                .disabled(connection.isSaving)
                        }
                    }
            }
            .interactiveDismissDisabled(connection.isSaving)
        }
    }

    private var settingsView: some View {
        ConnectionSettingsView(controller: connection) { showingSettings = false }
            #if DEBUG
            .toolbar {
                ToolbarItem(placement: .bottomBar) {
                    NavigationLink("Developer Tools") {
                        DeveloperToolsView(update: update, repository: timelineRepository)
                    }
                    .disabled(connection.isSaving)
                }
            }
            #endif
    }
}
