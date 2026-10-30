import SwiftUI
import PDFEngine
import WaraqaCore

/// Page thumbnails: preview, tap to select, or drag to reorder with per-page rotation.
struct PageGridView: View {
    enum Mode { case preview, select, reorder }

    @Environment(\.appLanguage) private var lang
    let file: PickedFile
    let mode: Mode
    @Binding var selection: Set<Int>
    @Binding var order: [PageEdit]

    @State private var pageCount = 0
    @State private var dragging: Int?

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.app(.headline, .bold))
                Spacer()
                if mode == .select && pageCount > 0 {
                    Button(selection.count == pageCount ? lang.t("إلغاء التحديد", "Deselect all") : lang.t("تحديد الكل", "Select all")) {
                        selection = selection.count == pageCount ? [] : Set(0..<pageCount)
                    }
                    .font(.app(.subheadline))
                }
            }
            LazyVGrid(columns: columns, spacing: 12) {
                if mode == .reorder {
                    ForEach(Array(order.enumerated()), id: \.element.sourceIndex) { position, edit in
                        cell(index: edit.sourceIndex, label: position + 1, rotation: edit.extraRotation)
                            .opacity(dragging == edit.sourceIndex ? 0.4 : 1)
                            .draggable("\(edit.sourceIndex)") {
                                PageThumb(file: file, index: edit.sourceIndex, rotation: edit.extraRotation).frame(width: 80)
                                    .onAppear { dragging = edit.sourceIndex }
                            }
                            .dropDestination(for: String.self) { items, _ in
                                dragging = nil
                                guard let source = items.first.flatMap(Int.init),
                                      let from = order.firstIndex(where: { $0.sourceIndex == source }),
                                      let to = order.firstIndex(where: { $0.sourceIndex == edit.sourceIndex }) else { return false }
                                withAnimation(.snappy) {
                                    let moved = order.remove(at: from)
                                    order.insert(moved, at: to)
                                }
                                return true
                            }
                            .contextMenu {
                                Button { rotate(edit.sourceIndex) } label: { Label(lang.t("تدوير", "Rotate"), systemImage: "rotate.right") }
                                Button(role: .destructive) { order.removeAll { $0.sourceIndex == edit.sourceIndex } } label: {
                                    Label(lang.t("إزالة الصفحة", "Remove page"), systemImage: "trash")
                                }
                            }
                    }
                } else {
                    ForEach(0..<pageCount, id: \.self) { index in
                        cell(index: index, label: index + 1, rotation: 0)
                    }
                }
            }
            if mode == .reorder {
                HStack {
                    T("اسحب الصفحات لترتيبها، واضغط مطولاً للتدوير أو الحذف.", "Drag pages to reorder; long-press to rotate or remove.")
                        .font(.app(.footnote)).foregroundStyle(Theme.secondaryText)
                    Spacer()
                    Button(lang.t("إعادة الضبط", "Reset")) { resetOrder() }.font(.app(.footnote))
                }
            }
        }
        .padding(Theme.gutter)
        .card()
        .task(id: file.id) {
            pageCount = (try? PDFEngine.pageCount(file.url, password: file.password)) ?? 0
            if mode == .reorder && order.isEmpty { resetOrder() }
        }
    }

    private var title: String {
        switch mode {
        case .preview: lang.t("معاينة (\(pageCount) صفحة)", "Preview (\(pageCount) pages)")
        case .select: lang.t("اضغط لتحديد الصفحات (\(selection.count) محددة)", "Tap to select pages (\(selection.count) selected)")
        case .reorder: lang.t("ترتيب الصفحات (\(order.count))", "Page order (\(order.count))")
        }
    }

    @ViewBuilder
    private func cell(index: Int, label: Int, rotation: Int) -> some View {
        let selected = selection.contains(index)
        VStack(spacing: 6) {
            PageThumb(file: file, index: index, rotation: rotation)
                .overlay(alignment: .topTrailing) {
                    if mode == .select {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.app(.title3))
                            .foregroundStyle(selected ? Theme.accent : .secondary)
                            .background(Circle().fill(Color(uiColor: .systemBackground)))
                            .padding(4)
                    }
                    if mode == .reorder {
                        Button { rotate(index) } label: {
                            Image(systemName: "rotate.right").font(.app(.caption, .bold))
                                .padding(6).background(.thinMaterial, in: Circle())
                        }
                        .padding(4)
                        .accessibilityLabel(lang.t("تدوير الصفحة \(label)", "Rotate page \(label)"))
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Theme.accent : .clear, lineWidth: 3))
            Text("\(label)").font(.app(.caption).monospacedDigit()).foregroundStyle(Theme.secondaryText)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard mode == .select else { return }
            if selected { selection.remove(index) } else { selection.insert(index) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(lang.t("صفحة \(label)", "Page \(label)"))
        .accessibilityAddTraits(mode == .select ? (selected ? [.isButton, .isSelected] : .isButton) : [])
    }

    private func rotate(_ source: Int) {
        guard let i = order.firstIndex(where: { $0.sourceIndex == source }) else { return }
        order[i] = PageEdit(sourceIndex: source, extraRotation: (order[i].extraRotation + 90) % 360)
    }

    private func resetOrder() {
        order = (0..<pageCount).map { PageEdit(sourceIndex: $0) }
    }
}

/// One page thumbnail, rendered off the main thread and cached.
struct PageThumb: View {
    let file: PickedFile
    let index: Int
    var rotation = 0
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                ProgressView()
            }
        }
        .aspectRatio(0.75, contentMode: .fit)
        .rotationEffect(.degrees(Double(rotation)))
        .animation(.snappy, value: rotation)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))
        .task(id: "\(file.id)-\(index)") {
            if let cached = ThumbCache.shared.image(file.url, index) { image = cached; return }
            let url = file.url, password = file.password, page = index
            let rendered = await Task.detached(priority: .utility) {
                PDFEngine.thumbnail(url, page: page, maxPixels: 260, password: password).map { UIImage(cgImage: $0) }
            }.value
            if let rendered { ThumbCache.shared.store(rendered, url, index) }
            image = rendered
        }
    }
}

final class ThumbCache {
    static let shared = ThumbCache()
    private let cache = NSCache<NSString, UIImage>()
    init() { cache.countLimit = 400 }
    func image(_ url: URL, _ page: Int) -> UIImage? { cache.object(forKey: "\(url.path)#\(page)" as NSString) }
    func store(_ image: UIImage, _ url: URL, _ page: Int) { cache.setObject(image, forKey: "\(url.path)#\(page)" as NSString) }
    func clear() { cache.removeAllObjects() }
}
