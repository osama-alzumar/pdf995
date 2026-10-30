import SwiftUI
import PencilKit

/// Draw a signature with a finger or Apple Pencil, or type it. Returns transparent PNG data.
/// The last signature is kept on the device (in the protected app folder) for reuse.
struct SignatureSheet: View {
    @Environment(\.appLanguage) private var lang
    let done: (Data?) -> Void

    enum Style: String { case draw, type }
    @State private var style: Style = .draw
    @State private var canvas = PKCanvasView()
    @State private var typed = ""
    @State private var inkColor: UIColor = SignatureSheet.inks[0].color
    @State private var hasDrawing = false
    @State private var saved: Data? = SignatureStore.load()

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let saved, let image = UIImage(data: saved) {
                    Button { done(saved) } label: {
                        HStack {
                            Image(uiImage: image).resizable().scaledToFit().frame(height: 44)
                                .padding(.horizontal, 6).background(Color.white, in: RoundedRectangle(cornerRadius: 6))
                            Spacer()
                            T("استخدم التوقيع المحفوظ", "Use saved signature").font(.app(.subheadline, .semibold))
                        }
                        .padding(12)
                        .background(Theme.subtleFill, in: RoundedRectangle(cornerRadius: Theme.smallRadius))
                    }
                    .buttonStyle(.plain)
                }
                Picker("", selection: $style) {
                    Text(lang.t("ارسم", "Draw")).tag(Style.draw)
                    Text(lang.t("اكتب", "Type")).tag(Style.type)
                }
                .pickerStyle(.segmented)

