import SwiftUI

@main
struct OpenWrtManagerApp: App {
    @State private var store = RouterStore()
    private let launchArguments = ProcessInfo.processInfo.arguments

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .tint(.accentColor)
                .modifier(AppPreferences())
                .modifier(LaunchAppearance(arguments: launchArguments))
                .task {
                    if launchArguments.contains("--demo") {
                        store.enterDemo()
                    }
                }
        }
    }
}

private struct LaunchAppearance: ViewModifier {
    let arguments: [String]

    func body(content: Content) -> some View {
        if arguments.contains("--dark") && arguments.contains("--large-type") {
            content
                .preferredColorScheme(.dark)
                .environment(\.dynamicTypeSize, .xxxLarge)
        } else if arguments.contains("--dark") {
            content.preferredColorScheme(.dark)
        } else if arguments.contains("--large-type") {
            content.environment(\.dynamicTypeSize, .xxxLarge)
        } else {
            content
        }
    }
}
