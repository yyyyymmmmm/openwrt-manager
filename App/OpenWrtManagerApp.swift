import SwiftUI

@main
struct OpenWrtManagerApp: App {
    @State private var store = RouterStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .tint(.accentColor)
                .modifier(AppPreferences())
        }
    }
}
