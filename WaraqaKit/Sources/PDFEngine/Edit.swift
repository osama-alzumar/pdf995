#if canImport(PDFKit)
import Foundation
import PDFKit
import CoreGraphics
import CoreText
import WaraqaCore
#if os(macOS)
import AppKit
typealias PlatformFont = NSFont
typealias PlatformColor = NSColor
#else
import UIKit
typealias PlatformFont = UIFont
typealias PlatformColor = UIColor
#endif

/// Something the user placed on a page in the editor or signer. Geometry is in PDF page space
/// (the coordinates PDFView reports), so what is exported matches the preview exactly.
public struct EditItem: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case text(String, fontSize: Double, bold: Bool)
        /// PNG/JPEG data; signatures are PNG with transparency.
        case image(Data)
        case rectangle(filled: Bool, lineWidth: Double)
        case ellipse(filled: Bool, lineWidth: Double)
        case line(lineWidth: Double, arrow: Bool)
        /// Freehand strokes, points in page space.
        case ink([[PagePoint]], lineWidth: Double)
        /// Translucent marker over text.
        case highlight
        /// A visible note box (yellow background).
        case note(String)
    }

    public let id: UUID
    public var pageIndex: Int
    public var rect: PageRect
    public var kind: Kind
    public var colorHex: String
    public var opacity: Double

    public init(id: UUID = UUID(), pageIndex: Int, rect: PageRect, kind: Kind, colorHex: String = "#111111", opacity: Double = 1) {
        self.id = id
        self.pageIndex = pageIndex
        self.rect = rect
        self.kind = kind
        self.colorHex = colorHex
        self.opacity = opacity
    }
}

public struct PagePoint: Equatable, Sendable, Codable {
    public var x: Double, y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

extension PDFEngine {
    // MARK: - Page numbers

    public static func addPageNumbers(_ input: PDFInput, options: PageNumberOptions, to output: URL,
                                      progress: ProgressHandler? = nil) throws {
        let work = try Workspace()
        let doc = try prepareForDrawing(input.url, password: input.password, work: work)
        let count = doc.pageCount
        let color = CGColor(gray: 0.2, alpha: 1)
        try redraw(doc, to: output, displaySpace: { ctx, index, box in
            guard let label = options.label(index: index, count: count) else { return }
            let line = line(label, size: options.fontSize, color: color)
            let size = bounds(of: line)
            let margin = max(18, min(box.width, box.height) * 0.04)
            let spot = options.position.place(width: size.width, height: size.height, in: pageRect(box), margin: margin)
            draw(line, at: CGPoint(x: spot.x, y: spot.y), in: ctx)
        }, progress: progress)
        try validate(output, expectedPages: count)
    }

    // MARK: - Watermark