                if style == .draw {
                    SignatureCanvas(canvas: canvas, color: inkColor) { hasDrawing = !canvas.drawing.bounds.isEmpty }
                        .frame(height: 220)
                        // Always paper-white, so the ink colors look the same in dark mode as on the page.
                        .background(Color.white, in: RoundedRectangle(cornerRadius: Theme.radius))
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(Color.secondary.opacity(0.4)).frame(height: 1).padding(.horizontal, 30).padding(.bottom, 50)
                        }
                        .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Color.secondary.opacity(0.25)))
                        .accessibilityLabel(lang.t("مساحة رسم التوقيع", "Signature drawing area"))
                        .accessibilityIdentifier("signature.canvas")
                    HStack {
                        inkPicker
                        Button(lang.t("مسح", "Clear")) { canvas.drawing = PKDrawing(); hasDrawing = false }
                    }
                } else {
                    TextField(lang.t("اكتب اسمك", "Type your name"), text: $typed)
                        .font(.app(.title2))
                        .padding(12)
                        .background(Theme.subtleFill, in: RoundedRectangle(cornerRadius: Theme.smallRadius))
                    if !typed.isEmpty {
                        typedSignature.frame(height: 90).frame(maxWidth: .infinity)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: Theme.smallRadius))
                    }
                    inkPicker
                }
                NoteBox(systemImage: "info.circle", text: lang.t(
                    "هذا توقيع مرئي يُرسم على الصفحة، وليس توقيعاً رقمياً معتمداً بشهادة إلكترونية.",
                    "This is a visual signature drawn on the page, not a certificate-based digital signature."))
                Spacer()
                PrimaryButton(title: lang.t("استخدم التوقيع", "Use signature"), systemImage: "signature",
                              isEnabled: style == .draw ? hasDrawing : !typed.trimmingCharacters(in: .whitespaces).isEmpty) {
                    let data = style == .draw ? drawnPNG() : typedPNG()
                    if let data { SignatureStore.save(data) }
                    done(data)
                }
            }
            .padding(Theme.gutter)
            .navigationTitle(lang.t("التوقيع", "Signature"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(lang.t("إلغاء", "Cancel")) { done(nil) } }
            }
        }
    }

    /// Fixed (non-dynamic) colors: what you pick is exactly what lands on the page.
    static let inks: [(id: String, title: LocalizedText, color: UIColor)] = [
        ("black", LocalizedText("أسود", "Black"), UIColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1)),
        ("blue", LocalizedText("أزرق", "Blue"), UIColor(red: 0.05, green: 0.35, blue: 0.85, alpha: 1)),
        ("navy", LocalizedText("كحلي", "Navy"), UIColor(red: 0.08, green: 0.16, blue: 0.45, alpha: 1)),
        ("green", LocalizedText("أخضر", "Green"), UIColor(red: 0.02, green: 0.45, blue: 0.25, alpha: 1)),
        ("red", LocalizedText("أحمر", "Red"), UIColor(red: 0.75, green: 0.1, blue: 0.1, alpha: 1)),
    ]

    private var inkPicker: some View {
        HStack(spacing: 14) {
            ForEach(SignatureSheet.inks, id: \.id) { ink in
                Button { choose(ink.color) } label: {
                    Circle().fill(Color(uiColor: ink.color)).frame(width: 32, height: 32)
                        .overlay(Circle().stroke(inkColor == ink.color ? Theme.accent : .clear, lineWidth: 3).padding(-4))
                }
                .accessibilityLabel(lang.t(ink.title))
                .accessibilityIdentifier("ink.\(ink.id)")
                .accessibilityAddTraits(inkColor == ink.color ? .isSelected : [])
            }
            Spacer()
        }
    }

    /// Changes the pen and recolors what was already drawn.
    private func choose(_ color: UIColor) {
        inkColor = color
        var drawing = canvas.drawing
        drawing.strokes = drawing.strokes.map { stroke in
            var stroke = stroke
            stroke.ink = PKInk(stroke.ink.inkType, color: color)
            return stroke
        }
        canvas.drawing = drawing
    }

    private var typedSignature: some View {
        Text(typed)
            .font(.custom(SignatureSheet.scriptFont(for: typed), size: 54))
            .foregroundStyle(Color(uiColor: inkColor))
            .lineLimit(1)
            .minimumScaleFactor(0.3)
            .padding(.horizontal, 8)
    }

    static func scriptFont(for text: String) -> String {
        let arabic = text.unicodeScalars.contains { (0x0600...0x06FF).contains($0.value) }
        let candidates = arabic ? ["DecoTypeNaskh", "Farah", "GeezaPro"] : ["SnellRoundhand", "Zapfino", "SavoyeLetPlain"]
        return candidates.first { UIFont(name: $0, size: 12) != nil } ?? "Helvetica"
    }

    private func drawnPNG() -> Data? {
        let bounds = canvas.drawing.bounds.insetBy(dx: -8, dy: -8)
        guard !bounds.isEmpty else { return nil }
        // PencilKit renders ink for the current appearance: in dark mode black ink comes out
        // white. The signature goes on a white page, so always render it in light mode.
        var image: UIImage?
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            image = canvas.drawing.image(from: bounds, scale: 3)
        }
        return image?.pngData()
    }

    @MainActor
    private func typedPNG() -> Data? {
        let renderer = ImageRenderer(content: typedSignature.frame(height: 110).fixedSize(horizontal: true, vertical: false))
        renderer.scale = 3
        renderer.isOpaque = false
        renderer.colorScheme = .light
        return renderer.uiImage?.pngData()
    }
}

struct SignatureCanvas: UIViewRepresentable {
    let canvas: PKCanvasView
    let color: UIColor
    let changed: () -> Void

    func makeUIView(context: Context) -> PKCanvasView {
        canvas.drawingPolicy = .anyInput
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.overrideUserInterfaceStyle = .light // ink stays dark on the white page
        canvas.delegate = context.coordinator
        return canvas
    }

    func updateUIView(_ view: PKCanvasView, context: Context) {
        view.tool = PKInkingTool(.pen, color: color, width: 4)
        context.coordinator.changed = changed
    }

    func makeCoordinator() -> Coordinator { Coordinator(changed: changed) }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var changed: () -> Void
        init(changed: @escaping () -> Void) { self.changed = changed }
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) { changed() }
    }
}

/// The user's last signature, stored with complete file protection and never uploaded.
enum SignatureStore {
    private static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Waraqa/signature.png")
    }

    static func load() -> Data? { try? Data(contentsOf: url) }

    static func save(_ data: Data) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: [.atomic, .completeFileProtection])
    }

    static func delete() { try? FileManager.default.removeItem(at: url) }
}
