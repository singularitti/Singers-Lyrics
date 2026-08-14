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
    private func waitForText(
        containing expectedText: String,
        in element: XCUIElement,
        timeout: TimeInterval = 3
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "label CONTAINS %@ OR value CONTAINS %@",
                expectedText,
                expectedText
            ),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
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

        let metadata = identified("songMetadataHeader", in: app)
        XCTAssertTrue(metadata.label.contains("Looked Up Song"))
        XCTAssertTrue(metadata.label.contains("Looked Up Singer"))
        XCTAssertFalse(app.textFields["songTitleField"].exists)
        XCTAssertFalse(app.textFields["songArtistField"].exists)
        let editor = identified("lyricsWorkspaceView", in: app)
        XCTAssertTrue(editor.exists)
        XCTAssertTrue(identified("timingPanel", in: app).exists)
        XCTAssertFalse(app.buttons["syncTimingButton"].exists)
        XCTAssertTrue(app.textViews["lyricText-0"].exists)
        XCTAssertTrue(identified("playerView", in: app).exists)
        let playerTitle = identified("playerSongTitle", in: app)
        let playerArtist = identified("playerSongArtist", in: app)
        XCTAssertEqual(playerTitle.label, "Looked Up Song")
        XCTAssertEqual(playerArtist.label, "Looked Up Singer")
        XCTAssertGreaterThanOrEqual(playerArtist.frame.minY - playerTitle.frame.maxY, 4)
    }

    @MainActor
    func testMetadataHeaderAlignsWithLyricCells() {
        let app = launchApp()
        _ = createSong(in: app)

        XCTAssertEqual(
            identified("songMetadataHeader", in: app).frame.minX,
            identified("lyricLine-0", in: app).frame.minX,
            accuracy: 2,
            "The song metadata should align with the lyric-cell leading edge"
        )
    }

    @MainActor
    func testSidebarSortControlSharesSidebarToolbarAndUsesFlatMenu() {
        let app = launchApp()
        _ = createSong(
            in: app,
            link: "https://music.apple.com/us/song/example/111"
        )
        _ = createSong(
            in: app,
            link: "https://music.apple.com/us/song/example/222"
        )

        let firstRow = identified("songRow-0", in: app)
        XCTAssertTrue(waitForText(containing: "Zulu", in: firstRow))

        let sortMenu = identified("songSortPicker", in: app)
        let sidebarToggle = app.buttons["Hide Sidebar"]
        XCTAssertEqual(sortMenu.label, "Sort Songs")
        XCTAssertTrue(sidebarToggle.exists)
        XCTAssertEqual(sortMenu.frame.midY, sidebarToggle.frame.midY, accuracy: 2)
        XCTAssertFalse(sortMenu.frame.intersects(sidebarToggle.frame))
        let toolbarItemGap = max(sortMenu.frame.minX, sidebarToggle.frame.minX)
            - min(sortMenu.frame.maxX, sidebarToggle.frame.maxX)
        XCTAssertGreaterThanOrEqual(toolbarItemGap, 0)
        XCTAssertLessThanOrEqual(toolbarItemGap, 12)

        sortMenu.click()
        XCTAssertFalse(app.menuItems["Sort"].exists)
        XCTAssertTrue(app.menuItems["Manual Order"].exists)
        let titleSort = app.menuItems["Title (A–Z)"]
        XCTAssertTrue(titleSort.waitForExistence(timeout: 3))
        titleSort.click()
        XCTAssertTrue(waitForText(containing: "Alpha", in: firstRow))
    }

    @MainActor
    func testScrollingAndSongChangesStartWithNoLyricSelection() {
        let app = launchApp()
        _ = createSong(
            in: app,
            link: "https://music.apple.com/us/song/example/111"
        )
        let importedLyrics = (1...24)
            .map { "Line \($0)" }
            .joined(separator: "\n")
        importLyrics(importedLyrics, in: app)

        let lyricsScrollView = identified("lyricsScrollView", in: app)
        for _ in 0..<3 {
            lyricsScrollView.scroll(byDeltaX: 0, deltaY: -400)
        }
        let lastLine = identified("lyricLine-23", in: app)
        XCTAssertTrue(lastLine.waitForExistence(timeout: 3))
        XCTAssertFalse(lastLine.isSelected)
        XCTAssertFalse(identified("textEditingPanel", in: app).exists)
        XCTAssertFalse(identified("lineSelectionPanel", in: app).exists)

        app.textViews["lyricText-23"].click()
        XCTAssertTrue(identified("textEditingPanel", in: app).waitForExistence(timeout: 3))
        XCTAssertTrue(lastLine.isSelected)

        _ = createSong(
            in: app,
            link: "https://music.apple.com/us/song/example/222"
        )
        XCTAssertFalse(identified("lyricLine-0", in: app).isSelected)
        XCTAssertFalse(identified("textEditingPanel", in: app).exists)
        XCTAssertFalse(identified("lineSelectionPanel", in: app).exists)

        identified("songRow-1", in: app).click()
        XCTAssertTrue(waitForText(
            containing: "Alpha",
            in: identified("songMetadataHeader", in: app)
        ))
        XCTAssertFalse(identified("lyricLine-0", in: app).isSelected)
        XCTAssertFalse(identified("textEditingPanel", in: app).exists)
        XCTAssertFalse(identified("lineSelectionPanel", in: app).exists)
    }

    @MainActor
    func testSidebarMetadataEditingLinkEditingAndWorkspaceColumnVisibility() {
        let app = launchApp()
        _ = createSong(in: app)

        XCTAssertFalse(app.buttons["editSongDetailsButton"].exists)
        identified("songRow-0", in: app).rightClick()
        let editDetails = app.menuItems["Edit Title and Singer…"]
        XCTAssertTrue(editDetails.waitForExistence(timeout: 3))
        editDetails.click()
        let titleField = app.textFields["songDetailsTitleField"]
        let artistField = app.textFields["songDetailsArtistField"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 3))
        replaceText(in: titleField, with: "Edited Song")
        replaceText(in: artistField, with: "Edited Singer")
        app.buttons["saveSongDetailsButton"].click()
        XCTAssertTrue(titleField.waitForNonExistence(timeout: 3))
        XCTAssertEqual(identified("playerSongTitle", in: app).label, "Edited Song")
        XCTAssertEqual(identified("playerSongArtist", in: app).label, "Edited Singer")
        XCTAssertTrue(identified("songMetadataHeader", in: app).label.contains("Edited Song"))

        app.buttons["appleMusicLinkButton"].click()
        let link = app.textFields["appleMusicURLField"]
        XCTAssertTrue(link.waitForExistence(timeout: 3))
        replaceText(
            in: link,
            with: "https://music.apple.com/us/song/example/111"
        )
        app.buttons["saveAppleMusicLinkButton"].click()
        XCTAssertTrue(link.waitForNonExistence(timeout: 3))
        var metadata = identified("songMetadataHeader", in: app)
        XCTAssertTrue(metadata.waitForExistence(timeout: 3))
        XCTAssertTrue(metadata.label.contains("Alpha"))
        XCTAssertTrue(metadata.label.contains("First Singer"))
        XCTAssertEqual(app.buttons["appleMusicLinkButton"].value as? String, "Linked")

        let editor = identified("lyricsWorkspaceView", in: app)
        let player = identified("playerView", in: app)

        let previewToggle = app.buttons["togglePreviewPanelButton"]
        XCTAssertEqual(previewToggle.value as? String, "Editor and Player")
        previewToggle.click()
        XCTAssertTrue(player.exists)
        XCTAssertTrue(editor.waitForNonExistence(timeout: 3))
        XCTAssertTrue(metadata.waitForNonExistence(timeout: 3))
        XCTAssertEqual(previewToggle.value as? String, "Player Only")
        previewToggle.click()
        XCTAssertEqual(previewToggle.value as? String, "Editor and Player")
        metadata = identified("songMetadataHeader", in: app)
        XCTAssertTrue(metadata.waitForExistence(timeout: 3))
        XCTAssertTrue(player.waitForExistence(timeout: 3))
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        XCTAssertTrue(identified("timingPanel", in: app).exists)

        let editorToggle = app.buttons["toggleEditorPanelButton"]
        XCTAssertEqual(editorToggle.value as? String, "Editor and Player")
        editorToggle.click()
        XCTAssertEqual(editorToggle.value as? String, "Editor Only")
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        XCTAssertTrue(player.waitForNonExistence(timeout: 3))
        editorToggle.click()
        XCTAssertEqual(editorToggle.value as? String, "Editor and Player")
        XCTAssertTrue(app.textViews["lyricText-0"].waitForExistence(timeout: 3))
        XCTAssertTrue(player.waitForExistence(timeout: 3))
        XCTAssertTrue(identified("timingPanel", in: app).waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["deleteSongButton"].isHittable)
    }

    @MainActor
    func testLineSplittingRichFormattingAndSymbolInsertion() {
        let app = launchApp()
        _ = createSong(in: app)

        XCTAssertTrue(identified("timingPanel", in: app).exists)
        XCTAssertFalse(identified("textEditingPanel", in: app).exists)
        XCTAssertFalse(identified("lineSelectionPanel", in: app).exists)
        let firstLine = app.textViews["lyricText-0"]
        firstLine.click()
        let formattingPanel = identified("textEditingPanel", in: app)
        XCTAssertTrue(formattingPanel.waitForExistence(timeout: 3))
        let firstRow = identified("lyricLine-0", in: app)
        XCTAssertTrue(firstRow.isSelected)
        XCTAssertLessThanOrEqual(formattingPanel.frame.maxY, firstRow.frame.minY + 1)
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
        let firstLine = app.textViews["lyricText-0"]
        let firstAnnotation = app.textFields["annotation-0"]

        XCTAssertFalse(identified("selectLine-0", in: app).exists)
        XCTAssertFalse(identified("selectLine-2", in: app).exists)
        XCTAssertFalse(firstRow.isSelected)
        XCTAssertFalse(thirdRow.isSelected)
        XCTAssertFalse(identified("boldButton", in: app).exists)
        XCTAssertFalse(identified("lineSelectionPanel", in: app).exists)
        XCTAssertLessThanOrEqual(
            thirdRow.frame.maxY,
            identified("timingPanel", in: app).frame.minY + 1
        )
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
            thirdRow.click()
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
            thirdRow.click()
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
    func testSongSortingMultiSelectionContextMenuDuplicationAndDeletion() {
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

        let secondRow = identified("songRow-1", in: app)
        firstRow.click()
        XCUIElement.perform(withKeyModifiers: .command) {
            secondRow.click()
        }
        XCTAssertTrue(firstRow.isSelected)
        XCTAssertTrue(secondRow.isSelected)

        firstRow.rightClick()
        let duplicate = app.menuItems["Duplicate"]
        XCTAssertTrue(duplicate.waitForExistence(timeout: 3))
        duplicate.click()
        XCTAssertTrue(identified("songRow-3", in: app).waitForExistence(timeout: 3))

        let rows = (0..<4).map { identified("songRow-\($0)", in: app) }
        let selectedRows = rows.filter(\.isSelected)
        XCTAssertEqual(selectedRows.count, 2)
        guard let selectedRow = selectedRows.first else {
            return XCTFail("Expected duplicated songs to be selected")
        }

        selectedRow.rightClick()
        let delete = app.menuItems["Delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 3))
        delete.click()
        XCTAssertTrue(app.staticTexts["Delete Selected Songs?"].waitForExistence(timeout: 3))
        app.sheets.firstMatch.buttons["Delete"].click()
        XCTAssertTrue(identified("songRow-1", in: app).waitForExistence(timeout: 3))
        XCTAssertFalse(identified("songRow-2", in: app).exists)
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
        let playerTitle = identified("playerSongTitle", in: app)
        let playerArtist = identified("playerSongArtist", in: app)
        let player = identified("playerView", in: app)
        XCTAssertEqual(playerTitle.frame.midX, player.frame.midX, accuracy: 3)
        XCTAssertEqual(playerArtist.frame.midX, player.frame.midX, accuracy: 3)
        XCTAssertLessThan(playerArtist.frame.maxY, identified("playerLine-0", in: app).frame.minY)

        let playFromLine = identified("playFromLineTimingButton", in: app)
        let pause = identified("pauseTimingButton", in: app)
        let removeTiming = identified("removeTimingButton", in: app)
        let clearSelection = identified("clearTimingSelectionButton", in: app)
        var actionRow = identified("timingActionRow", in: app)
        let wideHeader = identified("wideTimingHeader", in: app)
        let wideControls = identified("wideTimingControls", in: app)
        let oldValue = identified("timingOldValue", in: app)
        let jogWheel = identified("timingJogWheel", in: app)
        let newValue = identified("timingNewValue", in: app)
        let delayPicker = identified("timingDelayPicker", in: app)
        XCTAssertEqual(clearSelection.label, "Clear line selection")
        XCTAssertEqual(pause.label, "Pause")
        XCTAssertLessThanOrEqual(pause.frame.width, 44)
        XCTAssertLessThanOrEqual(clearSelection.frame.width, 44)
        for action in [pause, removeTiming, clearSelection] {
            XCTAssertEqual(playFromLine.frame.midY, action.frame.midY, accuracy: 3)
            XCTAssertEqual(playFromLine.frame.height, action.frame.height, accuracy: 2)
        }
        XCTAssertEqual(clearSelection.frame.maxX, actionRow.frame.maxX, accuracy: 3)
        XCTAssertEqual(clearSelection.frame.maxX, wideHeader.frame.maxX, accuracy: 3)
        XCTAssertEqual(delayPicker.frame.maxX, wideControls.frame.maxX, accuracy: 3)
        XCTAssertEqual(
            jogWheel.frame.minX - oldValue.frame.maxX,
            newValue.frame.minX - jogWheel.frame.maxX,
            accuracy: 2
        )

        let initialLineFrame = identified("lyricLine-0", in: app).frame
        let editorSplitter = app.splitters.allElementsBoundByIndex
            .filter { $0.frame.midX > initialLineFrame.maxX - 8 }
            .min { $0.frame.midX < $1.frame.midX }
        guard let editorSplitter else {
            XCTFail("Expected a splitter between the editor and preview panels")
            return
        }
        let workspaceToolbarButtons = [
            app.buttons["toggleEditorPanelButton"],
            app.buttons["togglePreviewPanelButton"],
            app.buttons["importLyricsButton"],
            app.buttons["exportLyricsButton"],
            app.buttons["newSongButton"],
            app.buttons["appleMusicLinkButton"],
            app.buttons["deleteSongButton"],
        ]
        let windowFrame = app.windows.firstMatch.frame
        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.exists)
        for toolbarButton in workspaceToolbarButtons {
            XCTAssertGreaterThan(toolbarButton.frame.minX, editorSplitter.frame.midX)
            XCTAssertLessThan(toolbarButton.frame.maxX, windowFrame.maxX)
        }
        XCTAssertGreaterThan(searchField.frame.minX, editorSplitter.frame.midX)
        XCTAssertLessThan(searchField.frame.maxX, windowFrame.maxX)
        let toolbarMinimumX = workspaceToolbarButtons.map(\.frame.minX).min() ?? 0
        let toolbarMaximumX = workspaceToolbarButtons.map(\.frame.maxX).max() ?? 0
        let searchGap = min(
            abs(searchField.frame.minX - toolbarMaximumX),
            abs(toolbarMinimumX - searchField.frame.maxX)
        )
        XCTAssertLessThanOrEqual(searchGap, 32)
        XCTAssertLessThan(
            app.buttons["togglePreviewPanelButton"].frame.maxX,
            app.buttons["importLyricsButton"].frame.minX
        )
        XCTAssertLessThan(
            app.buttons["exportLyricsButton"].frame.maxX,
            app.buttons["newSongButton"].frame.minX
        )

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
        actionRow = identified("timingActionRow", in: app)
        for action in [pause, removeTiming, clearSelection] {
            XCTAssertEqual(playFromLine.frame.midY, action.frame.midY, accuracy: 3)
            XCTAssertEqual(playFromLine.frame.height, action.frame.height, accuracy: 2)
        }
        XCTAssertGreaterThan(actionRow.frame.minX, compactHeaderFrame.minX)
        XCTAssertEqual(actionRow.frame.maxX, compactHeaderFrame.maxX, accuracy: 3)
        XCTAssertEqual(clearSelection.frame.maxX, actionRow.frame.maxX, accuracy: 3)
        XCTAssertGreaterThanOrEqual(actionRow.frame.minX, panelFrame.minX - 1)
        XCTAssertLessThanOrEqual(actionRow.frame.maxX, panelFrame.maxX + 1)
        let controlIDs = [
            "timingStatus",
            "timingActionRow",
            "playFromLineTimingButton",
            "pauseTimingButton",
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
