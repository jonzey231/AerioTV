import SwiftUI
import SwiftData
import UniformTypeIdentifiers

// MARK: - M3U Import View
struct M3UImportView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var urlText: String = ""
    @State private var sourceMode: ImportSourceMode = .url
    @State private var isImporting = false
    @State private var showFilePicker = false
    @State private var importedFileURL: URL? = nil
    @State private var importedFileName: String = ""
    @State private var previewChannels: [M3UChannel] = []
    @State private var isPreviewing = false
    @State private var errorMessage: String? = nil
    @State private var importSuccess = false

    enum ImportSourceMode: String, CaseIterable {
        case url  = "URL"
        case file = "File"
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.appBackground.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 20) {
                        // Source mode toggle
                        sourceModeToggle

                        // Name field
                        AppTextField("Playlist Name", placeholder: "My IPTV Playlist",
                                     text: $name, icon: "list.bullet")

                        // URL or File input
                        if sourceMode == .url {
                            urlInputSection
                        } else {
                            filePickerSection
                        }

                        // Preview / Import
                        if !previewChannels.isEmpty {
                            previewSection
                        }

                        if let error = errorMessage {
                            errorBanner(error)
                        }

                        actionButtons

                        Spacer(minLength: 40)
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Import M3U Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(.textSecondary)
                }
            }
            .toolbarBackground(Color.appBackground, for: .navigationBar)
            .fileImporter(
                isPresented: $showFilePicker,
                allowedContentTypes: [.m3uType, .plainText, .data],
                allowsMultipleSelection: false
            ) { result in
                handleFileImport(result)
            }
        }
    }

    // MARK: - Source Mode Toggle
    private var sourceModeToggle: some View {
        HStack(spacing: 0) {
            ForEach(ImportSourceMode.allCases, id: \.self) { mode in
                Button {
                    withAnimation(.spring(response: 0.3)) { sourceMode = mode }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: mode == .url ? "link" : "doc.fill")
                            .font(.system(size: 13, weight: .semibold))
                        Text(mode.rawValue)
                            .font(.headlineSmall)
                    }
                    .foregroundColor(sourceMode == mode ? .white : .textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        sourceMode == mode
                            ? AnyView(LinearGradient.accentGradient)
                            : AnyView(Color.clear)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Color.elevatedBackground)
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    // MARK: - URL Input
    private var urlInputSection: some View {
        VStack(spacing: 12) {
            AppTextField(
                "Playlist URL",
                placeholder: "https://example.com/playlist.m3u",
                text: $urlText,
                icon: "link",
                keyboardType: .URL
            )
            Text("Supports .m3u and .m3u8 formats")
                .font(.labelSmall)
                .foregroundColor(.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - File Picker
    private var filePickerSection: some View {
        VStack(spacing: 12) {
            Button {
                showFilePicker = true
            } label: {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.accentPrimary.opacity(0.15))
                            .frame(width: 46, height: 46)
                        Image(systemName: importedFileURL != nil ? "checkmark.circle.fill" : "doc.badge.plus")
                            .font(.system(size: 20))
                            .foregroundColor(.accentPrimary)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(importedFileName.isEmpty ? "Choose M3U File" : importedFileName)
                            .font(.headlineSmall)
                            .foregroundColor(importedFileName.isEmpty ? .textSecondary : .textPrimary)
                            .lineLimit(1)
                        Text(importedFileURL != nil ? "Tap to change" : "Browse from Files")
                            .font(.labelSmall)
                            .foregroundColor(.textTertiary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.textTertiary)
                }
                .padding(14)
                .background(Color.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(importedFileURL != nil ? Color.accentPrimary.opacity(0.4) : Color.borderSubtle, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Preview Section
    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Preview (\(previewChannels.count) channels)")

            // Group breakdown
            let groups = Dictionary(grouping: previewChannels, by: { $0.groupTitle })
                .sorted { $0.key < $1.key }

            VStack(spacing: 6) {
                ForEach(groups.prefix(5), id: \.key) { group, channels in
                    HStack {
                        Text(group.isEmpty ? "Ungrouped" : group)
                            .font(.bodySmall)
                            .foregroundColor(.textPrimary)
                            .lineLimit(1)
                        Spacer()
                        Text("\(channels.count)")
                            .font(.labelMedium)
                            .foregroundColor(.accentPrimary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color.elevatedBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                if groups.count > 5 {
                    Text("+ \(groups.count - 5) more groups")
                        .font(.labelSmall)
                        .foregroundColor(.textTertiary)
                        .padding(.leading, 12)
                }
            }
        }
    }

    // MARK: - Error Banner
    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundColor(.statusLive)
            Text(message)
                .font(.bodySmall)
                .foregroundColor(.statusLive)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.statusLive.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Action Buttons
    private var actionButtons: some View {
        VStack(spacing: 12) {
            if previewChannels.isEmpty {
                PrimaryButton(
                    isPreviewing ? "Loading..." : "Preview Channels",
                    icon: "eye.fill",
                    isLoading: isPreviewing,
                    isDisabled: !canPreview
                ) {
                    Task { await loadPreview() }
                }
            } else {
                PrimaryButton(
                    importSuccess ? "Saved!" : "Save Playlist",
                    icon: importSuccess ? "checkmark.circle.fill" : "square.and.arrow.down.fill",
                    isDisabled: name.isEmpty
                ) {
                    savePlaylist()
                }

                SecondaryButton("Re-preview") {
                    previewChannels = []
                    Task { await loadPreview() }
                }
            }
        }
    }

    // MARK: - Logic
    private var canPreview: Bool {
        if sourceMode == .url { return !urlText.isEmpty }
        return importedFileURL != nil
    }

    private func loadPreview() async {
        isPreviewing = true
        errorMessage = nil

        do {
            if sourceMode == .url {
                guard let url = URL(string: urlText.trimmingCharacters(in: .whitespaces)) else {
                    throw APIError.invalidURL
                }
                previewChannels = try await M3UParser.fetchAndParse(url: url)
                if name.isEmpty {
                    name = url.lastPathComponent.replacingOccurrences(of: ".m3u8", with: "")
                                                .replacingOccurrences(of: ".m3u", with: "")
                }
            } else if let fileURL = importedFileURL {
                let content = try String(contentsOf: fileURL, encoding: .utf8)
                previewChannels = M3UParser.parse(content: content)
            }

            if previewChannels.isEmpty {
                errorMessage = "No channels found in this playlist. Check the format."
            }
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "Failed to load playlist: \(error.localizedDescription)"
        }

        isPreviewing = false
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            _ = url.startAccessingSecurityScopedResource()
            importedFileURL = url
            importedFileName = url.lastPathComponent
            if name.isEmpty {
                name = url.deletingPathExtension().lastPathComponent
            }
        case .failure(let error):
            errorMessage = "File access error: \(error.localizedDescription)"
        }
    }

    private func savePlaylist() {
        let playlist: M3UPlaylist
        if sourceMode == .url {
            playlist = M3UPlaylist(name: name, sourceType: .url, urlString: urlText)
        } else {
            playlist = M3UPlaylist(name: name, sourceType: .file, localFilename: importedFileName)
        }
        playlist.channelCount = previewChannels.count
        playlist.lastRefreshed = Date()
        modelContext.insert(playlist)
        try? modelContext.save()
        importSuccess = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { dismiss() }
    }
}

// MARK: - EPG Import View
struct EPGImportView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var urlText: String = ""
    @State private var sourceMode: M3UImportView.ImportSourceMode = .url
    @State private var isLoading = false
    @State private var showFilePicker = false
    @State private var importedFileURL: URL? = nil
    @State private var importedFileName: String = ""
    @State private var previewCount: Int? = nil
    @State private var errorMessage: String? = nil
    @State private var saveSuccess = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.appBackground.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 20) {
                        // Info card
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "info.circle.fill")
                                .foregroundColor(.accentSecondary)
                                .font(.system(size: 15))
                            Text("Import an XMLTV-formatted EPG guide to show programme schedules in the TV Guide.")
                                .font(.bodySmall)
                                .foregroundColor(.textSecondary)
                        }
                        .padding(14)
                        .background(Color.accentSecondary.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                        // Source mode toggle (reuse M3U's style)
                        sourceModeToggle

                        AppTextField("EPG Source Name", placeholder: "My EPG Guide",
                                     text: $name, icon: "calendar")

                        if sourceMode == .url {
                            AppTextField("EPG URL", placeholder: "https://example.com/epg.xml",
                                         text: $urlText, icon: "link", keyboardType: .URL)
                        } else {
                            filePickerButton
                        }

                        if let count = previewCount {
                            HStack(spacing: 10) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.statusOnline)
                                Text("Found \(count) programmes")
                                    .font(.bodyMedium)
                                    .foregroundColor(.statusOnline)
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.statusOnline.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }

                        if let error = errorMessage {
                            HStack(spacing: 10) {
                                Image(systemName: "exclamationmark.circle.fill")
                                    .foregroundColor(.statusLive)
                                Text(error)
                                    .font(.bodySmall)
                                    .foregroundColor(.statusLive)
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.statusLive.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }

                        // Buttons
                        VStack(spacing: 12) {
                            if previewCount == nil {
                                PrimaryButton(
                                    isLoading ? "Validating..." : "Validate Source",
                                    icon: "checkmark.shield.fill",
                                    isLoading: isLoading,
                                    isDisabled: !canValidate
                                ) {
                                    Task { await validateSource() }
                                }
                            } else {
                                PrimaryButton(
                                    saveSuccess ? "Saved!" : "Save EPG Source",
                                    icon: saveSuccess ? "checkmark.circle.fill" : "square.and.arrow.down.fill",
                                    isDisabled: name.isEmpty
                                ) {
                                    saveEPGSource()
                                }
                            }
                        }

                        Spacer(minLength: 40)
                    }
                    .padding(20)
                }
            }
            .navigationTitle("Import EPG Guide")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(.textSecondary)
                }
            }
            .toolbarBackground(Color.appBackground, for: .navigationBar)
            .fileImporter(
                isPresented: $showFilePicker,
                allowedContentTypes: [UTType.xml, .plainText, .data],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    _ = url.startAccessingSecurityScopedResource()
                    importedFileURL = url
                    importedFileName = url.lastPathComponent
                    if name.isEmpty { name = url.deletingPathExtension().lastPathComponent }
                case .failure(let error):
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private var sourceModeToggle: some View {
        HStack(spacing: 0) {
            ForEach(M3UImportView.ImportSourceMode.allCases, id: \.self) { mode in
                Button {
                    withAnimation(.spring(response: 0.3)) { sourceMode = mode }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: mode == .url ? "link" : "doc.fill")
                            .font(.system(size: 13, weight: .semibold))
                        Text(mode.rawValue)
                            .font(.headlineSmall)
                    }
                    .foregroundColor(sourceMode == mode ? .white : .textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        sourceMode == mode
                            ? AnyView(LinearGradient.accentGradient)
                            : AnyView(Color.clear)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Color.elevatedBackground)
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    private var filePickerButton: some View {
        Button { showFilePicker = true } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.accentSecondary.opacity(0.15))
                        .frame(width: 46, height: 46)
                    Image(systemName: importedFileURL != nil ? "checkmark.circle.fill" : "doc.badge.plus")
                        .font(.system(size: 20))
                        .foregroundColor(.accentSecondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(importedFileName.isEmpty ? "Choose XMLTV File" : importedFileName)
                        .font(.headlineSmall)
                        .foregroundColor(importedFileName.isEmpty ? .textSecondary : .textPrimary)
                        .lineLimit(1)
                    Text(importedFileURL != nil ? "Tap to change" : ".xml or .xmltv files")
                        .font(.labelSmall)
                        .foregroundColor(.textTertiary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.textTertiary)
            }
            .padding(14)
            .background(Color.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(importedFileURL != nil ? Color.accentSecondary.opacity(0.4) : Color.borderSubtle, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var canValidate: Bool {
        sourceMode == .url ? !urlText.isEmpty : importedFileURL != nil
    }

    private func validateSource() async {
        isLoading = true
        errorMessage = nil
        do {
            var programmes: [ParsedEPGProgram] = []
            if sourceMode == .url {
                guard let url = URL(string: urlText.trimmingCharacters(in: .whitespaces)) else {
                    throw APIError.invalidURL
                }
                programmes = try await XMLTVParser.fetchAndParse(url: url)
            } else if let fileURL = importedFileURL {
                let data = try Data(contentsOf: fileURL)
                programmes = XMLTVParser.parse(data: data)
            }
            previewCount = programmes.count
            if programmes.isEmpty {
                errorMessage = "No programme data found. Make sure this is a valid XMLTV file."
            }
        } catch let error as APIError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = "Error: \(error.localizedDescription)"
        }
        isLoading = false
    }

    private func saveEPGSource() {
        let source: EPGSource
        if sourceMode == .url {
            source = EPGSource(name: name, sourceType: .url, urlString: urlText)
        } else {
            source = EPGSource(name: name, sourceType: .file, localFilename: importedFileName)
        }
        source.programCount = previewCount ?? 0
        source.lastRefreshed = Date()
        modelContext.insert(source)
        try? modelContext.save()
        saveSuccess = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { dismiss() }
    }
}

// MARK: - UTType Extension for M3U
extension UTType {
    static let m3uType = UTType(importedAs: "public.m3u-playlist", conformingTo: .plainText)
}
