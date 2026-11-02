//  QrScanViews.swift
//  Aerio
//
//  "Scan QR code", "Choose from Photos", and "Import file" for the
//  Dispatcharr user QR and the AerioTV setup link (iPhone and iPad; port of
//  Android feature/qrscan/QrScanScreen.kt, ImportSourceDeletePrompt.kt,
//  core/qr/QrImageImport.kt, CodeFileImport.kt, ImportSourceCleanup.kt).
//  One parser for all three inputs: ScannedCode / CodeTextImport.
//  Import is manual only: never a share target, never the clipboard.
//  Logs never carry the decoded text, a key, or a path.

#if os(iOS)
import SwiftUI
import AVFoundation
import PhotosUI
import Photos
import Vision
import UniformTypeIdentifiers

// MARK: - Decoding

enum QrImageImport {
    private static let maxSide = 1600

    /// The QR text in an image (EXIF orientation applied, at most 1600 px on
    /// the long side): the whole image, then the middle 60 percent.
    nonisolated static func decode(_ data: Data) -> String? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        if let s = detect(img) { return s }
        let w = Double(img.width), h = Double(img.height)
        let rect = CGRect(x: w * 0.2, y: h * 0.2, width: w * 0.6, height: h * 0.6).integral
        if rect.width >= 21, rect.height >= 21, let crop = img.cropping(to: rect) { return detect(crop) }
        return nil
    }

    nonisolated private static func detect(_ img: CGImage) -> String? {
        let req = VNDetectBarcodesRequest()
        req.symbologies = [.qr]
        try? VNImageRequestHandler(cgImage: img, options: [:]).perform([req])
        return req.results?.compactMap(\.payloadStringValue).first
    }
}

/// A picked image or file still holding the sign-in code.
enum ImportSource {
    /// A Photos asset (deleted through PHPhotoLibrary, system confirmation).
    case photo(assetId: String)
    /// A document whose location allows deletion.
    case file(URL)

    var isPhoto: Bool { if case .photo = self { return true } else { return false } }
}

enum CodeFileImport {
    /// Reads at most 64 KiB (plus one byte to reject larger files) and parses
    /// it. `deletable` is true only when the picked URL supports deletion.
    nonisolated static func read(_ url: URL) -> (result: ScannedCode.Result, deletable: Bool) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var data: Data?
        var err: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &err) { u in
            guard let fh = try? FileHandle(forReadingFrom: u) else { return }
            defer { try? fh.close() }
            data = try? fh.read(upToCount: CodeTextImport.maxBytes + 1)
        }
        guard let data else { return (.invalid, false) }
        let r = CodeTextImport.parse(data: data)
        return (r, FileManager.default.isDeletableFile(atPath: url.path))
    }

    nonisolated static func delete(_ url: URL) -> Bool {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var ok = false
        var err: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &err) { u in
            ok = (try? FileManager.default.removeItem(at: u)) != nil
        }
        return ok && err == nil
    }
}

enum ImportSourceCleanup {
    static func logOutcome(_ deleted: Bool) {
        debugLog(deleted ? "[SETUP-QR] import source deleted" : "[SETUP-QR] import source kept")
    }

    static func delete(_ s: ImportSource) async {
        switch s {
        case .photo(let id):
            let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            guard status == .authorized || status == .limited else { logOutcome(false); return }
            guard PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).count > 0 else { logOutcome(false); return }
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.deleteAssets(PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil))
                }
                logOutcome(true)
            } catch {
                // The user declined the system confirmation, or it failed.
                logOutcome(false)
            }
        case .file(let url):
            let ok = await Task.detached { CodeFileImport.delete(url) }.value
            logOutcome(ok)
        }
    }
}

/// Default rule: a Dispatcharr user code or an AerioTV setup code. Returns an error, or nil to accept.
func acceptAnyKnownCode(_ r: ScannedCode.Result) -> String? {
    r == .invalid ? ScannedCode.invalidMessage : nil
}

// MARK: - Pickers

/// System photo picker (one image). Returns the image data and, when the
/// library granted it, the asset id for the delete offer.
struct PhotoCodePicker: UIViewControllerRepresentable {
    let onPick: (Data?, String?) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var cfg = PHPickerConfiguration(photoLibrary: .shared())
        cfg.filter = .images
        cfg.selectionLimit = 1
        let vc = PHPickerViewController(configuration: cfg)
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: PHPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPick: (Data?, String?) -> Void
        init(onPick: @escaping (Data?, String?) -> Void) { self.onPick = onPick }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard let r = results.first else { onPick(nil, nil); return }
            let id = r.assetIdentifier
            nonisolated(unsafe) let done = onPick
            r.itemProvider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                nonisolated(unsafe) let d = data
                DispatchQueue.main.async { done(d ?? Data(), id) }
            }
        }
    }
}

