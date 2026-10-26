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
    /// Calm blue; defined in the asset catalog with light and dark variants.
    static let accent = Color("AccentColor")
    static let background = Color(uiColor: .systemGroupedBackground)
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    static let subtleFill = Color(uiColor: .tertiarySystemFill)
    static let secondaryText = Color(uiColor: .secondaryLabel)
    static let success = Color.green
    static let danger = Color.red

    static let radius: CGFloat = 16
    static let smallRadius: CGFloat = 12
    static let gutter: CGFloat = 16

    static func tint(for category: ToolCategory) -> Color {
        switch category {
        case .organize: Color.blue
        case .optimize: Color.teal
        case .convertToPDF: Color.indigo
        case .convertFromPDF: Color.cyan
        case .edit: Color.orange
        case .security: Color.pink
        case .ai: Color.purple
        }
    }
}

// MARK: - Components

struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
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
                .font(.subheadline.weight(.semibold))
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
                Text(lang.t(tool.title)).font(.body.weight(.medium)).foregroundStyle(.primary)
                Text(lang.t(tool.subtitle)).font(.footnote).foregroundStyle(Theme.secondaryText)
            }
            Spacer(minLength: 4)
            if tool.execution == .server {
                Image(systemName: "icloud")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryText)
                    .accessibilityLabel(lang.t("تحتاج اتصالاً بالإنترنت", "Needs internet"))
            }
            if isFavorite {
                Image(systemName: "star.fill").font(.footnote).foregroundStyle(.yellow)
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
            .font(.title3.weight(.bold))
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
            Text(text).font(.footnote).foregroundStyle(Theme.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Theme.subtleFill, in: RoundedRectangle(cornerRadius: Theme.smallRadius, style: .continuous))
    }
}
