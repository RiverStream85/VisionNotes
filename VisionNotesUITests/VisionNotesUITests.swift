import XCTest

/// End-to-end flow over the demo library: load it, search it, open a result,
/// edit its recognized text, and save.
///
/// The app launches with `-uiTesting`, which uses a fresh in-memory library so
/// each run starts from the empty state.
final class VisionNotesUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-uiTesting"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
        try super.tearDownWithError()
    }

    func testLoadDemoNotesFillsTheLibrary() {
        let loadDemo = app.buttons["loadDemoNotesButton"]
        XCTAssertTrue(loadDemo.waitForExistence(timeout: 10), "The empty state should offer demo notes")
        loadDemo.tap()

        XCTAssertTrue(
            app.staticTexts["Design Review Notes"].waitForExistence(timeout: 10),
            "The demo PDF should appear in the library"
        )
        XCTAssertTrue(app.staticTexts["OCR Textbook Page"].exists)
    }

    func testSearchOpensAResultAtTheRightPage() {
        loadDemoNotes()

        app.tabBars.buttons["Search"].tap()
        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        searchField.tap()
        searchField.typeText("architecture")

        let result = app.staticTexts["Design Review Notes"]
        XCTAssertTrue(result.waitForExistence(timeout: 10), "The PDF page containing the term should be listed")
        result.tap()

        // The match is on page two of the demo PDF, so the reader must open there.
        XCTAssertTrue(
            app.buttons["pageIndicatorButton"].waitForExistence(timeout: 10),
            "The PDF reader should be showing"
        )
        XCTAssertTrue(app.buttons["pageIndicatorButton"].label.contains("Page 2"))
    }

    func testEditingRecognizedTextAndSaving() {
        loadDemoNotes()

        app.staticTexts["OCR Textbook Page"].tap()

        let editButton = app.buttons["editOCRTextButton"]
        XCTAssertTrue(editButton.waitForExistence(timeout: 10))
        editButton.tap()

        let editor = app.textViews["ocrTextEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap()
        editor.typeText("Edited by a UI test. ")

        app.buttons["saveOCRTextButton"].tap()

        // Back in the reader, the edit is part of the page text.
        XCTAssertTrue(
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Edited by a UI test")).firstMatch
                .waitForExistence(timeout: 10),
            "Saved edits should be visible in the reader"
        )
    }

    func testImportTabOffersAllThreeSources() {
        app.tabBars.buttons["Import"].tap()

        XCTAssertTrue(app.buttons["takePhotoButton"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["importPhotoButton"].exists)
        XCTAssertTrue(app.buttons["importPDFButton"].exists)
    }

    // MARK: - Helpers

    private func loadDemoNotes() {
        let loadDemo = app.buttons["loadDemoNotesButton"]
        if loadDemo.waitForExistence(timeout: 10) {
            loadDemo.tap()
        }
        XCTAssertTrue(
            app.staticTexts["Design Review Notes"].waitForExistence(timeout: 10),
            "Demo notes should be loaded before the test continues"
        )
    }
}
