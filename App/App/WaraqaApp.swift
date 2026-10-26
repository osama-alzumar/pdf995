import SwiftUI
import WaraqaCore

@main
struct WaraqaApp: App {
    @StateObject private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .environment(\.appLanguage, app.language)
                .environment(\.layoutDirection, app.language.isRightToLeft ? .rightToLeft : .leftToRight)
                .environment(\.locale, app.language.locale)
                .tint(Theme.accent)
                .onOpenURL { url in app.receive(url) }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.appLanguage) private var lang

    var body: some View {
        TabView(selection: $app.selectedTab) {
            HomeView()
                .tabItem { Label(lang.t("الرئيسية", "Home"), systemImage: "house") }
                .tag(AppModel.Tab.home)
            MyFilesView()
                .tabItem { Label(lang.t("ملفاتي", "My files"), systemImage: "folder") }
                .tag(AppModel.Tab.files)
            SettingsView()
                .tabItem { Label(lang.t("الإعدادات", "Settings"), systemImage: "gearshape") }
                .tag(AppModel.Tab.settings)
        }
        .onAppear(perform: applyScreenshotLaunchArguments)
    }

    /// DEBUG-only launch arguments used by UI tests to capture screenshots of a given state.
    private func applyScreenshotLaunchArguments() {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-WaraqaLanguage"), i + 1 < args.count, let language = AppLanguage(rawValue: args[i + 1]) {
            app.setLanguage(language)
        }
        if let i = args.firstIndex(of: "-WaraqaOpenTool"), i + 1 < args.count, let tool = ToolID(rawValue: args[i + 1]) {
            app.open(tool)
        }
        #endif
    }
}