/// System document picker: application/json, text/plain, any type as the fallback.
struct CodeFilePicker: UIViewControllerRepresentable {
    let onPick: (URL?) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let vc = UIDocumentPickerViewController(forOpeningContentTypes: [.json, .plainText, .item], asCopy: false)
        vc.allowsMultipleSelection = false
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL?) -> Void
        init(onPick: @escaping (URL?) -> Void) { self.onPick = onPick }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { onPick(urls.first) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { onPick(nil) }
    }
}

/// Photos and Import file wiring shared by the form actions and the scanner.
/// `deliver` gets the decoded text (canonical for a file) and its source, and
/// returns an error to show, or nil when accepted.
private struct CodeImportPickers: ViewModifier {
    @Binding var showPhotos: Bool
    @Binding var showFile: Bool
    @Binding var busy: Bool
    @Binding var error: String?
    let deliver: (ScannedCode.Result, ImportSource?) -> String?

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showPhotos) {
                PhotoCodePicker { data, assetId in
                    showPhotos = false
                    guard let data, !data.isEmpty else { return }
                    busy = true
                    Task { @MainActor in
                        let text = await Task.detached { QrImageImport.decode(data) }.value
                        busy = false
                        guard let text else { error = ScannedCode.noQRInImage; return }
                        error = deliver(ScannedCode.parse(text), assetId.map { .photo(assetId: $0) })
                    }
                }
                .ignoresSafeArea()
            }
            .sheet(isPresented: $showFile) {
                CodeFilePicker { url in
                    showFile = false
                    guard let url else { return }
                    busy = true
                    Task { @MainActor in
                        let (r, deletable) = await Task.detached { CodeFileImport.read(url) }.value
                        busy = false
                        guard r != .invalid else { error = CodeTextImport.fileInvalidMessage; return }
                        error = deliver(r, deletable ? .file(url) : nil)
                    }
                }
                .ignoresSafeArea()
            }
    }
}

// MARK: - Form actions

/// "Scan QR code", "Choose from Photos", and "Import file" for a form.
/// `accept` returns an error for a result this form cannot use, or nil;
/// accepted results go to `onResult`. After a successful Photos or file
/// import the delete offer appears here.
struct QrScanActions: View {
    var enabled: Bool = true
    var prompt: String = "Point the camera at a Dispatcharr user QR code or an AerioTV setup code."
    var accept: (ScannedCode.Result) -> String? = acceptAnyKnownCode
    /// Onboarding Add Profiles: only "Choose from Photos" and "Import file" as small
    /// links; the Scan a QR code card opens the camera through scanTrigger (Android linksOnly).
    var linksOnly = false
    /// Bump to open the camera from outside (the onboarding Scan a QR code card).
    var scanTrigger = 0
    let onResult: (ScannedCode.Result) -> Void

    @State private var scanning = false
    @State private var showPhotos = false
    @State private var showFile = false
    @State private var busy = false
    @State private var error: String?
    @State private var pendingDelete: ImportSource?
    /// Delivered by the camera screen; handled once its cover is gone.
    @State private var fromScanner: (ScannedCode.Result, ImportSource?)?

