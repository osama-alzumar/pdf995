import SwiftUI
import PDFKit
import PDFEngine
import WaraqaCore

/// PDFView with the editor's items drawn on top as preview annotations, plus the gestures to
/// add, select, move and resize them. Pinch-to-zoom and scrolling are PDFView's own.
struct PDFCanvas: UIViewRepresentable {
    let document: PDFDocument
    @ObservedObject var model: EditorModel
    /// Called when the user taps a page with the image/signature tool.
    var onPlaceImage: (_ page: Int, _ point: PagePoint) -> Void

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.document = document
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .secondarySystemBackground
        view.pageShadowsEnabled = true
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.sync()
        context.coordinator.updateScrolling()
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: PDFCanvas
        weak var view: PDFView?
        private var previews: [UUID: ItemAnnotation] = [:]

        // Gesture state
        private var dragStart: PagePoint?
        private var dragPage: Int?
        private var dragItemID: UUID?
        private var dragMode: DragMode = .none
        private var inkPoints: [PagePoint] = []
        private var lastPoint: PagePoint?

        enum DragMode { case none, create, move, resize, ink }

        init(parent: PDFCanvas) { self.parent = parent }

        var model: EditorModel { parent.model }

        func attach(to view: PDFView) {
            self.view = view
            let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
            tap.delegate = self
            view.addGestureRecognizer(tap)
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            pan.maximumNumberOfTouches = 1
            pan.delegate = self
            view.addGestureRecognizer(pan)
            scrollView(in: view)?.panGestureRecognizer.require(toFail: pan)
            sync()
        }

        private func scrollView(in view: UIView) -> UIScrollView? {
            if let s = view as? UIScrollView { return s }
            for sub in view.subviews { if let s = scrollView(in: sub) { return s } }
            return nil
        }

        func updateScrolling() {
            guard let view else { return }
            scrollView(in: view)?.isScrollEnabled = !model.tool.drags
        }

        // MARK: Sync items → preview annotations

        func sync() {
            guard let document = view?.document else { return }
            let current = Dictionary(uniqueKeysWithValues: model.items.map { ($0.id, $0) })
            for (id, annotation) in previews where current[id] == nil || current[id]!.pageIndex != annotation.item.pageIndex {
                annotation.page?.removeAnnotation(annotation)
                previews[id] = nil
            }
            for item in model.items {
                let selected = item.id == model.selectedID
                if let existing = previews[item.id] {
                    if existing.item != item || existing.isSelected != selected {
                        existing.item = item
                        existing.isSelected = selected
                        existing.bounds = ItemAnnotation.bounds(for: item)
                    }
                } else if let page = document.page(at: item.pageIndex) {
                    let annotation = ItemAnnotation(item: item)
                    annotation.isSelected = selected
                    page.addAnnotation(annotation)
                    previews[item.id] = annotation
                }
            }
            view?.setNeedsDisplay()
            for page in Set(previews.values.compactMap(\.page)) { view?.annotationsChanged(on: page) }
        }

        // MARK: Hit testing

        private func location(_ g: UIGestureRecognizer) -> (page: Int, point: PagePoint)? {
            guard let view, let document = view.document else { return nil }
            let p = g.location(in: view)
            guard let page = view.page(for: p, nearest: true) else { return nil }
            let pt = view.convert(p, to: page)
            return (document.index(for: page), PagePoint(x: Double(pt.x), y: Double(pt.y)))
        }

        private func item(at point: PagePoint, page: Int) -> EditItem? {
            model.items.reversed().first { item in
                item.pageIndex == page && standardized(item.rect).insetBy(-8).contains(point)
            }
        }

