import SwiftUI
import PDFEngine
import WaraqaCore

@main
struct WaraqaApp: App {
    @StateObject private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            Group {
                if let sample = Self.demoSample {
                    ProtectFlowView(language: app.language, files: [sample])
                } else {
                    RootView()
                }
            }
                .environmentObject(app)
                .environment(\.appLanguage, app.language)
                .environment(\.layoutDirection, app.language.isRightToLeft ? .rightToLeft : .leftToRight)
                .environment(\.locale, app.language.locale)
                .tint(Theme.accent)
                .preferredColorScheme(Self.debugColorScheme)
                .onOpenURL { url in app.receive(url) }
        }
    }
}

extension WaraqaApp {
    /// DEBUG `-WaraqaDemoProtect`: opens the protect flow directly with a generated sample
    /// (fictional data), for UI tests and screenshots.
    static let demoSample: PickedFile? = {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("-WaraqaDemoProtect") else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("نموذج مستند تعريفي.pdf")
        let lines = ["مستند تعريفي — نموذج تجريبي", "الاسم: سارة أحمد (اسم افتراضي)", "رقم الهوية 1000000001",
                     "تاريخ الميلاد: 1995/01/01", "الجوال 0500000000", "هذا المستند للعرض فقط ولا يمثل وثيقة حقيقية."]
        try? PDFEngine.textToPDF(pages: [lines.joined(separator: "\n\n")], title: "بطاقة تعريف — نموذج", rightToLeft: true, to: url)
        return PickedFile(url: url, name: url.lastPathComponent)
        #else
        return nil
        #endif
    }()

    /// DEBUG `-WaraqaDark` forces dark mode for screenshot tests; release builds follow the system.
    static var debugColorScheme: ColorScheme? {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-WaraqaDark") ? .dark : nil
        #else
        return nil
        #endif
    }
}

struct RootView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.appLanguage) private var lang
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var shares = SharesStore.shared

    var body: some View {
        TabView(selection: $app.selectedTab) {
            HomeView()
                .tabItem { Label(lang.t("الرئيسية", "Home"), systemImage: "house") }
                .tag(AppModel.Tab.home)
            ToolsView()
                .tabItem { Label(lang.t("أدوات PDF", "PDF tools"), systemImage: "square.grid.2x2") }
                .tag(AppModel.Tab.tools)
            VaultView()
                .tabItem { Label(lang.t("مستنداتي", "My documents"), systemImage: "folder") }
                .tag(AppModel.Tab.documents)
                .badge(shares.newOpens)
            AccountView()
                .tabItem { Label(lang.t("حسابي", "Account"), systemImage: "person.crop.circle") }
                .tag(AppModel.Tab.account)
        }
        .onAppear(perform: applyScreenshotLaunchArguments)
        .task {
            await PurchaseStore.shared.start()
            await SharesStore.shared.refresh()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                // Lock the wallet and delete decrypted copies whenever the app leaves the screen.
                VaultLock.shared.lock()
                VaultStore.shared.closeOpenedFiles()
            case .active:
                Task { await SharesStore.shared.refresh() }
            default:
                break
            }
        }
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
