import SwiftUI
import CoreImage.CIFilterBuiltins
import WaraqaCore

/// Creates an expiring view link for an already-protected PDF, then shows its QR code.
struct SecureShareView: View {
    @Environment(\.appLanguage) private var lang
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var server = ServerService.shared
    @ObservedObject private var shares = SharesStore.shared

    let file: URL
    let title: String
    @State var recipient: String
    @State var purpose: String
    @State private var duration: ShareDuration = .oneDay
    @State private var maxViews = 3
    @State private var allowDownload = false
    @State private var agreed = false
    @State private var working = false
    @State private var error: WaraqaError?
    @State private var created: ShareRecord?

    init(file: URL, title: String, recipient: String, purpose: String) {
        self.file = file
        self.title = title
        _recipient = State(initialValue: recipient)
        _purpose = State(initialValue: purpose)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let created {
                        ShareLinkCard(record: created)
                    } else if !server.isConfigured {
                        NoteBox(systemImage: "icloud.slash", text: lang.t(
                            "المشاركة عبر الرابط تحتاج خادم ورقة، وهو غير مفعّل في هذه النسخة. يمكنك المشاركة المباشرة من الشاشة السابقة.",
                            "Link sharing needs the Waraqa server, which isn't enabled in this build. Use direct sharing instead."), tint: Theme.warning)
                    } else {
                        form
                    }
                }
                .padding(Theme.gutter)
            }
            .background(Theme.background)
            .navigationTitle(lang.t("مشاركة آمنة", "Secure share"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(lang.t("إغلاق", "Close")) { dismiss() } } }
            .alert(lang.t("تنبيه", "Notice"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button(lang.t("حسناً", "OK"), role: .cancel) {}
            } message: { Text(error.map { lang.t($0.message) } ?? "") }
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            labeled(lang.t("اسم المستلم", "Recipient"), text: $recipient)
            labeled(lang.t("الغرض", "Purpose"), text: $purpose)
            VStack(alignment: .leading, spacing: 8) {
                T("مدة الصلاحية", "Valid for").font(.app(.subheadline, .bold))
                Picker("", selection: $duration) {
                    ForEach(ShareDuration.allCases) { Text(lang.t($0.title)).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Stepper(value: $maxViews, in: 1...50) {
                Text(lang.t("مرات الفتح المسموحة: \(maxViews)", "Allowed opens: \(maxViews)")).font(.app(.subheadline, .bold))
            }
            Toggle(lang.t("السماح بتنزيل نسخة PDF", "Allow downloading the PDF"), isOn: $allowDownload).font(.app(.subheadline))
            NoteBox(systemImage: "exclamationmark.triangle", text: lang.t(
                "انتهاء الرابط أو إلغاؤه يوقف العرض فقط، ولا يحذف نسخة نزّلها المستلم أو صوّرها. منع التنزيل لا يمنع لقطة الشاشة.",
                "Expiry or revoking stops viewing only; it can't delete a copy the recipient downloaded or photographed. Blocking downloads doesn't stop screenshots."),
                    tint: Theme.warning)
            Toggle(isOn: $agreed) {
                Text(lang.t("أوافق على رفع النسخة المحمية (وليس الأصل) إلى خادم ورقة مشفّرة، وحذفها تلقائياً عند انتهاء الرابط أو إلغائه.",
                            "I agree to upload the protected copy (not the original) to the Waraqa server, encrypted, and have it deleted when the link ends or is revoked."))
                    .font(.app(.footnote))
            }
            PrimaryButton(title: working ? lang.t("جارٍ الإنشاء…", "Creating…") : lang.t("إنشاء الرابط ورمز QR", "Create link and QR"),
                          systemImage: "qrcode", isEnabled: agreed && !working) { create() }
        }
    }

    private func labeled(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.app(.subheadline, .bold))
            TextField(title, text: text).font(.app(.body)).padding(12)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.smallRadius))
        }
    }

    private func create() {
        working = true
        Task {
            defer { working = false }
            do {
                let part = MultipartBody.FilePart(fileName: file.lastPathComponent, contentType: "application/pdf", url: file)
                let response = try await server.withApprovedUpload { client in
                    try await client.createShare(file: part, recipient: recipient, purpose: purpose, duration: duration,
                                                 maxViews: maxViews, allowDownload: allowDownload)
                }
                shares.add(response, title: title, recipient: recipient, purpose: purpose, maxViews: maxViews, allowDownload: allowDownload)
                created = shares.records.first { $0.id == response.id }
            } catch {
                self.error = ToolRunner.map(error)
            }
        }
    }
}

/// Link + QR + status + revoke for one share.
struct ShareLinkCard: View {
    @Environment(\.appLanguage) private var lang
    @ObservedObject private var shares = SharesStore.shared
    let record: ShareRecord
    @State private var copied = false
    @State private var error: WaraqaError?

    private var current: ShareRecord { shares.records.first { $0.id == record.id } ?? record }

    var body: some View {
        VStack(spacing: 16) {
            if let qr = QRCode.image(for: current.url) {
                Image(uiImage: qr).interpolation(.none).resizable().scaledToFit()
                    .frame(width: 220, height: 220).padding(16)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 20))
                    .accessibilityLabel(lang.t("رمز QR لرابط المشاركة", "QR code for the share link"))
            }
            Text(current.url).font(.app(.footnote)).foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center).textSelection(.enabled)
                .environment(\.layoutDirection, .leftToRight)
            VStack(spacing: 8) {
                row(lang.t("المستلم", "Recipient"), current.recipient)
                row(lang.t("ينتهي", "Expires"), current.expires.formatted(date: .abbreviated, time: .shortened))
                row(lang.t("مرات الفتح", "Opens"), "\(current.opens) / \(current.maxViews)")
                row(lang.t("الحالة", "Status"), lang.t(current.effectiveState.title))
            }
            .padding(14).card()
            HStack(spacing: 10) {
                SecondaryButton(title: copied ? lang.t("تم النسخ", "Copied") : lang.t("نسخ الرابط", "Copy link"), systemImage: "doc.on.doc") {
                    UIPasteboard.general.string = current.url
                    copied = true
                }
                if let url = URL(string: current.url) {
                    ShareLink(item: url) {
                        Label(lang.t("إرسال", "Send"), systemImage: "square.and.arrow.up").frame(maxWidth: .infinity, minHeight: 46)
                    }
                    .buttonStyle(.bordered)
                }
            }
            if current.effectiveState == .active {
                Button(role: .destructive) {
                    Task {
                        do { try await shares.revoke(current) } catch { self.error = ToolRunner.map(error) }
                    }
                } label: {
                    Label(lang.t("إلغاء المشاركة الآن", "Revoke now"), systemImage: "xmark.octagon").frame(maxWidth: .infinity, minHeight: 46)
                }
                .buttonStyle(.bordered)
            }
            Text(lang.t("نسجّل عدد مرات الفتح ووقتها فقط؛ لا يمكن معرفة هوية من فتح الرابط.",
                        "Only the number and time of opens are recorded; who opened the link can't be known."))
                .font(.app(.caption)).foregroundStyle(Theme.secondaryText).multilineTextAlignment(.center)
        }
        .task { await shares.refresh() }
        .alert(lang.t("تنبيه", "Notice"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(lang.t("حسناً", "OK"), role: .cancel) {}
        } message: { Text(error.map { lang.t($0.message) } ?? "") }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack { Text(title).foregroundStyle(Theme.secondaryText); Spacer(); Text(value).fontWeight(.semibold) }.font(.app(.subheadline))
    }
}

enum QRCode {
    static func image(for text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