    public static func addWatermark(_ input: PDFInput, options: WatermarkOptions, to output: URL,
                                    progress: ProgressHandler? = nil) throws {
        guard options.hasContent else { throw WaraqaError.missingOptions }
        let work = try Workspace()
        let doc = try prepareForDrawing(input.url, password: input.password, work: work)
        let targets = options.pages.map(Set.init)
        let image = try options.imageData.map { try loadImage(data: $0, maxPixels: 2048) }
        let color = color(hex: options.colorHex)

        try redraw(doc, to: output, displaySpace: { ctx, index, box in
            if let targets, !targets.contains(index) { return }
            ctx.saveGState()
            ctx.setAlpha(CGFloat(options.opacity))
            let size: CGSize
            let paint: (CGContext) -> Void
            if let image {
                let w = box.width * 0.4
                let h = w * CGFloat(image.height) / CGFloat(max(image.width, 1))
                size = CGSize(width: w, height: h)
                paint = { $0.draw(image, in: CGRect(origin: .zero, size: size)) }
            } else {
                let fontSize = min(CGFloat(options.fontSize), box.width / CGFloat(max(options.text.count, 1)) * 1.6)
                let l = line(options.text, size: fontSize, color: color, bold: true)
                size = bounds(of: l)
                paint = { draw(l, at: .zero, in: $0) }
            }
            let angle = CGFloat(options.rotationDegrees) * .pi / 180
            func stamp(at center: CGPoint) {
                ctx.saveGState()
                ctx.translateBy(x: center.x, y: center.y)
                ctx.rotate(by: angle)
                ctx.translateBy(x: -size.width / 2, y: -size.height / 2)
                paint(ctx)
                ctx.restoreGState()
            }
            switch options.layout {
            case .single:
                let spot = options.position.place(width: size.width, height: size.height, in: pageRect(box), margin: 36)
                stamp(at: CGPoint(x: spot.midX, y: spot.midY))
            case .tiled:
                let stepX = max(size.width * 1.6, 120), stepY = max(size.height * 3.5, 120)
                var y = box.minY + stepY / 2
                var row = 0
                while y < box.maxY + stepY {
                    var x = box.minX + (row.isMultiple(of: 2) ? 0 : stepX / 2)
                    while x < box.maxX + stepX {
                        stamp(at: CGPoint(x: x, y: y))
                        x += stepX
                    }
                    y += stepY
                    row += 1
                }
            }
            ctx.restoreGState()
        }, progress: progress)
        try validate(output, expectedPages: doc.pageCount)
    }

    // MARK: - Crop

    /// Shrinks the crop box. Content outside stays in the file but is hidden in every viewer;
    /// use Redact to remove content for real.
    public static func crop(_ input: PDFInput, margins: CropMargins, pages: [Int]? = nil, to output: URL) throws {
        let doc = try open(input.url, password: input.password)
        let result = try copyPages(of: doc, indices: Array(0..<doc.pageCount))
        let targets = Set(pages ?? Array(0..<result.pageCount))
        for i in targets.sorted() {
            guard let page = result.page(at: i) else { continue }
            let box = page.bounds(for: .cropBox)
            guard let cropped = margins.apply(to: pageRect(box)) else {
                throw WaraqaError.invalidPageSelection("\(i + 1)")
            }
            page.setBounds(cgRect(cropped), for: .cropBox)
        }
        try write(result, to: output)
        try validate(output, expectedPages: doc.pageCount)
    }

    /// Margins that would trim the white border around a page's content (auto-crop).
    public static func detectContentMargins(_ input: PDFInput, page index: Int) throws -> CropMargins {
        let doc = try open(input.url, password: input.password)
        guard let pdfPage = doc.page(at: index), let page = pdfPage.pageRef, page.rotationAngle % 360 == 0 else {
            return CropMargins()
        }
        let image = try render(page, dpi: 50)
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return CropMargins() }
        let w = image.width, h = image.height, bpr = image.bytesPerRow, bpp = image.bitsPerPixel / 8
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w {
                let p = y * bpr + x * bpp
                if bytes[p] < 245 || bytes[p + 1] < 245 || bytes[p + 2] < 245 {
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return CropMargins() }
        let s = 72.0 / 50.0, pad = 6.0
        // Bitmap rows start at the top of the page.
        return CropMargins(top: max(0, Double(minY) * s - pad), bottom: max(0, Double(h - 1 - maxY) * s - pad),
                           left: max(0, Double(minX) * s - pad), right: max(0, Double(w - 1 - maxX) * s - pad))
    }

    // MARK: - Editor export

    /// Writes the document with the editor's items drawn permanently into the pages. Existing
    /// annotations are burned in too, so the result looks the same in every viewer.
    public static func applyEdits(_ input: PDFInput, items: [EditItem], to output: URL,
                                  progress: ProgressHandler? = nil) throws {
        let work = try Workspace()
        let doc = try prepareForDrawing(input.url, password: input.password, work: work)
        let byPage = Dictionary(grouping: items, by: \.pageIndex)
        try redraw(doc, to: output, pageSpace: { ctx, index, _ in
            for item in byPage[index] ?? [] { try draw(item, in: ctx) }
        }, progress: progress)
        try validate(output, expectedPages: doc.pageCount)
    }