    var body: some View {
        VStack(alignment: linksOnly ? .center : .leading, spacing: linksOnly ? 2 : 6) {
            if linksOnly {
                HStack(spacing: 8) {
                    linkButton("Choose from Photos") { error = nil; showPhotos = true }
                    linkButton("Import file") { error = nil; showFile = true }
                    if busy { ProgressView().controlSize(.small) }
                }
                .frame(maxWidth: .infinity)
            } else {
                HStack(spacing: 10) {
                    actionButton("Scan QR code", icon: "qrcode.viewfinder") { error = nil; scanning = true }
                    actionButton("Choose from Photos", icon: "photo.on.rectangle", loading: busy) { error = nil; showPhotos = true }
                }
                actionButton("Import file", icon: "doc.badge.arrow.up") { error = nil; showFile = true }
            }
            if let error {
                Text(error)
                    .scaledFont(.bodySmall)
                    .foregroundColor(.statusLive)
            }
        }
        .modifier(CodeImportPickers(showPhotos: $showPhotos, showFile: $showFile, busy: $busy, error: $error,
                                    deliver: { r, src in accepted(r, src) }))
        .onChange(of: scanTrigger) { _, n in if n > 0 { error = nil; scanning = true } }
        .fullScreenCover(isPresented: $scanning, onDismiss: {
            if let (r, src) = fromScanner { fromScanner = nil; finish(r, src) }
        }) {
            QrScanScreen(prompt: prompt, validate: accept) { r, src in
                fromScanner = (r, src)
                scanning = false
            } onCancel: { scanning = false }
        }
        .alert(pendingDelete?.isPhoto == true ? "Delete this image from Photos? It contains your sign-in code."
                                              : "Delete this file? It contains your sign-in code.",
               isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let s = pendingDelete { Task { await ImportSourceCleanup.delete(s) } }
                pendingDelete = nil
            }
            Button("Keep", role: .cancel) {
                ImportSourceCleanup.logOutcome(false)
                pendingDelete = nil
            }
        }
    }

    private func accepted(_ r: ScannedCode.Result, _ src: ImportSource?) -> String? {
        if let problem = accept(r) { return problem }
        finish(r, src)
        return nil
    }

    private func finish(_ r: ScannedCode.Result, _ src: ImportSource?) {
        debugLog("[SETUP-QR] code accepted kind=\(kind(r)) source=\(src == nil ? "camera-or-none" : (src!.isPhoto ? "photos" : "file"))")
        pendingDelete = src
        onResult(r)
    }

    private func kind(_ r: ScannedCode.Result) -> String {
        switch r { case .userKey: return "user"; case .setupLink: return "setup"; case .invalid: return "invalid" }
    }

    private func linkButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).scaledFont(.bodyMedium).foregroundColor(.accentPrimary).frame(minHeight: 40)
        }
        .buttonStyle(.plain)
        .disabled(!enabled || busy)
    }

    private func actionButton(_ title: String, icon: String, loading: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if loading { ProgressView().controlSize(.small) } else { Image(systemName: icon) }
                Text(title).scaledFont(.bodyMedium)
            }
            .foregroundColor(.accentPrimary)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(Color.accentPrimary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.accentPrimary.opacity(0.35), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!enabled || busy)
    }
}

// MARK: - Camera scanner

private let cameraRationale = "AerioTV uses the camera only to read QR codes."

/// Full-screen camera with a viewfinder, "Choose from Photos", "Import file",
/// and Cancel. The first code `validate` accepts ends the scan; a rejected
/// code shows its message and scanning goes on.
struct QrScanScreen: View {
    let prompt: String
    let validate: (ScannedCode.Result) -> String?
    let onResult: (ScannedCode.Result, ImportSource?) -> Void
    let onCancel: () -> Void

    @State private var granted = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    @State private var asked = false
    @State private var noCamera = AVCaptureDevice.default(for: .video) == nil
    @State private var error: String?
    @State private var busy = false
    @State private var showPhotos = false
    @State private var showFile = false
    @State private var done = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if granted && !noCamera {
                QrCameraView(onText: { deliver(ScannedCode.parse($0), nil) }, onNoCamera: { noCamera = true })
                    .ignoresSafeArea()
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.white.opacity(0.9), lineWidth: 3)
                    .frame(width: 260, height: 260)
            }
            VStack(spacing: 12) {
                Text(noCamera ? "No camera is available. Choose a QR code image from Photos instead."
                     : (granted ? prompt : "\(cameraRationale) You can still choose a QR code image from Photos."))
                    .scaledFont(.bodyLarge)
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .padding(12)
                    .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
                    .frame(maxWidth: 480)
                Spacer()
                if let error {
                    Text(error)
                        .scaledFont(.bodyMedium)
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .padding(12)
                        .background(Color.statusLive.opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
                        .frame(maxWidth: 480)
                }
                VStack(spacing: 10) {
                    if !granted && asked && !noCamera {
                        scannerButton("Allow Camera", filled: true) {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }
                    }
                    scannerButton("Choose from Photos", filled: true, loading: busy) { error = nil; showPhotos = true }
                    scannerButton("Import file", filled: true) { error = nil; showFile = true }
                    scannerButton("Cancel", filled: false, action: onCancel)
                }
                .frame(maxWidth: 480)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
        }
        .modifier(CodeImportPickers(showPhotos: $showPhotos, showFile: $showFile, busy: $busy, error: $error,
                                    deliver: { r, src in deliverChecked(r, src) }))
        .task {
            guard !granted, !noCamera else { return }
            granted = await AVCaptureDevice.requestAccess(for: .video)
            asked = true
        }
    }

    private func deliver(_ r: ScannedCode.Result, _ src: ImportSource?) {
        error = deliverChecked(r, src)
    }

    private func deliverChecked(_ r: ScannedCode.Result, _ src: ImportSource?) -> String? {
        guard !done else { return nil }
        if let problem = validate(r) { return problem }
        done = true
        onResult(r, src)
        return nil
    }

    private func scannerButton(_ title: String, filled: Bool, loading: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if loading { ProgressView().tint(.white) }
                Text(title).scaledFont(.bodyLarge.weight(.semibold))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(filled ? Color.accentPrimary : Color.clear, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(filled ? 0 : 0.7), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(busy && title != "Cancel")
    }
}

