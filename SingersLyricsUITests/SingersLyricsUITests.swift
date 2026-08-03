import AppKit
import XCTest

final class SingersLyricsUITests: XCTestCase {
    @MainActor
    private func launchApp(resetPreferences: Bool = true) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        if resetPreferences {
            app.launchArguments.append("--reset-ui-testing-preferences")
        }
        app.launch()
        return app
    }

    @MainActor
    private func identified(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    private func radioButtonIsSelected(_ element: XCUIElement) -> Bool {
        if let number = element.value as? NSNumber {
            return number.boolValue
        }
        return (element.value as? String) == "1"
    }

    @MainActor
    @discardableResult
    private func createSong(
        in app: XCUIApplication,
        link: String = "https://music.apple.com/us/song/example/1071506936"
    ) -> XCUIElement {
        let newSong = app.buttons["emptyNewSongButton"]
        if newSong.waitForExistence(timeout: 3) {
            newSong.click()
        } else {
            app.buttons["newSongButton"].click()
        }
        let linkField = app.textFields["appleMusicURLField"]
        XCTAssertTrue(linkField.waitForExistence(timeout: 3))
        replaceText(in: linkField, with: link)
        XCTAssertEqual(linkField.value as? String, link)
        linkField.typeKey(.tab, modifierFlags: [])
        app.buttons["saveAppleMusicLinkButton"].click()
        let editor = app.buttons["syncTimingButton"]
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        return editor
    }

    @MainActor
    private func replaceText(in element: XCUIElement, with value: String) {
        element.click()
        element.typeKey("a", modifierFlags: .command)
        NSPasteboard.general.clearContents()
        XCTAssertTrue(NSPasteboard.general.setString(value, forType: .string))
        element.typeKey("v", modifierFlags: .command)
    }

    @MainActor
    private func openSettings(in app: XCUIApplication) {
        app.menuBars.menuBarItems["Singers Lyrics"].click()
        app.menuItems["Settings…"].click()
    }

    @MainActor
    private func importLyrics(_ source: String, in app: XCUIApplication) {
        app.buttons["importLyricsButton"].click()
        let editor = app.textViews["lyricsImportText"]
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        replaceText(in: editor, with: source)
        app.buttons["confirmLyricsImportButton"].click()
        XCTAssertTrue(app.buttons["syncTimingButton"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testEmptyLaunchAndSongCreation() {
        let app = launchApp()
        let newSong = app.buttons["emptyNewSongButton"]
        XCTAssertTrue(newSong.waitForExistence(timeout: 5))
        XCTAssertEqual(newSong.label, "New Song from Apple Music")
        XCTAssertFalse(app.buttons["sidebarEmptyNewSongButton"].exists)
        _ = createSong(in: app)

        XCTAssertTrue(app.staticTexts["Looked Up Song | Looked Up Singer"].exists)
        XCTAssertFalse(app.textFields["songTitleField"].exists)
        XCTAssertFalse(app.textFields["songArtistField"].exists)
        XCTAssertTrue(app.buttons["syncTimingButton"].exists)
        XCTAssertTrue(app.textViews["lyricText-0"].exists)
        XCTAssertTrue(identified("playerView", in: app).exists)
    }

    @MainActor
    func testReadOnlyMetadataLinkEditingAndCollapsiblePanels() {
        let app = launchApp()
        _ = createSong(in: app)
        XCTAssertTrue(app.staticTexts["Looked Up Song | Looked Up Singer"].exists)

        app.buttons["appleMusicLinkButton"].click()
        let link = app.textFields["appleMusicURLField"]
        XCTAssertTrue(link.waitForExistence(timeout: 3))
        replaceText(
            in: link,
            with: "https://music.apple.com/us/song/example/111"
        )
        app.buttons["saveAppleMusicLinkButton"].click()
        XCTAssertTrue(link.waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Alpha | First Singer"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.buttons["appleMusicLinkButton"].value as? String, "Linked")

        let previewToggle = app.buttons["togglePreviewPanelButton"]
        previewToggle.click()
        XCTAssertTrue(identified("playerView", in: app).waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.buttons["syncTimingButton"].exists)
        previewToggle.click()
        XCTAssertTrue(identified("playerView", in: app).waitForExistence(timeout: 3))

        let libraryToggle = app.buttons["toggleLibraryPanelButton"]
        libraryToggle.click()
        XCTAssertTrue(app.buttons["deleteSongButton"].isHittable)

        let editorToggle = app.buttons["toggleEditorPanelButton"]
        editorToggle.click()
        XCTAssertTrue(app.textViews["lyricText-0"].waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.buttons["syncTimingButton"].exists)
        XCTAssertTrue(identified("playerView", in: app).exists)
        editorToggle.click()
        XCTAssertTrue(app.textViews["lyricText-0"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testLineSplittingRichFormattingAndSymbolInsertion() {
        let app = launchApp()
        _ = createSong(in: app)

        let firstLine = app.textViews["lyricText-0"]
        firstLine.click()
        firstLine.typeText("First")
        firstLine.typeKey("a", modifierFlags: .command)

        for identifier in ["boldButton", "italicButton", "underlineButton"] {
            let button = identified(identifier, in: app)
            XCTAssertTrue(button.isEnabled)
            button.click()
            XCTAssertEqual(button.value as? String, "On")
        }

        let undo = identified("undoFormattingButton", in: app)
        let redo = identified("redoFormattingButton", in: app)
        XCTAssertTrue(undo.isEnabled)
        undo.click()
        XCTAssertEqual(identified("underlineButton", in: app).value as? String, "Off")
        XCTAssertTrue(redo.isEnabled)
        redo.click()
        XCTAssertEqual(identified("underlineButton", in: app).value as? String, "On")

        firstLine.typeKey("z", modifierFlags: .command)
        XCTAssertEqual(identified("underlineButton", in: app).value as? String, "Off")
        firstLine.typeKey("z", modifierFlags: [.command, .shift])
        XCTAssertEqual(identified("underlineButton", in: app).value as? String, "On")

        identified("textColorMenu", in: app).click()
        app.menuItems["Blue"].click()

        firstLine.typeKey(XCUIKeyboardKey.end, modifierFlags: [])
        firstLine.typeKey(XCUIKeyboardKey.return, modifierFlags: [])
        let secondLine = app.textViews["lyricText-1"]
        XCTAssertTrue(secondLine.waitForExistence(timeout: 3))
        secondLine.typeText("Second")
        for identifier in ["boldButton", "italicButton", "underlineButton"] {
            XCTAssertEqual(identified(identifier, in: app).value as? String, "On")
        }

        app.buttons["symbolsButton"].click()
        let symbol = app.buttons["symbolButton-♪"]
        XCTAssertTrue(symbol.waitForExistence(timeout: 3))
        symbol.click()
        XCTAssertTrue((secondLine.value as? String)?.contains("Second♪") == true)
    }

    @MainActor
    func testLRCImportMultiSelectionAndBulkDeletion() {
        let app = launchApp()
        _ = createSong(in: app)
        importLyrics("[00:01.20] First\n[00:02.30] Second\nPlain third", in: app)

        XCTAssertEqual(app.textViews["lyricText-0"].value as? String, "First")
        XCTAssertEqual(app.textViews["lyricText-1"].value as? String, "Second")
        XCTAssertEqual(app.textViews["lyricText-2"].value as? String, "Plain third")

        let first = app.buttons["selectLine-0"]
        let third = app.buttons["selectLine-2"]
        XCTAssertEqual(first.value as? String, "Not selected")
        first.click()
        XCTAssertEqual(first.value as? String, "Selected")
        first.click()
        XCTAssertEqual(first.value as? String, "Not selected")
        XCTAssertFalse(app.buttons["deleteSelectedLinesButton"].exists)

        first.click()
        XCUIElement.perform(withKeyModifiers: .command) {
            third.click()
        }
        let bulkDelete = app.buttons["deleteSelectedLinesButton"]
        XCTAssertTrue(bulkDelete.label.contains("2"))

        let scrollView = identified("lyricsScrollView", in: app)
        scrollView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)).click()
        XCTAssertFalse(app.buttons["deleteSelectedLinesButton"].exists)

        first.click()
        XCTAssertTrue(app.buttons["deleteSelectedLinesButton"].exists)
        app.buttons["playerPlayPauseButton"].click()
        XCTAssertFalse(app.buttons["deleteSelectedLinesButton"].exists)

        first.click()
        XCUIElement.perform(withKeyModifiers: .shift) {
            third.click()
        }
        XCTAssertTrue(bulkDelete.label.contains("3"))

        first.click()
        app.typeKey("a", modifierFlags: .command)
        XCTAssertTrue(bulkDelete.label.contains("3"))
        bulkDelete.click()

        XCTAssertTrue(app.buttons["emptyAddLineButton"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.textViews["lyricText-0"].exists)

        let undo = identified("undoFormattingButton", in: app)
        XCTAssertTrue(undo.isEnabled)
        undo.click()
        XCTAssertEqual(app.textViews["lyricText-0"].value as? String, "First")
        XCTAssertEqual(app.textViews["lyricText-2"].value as? String, "Plain third")

        app.buttons["addLineBelow-0"].click()
        XCTAssertTrue(app.textViews["lyricText-1"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.textViews["lyricText-1"].value as? String, "")
        XCTAssertEqual(
            app.buttons["addLineBelow-0"].frame.midY,
            identified("editLine-0", in: app).frame.maxY,
            accuracy: 3
        )
        app.buttons["deleteLine-1"].click()
        XCTAssertEqual(app.textViews["lyricText-1"].value as? String, "Second")
        app.typeKey("z", modifierFlags: .command)
        XCTAssertEqual(app.textViews["lyricText-1"].value as? String, "")
    }

    @MainActor
    func testImportedLyricsCanBeFormattedBeforeEditingText() {
        let app = launchApp()
        _ = createSong(in: app)
        importLyrics("[00:01.20] First", in: app)

        let firstLine = app.textViews["lyricText-0"]
        firstLine.click()
        firstLine.typeKey("a", modifierFlags: .command)

        let bold = identified("boldButton", in: app)
        XCTAssertTrue(bold.isEnabled)
        bold.click()
        XCTAssertEqual(bold.value as? String, "On")
    }

    @MainActor
    func testSongSortingAndDeleteConfirmation() {
        let app = launchApp()
        _ = createSong(
            in: app,
            link: "https://music.apple.com/us/song/example/111"
        )
        _ = createSong(
            in: app,
            link: "https://music.apple.com/us/song/example/222"
        )

        var firstRow = identified("songRow-0", in: app)
        XCTAssertTrue(firstRow.label.contains("Zulu"))
        let sortPicker = identified("songSortPicker", in: app)
        sortPicker.click()
        app.menuItems["Title (A–Z)"].click()
        firstRow = identified("songRow-0", in: app)
        XCTAssertTrue(firstRow.label.contains("Alpha"))

        app.buttons["deleteSongButton"].click()
        XCTAssertTrue(app.staticTexts["Delete This Song?"].waitForExistence(timeout: 3))
        app.sheets.firstMatch.buttons["Delete"].click()
        XCTAssertTrue(identified("songRow-0", in: app).label.contains("Alpha"))
        XCTAssertFalse(identified("songRow-1", in: app).exists)
    }

    @MainActor
    func testTimingChangesCanBeCancelledOrSaved() {
        let app = launchApp()
        _ = createSong(in: app)
        importLyrics("[00:01.20] First\n[00:02.30] Second", in: app)

        let editFrame = identified("editLine-0", in: app).frame
        XCTAssertGreaterThan(identified("lineTime-0", in: app).frame.midX, editFrame.midX)
        app.buttons["syncTimingButton"].click()
        XCTAssertTrue(identified("syncView", in: app).waitForExistence(timeout: 3))
        XCTAssertTrue(identified("songList", in: app).exists)
        XCTAssertTrue(identified("songRow-0", in: app).isHittable)
        XCTAssertTrue(identified("playerView", in: app).exists)
        XCTAssertTrue(app.buttons["playerPlayPauseButton"].isHittable)
        XCTAssertFalse(app.textViews["lyricText-0"].exists)
        var firstTiming = identified("syncLine-0", in: app)
        XCTAssertEqual(firstTiming.frame.minX, editFrame.minX, accuracy: 1)
        XCTAssertEqual(firstTiming.frame.width, editFrame.width, accuracy: 1)
        XCTAssertGreaterThan(identified("lineTime-0", in: app).frame.midX, firstTiming.frame.midX)
        XCTAssertEqual(firstTiming.value as? String, "1.20")
        XCTAssertFalse(app.buttons["shiftMinusOneButton"].exists)
        XCTAssertFalse(app.buttons["shiftMinusTenthButton"].exists)
        XCTAssertFalse(app.buttons["shiftPlusTenthButton"].exists)
        XCTAssertFalse(app.buttons["shiftPlusOneButton"].exists)
        XCTAssertFalse(app.buttons["fineAdjustMinusButton"].exists)
        XCTAssertFalse(app.buttons["fineAdjustPlusButton"].exists)
        XCTAssertFalse(app.buttons["Previous line"].exists)
        XCTAssertTrue(identified("timingJogWheel", in: app).exists)
        XCTAssertTrue(identified("shiftedTimingPreview", in: app).exists)
        firstTiming.click()
        XCTAssertEqual(identified("syncLine-0", in: app).value as? String, "0.00")
        app.buttons["stampTimingButton"].click()
        XCTAssertEqual(identified("syncLine-1", in: app).value as? String, "0.00")
        XCUIElement.perform(withKeyModifiers: .command) {
            firstTiming.click()
        }
        firstTiming = identified("syncLine-0", in: app)
        app.buttons["removeTimingButton"].click()
        XCTAssertEqual(identified("syncLine-0", in: app).value as? String, "No timing")
        app.buttons["cancelTimingButton"].click()
        XCTAssertEqual(identified("lineTime-0", in: app).label, "0:01")

        app.buttons["syncTimingButton"].click()
        XCTAssertTrue(identified("syncView", in: app).waitForExistence(timeout: 3))
        firstTiming = identified("syncLine-0", in: app)
        XCTAssertEqual(firstTiming.value as? String, "1.20")
        app.buttons["removeTimingButton"].click()
        app.buttons["syncTimingButton"].click()
        XCTAssertTrue(identified("lyricsEditorView", in: app).waitForExistence(timeout: 3))
        XCTAssertEqual(identified("lineTime-0", in: app).label, "––:––")
    }

    @MainActor
    func testSettingsPersistence() {
        var app = launchApp()
        XCTAssertTrue(app.buttons["emptyNewSongButton"].waitForExistence(timeout: 5))
        openSettings(in: app)
        var appearance = identified("appearancePicker", in: app)
        XCTAssertTrue(appearance.waitForExistence(timeout: 3))
        var dark = appearance.radioButtons["Dark"]
        dark.click()
        XCTAssertTrue(radioButtonIsSelected(dark))
        var fallbackFont = identified("defaultLyricsFontPicker", in: app)
        fallbackFont.click()
        app.menuItems["Helvetica Neue"].click()
        XCTAssertEqual(fallbackFont.value as? String, "Helvetica Neue")
        app.terminate()

        app = launchApp(resetPreferences: false)
        XCTAssertTrue(app.buttons["emptyNewSongButton"].waitForExistence(timeout: 5))
        openSettings(in: app)
        appearance = identified("appearancePicker", in: app)
        XCTAssertTrue(appearance.waitForExistence(timeout: 3))
        dark = appearance.radioButtons["Dark"]
        XCTAssertTrue(radioButtonIsSelected(dark))
        fallbackFont = identified("defaultLyricsFontPicker", in: app)
        XCTAssertEqual(fallbackFont.value as? String, "Helvetica Neue")
    }

    @MainActor
    func testAppleMusicLinkValidationDoesNotTouchMusicApp() {
        let app = launchApp()
        let newSong = app.buttons["emptyNewSongButton"]
        XCTAssertTrue(newSong.waitForExistence(timeout: 5))
        newSong.click()
        let field = app.textFields["appleMusicURLField"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.typeText("https://example.com/not-music")
        app.buttons["saveAppleMusicLinkButton"].click()
        XCTAssertTrue(
            identified("appleMusicLinkError", in: app)
                .waitForExistence(timeout: 3)
        )
    }
}