    /// Draws an item in page space. Also used by the editor preview, so preview and export match.
    public static func draw(_ item: EditItem, in ctx: CGContext) throws {
        let rect = cgRect(item.rect)
        let color = color(hex: item.colorHex)
        ctx.saveGState()
        ctx.setAlpha(CGFloat(item.opacity))
        switch item.kind {
        case let .text(text, fontSize, bold):
            drawParagraph(text, in: rect, size: CGFloat(fontSize), color: color, bold: bold, ctx: ctx)
        case .image(let data):
            let image = try loadImage(data: data, maxPixels: 2400)
            ctx.interpolationQuality = .high
            ctx.draw(image, in: aspectFit(CGSize(width: image.width, height: image.height), in: rect))
        case let .rectangle(filled, lineWidth):
            if filled {
                ctx.setFillColor(color); ctx.fill(rect)
            } else {
                ctx.setStrokeColor(color); ctx.setLineWidth(CGFloat(lineWidth))
                ctx.stroke(rect.insetBy(dx: CGFloat(lineWidth) / 2, dy: CGFloat(lineWidth) / 2))
            }
        case let .ellipse(filled, lineWidth):
            if filled {
                ctx.setFillColor(color); ctx.fillEllipse(in: rect)
            } else {
                ctx.setStrokeColor(color); ctx.setLineWidth(CGFloat(lineWidth))
                ctx.strokeEllipse(in: rect.insetBy(dx: CGFloat(lineWidth) / 2, dy: CGFloat(lineWidth) / 2))
            }
        case let .line(lineWidth, arrow):
            // From (x, y) to (x + width, y + height); width/height may be negative so the
            // arrow can point in any direction.
            let r = item.rect
            let start = CGPoint(x: r.x, y: r.y), end = CGPoint(x: r.x + r.width, y: r.y + r.height)
            ctx.setStrokeColor(color); ctx.setLineWidth(CGFloat(lineWidth)); ctx.setLineCap(.round)
            ctx.move(to: start); ctx.addLine(to: end); ctx.strokePath()
            if arrow {
                let angle = atan2(end.y - start.y, end.x - start.x)
                let len = max(8, CGFloat(lineWidth) * 4)
                ctx.move(to: end)
                ctx.addLine(to: CGPoint(x: end.x - len * cos(angle - .pi / 7), y: end.y - len * sin(angle - .pi / 7)))
                ctx.move(to: end)
                ctx.addLine(to: CGPoint(x: end.x - len * cos(angle + .pi / 7), y: end.y - len * sin(angle + .pi / 7)))
                ctx.strokePath()
            }
        case let .ink(strokes, lineWidth):
            ctx.setStrokeColor(color); ctx.setLineWidth(CGFloat(lineWidth))
            ctx.setLineCap(.round); ctx.setLineJoin(.round)
            for stroke in strokes where stroke.count > 1 {
                ctx.move(to: CGPoint(x: stroke[0].x, y: stroke[0].y))
                for p in stroke.dropFirst() { ctx.addLine(to: CGPoint(x: p.x, y: p.y)) }
                ctx.strokePath()
            }
        case .highlight:
            ctx.setBlendMode(.multiply)
            ctx.setFillColor(color.copy(alpha: 0.4) ?? color)
            ctx.fill(rect)
        case .note(let text):
            ctx.setFillColor(CGColor(srgbRed: 1, green: 0.95, blue: 0.6, alpha: 1))
            ctx.fill(rect)
            ctx.setStrokeColor(CGColor(srgbRed: 0.85, green: 0.7, blue: 0.1, alpha: 1))
            ctx.setLineWidth(1)
            ctx.stroke(rect.insetBy(dx: 0.5, dy: 0.5))
            drawParagraph(text, in: rect.insetBy(dx: 6, dy: 6), size: 10, color: CGColor(gray: 0.1, alpha: 1), bold: false, ctx: ctx)
        }
        ctx.restoreGState()
    }

