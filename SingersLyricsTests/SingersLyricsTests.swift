import AppKit
import XCTest
@testable import SingersLyrics

final class SingersLyricsTests: XCTestCase {
    func testLibraryJSONRoundTripPreservesStyledLyrics() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let style = TextStyle(
            fontFamily: "Avenir Next",
            foregroundColor: RGBAColor(red: 12, green: 34, blue: 56, alpha: 200),
            bold: true,
            italic: false,
            underline: true
        )
        let song = Song(
            id: UUID(),
            title: "Example",
            artist: "Singer",
            appleMusicURL: URL(string: "https://music.apple.com/us/song/example/123"),
            linkedTrackMetadata: TrackMetadata(
                title: "Music Example",
                artist: "Music Singer"
            ),
            lines: [
                LyricLine(
                    id: UUID(),
                    annotation: "pronunciation",
                    lyric: StyledText(runs: [TextRun(text: "A lyric", style: style)]),
                    timestampSeconds: 12.345
                ),
            ],
            createdAt: now,
            updatedAt: now
        )
        let document = LibraryDocument(songs: [song])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(document)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        XCTAssertEqual(try decoder.decode(LibraryDocument.self, from: data), document)
    }

    func testSongBundleRoundTripPreservesEverySongField() throws {
        let createdAt = Date(timeIntervalSince1970: 1_800_000_000.123456)
        let updatedAt = Date(timeIntervalSince1970: 1_800_000_123.987654)
        let styledLyric = StyledText(runs: [
            TextRun(
                text: "Rich ",
                style: TextStyle(
                    fontFamily: "Avenir Next",
                    foregroundColor: RGBAColor(red: 12, green: 34, blue: 56, alpha: 200),
                    bold: true,
                    italic: false,
                    underline: true
                )
            ),
            TextRun(
                text: "lyric",
                style: TextStyle(
                    fontFamily: nil,
                    foregroundColor: nil,
                    bold: false,
                    italic: true,
                    underline: false
                )
            ),
        ])
        let songs = [
            Song(
                id: UUID(),
                title: "First Song",
                artist: "First Singer",
                appleMusicURL: URL(string: "https://music.apple.com/us/song/example/123"),
                linkedTrackMetadata: TrackMetadata(
                    title: "Linked Title",
                    artist: "Linked Singer"
                ),
                lines: [
                    LyricLine(
                        id: UUID(),
                        annotation: "complete annotation / pronunciation",
                        lyric: styledLyric,
                        timestampSeconds: 12.345678
                    ),
                    LyricLine(
                        id: UUID(),
                        annotation: "",
                        lyric: .plain("Untimed line"),
                        timestampSeconds: nil
                    ),
                ],
                createdAt: createdAt,
                updatedAt: updatedAt
            ),
            Song(
                id: UUID(),
                title: "Second Song",
                artist: "",
                appleMusicURL: nil,
                lines: [],
                createdAt: createdAt,
                updatedAt: updatedAt
            ),
        ]
        let original = SongBundle(songs: songs)

        let data = try SongBundleCodec.encode(original)
        let source = try XCTUnwrap(String(data: data, encoding: .utf8))
        let restored = try SongBundleCodec.decode(data)

        XCTAssertTrue(source.contains("\n"), "The bundle should remain human-readable JSON")
        XCTAssertTrue(source.contains("\"format\" : \"app.singerslyrics.song-bundle\""))
        XCTAssertTrue(source.contains("\"annotation\" : \"complete annotation / pronunciation\""))
        XCTAssertEqual(restored, original)
    }

    func testSongBundleRejectsUnsupportedVersionsAndDuplicateIdentities() throws {
        let song = Song.blank(now: Date(timeIntervalSince1970: 1_800_000_000))
        let futureData = try SongBundleCodec.encode(
            SongBundle(formatVersion: SongBundle.currentFormatVersion + 1, songs: [song])
        )
        XCTAssertThrowsError(try SongBundleCodec.decode(futureData)) { error in
            XCTAssertEqual(
                error as? SongBundleError,
                .unsupportedVersion(SongBundle.currentFormatVersion + 1)
            )
        }

        let duplicateData = try SongBundleCodec.encode(SongBundle(songs: [song, song]))
        XCTAssertThrowsError(try SongBundleCodec.decode(duplicateData)) { error in
            XCTAssertEqual(error as? SongBundleError, .duplicateSongIDs)
        }
    }

    func testStyledTextNormalizesAndSplitsOnUTF16Boundaries() {
        let style = TextStyle.plain
        let value = StyledText(runs: [
            TextRun(text: "A🎵", style: style),
            TextRun(text: "BC", style: style),
        ])

        XCTAssertEqual(value.normalized().runs.count, 1)
        let split = value.split(atUTF16Offset: 3)
        XCTAssertEqual(split.before.plainText, "A🎵")
        XCTAssertEqual(split.after.plainText, "BC")
    }

    func testAttributedTextRoundTripPreservesSupportedFormatting() {
        let original = StyledText(runs: [
            TextRun(
                text: "Formatted",
                style: TextStyle(
                    fontFamily: "Helvetica Neue",
                    foregroundColor: RGBAColor(red: 255, green: 55, blue: 95),
                    bold: true,
                    italic: true,
                    underline: true
                )
            ),
        ])

        let attributed = AttributedTextCodec.makeAttributedString(from: original)
        let restored = AttributedTextCodec.makeStyledText(from: attributed)

        XCTAssertEqual(restored.plainText, original.plainText)
        XCTAssertTrue(restored.runs.first?.style.bold == true)
        XCTAssertTrue(restored.runs.first?.style.italic == true)
        XCTAssertTrue(restored.runs.first?.style.underline == true)
        XCTAssertEqual(restored.runs.first?.style.foregroundColor, original.runs.first?.style.foregroundColor)
    }

    @MainActor
    func testFormattingContextPersistsAttributeOnlyToolbarChanges() throws {
        let textView = NSTextView()
        textView.textStorage?.setAttributedString(
            AttributedTextCodec.makeAttributedString(from: .plain("Format me"))
        )
        textView.setSelectedRange(NSRange(location: 0, length: textView.string.utf16.count))

        var persisted: StyledText?
        let context = RichTextEditingContext()
        context.attach(textView) {
            persisted = AttributedTextCodec.makeStyledText(from: textView.attributedString())
        }
        context.detach(textView)

        context.toggleBold()
        context.toggleItalic()
        context.toggleUnderline()
        let customColor = RGBAColor(red: 19, green: 87, blue: 203, alpha: 171)
        context.applyColor(customColor)

        let style = try XCTUnwrap(persisted?.runs.first?.style)
        XCTAssertTrue(style.bold)
        XCTAssertTrue(style.italic)
        XCTAssertTrue(style.underline)
        XCTAssertEqual(style.foregroundColor, customColor)
        XCTAssertEqual(context.selectedTextColor, customColor)
    }

    @MainActor
    func testChineseFallbackTextFormatsAndPersistsWithoutPinningItsResolvedFont() throws {
        let textView = NSTextView()
        textView.textStorage?.setAttributedString(
            AttributedTextCodec.makeAttributedString(from: .plain("中文歌词"))
        )
        textView.setSelectedRange(NSRange(location: 0, length: textView.string.utf16.count))

        var persisted: StyledText?
        let context = RichTextEditingContext()
        context.attach(textView) {
            persisted = AttributedTextCodec.makeStyledText(from: textView.attributedString())
        }
        context.detach(textView)

        context.toggleBold()
        context.toggleUnderline()
        context.applyColor(TextColorPalette.choices[4].storedColor)

        let style = try XCTUnwrap(persisted?.runs.first?.style)
        XCTAssertTrue(style.bold)
        XCTAssertTrue(style.underline)
        XCTAssertEqual(style.foregroundColor, TextColorPalette.choices[4].storedColor)
        XCTAssertNil(style.fontFamily)

        let displayedFont = try XCTUnwrap(
            textView.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        )
        XCTAssertTrue(NSFontManager.shared.traits(of: displayedFont).contains(.boldFontMask))
    }

    @MainActor
    func testChineseFallbackTextWarnsWhenItalicFaceIsUnavailable() {
        let textView = NSTextView()
        textView.textStorage?.setAttributedString(
            AttributedTextCodec.makeAttributedString(from: .plain("中文歌词"))
        )
        textView.setSelectedRange(NSRange(location: 0, length: textView.string.utf16.count))
        let context = RichTextEditingContext()
        context.attach(textView)
        context.detach(textView)

        context.toggleItalic()

        XCTAssertEqual(context.warning?.traitName, "Italic")
        XCTAssertFalse(
            AttributedTextCodec.makeStyledText(from: textView.attributedString())
                .runs.contains { $0.style.italic }
        )
    }

    func testFallbackFontDisplaysWithoutBecomingExplicitFormatting() throws {
        let attributed = AttributedTextCodec.makeAttributedString(
            from: .plain("Fallback"),
            fallbackFontFamily: "Helvetica Neue"
        )
        let font = try XCTUnwrap(
            attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        )

        XCTAssertEqual(font.familyName, "Helvetica Neue")
        XCTAssertNil(
            AttributedTextCodec.makeStyledText(from: attributed)
                .runs.first?.style.fontFamily
        )
    }

    @MainActor
    func testUnsupportedFontTraitWarnsWithoutChangingSelectedText() throws {
        let fontManager = NSFontManager.shared
        let font = try XCTUnwrap(
            fontManager.font(
                withFamily: "STKaiti",
                traits: [],
                weight: 5,
                size: 17
            )
        )
        XCTAssertFalse(
            fontManager.traits(
                of: fontManager.convert(font, toHaveTrait: .italicFontMask)
            ).contains(.italicFontMask)
        )

        let textView = NSTextView()
        textView.textStorage?.setAttributedString(
            NSAttributedString(string: "中文", attributes: [.font: font])
        )
        textView.setSelectedRange(NSRange(location: 0, length: textView.string.utf16.count))
        let context = RichTextEditingContext()
        context.attach(textView)

        context.toggleItalic()

        XCTAssertEqual(context.warning?.traitName, "Italic")
        XCTAssertEqual(context.warning?.fontFamily, "STKaiti")
        let resultingFont = try XCTUnwrap(
            textView.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        )
        XCTAssertEqual(resultingFont, font)
        XCTAssertFalse(fontManager.traits(of: resultingFont).contains(.italicFontMask))
    }

    func testDefaultAndCuratedColorsRoundTripWithoutBecomingAppearanceColors() {
        let defaultText = StyledText.plain("Adaptive")
        let defaultAttributed = AttributedTextCodec.makeAttributedString(from: defaultText)
        XCTAssertNotNil(defaultAttributed.attribute(.foregroundColor, at: 0, effectiveRange: nil))
        XCTAssertNil(
            AttributedTextCodec.makeStyledText(from: defaultAttributed)
                .runs.first?.style.foregroundColor
        )

        let choice = TextColorPalette.choices[0].storedColor
        let colored = StyledText(runs: [
            TextRun(
                text: "Colored",
                style: TextStyle(
                    fontFamily: nil,
                    foregroundColor: choice,
                    bold: false,
                    italic: false,
                    underline: false
                )
            ),
        ])
        XCTAssertEqual(
            AttributedTextCodec.makeStyledText(
                from: AttributedTextCodec.makeAttributedString(from: colored)
            ).runs.first?.style.foregroundColor,
            choice
        )
    }

    func testLRCParserHandlesFractionsMetadataAndPlainLines() {
        let source = """
        [ti:Example]
        [ar:Singer]
        [00:01] First
        [00:02.5] Second
        [01:03.045] Third
        Plain fourth
        """
        let lines = LRCParser.parse(source)

        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(lines[0].timestampSeconds ?? -1, 1, accuracy: 0.0001)
        XCTAssertEqual(lines[1].timestampSeconds ?? -1, 2.5, accuracy: 0.0001)
        XCTAssertEqual(lines[2].timestampSeconds ?? -1, 63.045, accuracy: 0.0001)
        XCTAssertNil(lines[3].timestampSeconds)
        XCTAssertEqual(lines.map(\.lyric.plainText), ["First", "Second", "Third", "Plain fourth"])
    }

    func testLRCParserUsesFirstOfMultipleTimestampsAndRemovesTags() {
        let lines = LRCParser.parse("[00:01.2][00:02.3] Repeated")
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].timestampSeconds ?? -1, 1.2, accuracy: 0.0001)
        XCTAssertEqual(lines[0].lyric.plainText, "Repeated")
    }

    func testLRCExporterWritesMetadataTimedLinesAndPlainLines() {
        let song = Song(
            id: UUID(),
            title: "Example\nSong",
            artist: "Singer",
            appleMusicURL: nil,
            lines: [
                LyricLine(
                    id: UUID(),
                    annotation: "ignored by LRC",
                    lyric: .plain("First"),
                    timestampSeconds: 1.234
                ),
                LyricLine(
                    id: UUID(),
                    annotation: "",
                    lyric: .plain("Minute boundary"),
                    timestampSeconds: 59.999
                ),
                LyricLine(
                    id: UUID(),
                    annotation: "",
                    lyric: .plain("Plain line"),
                    timestampSeconds: nil
                ),
            ],
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(
            LRCExporter.render(song: song),
            """
            [ti:Example Song]
            [ar:Singer]

            [00:01.23]First
            [01:00.00]Minute boundary
            Plain line

            """
        )
    }

    func testProvidedLRCFixtureParsesAllTimedUnicodeLines() throws {
        let fixtureURL = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "provided-lyrics", withExtension: "lrc")
        )
        let source = try String(contentsOf: fixtureURL, encoding: .utf8)
        let lines = LRCParser.parse(source)

        XCTAssertEqual(lines.count, 41)
        XCTAssertEqual(lines.first?.timestampSeconds ?? -1, 0.99, accuracy: 0.0001)
        XCTAssertEqual(lines.last?.timestampSeconds ?? -1, 201.65, accuracy: 0.0001)
        XCTAssertEqual(lines.first?.lyric.plainText, "一个人眺望碧海和蓝天")
        XCTAssertEqual(lines.last?.lyric.plainText, "你会闻到幸福晴朗的芬芳")
        XCTAssertTrue(lines.allSatisfy { $0.timestampSeconds != nil })
    }

    func testTrackIDExtractionValidatesMusicURLs() {
        XCTAssertEqual(
            ITunesTrackMetadataService.trackID(
                from: URL(string: "https://music.apple.com/us/album/example/111?i=222")!
            ),
            "222"
        )
        XCTAssertEqual(
            ITunesTrackMetadataService.trackID(
                from: URL(string: "https://music.apple.com/us/song/example/333")!
            ),
            "333"
        )
        XCTAssertEqual(
            ITunesTrackMetadataService.trackID(
                from: URL(
                    string: "https://geo.music.apple.com/us/album/_/1071506928?i=1071506936&ls=1"
                )!
            ),
            "1071506936"
        )
        XCTAssertNil(ITunesTrackMetadataService.trackID(from: URL(string: "http://music.apple.com/song/333")!))
        XCTAssertNil(ITunesTrackMetadataService.trackID(from: URL(string: "https://example.com/song/333")!))
    }

    func testMetadataLookupUsesInjectedURLSession() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://itunes.apple.com/lookup?id=222")
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            let data = Data(
                #"{"results":[{"trackName":"Mock Song","artistName":"Mock Singer"}]}"#.utf8
            )
            return (response, data)
        }
        defer {
            MockURLProtocol.requestHandler = nil
            session.invalidateAndCancel()
        }

        let service = ITunesTrackMetadataService(session: session)
        let metadata = try await service.lookup(
            url: URL(string: "https://music.apple.com/us/album/example/111?i=222")!
        )

        XCTAssertEqual(metadata, TrackMetadata(title: "Mock Song", artist: "Mock Singer"))
    }

    func testSongSortingModes() {
        let older = Date(timeIntervalSince1970: 100)
        let newer = Date(timeIntervalSince1970: 200)
        var beta = Song.blank(now: older)
        beta.title = "Beta"
        beta.artist = "Alpha Singer"
        beta.updatedAt = newer
        var alpha = Song.blank(now: newer)
        alpha.title = "Alpha"
        alpha.artist = "Beta Singer"
        alpha.updatedAt = older

        XCTAssertEqual(SongSortMode.title.sorted([beta, alpha]).map(\.id), [alpha.id, beta.id])
        XCTAssertEqual(SongSortMode.artist.sorted([beta, alpha]).map(\.id), [beta.id, alpha.id])
        XCTAssertEqual(SongSortMode.added.sorted([beta, alpha]).map(\.id), [alpha.id, beta.id])
        XCTAssertEqual(SongSortMode.edited.sorted([beta, alpha]).map(\.id), [beta.id, alpha.id])
    }

    func testPlayerMetadataTypographyTracksTheLyricScaleAcrossTheFullRange() {
        let minimumLyricSize = 28.0
        let maximumLyricSize = 72.0
        let expectedRatio = CGFloat(maximumLyricSize / minimumLyricSize)

        XCTAssertEqual(
            PlayerTypography.titleSize(for: maximumLyricSize)
                / PlayerTypography.titleSize(for: minimumLyricSize),
            expectedRatio,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            PlayerTypography.artistSize(for: maximumLyricSize)
                / PlayerTypography.artistSize(for: minimumLyricSize),
            expectedRatio,
            accuracy: 0.0001
        )
        XCTAssertEqual(PlayerTypography.titleSize(for: minimumLyricSize), 37.8, accuracy: 0.0001)
        XCTAssertEqual(PlayerTypography.artistSize(for: minimumLyricSize), 20.16, accuracy: 0.0001)
    }

    func testTimingUtilitiesClampShiftAndChooseActiveLine() {
        var lines = [LyricLine.blank(text: "A"), .blank(text: "B"), .blank(text: "C")]
        lines[0].timestampSeconds = 1
        lines[2].timestampSeconds = 4

        XCTAssertEqual(TimingUtilities.timestamp(forLineAt: 1, in: lines), 1)
        XCTAssertEqual(TimingUtilities.activeLineIndex(in: lines, position: 3.9), 2)
        XCTAssertEqual(TimingUtilities.shifted(0.05, by: -0.1), 0)
        XCTAssertNil(TimingUtilities.shifted(nil, by: 1))
        XCTAssertEqual(TimingUtilities.shiftedByPoints(1, points: 25), 1.25)
        XCTAssertEqual(TimingUtilities.shiftedByPoints(nil, points: -25), 0)
    }

    func testJSONStoreStartsEmptyAndWritesAtomically() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "SingersLyricsTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "library-v1.json")
        let store = JSONLibraryStore(fileURL: file)

        let initiallyLoaded = try await store.load()
        XCTAssertEqual(initiallyLoaded, LibraryDocument())
        let preciseDate = Date(timeIntervalSince1970: 1_800_000_000.123_456_7)
        let expected = LibraryDocument(songs: [.blank(now: preciseDate)])
        try await store.save(expected)
        let reloaded = try await store.load()
        XCTAssertEqual(reloaded, expected)

        let encoded = try String(contentsOf: file, encoding: .utf8)
        XCTAssertNotNil(encoded.range(of: #"\.\d{9}Z"#, options: .regularExpression))

        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(names, ["library-v1.json"])
    }

    func testJSONStoreDoesNotOverwriteCorruptLibrary() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "SingersLyricsTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "library-v1.json")
        let invalid = Data("not json".utf8)
        try invalid.write(to: file)
        let store = JSONLibraryStore(fileURL: file)

        do {
            _ = try await store.load()
            XCTFail("Expected corrupt library error")
        } catch let error as LibraryStoreError {
            guard case .corruptLibrary = error else {
                return XCTFail("Unexpected library error: \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: file), invalid)
    }

    func testJSONStoreRejectsUnsupportedSchemaWithoutChangingFile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "SingersLyricsTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "library-v1.json")
        let unsupported = Data(#"{"schemaVersion":2,"songs":[]}"#.utf8)
        try unsupported.write(to: file)
        let store = JSONLibraryStore(fileURL: file)

        do {
            _ = try await store.load()
            XCTFail("Expected unsupported schema error")
        } catch let error as LibraryStoreError {
            XCTAssertEqual(error, .unsupportedSchema(2))
        }
        XCTAssertEqual(try Data(contentsOf: file), unsupported)
    }

    @MainActor
    func testAppModelDisablesAutosaveAfterCorruptLoad() async {
        let store = FailingLibraryStore()
        let model = AppModel(store: store)

        await model.load()
        XCTAssertTrue(model.autosaveDisabled)
        XCTAssertNotNil(model.storageIssue)
        model.createSong(
            appleMusicURL: URL(string: "https://music.apple.com/us/song/test/1")!,
            metadata: TrackMetadata(title: "Test", artist: "Singer")
        )
        await model.flush()

        let saveCount = await store.savedDocumentCount()
        XCTAssertEqual(saveCount, 0)
    }

    @MainActor
    func testAppModelCreatesEditsAndPersistsOneAuthoritativeSong() async throws {
        let store = InMemoryLibraryStore()
        let model = AppModel(store: store)
        await model.load()
        var song = model.createSong(
            appleMusicURL: URL(string: "https://music.apple.com/us/song/test/1")!,
            metadata: TrackMetadata(title: "Test", artist: "Singer")
        )
        song.title = "Changed"
        song.lines[0].lyric = .plain("Line")
        model.replaceSong(song)
        await model.flush()

        let saved = try await store.load()
        XCTAssertEqual(saved.songs.count, 1)
        XCTAssertEqual(saved.songs[0].title, "Changed")
        XCTAssertEqual(
            saved.songs[0].linkedTrackMetadata,
            TrackMetadata(title: "Test", artist: "Singer")
        )
        XCTAssertEqual(saved.songs[0].lines[0].lyric.plainText, "Line")
    }

    @MainActor
    func testEditingLegacyDisplayMetadataPreservesTheOriginalMusicMatch() async throws {
        var legacySong = Song.blank()
        legacySong.title = "Music Title"
        legacySong.artist = "Music Singer"
        legacySong.appleMusicURL = URL(string: "https://music.apple.com/us/song/test/1")!
        let model = AppModel(
            store: InMemoryLibraryStore(document: LibraryDocument(songs: [legacySong]))
        )
        await model.load()

        var editedSong = legacySong
        editedSong.title = "Custom Title"
        editedSong.artist = "Custom Singer"
        model.replaceSong(editedSong)

        let storedSong = try XCTUnwrap(model.song(withID: legacySong.id))
        XCTAssertEqual(storedSong.title, "Custom Title")
        XCTAssertEqual(storedSong.artist, "Custom Singer")
        XCTAssertEqual(
            storedSong.linkedTrackMetadata,
            TrackMetadata(title: "Music Title", artist: "Music Singer")
        )
    }

    @MainActor
    func testLegacyMetadataBackfillRepairsAnAlreadyCustomizedSong() async throws {
        var legacySong = Song.blank()
        legacySong.title = "Existing Custom Title"
        legacySong.artist = "Existing Custom Singer"
        legacySong.appleMusicURL = URL(string: "https://music.apple.com/us/song/test/111")!
        let model = AppModel(
            store: InMemoryLibraryStore(document: LibraryDocument(songs: [legacySong]))
        )
        await model.load()

        await model.backfillLinkedTrackMetadata(using: UITestTrackMetadataService())

        let storedSong = try XCTUnwrap(model.song(withID: legacySong.id))
        XCTAssertEqual(storedSong.title, "Existing Custom Title")
        XCTAssertEqual(storedSong.artist, "Existing Custom Singer")
        XCTAssertEqual(
            storedSong.linkedTrackMetadata,
            TrackMetadata(title: "Alpha", artist: "First Singer")
        )
    }

    @MainActor
    func testChangingAppleMusicLinkPreservesCustomDisplayMetadata() async throws {
        let model = AppModel(store: InMemoryLibraryStore())
        await model.load()
        var song = model.createSong(
            appleMusicURL: URL(string: "https://music.apple.com/us/song/old/1")!,
            metadata: TrackMetadata(title: "Old Music Title", artist: "Old Music Singer")
        )
        song.title = "Custom Title"
        song.artist = "Custom Singer"
        model.replaceSong(song)

        let newURL = URL(string: "https://music.apple.com/us/song/new/2")!
        let newMetadata = TrackMetadata(title: "New Music Title", artist: "New Music Singer")
        model.updateAppleMusicLink(
            for: song.id,
            appleMusicURL: newURL,
            metadata: newMetadata
        )

        let storedSong = try XCTUnwrap(model.song(withID: song.id))
        XCTAssertEqual(storedSong.title, "Custom Title")
        XCTAssertEqual(storedSong.artist, "Custom Singer")
        XCTAssertEqual(storedSong.appleMusicURL, newURL)
        XCTAssertEqual(storedSong.linkedTrackMetadata, newMetadata)
    }

    @MainActor
    func testAppModelDuplicatesSelectedSongsWithIndependentIdentities() async throws {
        let store = InMemoryLibraryStore()
        let model = AppModel(store: store)
        await model.load()

        var first = model.createSong(
            appleMusicURL: URL(string: "https://music.apple.com/us/song/test/1")!,
            metadata: TrackMetadata(title: "First", artist: "Singer One")
        )
        first.lines = [
            LyricLine(
                id: UUID(),
                annotation: "note",
                lyric: .plain("First lyric"),
                timestampSeconds: 12.34
            ),
        ]
        model.replaceSong(first)
        model.createSong(
            appleMusicURL: URL(string: "https://music.apple.com/us/song/test/2")!,
            metadata: TrackMetadata(title: "Second", artist: "Singer Two")
        )
        let originals = model.library.songs
        let duplicateDate = Date(timeIntervalSince1970: 1_900_000_000)

        let duplicateIDs = model.duplicateSongs(
            Set(originals.map(\.id)),
            now: duplicateDate
        )

        XCTAssertEqual(duplicateIDs.count, 2)
        XCTAssertEqual(model.selectedSongIDs, duplicateIDs)
        XCTAssertEqual(model.library.songs.count, 4)
        XCTAssertEqual(
            model.library.songs.map(\.title),
            originals.flatMap { [$0.title, $0.title] }
        )

        for (index, original) in originals.enumerated() {
            let storedOriginal = model.library.songs[index * 2]
            let duplicate = model.library.songs[index * 2 + 1]
            XCTAssertEqual(storedOriginal, original)
            XCTAssertTrue(duplicateIDs.contains(duplicate.id))
            XCTAssertNotEqual(duplicate.id, original.id)
            XCTAssertEqual(duplicate.title, original.title)
            XCTAssertEqual(duplicate.artist, original.artist)
            XCTAssertEqual(duplicate.appleMusicURL, original.appleMusicURL)
            XCTAssertEqual(duplicate.lines.map(\.annotation), original.lines.map(\.annotation))
            XCTAssertEqual(duplicate.lines.map(\.lyric), original.lines.map(\.lyric))
            XCTAssertEqual(
                duplicate.lines.map(\.timestampSeconds),
                original.lines.map(\.timestampSeconds)
            )
            XCTAssertEqual(duplicate.createdAt, duplicateDate)
            XCTAssertEqual(duplicate.updatedAt, duplicateDate)
            XCTAssertEqual(duplicate.lines.count, original.lines.count)
            for (duplicateLine, originalLine) in zip(duplicate.lines, original.lines) {
                XCTAssertNotEqual(duplicateLine.id, originalLine.id)
            }
        }

        await model.flush()
        let saved = try await store.load()
        XCTAssertEqual(saved, model.library)
    }

    @MainActor
    func testAppModelImportsBundledSongsAndRegeneratesConflictingIdentities() async throws {
        let original = Song(
            id: UUID(),
            title: "Imported Song",
            artist: "Imported Singer",
            appleMusicURL: URL(string: "https://music.apple.com/us/song/test/1"),
            linkedTrackMetadata: TrackMetadata(title: "Linked Song", artist: "Linked Singer"),
            lines: [
                LyricLine(
                    id: UUID(),
                    annotation: "imported annotation",
                    lyric: .plain("Imported lyric"),
                    timestampSeconds: 4.2
                ),
            ],
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_800_000_100)
        )
        let store = InMemoryLibraryStore()
        let model = AppModel(store: store)
        await model.load()

        XCTAssertEqual(model.importSongs([original]), [original.id])
        XCTAssertEqual(model.library.songs, [original])
        XCTAssertEqual(model.selectedSongID, original.id)
        XCTAssertEqual(model.selectedSongIDs, [original.id])

        let duplicateIDs = model.importSongs([original])
        let duplicate = try XCTUnwrap(model.library.songs.last)
        XCTAssertEqual(duplicateIDs, [duplicate.id])
        XCTAssertNotEqual(duplicate.id, original.id)
        XCTAssertNotEqual(duplicate.lines[0].id, original.lines[0].id)
        XCTAssertEqual(duplicate.title, original.title)
        XCTAssertEqual(duplicate.artist, original.artist)
        XCTAssertEqual(duplicate.lines[0].annotation, original.lines[0].annotation)
        XCTAssertEqual(duplicate.lines[0].lyric, original.lines[0].lyric)
        XCTAssertEqual(duplicate.lines[0].timestampSeconds, original.lines[0].timestampSeconds)
        XCTAssertEqual(duplicate.createdAt, original.createdAt)
        XCTAssertEqual(duplicate.updatedAt, original.updatedAt)

        await model.flush()
        let saved = try await store.load()
        XCTAssertEqual(saved, model.library)
    }

    @MainActor
    func testLiveTimestampEditPersistsWithoutOverwritingLyricText() async throws {
        let store = InMemoryLibraryStore()
        let model = AppModel(store: store)
        await model.load()
        let song = model.createSong(
            appleMusicURL: URL(string: "https://music.apple.com/us/song/test/1")!,
            metadata: TrackMetadata(title: "Test", artist: "Singer")
        )
        guard let songBinding = model.bindingForSelectedSong() else {
            return XCTFail("Expected the newly created song to have a live binding")
        }

        let editedLyric = StyledText(runs: [
            TextRun(
                text: "Edited lyric",
                style: TextStyle(
                    fontFamily: "Helvetica Neue",
                    foregroundColor: nil,
                    bold: true,
                    italic: false,
                    underline: false
                )
            ),
        ])
        var textEdit = songBinding.wrappedValue
        textEdit.lines[0].lyric = editedLyric
        songBinding.wrappedValue = textEdit

        var timingEdit = songBinding.wrappedValue
        timingEdit.lines[0].timestampSeconds = 12.34
        songBinding.wrappedValue = timingEdit
        await model.flush()

        let saved = try await store.load()
        let savedSong = try XCTUnwrap(saved.songs.first { $0.id == song.id })
        let savedLine = try XCTUnwrap(savedSong.lines.first)
        XCTAssertEqual(savedLine.lyric, editedLyric)
        XCTAssertEqual(savedLine.timestampSeconds ?? -1, 12.34, accuracy: 0.0001)
    }

    @MainActor
    func testAppModelPreservesSongWithNoLyricLines() async {
        let model = AppModel(store: InMemoryLibraryStore())
        await model.load()
        var song = model.createSong(
            appleMusicURL: URL(string: "https://music.apple.com/us/song/test/1")!,
            metadata: TrackMetadata(title: "Test", artist: "Singer")
        )
        song.lines.removeAll()

        model.replaceSong(song)

        XCTAssertEqual(model.song(withID: song.id)?.lines, [])
    }

    @MainActor
    func testMusicPlaybackModelClampsSongAwareSeek() async {
        let song = linkedSong(title: "Expected", artist: "Singer")
        let controller = MockMusicController(states: [
            MusicState(
                state: .paused,
                position: 4,
                duration: 10,
                trackName: "Expected",
                trackArtist: "Singer",
                trackPersistentID: "AAA"
            ),
        ])
        let model = MusicPlaybackModel(controller: controller)
        model.beginMonitoring(song)
        await model.refresh()
        await model.seekAndPlay(song, to: -10)
        let lastSeek = await controller.recordedSeek()
        XCTAssertEqual(lastSeek, 0)
        XCTAssertEqual(model.state.state, .playing)
    }

    @MainActor
    func testMusicPlaybackPlayheadSeekKeepsStoppedTrackStoppedAtZero() async {
        let song = linkedSong(title: "Expected", artist: "Singer")
        let controller = MockMusicController(states: [
            MusicState(
                state: .stopped,
                position: 4,
                duration: 10,
                trackName: "Expected",
                trackArtist: "Singer",
                trackPersistentID: "AAA"
            ),
        ])
        let model = MusicPlaybackModel(controller: controller)
        model.beginMonitoring(song)
        await model.refresh()

        await model.seek(song, to: 0)

        let positionOnlySeek = await controller.recordedPositionOnlySeek()
        let seekAndPlay = await controller.recordedSeek()
        XCTAssertEqual(positionOnlySeek, 0)
        XCTAssertNil(seekAndPlay)
        XCTAssertEqual(model.state.position, 0)
        XCTAssertEqual(model.state.state, .stopped)
    }

    @MainActor
    func testMusicPlaybackStopsWhenPersistentTrackIdentityChanges() async {
        let song = linkedSong(title: "Expected", artist: "Singer")
        let controller = MockMusicController(states: [
            MusicState(
                state: .playing,
                position: 4,
                duration: 10,
                trackName: "Expected",
                trackArtist: "Singer",
                trackPersistentID: "AAA"
            ),
            MusicState(
                state: .playing,
                position: 1,
                duration: 12,
                trackName: "Another Track",
                trackArtist: "Another Singer",
                trackPersistentID: "BBB"
            ),
        ])
        let model = MusicPlaybackModel(controller: controller)
        model.beginMonitoring(song)

        await model.refresh()
        await model.refresh()

        let stopCount = await controller.recordedStopCount()
        XCTAssertEqual(stopCount, 1)
        XCTAssertEqual(model.issue, .unexpectedTrack)
        XCTAssertEqual(model.state.state, .stopped)
        XCTAssertEqual(model.state.position, 4)
    }

    @MainActor
    func testSongAwarePlaybackPositionIgnoresAnUnrelatedCurrentTrack() async {
        let song = linkedSong(title: "Expected", artist: "Singer")
        let controller = MockMusicController(states: [
            MusicState(
                state: .playing,
                position: 42,
                duration: 180,
                trackName: "Another Track",
                trackArtist: "Another Singer",
                trackPersistentID: "OTHER"
            ),
        ])
        let model = MusicPlaybackModel(controller: controller)
        model.beginMonitoring(song)

        await model.refresh()

        XCTAssertEqual(model.interpolatedPosition(for: song), 0)
        XCTAssertFalse(model.isPlaying(song))
    }

    @MainActor
    func testSongAwarePlaybackPositionTracksTheEstablishedSong() async {
        let song = linkedSong(title: "Expected", artist: "Singer")
        let controller = MockMusicController(states: [
            MusicState(
                state: .paused,
                position: 42,
                duration: 180,
                trackName: "Expected",
                trackArtist: "Singer",
                trackPersistentID: "EXPECTED"
            ),
        ])
        let model = MusicPlaybackModel(controller: controller)
        model.beginMonitoring(song)

        await model.refresh()

        XCTAssertEqual(model.interpolatedPosition(for: song), 42)
    }

    @MainActor
    func testDisplayMetadataEditKeepsTheEstablishedMusicSession() async {
        var song = linkedSong(title: "Music Title", artist: "Music Singer")
        let controller = MockMusicController(states: [
            MusicState(
                state: .playing,
                position: 4,
                duration: 180,
                trackName: "Music Title",
                trackArtist: "Music Singer",
                trackPersistentID: "TARGET"
            ),
            MusicState(
                state: .playing,
                position: 5,
                duration: 180,
                trackName: "Music Title",
                trackArtist: "Music Singer",
                trackPersistentID: "TARGET"
            ),
        ])
        let model = MusicPlaybackModel(controller: controller)
        model.beginMonitoring(song)
        await model.refresh()

        song.title = "Custom Title"
        song.artist = "Custom Singer"
        model.beginMonitoring(song)
        await model.refresh()

        let stopCount = await controller.recordedStopCount()
        XCTAssertTrue(model.isPlaying(song))
        XCTAssertEqual(model.state.position, 5)
        XCTAssertNil(model.issue)
        XCTAssertEqual(stopCount, 0)
    }

    @MainActor
    func testSongAwarePlaybackPositionRejectsANewPersistentIDWithMatchingMetadata() async {
        let song = linkedSong(title: "Expected", artist: "Singer")
        let controller = MockMusicController(states: [
            MusicState(
                state: .playing,
                position: 4,
                duration: 180,
                trackName: "Expected",
                trackArtist: "Singer",
                trackPersistentID: "ORIGINAL"
            ),
            MusicState(
                state: .playing,
                position: 42,
                duration: 180,
                trackName: "Expected",
                trackArtist: "Singer",
                trackPersistentID: "DIFFERENT"
            ),
        ])
        let model = MusicPlaybackModel(controller: controller)
        model.beginMonitoring(song)

        await model.refresh()
        await model.refresh()

        let stopCount = await controller.recordedStopCount()
        XCTAssertEqual(model.interpolatedPosition(for: song), 4)
        XCTAssertFalse(model.isPlaying(song))
        XCTAssertEqual(model.issue, .unexpectedTrack)
        XCTAssertEqual(stopCount, 1)
    }

    @MainActor
    func testPlayAfterUnexpectedTrackReopensSelectedLink() async {
        let song = linkedSong(title: "Expected", artist: "Singer")
        let controller = MockMusicController(states: [
            MusicState(
                state: .playing,
                position: 4,
                duration: 10,
                trackName: "Expected",
                trackArtist: "Singer",
                trackPersistentID: "AAA"
            ),
            MusicState(
                state: .playing,
                position: 1,
                duration: 12,
                trackName: "Another Track",
                trackArtist: "Another Singer",
                trackPersistentID: "BBB"
            ),
            MusicState(
                state: .stopped,
                position: 0,
                duration: 10,
                trackName: "Expected",
                trackArtist: "Singer",
                trackPersistentID: "AAA"
            ),
        ])
        let model = MusicPlaybackModel(controller: controller)
        model.beginMonitoring(song)

        await model.refresh()
        await model.refresh()
        await model.togglePlayback(for: song)

        let openCount = await controller.recordedOpenCount()
        let seek = await controller.recordedSeek()
        XCTAssertEqual(openCount, 1)
        XCTAssertEqual(seek, 0)
        XCTAssertNil(model.issue)
        XCTAssertEqual(model.state.state, .playing)
    }

    @MainActor
    func testLinkedTrackStartupToleratesLocalizedMetadataAndArtistVariation() async {
        let song = linkedSong(title: "心牆", artist: "郭靜")
        let controller = MockMusicController(states: [
            MusicState(
                state: .stopped,
                trackName: "Previous",
                trackArtist: "Someone Else",
                trackPersistentID: ""
            ),
            MusicState(
                state: .paused,
                duration: 220,
                trackName: "心墙 (Remastered)",
                trackArtist: "郭静 & Guest",
                trackPersistentID: ""
            ),
        ])
        let model = MusicPlaybackModel(
            controller: controller,
            startupPollInterval: .zero,
            startupMaxSamples: 1
        )

        await model.play(song, from: 0)

        let openCount = await controller.recordedOpenCount()
        let seek = await controller.recordedSeek()
        XCTAssertEqual(openCount, 1)
        XCTAssertEqual(seek, 0)
        XCTAssertNil(model.issue)
        XCTAssertTrue(model.isPlaying(song))
    }

    @MainActor
    func testLinkedTrackStartupUsesMusicMetadataAfterDisplayMetadataChanges() async {
        var song = linkedSong(title: "Music Title", artist: "Music Singer")
        song.title = "Custom Title"
        song.artist = "Custom Singer"
        let controller = MockMusicController(states: [
            MusicState(
                state: .stopped,
                trackName: "Previous",
                trackArtist: "Someone Else",
                trackPersistentID: "OLD"
            ),
            MusicState(
                state: .paused,
                duration: 200,
                trackName: "Music Title",
                trackArtist: "Music Singer",
                trackPersistentID: "TARGET"
            ),
        ])
        let model = MusicPlaybackModel(
            controller: controller,
            startupPollInterval: .zero,
            startupMaxSamples: 1
        )

        await model.play(song, from: 0)

        let openedMetadata = await controller.recordedOpenedMetadata()
        XCTAssertEqual(
            openedMetadata,
            TrackMetadata(title: "Music Title", artist: "Music Singer")
        )
        XCTAssertNil(model.issue)
        XCTAssertTrue(model.isPlaying(song))
    }

    @MainActor
    func testLinkedTrackStartupAcceptsAStableChangedPersistentIdentity() async {
        let song = linkedSong(title: "Expected", artist: "Singer")
        let oldState = MusicState(
            state: .stopped,
            trackName: "Previous",
            trackArtist: "Someone Else",
            trackPersistentID: "OLD"
        )
        let selectedState = MusicState(
            state: .paused,
            duration: 200,
            trackName: "",
            trackArtist: "",
            trackPersistentID: "TARGET"
        )
        let controller = MockMusicController(states: [
            oldState,
            oldState,
            selectedState,
            selectedState,
            selectedState,
            selectedState,
        ])
        let model = MusicPlaybackModel(
            controller: controller,
            startupPollInterval: .zero,
            startupMaxSamples: 8,
            startupStableIdentitySamples: 3,
            startupIdentityGraceSamples: 4
        )

        await model.play(song, from: 0)

        let seek = await controller.recordedSeek()
        XCTAssertEqual(seek, 0)
        XCTAssertNil(model.issue)
        XCTAssertTrue(model.isPlaying(song))
    }

    @MainActor
    func testLinkedTrackStartupRejectsAutoPlayIdentity() async {
        let song = linkedSong(title: "Expected", artist: "Singer")
        let oldState = MusicState(
            state: .stopped,
            trackName: "Previous",
            trackArtist: "Someone Else",
            trackPersistentID: "OLD"
        )
        let autoPlayState = MusicState(
            state: .playing,
            duration: 180,
            trackName: "AutoPlay",
            trackArtist: "",
            trackPersistentID: "AUTOPLAY"
        )
        let controller = MockMusicController(states: [
            oldState,
            autoPlayState,
            autoPlayState,
            autoPlayState,
        ])
        let model = MusicPlaybackModel(
            controller: controller,
            startupPollInterval: .zero,
            startupMaxSamples: 3,
            startupStableIdentitySamples: 2,
            startupIdentityGraceSamples: 2
        )

        await model.play(song, from: 0)

        let seek = await controller.recordedSeek()
        let stopCount = await controller.recordedStopCount()
        XCTAssertNil(seek)
        XCTAssertEqual(stopCount, 1)
        XCTAssertEqual(model.issue, .unableToStart)
        XCTAssertFalse(model.isPlaying(song))
    }

    @MainActor
    func testLinkedTrackStartupDoesNotAcceptAnUnchangedUnrelatedTrack() async {
        let song = linkedSong(title: "Expected", artist: "Singer")
        let unrelated = MusicState(
            state: .playing,
            position: 3,
            duration: 180,
            trackName: "Unrelated",
            trackArtist: "Someone Else",
            trackPersistentID: "UNCHANGED"
        )
        let controller = MockMusicController(states: [unrelated])
        let model = MusicPlaybackModel(
            controller: controller,
            startupPollInterval: .zero,
            startupMaxSamples: 4,
            startupStableIdentitySamples: 2,
            startupIdentityGraceSamples: 2
        )

        await model.play(song, from: 0)

        let seek = await controller.recordedSeek()
        let stopCount = await controller.recordedStopCount()
        XCTAssertNil(seek)
        XCTAssertEqual(stopCount, 0)
        XCTAssertEqual(model.issue, .unableToStart)
    }

    @MainActor
    func testMusicPlaybackRepeatsOnlyTheEstablishedTrackAtItsEnd() async {
        let song = linkedSong(title: "Expected", artist: "Singer")
        let controller = MockMusicController(states: [
            MusicState(
                state: .playing,
                position: 9.7,
                duration: 10,
                trackName: "Expected",
                trackArtist: "Singer",
                trackPersistentID: "AAA"
            ),
            MusicState(
                state: .stopped,
                position: 10,
                duration: 10,
                trackName: "Expected",
                trackArtist: "Singer",
                trackPersistentID: "AAA"
            ),
        ])
        let model = MusicPlaybackModel(controller: controller)
        model.beginMonitoring(song, repeatsWhenFinished: true)

        await model.refresh()
        await model.refresh()

        let seek = await controller.recordedSeek()
        let stopCount = await controller.recordedStopCount()
        XCTAssertEqual(seek, 0)
        XCTAssertEqual(stopCount, 0)
        XCTAssertEqual(model.state.state, .playing)
        XCTAssertEqual(model.state.position, 0)
    }

    @MainActor
    func testUnrelatedMusicIsNotStoppedBeforeExpectedTrackIsEstablished() async {
        let song = linkedSong(title: "Expected", artist: "Singer")
        let controller = MockMusicController(states: [
            MusicState(
                state: .playing,
                position: 2,
                duration: 20,
                trackName: "Unrelated",
                trackArtist: "Someone Else",
                trackPersistentID: "OTHER"
            ),
        ])
        let model = MusicPlaybackModel(controller: controller)
        model.beginMonitoring(song)

        await model.refresh()

        let stopCount = await controller.recordedStopCount()
        XCTAssertEqual(stopCount, 0)
        XCTAssertNil(model.issue)
    }

    private func linkedSong(title: String, artist: String) -> Song {
        var song = Song.blank()
        song.title = title
        song.artist = artist
        song.appleMusicURL = URL(string: "https://music.apple.com/us/song/test/1")!
        song.linkedTrackMetadata = TrackMetadata(title: title, artist: artist)
        return song
    }
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: (
        @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    )?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private actor FailingLibraryStore: LibraryStoring {
    private var saveCount = 0

    func load() async throws -> LibraryDocument {
        throw LibraryStoreError.corruptLibrary("Test corruption")
    }

    func save(_ document: LibraryDocument) async throws {
        saveCount += 1
    }

    func savedDocumentCount() -> Int { saveCount }
}

private actor MockMusicController: MusicControlling {
    private var states: [MusicState]
    private var mostRecentState = MusicState()
    var lastSeek: Double?
    var lastPositionOnlySeek: Double?
    var stopCount = 0
    var openCount = 0
    var openedMetadata: TrackMetadata?

    init(states: [MusicState] = []) {
        self.states = states
    }

    func currentState() async -> MusicState {
        if !states.isEmpty {
            mostRecentState = states.removeFirst()
        }
        return mostRecentState
    }
    func openTrack(_ url: URL, title: String, artist: String) async -> MusicActionResult {
        openCount += 1
        openedMetadata = TrackMetadata(title: title, artist: artist)
        return MusicActionResult(succeeded: true, permissionDenied: false)
    }
    func playPause() async -> MusicState {
        mostRecentState.state = mostRecentState.state == .playing ? .paused : .playing
        return mostRecentState
    }
    func seek(to seconds: Double) async -> MusicActionResult {
        lastPositionOnlySeek = seconds
        mostRecentState.position = seconds
        return MusicActionResult(succeeded: true, permissionDenied: false)
    }
    func seekAndPlay(to seconds: Double) async -> MusicActionResult {
        lastSeek = seconds
        mostRecentState.position = seconds
        mostRecentState.state = .playing
        return MusicActionResult(succeeded: true, permissionDenied: false)
    }

    func stop() async -> MusicActionResult {
        stopCount += 1
        mostRecentState.state = .stopped
        return MusicActionResult(succeeded: true, permissionDenied: false)
    }

    func recordedSeek() -> Double? { lastSeek }
    func recordedPositionOnlySeek() -> Double? { lastPositionOnlySeek }
    func recordedStopCount() -> Int { stopCount }
    func recordedOpenCount() -> Int { openCount }
    func recordedOpenedMetadata() -> TrackMetadata? { openedMetadata }
}
