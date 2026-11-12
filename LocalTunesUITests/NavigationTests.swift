import XCTest

final class NavigationTests: XCTestCase {
    @MainActor
    func testEmptyLibraryNavigationAndPlaylistCreation() throws {
        let app = XCUIApplication()
        app.launchArguments.append("--ui-test-isolated-library")
        app.launch()
        XCTAssertTrue(app.staticTexts["A little closer\nto your music."].waitForExistence(timeout: 15))
        capture(app, name: "01-Home")
        app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(app.buttons["Import music"].waitForExistence(timeout: 5))
        capture(app, name: "02-Library")
        app.tabBars.buttons["Search"].tap()
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 5))
        app.searchFields.firstMatch.tap()
        app.searchFields.firstMatch.typeText("A song")
        XCTAssertTrue(app.staticTexts["No matches"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        app.tabBars.buttons["Playlists"].tap()
        app.buttons["Create playlist"].tap()
        let alert = app.alerts["New playlist"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.textFields.firstMatch.typeText("Evening listening")
        alert.buttons["Create"].tap()
        XCTAssertTrue(app.staticTexts["Evening listening"].waitForExistence(timeout: 5))
        capture(app, name: "03-Playlists")
        app.staticTexts["Evening listening"].tap()
        XCTAssertTrue(app.buttons["Add songs"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.staticTexts["Indexed audio"].waitForExistence(timeout: 5))
        capture(app, name: "04-Settings")
    }

    @MainActor
    func testImportedAudioPlaybackQueueAndLyrics() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-isolated-library", "--ui-test-seed-audio"]
        app.launch()
        XCTAssertTrue(app.staticTexts["A little closer\nto your music."].waitForExistence(timeout: 20))
        app.tabBars.buttons["Library"].tap()
        let song = app.buttons["song.CI reference tone"]
        XCTAssertTrue(song.waitForExistence(timeout: 10))
        song.tap()
        XCTAssertTrue(app.buttons["miniPlayer"].waitForExistence(timeout: 10))
        app.buttons["miniPlayer"].tap()
        let control = app.buttons["nowPlaying.playPause"]
        XCTAssertTrue(control.waitForExistence(timeout: 5))
        let playing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Pause'"), object: control)
        XCTAssertEqual(XCTWaiter.wait(for: [playing], timeout: 10), .completed)
        control.tap()
        let paused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Play'"), object: control)
        XCTAssertEqual(XCTWaiter.wait(for: [paused], timeout: 5), .completed)
        capture(app, name: "05-NowPlaying")
        if !app.buttons["nowPlaying.lyrics"].isHittable { app.swipeUp() }
        app.buttons["nowPlaying.lyrics"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Music stays with you'")).firstMatch.waitForExistence(timeout: 5))
        capture(app, name: "06-Lyrics")
        app.buttons["Done"].tap()
        if !app.buttons["nowPlaying.queue"].isHittable { app.swipeUp() }
        app.buttons["nowPlaying.queue"].tap()
        XCTAssertTrue(app.navigationBars["Your queue"].waitForExistence(timeout: 5))
        capture(app, name: "07-Queue")
    }

    @MainActor
    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