    /// Multi-line text wrapped inside `rect`, natural alignment (right-aligned for Arabic).
    static func drawParagraph(_ text: String, in rect: CGRect, size: CGFloat, color: CGColor, bold: Bool, ctx: CGContext) {
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font(size: size, bold: bold),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        let framesetter = CTFramesetterCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        // Allow the frame to grow downward so short boxes don't clip the last line.
        let needed = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(), nil,
                                                                  CGSize(width: rect.width, height: .greatestFiniteMagnitude), nil)
        let height = max(rect.height, needed.height)
        let frameRect = CGRect(x: rect.minX, y: rect.maxY - height, width: rect.width, height: height)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(), CGPath(rect: frameRect, transform: nil), nil)
        ctx.saveGState()
        ctx.textMatrix = .identity
        CTFrameDraw(frame, ctx)
        ctx.restoreGState()
    }

    static func aspectFit(_ size: CGSize, in rect: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return rect }
        let scale = min(rect.width / size.width, rect.height / size.height)
        let w = size.width * scale, h = size.height * scale
        return CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    }

    // MARK: - Forms

    /// Names and current values of the fillable fields in a document.
    public static func formFields(_ input: PDFInput) throws -> [(page: Int, name: String, value: String)] {
        let doc = try open(input.url, password: input.password)
        var fields: [(Int, String, String)] = []
        for i in 0..<doc.pageCount {
            for annotation in doc.page(at: i)?.annotations ?? [] where annotation.type == "Widget" {
                fields.append((i, annotation.fieldName ?? "", annotation.widgetStringValue ?? ""))
            }
        }
        return fields
    }

    public struct NewFormField: Sendable {
        public enum Kind: Sendable { case text, checkbox }
        public let pageIndex: Int
        public let rect: PageRect
        public let name: String
        public let kind: Kind
        public init(pageIndex: Int, rect: PageRect, name: String, kind: Kind) {
            self.pageIndex = pageIndex
            self.rect = rect
            self.name = name
            self.kind = kind
        }
    }

    /// Adds fillable fields and/or sets values of existing fields by name.
    public static func updateForm(_ input: PDFInput, newFields: [NewFormField], values: [String: String],
                                  to output: URL) throws {
        let doc = try open(input.url, password: input.password)
        for field in newFields {
            guard let page = doc.page(at: field.pageIndex) else { continue }
            let widget = PDFAnnotation(bounds: cgRect(field.rect), forType: .widget, withProperties: nil)
            // Set the name in the annotation dictionary (/T) too; otherwise PDFKit writes
            // generated names such as "text0" when saving.
            widget.setValue(field.name as NSString, forAnnotationKey: .widgetFieldName)
            widget.fieldName = field.name
            switch field.kind {
            case .text:
                widget.widgetFieldType = .text
                widget.font = PlatformFont.systemFont(ofSize: 12)
                widget.backgroundColor = PlatformColor(red: 0.9, green: 0.94, blue: 1, alpha: 1)
            case .checkbox:
                widget.widgetFieldType = .button
                widget.widgetControlType = .checkBoxControl
            }
            page.addAnnotation(widget)
        }
        if !values.isEmpty {
            for i in 0..<doc.pageCount {
                for annotation in doc.page(at: i)?.annotations ?? [] {
                    guard let name = annotation.fieldName, let value = values[name] else { continue }
                    if annotation.widgetFieldType == .button {
                        annotation.buttonWidgetState = (value == "1" || value.lowercased() == "on") ? .onState : .offState
                    } else {
                        annotation.widgetStringValue = value
                        annotation.setValue(value as NSString, forAnnotationKey: .widgetValue)
                    }
                }
            }
        }
        try write(doc, to: output)
        try validate(output, expectedPages: doc.pageCount)
    }
}
#endif
