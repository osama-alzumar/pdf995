import SwiftUI
import WaraqaCore

// MARK: - Language

private struct AppLanguageKey: EnvironmentKey {
    static let defaultValue: AppLanguage = .arabic
}

extension EnvironmentValues {
    var appLanguage: AppLanguage {
        get { self[AppLanguageKey.self] }
        set { self[AppLanguageKey.self] = newValue }
    }
}

extension AppLanguage {
    /// Picks the string for this language: `lang.t("دمج", "Merge")`.
    func t(_ ar: String, _ en: String) -> String { self == .arabic ? ar : en }
    func t(_ text: LocalizedText) -> String { text.resolve(self) }
    var locale: Locale { Locale(identifier: self == .arabic ? "ar" : "en") }
}

/// Text in the current app language.
struct T: View {
    @Environment(\.appLanguage) private var lang
    let ar: String
    let en: String

    init(_ ar: String, _ en: String) {
        self.ar = ar
        self.en = en
    }

    init(_ text: LocalizedText) {
        ar = text.ar
        en = text.en
    }

    var body: some View { Text(lang.t(ar, en)) }
}

// MARK: - Colors & metrics

enum Theme {
    /// Navy accent from design B; defined in the asset catalog with light and dark variants.
    static let accent = Color("AccentColor")
    static let background = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.043, green: 0.055, blue: 0.078, alpha: 1) : UIColor(red: 0.961, green: 0.969, blue: 0.984, alpha: 1) })
    static let card = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.086, green: 0.106, blue: 0.145, alpha: 1) : .white })
    static let subtleFill = Color(uiColor: .tertiarySystemFill)
    static let secondaryText = Color(uiColor: .secondaryLabel)
    static let line = Color(uiColor: .separator)
    static let success = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.29, green: 0.87, blue: 0.5, alpha: 1) : UIColor(red: 0.024, green: 0.463, blue: 0.278, alpha: 1) })
    static let warning = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.98, green: 0.75, blue: 0.14, alpha: 1) : UIColor(red: 0.71, green: 0.28, blue: 0.03, alpha: 1) })
    static let danger = Color(uiColor: .systemRed)

    /// The protection card: a soft navy gradient (design B).
    static let heroGradient = LinearGradient(
        colors: [Color(red: 0.118, green: 0.227, blue: 0.431), Color(red: 0.067, green: 0.133, blue: 0.267)],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    static let radius: CGFloat = 22
    static let smallRadius: CGFloat = 16
    static let gutter: CGFloat = 16

    static func tint(for category: ToolCategory) -> Color {
        switch category {
        case .organize: Color(red: 0.12, green: 0.23, blue: 0.43)
        case .optimize: Color.teal
        case .convertToPDF: Color.indigo
        case .convertFromPDF: Color.cyan
        case .edit: Color.orange
        case .security: Color.pink
        case .images: Color.mint
        case .ai: Color.purple
        }
    }
}

// MARK: - Type (Tajawal, scales with Dynamic Type)

extension Font {
    static func app(_ style: Font.TextStyle, _ weight: Font.Weight = .regular) -> Font {
        let size: CGFloat
        switch style {
        case .largeTitle: size = 34
        case .title: size = 28
        case .title2: size = 22
        case .title3: size = 20
        case .headline: size = 17
        case .body: size = 17
        case .callout: size = 16
        case .subheadline: size = 15
        case .footnote: size = 13
        case .caption: size = 12
        case .caption2: size = 11
        @unknown default: size = 17
        }
        let name: String
        switch weight {
        case .black, .heavy: name = "Tajawal-ExtraBold"
        case .bold, .semibold: name = "Tajawal-Bold"
        case .medium: name = "Tajawal-Medium"
        default: name = "Tajawal-Regular"
        }
        return .custom(name, size: size, relativeTo: style)
    }
}

// MARK: - Components

struct CardBackground: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.06), radius: 12, x: 0, y: 6)
    }
}

extension View {
    func card() -> some View { modifier(CardBackground()) }
}

/// The one big, clear action button of every tool screen.
struct PrimaryButton: View {
    let title: String
    var systemImage: String?
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage { Image(systemName: systemImage).accessibilityHidden(true) }
                Text(title).fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity, minHeight: 52)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.roundedRectangle(radius: Theme.radius))
        .controlSize(.large)
        .disabled(!isEnabled)
    }
}

struct SecondaryButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, minHeight: 46)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle(radius: Theme.smallRadius))
    }
}

/// Round tinted icon used for tools.
struct ToolIcon: View {
    let tool: ToolInfo
    var size: CGFloat = 44

    var body: some View {
        Image(systemName: tool.symbol)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(Theme.tint(for: tool.category))
            .frame(width: size, height: size)
            .background(Theme.tint(for: tool.category).opacity(0.13), in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Large tile for the quick tools on the home screen.
struct QuickToolTile: View {
    @Environment(\.appLanguage) private var lang
    let tool: ToolInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ToolIcon(tool: tool, size: 40)
            Text(lang.t(tool.title))
                .font(.app(.subheadline, .semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
        .card()
        .accessibilityElement(children: .combine)
        .accessibilityHint(lang.t(tool.subtitle))
    }
}

/// A row in the full tools list.
struct ToolRow: View {
    @Environment(\.appLanguage) private var lang
    let tool: ToolInfo
    var isFavorite = false

    var body: some View {
        HStack(spacing: 12) {
            ToolIcon(tool: tool, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(lang.t(tool.title)).font(.app(.body, .medium)).foregroundStyle(.primary)
                Text(lang.t(tool.subtitle)).font(.app(.footnote)).foregroundStyle(Theme.secondaryText)
            }
            Spacer(minLength: 4)
            if tool.execution == .server {
                Image(systemName: "icloud")
                    .font(.app(.footnote))
                    .foregroundStyle(Theme.secondaryText)
                    .accessibilityLabel(lang.t("تحتاج اتصالاً بالإنترنت", "Needs internet"))
            }
            if isFavorite {
                Image(systemName: "star.fill").font(.app(.footnote)).foregroundStyle(.yellow)
                    .accessibilityLabel(lang.t("مفضلة", "Favorite"))
            }
        }
        .contentShape(Rectangle())
    }
}

struct SectionTitle: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.app(.title3, .bold))
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A plain explanation box (info, privacy notes, limitations).
struct NoteBox: View {
    let systemImage: String
    let text: String
    var tint: Color = .secondary

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage).foregroundStyle(tint).accessibilityHidden(true)
            Text(text).font(.app(.footnote)).foregroundStyle(Theme.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Theme.subtleFill, in: RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous))
    }
}
