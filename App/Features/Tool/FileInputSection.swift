import SwiftUI
import PhotosUI
import ImageIO
import UniformTypeIdentifiers
import PDFEngine
import WaraqaCore

/// "Add a file" area: Files app, Photos, camera scan or a web address, depending on the tool.
/// Picked files are copied into the app; the originals are never modified.
struct FileInputSection: View {
    @Environment(\.appLanguage) private var lang
    let tool: ToolInfo
    @Binding var files: [PickedFile]
    @Binding var webURL: String
    @Binding var error: WaraqaError?

    @State private var showImporter = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showScanner = false
    @State private var passwordTarget: PickedFile?
    @State private var passwordText = ""
    @State private var loading = false

    private var allowsMultiple: Bool {
        [.multiplePDFs, .images, .camera, .twoPDFs].contains(tool.input)
    }

    private var maxFiles: Int {
        switch tool.input {
        case .twoPDFs: 2
        case .multiplePDFs: Limits.maxMergeFiles
        case .images, .camera: Limits.maxImages
        default: 1
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if tool.input == .webPage {
                webField
            }
            if !files.isEmpty {
                fileList
            }
            if files.count < maxFiles {
                addButtons
            }
            if loading { ProgressView().frame(maxWidth: .infinity) }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: UTType.types(for: tool.input),
                      allowsMultipleSelection: allowsMultiple) { result in
            switch result {
            case .success(let urls): add(urls)
            case .failure: error = .cannotOpen(fileName: "")
            }
        }
        .onChange(of: photoItems) { _, items in loadPhotos(items) }
        .sheet(isPresented: $showScanner) {
            DocumentScannerView { images in
                showScanner = false
                addScans(images)
            }
            .ignoresSafeArea()
        }
        .alert(lang.t("الملف محمي بكلمة مرور", "Password-protected file"), isPresented: Binding(
            get: { passwordTarget != nil }, set: { if !$0 { passwordTarget = nil } })) {
            SecureField(lang.t("كلمة المرور", "Password"), text: $passwordText)
            Button(lang.t("فتح", "Open")) { applyPassword() }
            Button(lang.t("إلغاء", "Cancel"), role: .cancel) {
                if let target = passwordTarget { files.removeAll { $0.id == target.id } }
                passwordTarget = nil
            }
        } message: {
            Text(lang.t("أدخل كلمة مرور «\(passwordTarget?.name ?? "")». لا تُحفظ كلمة المرور.",
                        "Enter the password for “\(passwordTarget?.name ?? "")”. It isn't stored."))
        }
    }

    // MARK: Pieces

