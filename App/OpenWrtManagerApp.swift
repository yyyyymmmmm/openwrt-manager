import SwiftUI

@main
struct OpenWrtManagerApp: App {
    @State private var store = RouterStore()

    init() {
        // The kit resolves its fixed copy through KitL10n; feed it the
        // language the system selected for this app before any view or
        // store string is produced. The UI itself follows the system
        // automatically through the String Catalog — there is no
        // in-app language switch, matching the platform convention.
        L10n.syncKitLanguage()
        AppDiagnostics.record(.app, L10n.string("App 启动"),
                              metadata: ["version": AppDiagnostics.appVersion,
                                         "build": AppDiagnostics.appBuild])
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .tint(.accentColor)
                .modifier(AppPreferences())
        }
    }
}
