import SwiftUI

@main
struct RoomMaquetteApp: App {
    @StateObject private var projectStore = ProjectStore()
    
    var body: some Scene {
        WindowGroup {
            HomeDashboardView()
                .environmentObject(projectStore)
        }
    }
}
