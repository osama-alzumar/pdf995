import SwiftUI
import PDFEngine
import WaraqaCore

/// Editor state with undo/redo. Items live in PDF page space; the preview and the export draw
/// them with the same code (`PDFEngine.draw`), so what you see is what you save.
@MainActor
final class EditorModel: ObservableObject {
    enum Tool: String, CaseIterable, Identifiable {
        case select, text, note, image, signature, rectangle, ellipse, arrow, ink, highlight, redact
        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .select: "hand.point.up.left"
            case .text: "textformat"
            case .note: "note.text"
            case .image: "photo"
            case .signature: "signature"
            case .rectangle: "rectangle"
            case .ellipse: "circle"
            case .arrow: "arrow.up.right"
            case .ink: "scribble"
            case .highlight: "highlighter"
            case .redact: "rectangle.fill"
            }
        }

        var title: LocalizedText {
            switch self {
            case .select: LocalizedText("تحديد", "Select")
            case .text: LocalizedText("نص", "Text")
            case .note: LocalizedText("ملاحظة", "Note")
            case .image: LocalizedText("صورة", "Image")
            case .signature: LocalizedText("توقيع", "Signature")
            case .rectangle: LocalizedText("مستطيل", "Rectangle")
            case .ellipse: LocalizedText("دائرة", "Ellipse")
            case .arrow: LocalizedText("سهم", "Arrow")
            case .ink: LocalizedText("رسم حر", "Draw")
            case .highlight: LocalizedText("تظليل", "Highlight")
            case .redact: LocalizedText("منطقة تنقيح", "Redaction area")
            }
        }

        /// Tools that draw by dragging on the page (so the page doesn't scroll meanwhile).
        var drags: Bool { [.rectangle, .ellipse, .arrow, .ink, .highlight, .redact].contains(self) }
    }

    @Published private(set) var items: [EditItem]
    @Published var tool: Tool = .select
    @Published var selectedID: UUID?
    @Published var color = "#1F5FAD"
    @Published var fontSize: Double = 16
    @Published var lineWidth: Double = 2
    /// Text being typed for a new or edited text/note item.
    @Published var textPrompt: TextPrompt?

    struct TextPrompt: Identifiable {
        let id = UUID()
        var itemID: UUID?
        var pageIndex: Int
        var point: PagePoint
        var text: String
        var isNote: Bool
    }

    private var undoStack: [[EditItem]] = []
    private var redoStack: [[EditItem]] = []

    init(items: [EditItem]) {
        self.items = items
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var selected: EditItem? { items.first { $0.id == selectedID } }

    static let palette = ["#111111", "#1F5FAD", "#D92D20", "#16A34A", "#F79009", "#FFE600", "#FFFFFF"]

    // MARK: Changes (each one is undoable)

    private func commit(_ change: (inout [EditItem]) -> Void) {
        undoStack.append(items)
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
        change(&items)
    }

    func add(_ item: EditItem) {
        commit { $0.append(item) }
        selectedID = item.id
    }

    func update(_ id: UUID, _ change: (inout EditItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        commit { change(&$0[index]) }
    }

    /// Live updates during a drag: no undo entry per frame; call `endInteractive` once at the end.
    private var interactiveSnapshot: [EditItem]?

    func beginInteractive() { interactiveSnapshot = items }

    func updateInteractive(_ id: UUID, _ change: (inout EditItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }

    func insertInteractive(_ item: EditItem) {
        items.append(item)
        selectedID = item.id
    }

    func removeInteractive(_ id: UUID) {
        items.removeAll { $0.id == id }
        if selectedID == id { selectedID = nil }
    }

    func endInteractive() {
        guard let snapshot = interactiveSnapshot else { return }
        interactiveSnapshot = nil
        if snapshot != items {
            undoStack.append(snapshot)
            redoStack.removeAll()
        }
    }

    func deleteSelected() {
        guard let id = selectedID else { return }
        commit { $0.removeAll { $0.id == id } }
        selectedID = nil
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(items)
        items = previous
        if let id = selectedID, !items.contains(where: { $0.id == id }) { selectedID = nil }
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(items)
        items = next
    }

    func applyColor(_ hex: String) {
        color = hex
        if let id = selectedID { update(id) { $0.colorHex = hex } }
    }

    func applySize(_ value: Double) {
        guard let id = selectedID, let item = selected else { return }
        switch item.kind {
        case .text(let text, _, let bold):
            fontSize = value
            update(id) { $0.kind = .text(text, fontSize: value, bold: bold) }
        case .rectangle(let filled, _):
            lineWidth = value
            update(id) { $0.kind = .rectangle(filled: filled, lineWidth: value) }
        case .ellipse(let filled, _):
            lineWidth = value
            update(id) { $0.kind = .ellipse(filled: filled, lineWidth: value) }
        case .line(_, let arrow):
            lineWidth = value
            update(id) { $0.kind = .line(lineWidth: value, arrow: arrow) }
        case .ink(let strokes, _):
            lineWidth = value
            update(id) { $0.kind = .ink(strokes, lineWidth: value) }
        default:
            break
        }
    }

    // MARK: Factories

    func commitText(_ prompt: TextPrompt) {
        let text = prompt.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = prompt.itemID {
            if text.isEmpty {
                selectedID = id
                deleteSelected()
            } else {
                update(id) { item in
                    switch item.kind {
                    case .text(_, let size, let bold): item.kind = .text(text, fontSize: size, bold: bold)
                    case .note: item.kind = .note(text)
                    default: break
                    }
                }
            }
            return
        }
        guard !text.isEmpty else { return }
        let width = min(320, max(120, Double(text.count) * fontSize * 0.55))
        let lines = Double(text.split(separator: "\n").count)
        if prompt.isNote {
            add(EditItem(pageIndex: prompt.pageIndex, rect: PageRect(x: prompt.point.x, y: prompt.point.y - 70, width: 180, height: 70),
                         kind: .note(text)))
        } else {
            let height = fontSize * 1.5 * max(1, lines)
            add(EditItem(pageIndex: prompt.pageIndex, rect: PageRect(x: prompt.point.x, y: prompt.point.y - height, width: width, height: height),
                         kind: .text(text, fontSize: fontSize, bold: false), colorHex: color))
        }
        tool = .select
    }

    func addImage(_ data: Data, pageIndex: Int, center: PagePoint, isSignature: Bool) {
        guard let image = UIImage(data: data) else { return }
        let width: Double = isSignature ? 180 : 220
        let height = width * Double(image.size.height / max(image.size.width, 1))
        add(EditItem(pageIndex: pageIndex, rect: PageRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height),
                     kind: .image(data)))
        tool = .select
    }

    /// A shape from a drag between two points in page space.
    func shape(for tool: Tool, page: Int, from a: PagePoint, to b: PagePoint, id: UUID) -> EditItem? {
        let rect = PageRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        switch tool {
        case .rectangle: return EditItem(id: id, pageIndex: page, rect: rect, kind: .rectangle(filled: false, lineWidth: lineWidth), colorHex: color)
        case .ellipse: return EditItem(id: id, pageIndex: page, rect: rect, kind: .ellipse(filled: false, lineWidth: lineWidth), colorHex: color)
        case .highlight: return EditItem(id: id, pageIndex: page, rect: rect, kind: .highlight, colorHex: color == "#1F5FAD" ? "#FFE600" : color)
        case .redact: return EditItem(id: id, pageIndex: page, rect: rect, kind: .rectangle(filled: true, lineWidth: 0), colorHex: "#000000")
        case .arrow:
            // Lines are drawn from the rect's min corner to its max corner; flip so the arrow
            // points where the finger went.
            let flipX = b.x < a.x, flipY = b.y < a.y
            var item = EditItem(id: id, pageIndex: page, rect: rect, kind: .line(lineWidth: lineWidth, arrow: true), colorHex: color)
            if flipX != flipY {
                // Store as a line from (minX, maxY) to (maxX, minY) using a negative height.
                item.rect = PageRect(x: rect.x, y: rect.maxY, width: rect.width, height: -rect.height)
            }
            if flipX && flipY { item.rect = PageRect(x: rect.maxX, y: rect.maxY, width: -rect.width, height: -rect.height) }
            return item
        default:
            return nil
        }
    }

    static func inkBounds(_ points: [PagePoint], padding: Double) -> PageRect {
        let xs = points.map(\.x), ys = points.map(\.y)
        let minX = (xs.min() ?? 0) - padding, minY = (ys.min() ?? 0) - padding
        return PageRect(x: minX, y: minY, width: (xs.max() ?? 0) + padding - minX, height: (ys.max() ?? 0) + padding - minY)
    }
}