        private func nearResizeHandle(_ item: EditItem, _ point: PagePoint) -> Bool {
            let r = standardized(item.rect)
            return abs(point.x - r.maxX) < 22 && abs(point.y - r.minY) < 22
        }

        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard g is UIPanGestureRecognizer else { return true }
            if model.tool.drags { return true }
            guard model.tool == .select, let loc = location(g) else { return false }
            return item(at: loc.point, page: loc.page) != nil
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            g is UITapGestureRecognizer
        }

        // MARK: Gestures

        @objc func handleTap(_ g: UITapGestureRecognizer) {
            guard let loc = location(g) else { return }
            switch model.tool {
            case .select:
                if let hit = item(at: loc.point, page: loc.page) {
                    if model.selectedID == hit.id {
                        switch hit.kind {
                        case .text(let text, _, _):
                            model.textPrompt = .init(itemID: hit.id, pageIndex: hit.pageIndex, point: loc.point, text: text, isNote: false)
                        case .note(let text):
                            model.textPrompt = .init(itemID: hit.id, pageIndex: hit.pageIndex, point: loc.point, text: text, isNote: true)
                        default: break
                        }
                    }
                    model.selectedID = hit.id
                } else {
                    model.selectedID = nil
                }
            case .text, .note:
                model.textPrompt = .init(itemID: nil, pageIndex: loc.page, point: loc.point, text: "", isNote: model.tool == .note)
            case .image, .signature:
                parent.onPlaceImage(loc.page, loc.point)
            default:
                break
            }
        }

        @objc func handlePan(_ g: UIPanGestureRecognizer) {
            guard let loc = location(g) else { return }
            switch g.state {
            case .began:
                dragStart = loc.point
                dragPage = loc.page
                lastPoint = loc.point
                model.beginInteractive()
                if model.tool == .ink {
                    dragMode = .ink
                    inkPoints = [loc.point]
                    let id = UUID()
                    dragItemID = id
                    model.insertInteractive(EditItem(id: id, pageIndex: loc.page, rect: EditorModel.inkBounds(inkPoints, padding: model.lineWidth),
                                                     kind: .ink([inkPoints], lineWidth: model.lineWidth), colorHex: model.color))
                } else if model.tool.drags {
                    dragMode = .create
                    dragItemID = nil
                } else if let hit = item(at: loc.point, page: loc.page) {
                    model.selectedID = hit.id
                    dragItemID = hit.id
                    dragMode = nearResizeHandle(hit, loc.point) ? .resize : .move
                }
            case .changed:
                guard loc.page == dragPage, let start = dragStart else { return }
                switch dragMode {
                case .ink:
                    inkPoints.append(loc.point)
                    let points = inkPoints, width = model.lineWidth
                    if let id = dragItemID {
                        model.updateInteractive(id) {
                            $0.kind = .ink([points], lineWidth: width)
                            $0.rect = EditorModel.inkBounds(points, padding: width)
                        }
                    }
                case .create:
                    if dragItemID == nil {
                        let id = UUID()
                        if let shape = model.shape(for: model.tool, page: loc.page, from: start, to: loc.point, id: id) {
                            dragItemID = id
                            model.insertInteractive(shape)
                        }
                    } else if let id = dragItemID, let shape = model.shape(for: model.tool, page: loc.page, from: start, to: loc.point, id: id) {
                        model.updateInteractive(id) { $0.rect = shape.rect }
                    }
                case .move:
                    guard let id = dragItemID, let last = lastPoint else { return }
                    let dx = loc.point.x - last.x, dy = loc.point.y - last.y
                    model.updateInteractive(id) { item in
                        item.rect.x += dx
                        item.rect.y += dy
                        if case .ink(let strokes, let width) = item.kind {
                            item.kind = .ink(strokes.map { $0.map { PagePoint(x: $0.x + dx, y: $0.y + dy) } }, lineWidth: width)
                        }
                    }
                case .resize:
                    guard let id = dragItemID, let last = lastPoint else { return }
                    let dx = loc.point.x - last.x, dy = loc.point.y - last.y
                    model.updateInteractive(id) { item in
                        // Bottom-right handle: width grows to the right, height grows downward.
                        item.rect.width = max(16, item.rect.width + dx)
                        let newHeight = max(12, item.rect.height - dy)
                        item.rect.y += item.rect.height - newHeight
                        item.rect.height = newHeight
                    }
                case .none:
                    break
                }
                lastPoint = loc.point
            default:
                if dragMode == .create || dragMode == .ink, let id = dragItemID,
                   let made = model.items.first(where: { $0.id == id }), standardized(made.rect).width < 4, standardized(made.rect).height < 4 {
                    model.removeInteractive(id) // an accidental tap-drag, not a shape
                }
                model.endInteractive()
                dragMode = .none
                dragItemID = nil
                dragStart = nil
                lastPoint = nil
            }
        }
    }
}

func standardized(_ r: PageRect) -> PageRect {
    PageRect(x: min(r.x, r.x + r.width), y: min(r.y, r.y + r.height), width: abs(r.width), height: abs(r.height))
}

extension PageRect {
    func contains(_ p: PagePoint) -> Bool { p.x >= minX && p.x <= maxX && p.y >= minY && p.y <= maxY }
    func insetBy(_ d: Double) -> PageRect { PageRect(x: x + d, y: y + d, width: width - 2 * d, height: height - 2 * d) }
}

/// Draws an editor item exactly as the export will (shared drawing code), plus a selection frame.
final class ItemAnnotation: PDFAnnotation {
    var item: EditItem
    var isSelected = false

    init(item: EditItem) {
        self.item = item
        super.init(bounds: ItemAnnotation.bounds(for: item), forType: .stamp, withProperties: nil)
        shouldDisplay = true
        shouldPrint = false
    }

    required init?(coder: NSCoder) { nil }

    static func bounds(for item: EditItem) -> CGRect {
        let r = standardized(item.rect)
        return CGRect(x: r.x, y: r.y, width: r.width, height: r.height).insetBy(dx: -12, dy: -12)
    }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }
        context.saveGState()
        try? PDFEngine.draw(item, in: context)
        context.restoreGState()
        guard isSelected else { return }
        let r = standardized(item.rect)
        let frame = CGRect(x: r.x, y: r.y, width: r.width, height: r.height).insetBy(dx: -3, dy: -3)
        context.saveGState()
        context.setStrokeColor(UIColor.systemBlue.cgColor)
        context.setLineWidth(1)
        context.setLineDash(phase: 0, lengths: [4, 3])
        context.stroke(frame)
        context.setLineDash(phase: 0, lengths: [])
        context.setFillColor(UIColor.systemBlue.cgColor)
        context.fillEllipse(in: CGRect(x: frame.maxX - 6, y: frame.minY - 6, width: 12, height: 12))
        context.restoreGState()
    }
}