    private var webField: some View {
        VStack(alignment: .leading, spacing: 6) {
            T("رابط الصفحة", "Page address").font(.subheadline.weight(.semibold))
            TextField("https://", text: $webURL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .environment(\.layoutDirection, .leftToRight)
                .padding(12)
                .background(Theme.subtleFill, in: RoundedRectangle(cornerRadius: Theme.smallRadius))
            T("أو اختر ملف HTML من الملفات.", "Or pick an HTML file.").font(.footnote).foregroundStyle(Theme.secondaryText)
        }
    }

    private var fileList: some View {
        VStack(spacing: 8) {
            ForEach(Array(files.enumerated()), id: \.element.id) { index, file in
                HStack(spacing: 12) {
                    FileThumbnail(file: file)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.name).font(.subheadline.weight(.medium)).lineLimit(2)
                        HStack(spacing: 6) {
                            Text(ByteSize.format(file.size, language: lang))
                            if file.isPDF, let count = try? PDFEngine.pageCount(file.url, password: file.password) {
                                Text("·")
                                Text(lang.t("\(count) صفحة", "\(count) pages"))
                            }
                            if file.password != nil { Image(systemName: "lock.open").accessibilityLabel(lang.t("تم فتح الحماية", "Unlocked")) }
                        }
                        .font(.caption).foregroundStyle(Theme.secondaryText)
                    }
                    Spacer()
                    if tool.input == .multiplePDFs || tool.input == .images {
                        VStack(spacing: 4) {
                            Button { move(index, by: -1) } label: { Image(systemName: "chevron.up") }
                                .disabled(index == 0)
                                .accessibilityLabel(lang.t("تحريك لأعلى", "Move up"))
                            Button { move(index, by: 1) } label: { Image(systemName: "chevron.down") }
                                .disabled(index == files.count - 1)
                                .accessibilityLabel(lang.t("تحريك لأسفل", "Move down"))
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                    Button(role: .destructive) { files.remove(at: index) } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(lang.t("إزالة \(file.name)", "Remove \(file.name)"))
                }
                .padding(10)
                .background(Theme.subtleFill, in: RoundedRectangle(cornerRadius: Theme.smallRadius))
            }
            if tool.input == .twoPDFs && files.count == 2 {
                T("الأول: النسخة القديمة — الثاني: النسخة الجديدة", "First: old version — second: new version")
                    .font(.caption).foregroundStyle(Theme.secondaryText)
            }
        }
    }

    private var addButtons: some View {
        VStack(spacing: 10) {
            switch tool.input {
            case .images:
                PhotosPicker(selection: $photoItems, maxSelectionCount: maxFiles - files.count, matching: .images) {
                    addLabel(lang.t("اختر من الصور", "Choose from Photos"), "photo.on.rectangle")
                }
                Button { showImporter = true } label: { addLabel(lang.t("اختر من الملفات", "Choose from Files"), "folder") }
                if DocumentScannerView.isSupported {
                    Button { showScanner = true } label: { addLabel(lang.t("صوّر بالكاميرا", "Scan with camera"), "camera") }
                }
            case .camera:
                if DocumentScannerView.isSupported {
                    Button { showScanner = true } label: { addLabel(lang.t(files.isEmpty ? "ابدأ المسح" : "امسح صفحات أخرى", files.isEmpty ? "Start scanning" : "Scan more pages"), "doc.viewfinder") }
                } else {
                    NoteBox(systemImage: "camera", text: lang.t("الكاميرا غير متاحة على هذا الجهاز.", "The camera isn't available on this device."))
                }
            case .twoPDFs:
                Button { showImporter = true } label: {
                    addLabel(files.isEmpty ? lang.t("اختر النسخة القديمة", "Choose the old version") : lang.t("اختر النسخة الجديدة", "Choose the new version"), "doc.badge.plus")
                }
            default:
                Button { showImporter = true } label: {
                    addLabel(files.isEmpty ? lang.t("اختر ملفاً", "Choose a file") : lang.t("أضف ملفات", "Add files"), "doc.badge.plus")
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func addLabel(_ title: String, _ symbol: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.title3)
            Text(title).font(.body.weight(.semibold))
            Spacer()
        }
        .foregroundStyle(Theme.accent)
        .padding(.horizontal, 16)
        .frame(minHeight: 56)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .strokeBorder(Theme.accent.opacity(0.45), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
        )
        .contentShape(Rectangle())
    }

    // MARK: Actions

    private func move(_ index: Int, by offset: Int) {
        let target = index + offset
        guard files.indices.contains(target) else { return }
        files.swapAt(index, target)
    }

    private func add(_ urls: [URL]) {
        for url in urls.prefix(maxFiles - files.count) {
            do {
                let file = try FileStore.shared.importFile(url)
                files.append(file)
                if file.isPDF && PDFEngine.isPasswordProtected(file.url) {
                    passwordText = ""
                    passwordTarget = file
                }
            } catch let e as WaraqaError {
                error = e
            } catch {
                self.error = .cannotOpen(fileName: url.lastPathComponent)
            }
        }
    }

    private func applyPassword() {
        guard let target = passwordTarget, let index = files.firstIndex(where: { $0.id == target.id }) else { return }
        do {
            _ = try PDFEngine.open(target.url, password: passwordText)
            files[index].password = passwordText
        } catch {
            files.remove(at: index)
            self.error = .wrongPassword
        }
        passwordTarget = nil
        passwordText = ""
    }

    private func loadPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        loading = true
        Task {
            for (n, item) in items.enumerated() {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
                    if let file = try? FileStore.shared.importData(data, name: lang.t("صورة", "Photo") + " \(files.count + 1).\(ext)") {
                        files.append(file)
                    }
                } else {
                    error = .imageUnreadable(fileName: "\(n + 1)")
                }
            }
            photoItems = []
            loading = false
        }
    }

    private func addScans(_ images: [UIImage]) {
        for image in images {
            guard let data = image.jpegData(compressionQuality: 0.85),
                  let file = try? FileStore.shared.importData(data, name: lang.t("صفحة", "Page") + " \(files.count + 1).jpg") else { continue }
            files.append(file)
        }
    }
}

/// Small preview of a picked file (first page of a PDF, the image itself, or an icon).
struct FileThumbnail: View {
    let file: PickedFile
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: file.isPDF ? "doc.richtext" : "doc")
                    .font(.title2).foregroundStyle(.secondary)
            }
        }
        .frame(width: 44, height: 56)
        .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
        .accessibilityHidden(true)
        .task(id: file.id) {
            let url = file.url, password = file.password, isPDF = file.isPDF
            image = await Task.detached(priority: .utility) { () -> UIImage? in
                if isPDF {
                    return PDFEngine.thumbnail(url, page: 0, maxPixels: 160, password: password).map { UIImage(cgImage: $0) }
                }
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 160,
                      ] as CFDictionary) else { return nil }
                return UIImage(cgImage: cg)
            }.value
        }
    }
}
