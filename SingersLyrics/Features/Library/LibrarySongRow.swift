import SwiftUI

struct LibrarySongRow: View {
    let song: Song
    let showsArtwork: Bool
    let artworkSize: LibraryArtworkSize

    private var album: String { song.album.isEmpty ? "Unknown Album" : song.album }
    private var title: String { song.title.isEmpty ? "Untitled" : song.title }
    private var artist: String { song.artist.isEmpty ? "Unknown Singer" : song.artist }

    var body: some View {
        #if os(macOS)
        LibraryRowScrollView {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        #else
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
        #endif
    }

    private var content: some View {
        HStack(alignment: artworkSize == .medium ? .top : .center, spacing: 12) {
            if showsArtwork {
                SongArtworkView(appleMusicURL: song.appleMusicURL, size: artworkSize.dimension)
            }

            VStack(alignment: .leading, spacing: artworkSize == .small ? 3 : 5) {
                HStack(spacing: 5) {
                    Text(album)
                        .font(albumFont)
                    if song.isFavorite {
                        Image(systemName: "heart.fill")
                            #if os(macOS)
                            .font(.system(size: 9))
                            #else
                            .font(.caption2)
                            #endif
                            .accessibilityLabel("Favorite")
                    }
                }
                .foregroundStyle(.secondary)

                Text(title)
                    .font(titleFont)
                    #if os(iOS)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    #endif

                HStack(spacing: 4) {
                    Text(artist)
                    SongReleaseYearView(appleMusicURL: song.appleMusicURL)
                        #if os(iOS)
                        .fixedSize()
                        #endif
                }
                .font(artistFont)
                .foregroundStyle(.secondary)

                if artworkSize == .large && !song.tags.isEmpty {
                    tagList
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Tags: \(song.tags.joined(separator: ", "))")
                }
            }
            .lineLimit(1)
            #if os(macOS)
            .fixedSize(horizontal: true, vertical: true)
            #endif
        }
        .frame(minHeight: showsArtwork ? artworkSize.dimension : 0, alignment: .leading)
    }

    @ViewBuilder
    private var tagList: some View {
        #if os(iOS)
        ViewThatFits(in: .horizontal) {
            tagChips
            Text(song.tags.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        #else
        tagChips
        #endif
    }

    private var tagChips: some View {
        HStack(spacing: 5) {
            ForEach(song.tags, id: \.self) { tag in
                TagChip(name: tag)
            }
        }
    }

    private var albumFont: Font {
        #if os(macOS)
        .system(size: 11, weight: .medium)
        #else
        .caption.weight(.medium)
        #endif
    }

    private var titleFont: Font {
        #if os(macOS)
        .system(size: 17, weight: .semibold)
        #else
        .headline
        #endif
    }

    private var artistFont: Font {
        #if os(macOS)
        .system(size: 12)
        #else
        .subheadline
        #endif
    }
}
