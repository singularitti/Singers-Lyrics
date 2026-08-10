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
        let workspace = identified("lyricsWorkspaceView", in: app)
        XCTAssertTrue(workspace.waitForExistence(timeout: 3))
        XCTAssertTrue(identified("timingPanel", in: app).exists)
        return workspace
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
        XCTAssertTrue(editor.waitForNonExistence(timeout: 3))
        XCTAssertTrue(identified("lyricsWorkspaceView", in: app).exists)
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
        XCTAssertTrue(identified("lyricsWorkspaceView", in: app).exists)
        XCTAssertTrue(identified("timingPanel", in: app).exists)
        XCTAssertFalse(app.buttons["syncTimingButton"].exists)
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
        XCTAssertTrue(identified("timingPanel", in: app).exists)
        previewToggle.click()
        XCTAssertTrue(identified("playerView", in: app).waitForExistence(timeout: 3))

        let libraryToggle = app.buttons["toggleLibraryPanelButton"]
        libraryToggle.click()
        XCTAssertTrue(app.buttons["deleteSongButton"].isHittable)

        let editorToggle = app.buttons["toggleEditorPanelButton"]
        editorToggle.click()
        XCTAssertTrue(app.textViews["lyricText-0"].waitForNonExistence(timeout: 3))
        XCTAssertTrue(identified("timingPanel", in: app).waitForNonExistence(timeout: 3))
        XCTAssertTrue(identified("lyricsWorkspaceView", in: app).waitForNonExistence(timeout: 3))
        XCTAssertTrue(identified("playerView", in: app).exists)
        editorToggle.click()
        XCTAssertTrue(app.textViews["lyricText-0"].waitForExistence(timeout: 3))
        XCTAssertTrue(identified("timingPanel", in: app).waitForExistence(timeout: 3))
    }

    @MainActor
    func testLineSplittingRichFormattingAndSymbolInsertion() {
        let app = launchApp()
        _ = createSong(in: app)

        XCTAssertTrue(identified("timingPanel", in: app).exists)
        XCTAssertFalse(identified("textEditingPanel", in: app).exists)
        let firstLine = app.textViews["lyricText-0"]
        firstLine.click()
        XCTAssertTrue(identified("textEditingPanel", in: app).waitForExistence(timeout: 3))
        XCTAssertTrue(identified("lyricLine-0", in: app).isSelected)
        firstLine.typeText("First")
        firstLine.typeKey("a", modifierFlags: .command)

        XCTAssertTrue(identified("boldButton", in: app).waitForExistence(timeout: 3))
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

        let colorPicker = identified("textColorPicker", in: app)
        XCTAssertTrue(colorPicker.exists)
        colorPicker.click()
        let colorsWindow = app.windows["Colors"]
        XCTAssertTrue(colorsWindow.waitForExistence(timeout: 3))
        colorsWindow.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(colorsWindow.waitForNonExistence(timeout: 3))

        firstLine.click()
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

        identified("lineTime-1", in: app).click()
        XCTAssertTrue(identified("textEditingPanel", in: app).waitForNonExistence(timeout: 3))
        XCTAssertTrue(identified("timingPanel", in: app).exists)
        XCTAssertTrue(identified("lyricLine-1", in: app).isSelected)
    }

    @MainActor
    func testLRCImportUnifiedRowSelectionAndBulkDeletion() {
        let app = launchApp()
        _ = createSong(in: app)
        importLyrics("[00:01.20] First\n[00:02.30] Second\nPlain third", in: app)

        XCTAssertEqual(app.textViews["lyricText-0"].value as? String, "First")
        XCTAssertEqual(app.textViews["lyricText-1"].value as? String, "Second")
        XCTAssertEqual(app.textViews["lyricText-2"].value as? String, "Plain third")

        var firstRow = identified("lyricLine-0", in: app)
        let thirdRow = identified("lyricLine-2", in: app)
        let firstTime = identified("lineTime-0", in: app)
        let thirdTime = identified("lineTime-2", in: app)
        let firstLine = app.textViews["lyricText-0"]
        let firstAnnotation = app.textFields["annotation-0"]

        XCTAssertFalse(identified("selectLine-0", in: app).exists)
        XCTAssertFalse(identified("selectLine-2", in: app).exists)
        XCTAssertFalse(firstRow.isSelected)
        XCTAssertFalse(thirdRow.isSelected)
        XCTAssertFalse(identified("boldButton", in: app).exists)
        XCTAssertLessThanOrEqual(firstRow.frame.height, 70)
        XCTAssertLessThanOrEqual(firstLine.frame.minX - firstRow.frame.minX, 12)
        XCTAssertLessThanOrEqual(firstAnnotation.frame.minY - firstRow.frame.minY, 8)
        // The row accessibility frame includes the 10-point clearance reserved
        // for the add/delete capsule that overlaps the card's lower edge.
        XCTAssertLessThanOrEqual(firstRow.frame.maxY - firstLine.frame.maxY, 18)

        firstTime.click()
        XCTAssertTrue(firstRow.isSelected)
        XCTAssertFalse(identified("textEditingPanel", in: app).exists)
        XCTAssertTrue(identified("clearTimingSelectionButton", in: app).isEnabled)
        identified("clearTimingSelectionButton", in: app).click()
        XCTAssertFalse(firstRow.isSelected)

        firstTime.click()
        XCUIElement.perform(withKeyModifiers: .command) {
            thirdTime.click()
        }
        XCTAssertTrue(firstRow.isSelected)
        XCTAssertTrue(thirdRow.isSelected)
        XCTAssertTrue(identified("lineSelectionPanel", in: app).waitForExistence(timeout: 3))
        let bulkDelete = identified("deleteSelectedLinesButton", in: app)
        XCTAssertEqual(bulkDelete.label, "Delete 2 lines")

        identified("clearTimingSelectionButton", in: app).click()
        XCTAssertTrue(identified("lineSelectionPanel", in: app).waitForNonExistence(timeout: 3))
        XCTAssertFalse(firstRow.isSelected)
        XCTAssertFalse(thirdRow.isSelected)

        firstTime.click()
        app.buttons["playerPlayPauseButton"].click()
        XCTAssertFalse(firstRow.isSelected)

        firstTime.click()
        XCUIElement.perform(withKeyModifiers: .shift) {
            thirdTime.click()
        }
        XCTAssertTrue(identified("lyricLine-1", in: app).isSelected)
        XCTAssertEqual(bulkDelete.label, "Delete 3 lines")

        firstTime.click()
        app.typeKey("a", modifierFlags: .command)
        XCTAssertEqual(bulkDelete.label, "Delete 3 lines")
        bulkDelete.click()

        XCTAssertTrue(app.buttons["emptyAddLineButton"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.textViews["lyricText-0"].exists)

        app.typeKey("z", modifierFlags: .command)
        XCTAssertEqual(app.textViews["lyricText-0"].value as? String, "First")
        XCTAssertEqual(app.textViews["lyricText-2"].value as? String, "Plain third")

        identified("clearTimingSelectionButton", in: app).click()
        firstRow = identified("lyricLine-0", in: app)
        XCTAssertFalse(app.buttons["addLineBelow-0"].exists)
        firstRow.hover()
        let addButton = app.buttons["addLineBelow-0"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 3))
        addButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertTrue(app.textViews["lyricText-1"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.textViews["lyricText-1"].value as? String, "")
        firstRow.hover()
        XCTAssertTrue(app.buttons["addLineBelow-0"].waitForExistence(timeout: 3))
        let lineControls = identified("lineControls-0", in: app)
        XCTAssertTrue(lineControls.exists)
        XCTAssertEqual(
            lineControls.frame.midY,
            identified("lyricLine-0", in: app).frame.maxY - lineControls.frame.height / 2,
            accuracy: 3
        )
        let secondRow = identified("lyricLine-1", in: app)
        XCTAssertGreaterThan(secondRow.frame.minY, lineControls.frame.maxY)
        XCTAssertLessThanOrEqual(secondRow.frame.minY - lineControls.frame.maxY, 6)
        secondRow.hover()
        let deleteButton = app.buttons["deleteLine-1"]
        XCTAssertTrue(deleteButton.waitForExistence(timeout: 3))
        deleteButton.click()
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
    func testTextEditingAndLiveTimingChangesCoexistAndUndo() {
        let app = launchApp()
        _ = createSong(in: app)
        importLyrics("[00:01.20] First\n[00:02.30] Second", in: app)

        let firstRow = identified("lyricLine-0", in: app)
        let firstLine = app.textViews["lyricText-0"]
        XCTAssertTrue(identified("lyricsWorkspaceView", in: app).exists)
        XCTAssertTrue(identified("timingPanel", in: app).exists)
        XCTAssertTrue(firstLine.exists)
        XCTAssertFalse(app.buttons["syncTimingButton"].exists)
        XCTAssertTrue(identified("songList", in: app).exists)
        XCTAssertTrue(identified("songRow-0", in: app).isHittable)
        XCTAssertTrue(identified("playerView", in: app).exists)
        XCTAssertTrue(app.buttons["playerPlayPauseButton"].isHittable)
        XCTAssertGreaterThan(identified("lineTime-0", in: app).frame.midX, firstRow.frame.midX)
        XCTAssertEqual(identified("lineTime-0", in: app).label, "0:01")
        XCTAssertFalse(app.buttons["shiftMinusOneButton"].exists)
        XCTAssertFalse(app.buttons["shiftMinusTenthButton"].exists)
        XCTAssertFalse(app.buttons["shiftPlusTenthButton"].exists)
        XCTAssertFalse(app.buttons["shiftPlusOneButton"].exists)
        XCTAssertFalse(app.buttons["fineAdjustMinusButton"].exists)
        XCTAssertFalse(app.buttons["fineAdjustPlusButton"].exists)
        XCTAssertFalse(app.buttons["Previous line"].exists)
        let oldTime = identified("timingOldValue", in: app)
        let wheel = identified("timingJogWheel", in: app)
        let newTime = identified("timingNewValue", in: app)
        XCTAssertTrue(oldTime.exists)
        XCTAssertTrue(wheel.exists)
        XCTAssertTrue(newTime.exists)
        XCTAssertFalse(identified("shiftedTimingPreview", in: app).exists)
        XCTAssertLessThanOrEqual(wheel.frame.width, 140)
        XCTAssertLessThanOrEqual(oldTime.frame.maxX, wheel.frame.minX)
        XCTAssertGreaterThanOrEqual(newTime.frame.minX, wheel.frame.maxX)

        firstLine.click()
        firstLine.typeKey(.end, modifierFlags: [])
        firstLine.typeKey(.space, modifierFlags: [])
        firstLine.typeText("X")
        XCTAssertEqual(firstLine.value as? String, "First X")
        XCTAssertEqual(identified("lineTime-0", in: app).label, "0:01")
        XCTAssertTrue(identified("textEditingPanel", in: app).waitForExistence(timeout: 3))
        XCTAssertTrue(firstRow.isSelected)

        identified("lineTime-0", in: app).click()
        XCTAssertTrue(identified("textEditingPanel", in: app).waitForNonExistence(timeout: 3))
        XCTAssertTrue(firstRow.isSelected)
        app.buttons["stampTimingButton"].click()
        XCTAssertEqual(identified("lineTime-0", in: app).label, "0:00")
        XCTAssertEqual(identified("lineTime-1", in: app).label, "0:02")
        XCTAssertTrue(identified("lyricLine-1", in: app).isSelected)

        app.typeKey("z", modifierFlags: .command)
        XCTAssertEqual(identified("lineTime-0", in: app).label, "0:01")
        XCTAssertTrue(identified("lyricLine-0", in: app).isSelected)

        app.buttons["removeTimingButton"].click()
        XCTAssertEqual(identified("lineTime-0", in: app).label, "––:––")
        app.typeKey("z", modifierFlags: .command)
        XCTAssertEqual(identified("lineTime-0", in: app).label, "0:01")

        identified("clearTimingSelectionButton", in: app).click()
        XCTAssertFalse(identified("lyricLine-0", in: app).isSelected)
        XCTAssertFalse(app.buttons["stampTimingButton"].isEnabled)
        XCTAssertFalse(app.buttons["removeTimingButton"].isEnabled)
    }

    @MainActor
    func testUnifiedRowSelectionTargetsTheExactLineBeforeStamping() {
        let app = launchApp()
        _ = createSong(in: app)
        importLyrics(
            "[00:01.20] First\n[00:02.30] Second\n[00:03.40] Third",
            in: app
        )

        identified("lineTime-1", in: app).click()
        XCTAssertFalse(identified("lyricLine-0", in: app).isSelected)
        XCTAssertTrue(identified("lyricLine-1", in: app).isSelected)
        XCTAssertFalse(identified("lyricLine-2", in: app).isSelected)
        XCTAssertEqual(identified("lineTime-0", in: app).label, "0:01")
        XCTAssertEqual(identified("lineTime-1", in: app).label, "0:02")
        XCTAssertEqual(identified("lineTime-2", in: app).label, "0:03")

        app.buttons["stampTimingButton"].click()
        XCTAssertEqual(identified("lineTime-0", in: app).label, "0:01")
        XCTAssertEqual(identified("lineTime-1", in: app).label, "0:00")
        XCTAssertEqual(identified("lineTime-2", in: app).label, "0:03")
        XCTAssertTrue(identified("lyricLine-2", in: app).isSelected)

        identified("lineTime-0", in: app).click()
        XCTAssertTrue(identified("lyricLine-0", in: app).isSelected)
        XCTAssertEqual(identified("lineTime-0", in: app).label, "0:01")
        app.buttons["stampTimingButton"].click()
        XCTAssertEqual(identified("lineTime-0", in: app).label, "0:00")
        XCTAssertEqual(identified("lineTime-1", in: app).label, "0:00")
        XCTAssertEqual(identified("lineTime-2", in: app).label, "0:03")
    }

    @MainActor
    func testTimeSyncPanelAdaptsToNarrowEditorColumn() {
        let app = launchApp()
        _ = createSong(in: app)
        importLyrics("[00:01.20] First\n[00:02.30] Second", in: app)

        XCTAssertTrue(identified("lyricsWorkspaceView", in: app).exists)
        XCTAssertFalse(app.buttons["syncTimingButton"].exists)

        let openApp = identified("openInMusicTimingButton", in: app)
        let playFromLine = identified("playFromLineTimingButton", in: app)
        let removeTiming = identified("removeTimingButton", in: app)
        let clearSelection = identified("clearTimingSelectionButton", in: app)
        var primaryActionRow = identified("timingPrimaryActionRow", in: app)
        var secondaryActionRow = identified("timingSecondaryActionRow", in: app)
        XCTAssertEqual(openApp.label, "Open song in Music")
        XCTAssertEqual(clearSelection.label, "Clear line selection")
        XCTAssertEqual(openApp.frame.midY, playFromLine.frame.midY, accuracy: 3)
        XCTAssertGreaterThanOrEqual(secondaryActionRow.frame.minY, primaryActionRow.frame.maxY)
        XCTAssertEqual(removeTiming.frame.minX, secondaryActionRow.frame.minX, accuracy: 3)
        XCTAssertEqual(clearSelection.frame.maxX, secondaryActionRow.frame.maxX, accuracy: 3)

        let initialLineFrame = identified("lyricLine-0", in: app).frame
        let editorSplitter = app.splitters.allElementsBoundByIndex
            .filter { $0.frame.midX > initialLineFrame.maxX - 8 }
            .min { $0.frame.midX < $1.frame.midX }
        guard let editorSplitter else {
            XCTFail("Expected a splitter between the editor and preview panels")
            return
        }

        let dragDistance = max(120, initialLineFrame.width - 388)
        let dragStart = editorSplitter.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        )
        dragStart.press(
            forDuration: 0.2,
            thenDragTo: dragStart.withOffset(CGVector(dx: -dragDistance, dy: 0))
        )

        let narrowLineFrame = identified("lyricLine-0", in: app).frame
        XCTAssertLessThan(narrowLineFrame.width, initialLineFrame.width - 40)
        XCTAssertLessThanOrEqual(narrowLineFrame.width, 410)
        XCTAssertTrue(identified("compactTimingHeader", in: app).waitForExistence(timeout: 3))
        XCTAssertTrue(identified("compactTimingControls", in: app).exists)

        let panelFrame = identified("timingPanel", in: app).frame
        let compactHeaderFrame = identified("compactTimingHeader", in: app).frame
        primaryActionRow = identified("timingPrimaryActionRow", in: app)
        secondaryActionRow = identified("timingSecondaryActionRow", in: app)
        XCTAssertGreaterThanOrEqual(secondaryActionRow.frame.minY, primaryActionRow.frame.maxY)
        XCTAssertEqual(removeTiming.frame.minX, secondaryActionRow.frame.minX, accuracy: 3)
        XCTAssertEqual(clearSelection.frame.maxX, secondaryActionRow.frame.maxX, accuracy: 3)
        XCTAssertEqual(secondaryActionRow.frame.minX, compactHeaderFrame.minX, accuracy: 3)
        XCTAssertEqual(secondaryActionRow.frame.maxX, compactHeaderFrame.maxX, accuracy: 3)
        XCTAssertGreaterThanOrEqual(secondaryActionRow.frame.minX, panelFrame.minX - 1)
        XCTAssertLessThanOrEqual(secondaryActionRow.frame.maxX, panelFrame.maxX + 1)
        let controlIDs = [
            "timingStatus",
            "timingPrimaryActionRow",
            "timingSecondaryActionRow",
            "openInMusicTimingButton",
            "playFromLineTimingButton",
            "removeTimingButton",
            "clearTimingSelectionButton",
            "timingSelectionSummary",
            "timingOldValue",
            "timingJogWheel",
            "timingNewValue",
            "stampTimingButton",
            "timingDelayPicker",
        ]
        for identifier in controlIDs {
            let control = identified(identifier, in: app)
            XCTAssertTrue(control.exists, "Missing \(identifier) in the compact timing panel")
            XCTAssertGreaterThanOrEqual(control.frame.minX, panelFrame.minX - 1, identifier)
            XCTAssertLessThanOrEqual(control.frame.maxX, panelFrame.maxX + 1, identifier)
            XCTAssertGreaterThanOrEqual(control.frame.minY, panelFrame.minY - 1, identifier)
            XCTAssertLessThanOrEqual(control.frame.maxY, panelFrame.maxY + 1, identifier)
        }

        XCTAssertLessThanOrEqual(
            identified("timingOldValue", in: app).frame.maxX,
            identified("timingJogWheel", in: app).frame.minX
        )
        XCTAssertLessThanOrEqual(
            identified("timingJogWheel", in: app).frame.maxX,
            identified("timingNewValue", in: app).frame.minX
        )
        XCTAssertLessThanOrEqual(
            identified("stampTimingButton", in: app).frame.maxX,
            identified("timingDelayPicker", in: app).frame.minX
        )
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