/// AVCaptureSession preview with QR metadata output (back camera, else front).
struct QrCameraView: UIViewRepresentable {
    let onText: (String) -> Void
    let onNoCamera: () -> Void

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        context.coordinator.attach(v, onNoCamera: onNoCamera)
        return v
    }

    func updateUIView(_ v: PreviewView, context: Context) { context.coordinator.onText = onText }

    static func dismantleUIView(_ v: PreviewView, coordinator: Coordinator) { coordinator.stop() }

    func makeCoordinator() -> Coordinator { Coordinator(onText: onText) }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        var onText: (String) -> Void
        private let session = AVCaptureSession()
        private let queue = DispatchQueue(label: "aerio.qr.camera")
        private var last: String?

        init(onText: @escaping (String) -> Void) { self.onText = onText }

        @MainActor func attach(_ v: PreviewView, onNoCamera: () -> Void) {
            let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
            guard let device, let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
                onNoCamera(); return
            }
            session.beginConfiguration()
            session.addInput(input)
            let out = AVCaptureMetadataOutput()
            guard session.canAddOutput(out) else { session.commitConfiguration(); onNoCamera(); return }
            session.addOutput(out)
            out.setMetadataObjectsDelegate(self, queue: .main)
            if out.availableMetadataObjectTypes.contains(.qr) { out.metadataObjectTypes = [.qr] }
            session.commitConfiguration()
            v.previewLayer.session = session
            v.previewLayer.videoGravity = .resizeAspectFill
            nonisolated(unsafe) let s = session
            queue.async { s.startRunning() }
        }

        func stop() {
            nonisolated(unsafe) let s = session
            queue.async { s.stopRunning() }
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard let text = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else { return }
            // Delivered on the main queue (setMetadataObjectsDelegate queue: .main).
            nonisolated(unsafe) let me = self
            MainActor.assumeIsolated {
                // The same rejected code repeats every frame; report it once.
                guard text != me.last else { return }
                me.last = text
                me.onText(text)
            }
        }
    }
}

// MARK: - Restore offer after a QR sign-in (Settings > Add Playlist)

let qrRestoreCopy = "Restore your favorites, progress, and settings from your server."

/// When the Dispatcharr playlist was added from a user QR and the server
/// already holds this user's AerioTV data, offer Dispatcharr Sync in one tap.
/// Shows nothing when there is no data or sync is already on.
struct QrRestoreOfferModifier: ViewModifier {
    let signIn: QrImportBus.SignIn?
    @State private var show = false
    @State private var busy = false

    func body(content: Content) -> some View {
        content
            .task(id: signIn?.id) {
                guard let signIn, !DispatcharrSyncManager.shared.isEnabled else { return }
                if await QrImportBus.serverHasData(signIn) { show = true }
            }
            .alert("Turn on Dispatcharr Sync?", isPresented: $show) {
                Button(busy ? "Turning On" : "Turn On") {
                    guard !busy else { return }
                    busy = true
                    Task { await Self.turnOn() }
                }
                Button("Not Now", role: .cancel) {}
            } message: {
                Text(qrRestoreCopy)
            }
    }

    @MainActor private static func turnOn() async {
        DispatcharrSyncManager.shared.setEnabled(true)
        debugLog("[DSYNC] enabled from add playlist QR restore")
        let ok = await DispatcharrSyncManager.shared.awaitFirstPull()
        debugLog("[DSYNC] add playlist QR restore first pull \(ok ? "done" : "not finished; continuing")")
    }
}
#endif
