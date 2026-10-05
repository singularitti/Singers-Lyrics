#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers

struct MobileMusicLinkSheet: View {
    let metadataLookup: any TrackMetadataLookingUp
    var existingURL: URL?
    let onSave: (URL, TrackMetadata) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var isLookingUp = false
    @State private var lookupTask: Task<Void, Never>?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Paste song link", text: $link, axis: .vertical)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(isLookingUp)
                        .accessibilityLabel("Apple Music song link")
                        .accessibilityIdentifier("appleMusicLinkField")
                } header: {
                    Text("Apple Music Song Link")
                } footer: {
                    Text("In Apple Music, choose Share Song, then Copy Link. Paste the link here to load the song’s title and singer.")
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
                if isLookingUp {
                    Section { ProgressView("Looking up song…") }
                }
            }
            .navigationTitle(existingURL == nil ? "Add Music" : "Change Music Link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { lookupTask?.cancel(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(existingURL == nil ? "Add" : "Save") { lookUp() }
                        .disabled(isLookingUp || link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { if let existingURL { link = existingURL.absoluteString } }
            .onDisappear { lookupTask?.cancel() }
        }
    }

    private func lookUp() {
        guard let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)),
              ITunesTrackMetadataService.trackID(from: url) != nil else {
            error = TrackMetadataError.unsupportedURL.localizedDescription
            return
        }
        isLookingUp = true
        error = nil
        lookupTask = Task {
            defer { isLookingUp = false }
            do {
                guard let metadata = try await metadataLookup.lookup(url: url) else {
                    throw TrackMetadataError.trackNotFound
                }
                try Task.checkCancellation()
                onSave(url, metadata)
                dismiss()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
        }
    }
}

struct MobileSongDetailsSheet: View {
    @Binding var song: Song
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var artist = ""
    @State private var album = ""
    @State private var tags = ""
    @State private var favorite = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Song") {
                    TextField("Title", text: $title)
                    TextField("Singer", text: $artist)
                    TextField("Album", text: $album)
                    Toggle("Favorite", isOn: $favorite)
                }
                Section {
                    TextField("Tags, separated by commas", text: $tags, axis: .vertical)
                } header: { Text("Tags") }
                footer: { Text("These details describe your lyrics. Changing them preserves the linked Apple Music track.") }
            }
            .navigationTitle("Song Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        song.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
                        song.artist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
                        song.album = album.trimmingCharacters(in: .whitespacesAndNewlines)
                        song.tags = Song.normalizedTags(tags.components(separatedBy: ","))
                        song.isFavorite = favorite
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                title = song.title
                artist = song.artist
                album = song.album
                tags = song.tags.joined(separator: ", ")
                favorite = song.isFavorite
            }
        }
    }
}

struct MobileLyricsImportSheet: View {
    let onImport: ([LyricLine]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var source = ""
    @State private var showsImporter = false
    @State private var confirmsReplacement = false
    @State private var error: String?

    private var lines: [LyricLine] { LRCParser.parse(source) }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("Paste one lyric per line, with optional LRC timestamps such as [00:12.34].")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextEditor(text: $source)
                    .font(.body.monospaced())
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel("Lyrics to import")
                HStack {
                    Button("Choose File", systemImage: "folder") { showsImporter = true }
                    Spacer()
                    Text("\(lines.count) lines · \(lines.count { $0.timestampSeconds != nil }) timed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(minHeight: 44)
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            }
            .padding()
            .navigationTitle("Import Lyrics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Replace") { confirmsReplacement = true }
                        .disabled(source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || lines.isEmpty)
                }
            }
            .confirmationDialog("Replace all lyrics and timing for this song?", isPresented: $confirmsReplacement,
                                titleVisibility: .visible) {
                Button("Replace Lyrics", role: .destructive) {
                    onImport(lines)
                    dismiss()
                }
            } message: {
                Text("The imported text will replace the song’s existing formatting, annotations, and timestamps. Attached recordings will move to Trash.")
            }
            .fileImporter(isPresented: $showsImporter, allowedContentTypes: [.plainText, .lrcLyrics]) { result in
                do {
                    let url = try result.get()
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    source = try String(contentsOf: url, encoding: .utf8)
                } catch { self.error = error.localizedDescription }
            }
        }
    }
}
#endif
