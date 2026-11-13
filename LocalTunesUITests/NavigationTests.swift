import XCTest

final class NavigationTests: XCTestCase {
    @MainActor
    func testEmptyLibraryNavigationAndPlaylistCreation() throws {
        let app = XCUIApplication()
        app.launchArguments.append("--ui-test-isolated-library")
        app.launch()
        XCTAssertTrue(app.buttons["home.search"].waitForExistence(timeout: 15))
        capture(app, name: "01-Home")
        app.buttons["home.search"].tap()
        XCTAssertTrue(app.textFields["localSearchField"].waitForExistence(timeout: 5))
        app.buttons["search.dismissKeyboard"].tap()
        app.tabBars.buttons["Library"].tap()
        XCTAssertTrue(app.buttons["Import music"].waitForExistence(timeout: 5))
        capture(app, name: "02-Library")
        app.tabBars.buttons["Search"].tap()
        let field = app.textFields["localSearchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("A song")
        XCTAssertTrue(app.staticTexts["No matches"].waitForExistence(timeout: 5))
        capture(app, name: "08-VisibleSearch")
        app.buttons["search.dismissKeyboard"].tap()
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
        app.tabBars.buttons["Home"].tap()
        app.buttons["Open settings"].tap()
        XCTAssertTrue(app.staticTexts["Indexed audio"].waitForExistence(timeout: 5))
        capture(app, name: "04-Settings")
    }

    @MainActor
    func testImportedAudioPlaybackQueueAndLyrics() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-isolated-library", "--ui-test-seed-audio"]
        app.launch()
        XCTAssertTrue(app.buttons["home.search"].waitForExistence(timeout: 20))
        capture(app, name: "09-HomeWithArtwork")
        app.tabBars.buttons["Search"].tap()
        let search = app.textFields["localSearchField"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        capture(app, name: "14-SearchBrowse")
        search.tap(); search.typeText("CI reference")
        XCTAssertTrue(app.buttons["song.CI reference tone"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["song.CI second tone"].exists)
        capture(app, name: "10-SearchResults")
        app.buttons["search.dismissKeyboard"].tap()
        app.tabBars.buttons["Library"].tap()
        app.buttons["Albums"].tap()
        XCTAssertTrue(app.buttons["collection.album.After Hours"].waitForExistence(timeout: 5))
        capture(app, name: "13-AlbumGrid")
        app.buttons["Songs"].tap()
        let song = app.buttons["song.CI reference tone"]
        XCTAssertTrue(song.waitForExistence(timeout: 10))
        song.tap()
        XCTAssertTrue(app.buttons["miniPlayer"].waitForExistence(timeout: 10))
        capture(app, name: "11-LibraryWithMiniPlayer")
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
        XCTAssertTrue(app.navigationBars["Queue"].waitForExistence(timeout: 5))
        capture(app, name: "07-Queue")
        app.buttons["Done"].tap()
        app.buttons["nowPlaying.next"].tap()
        let nextTrack = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'CI second tone'"), object: app.staticTexts["nowPlaying.title"])
        XCTAssertEqual(XCTWaiter.wait(for: [nextTrack], timeout: 5), .completed)
        capture(app, name: "12-CoolAlbumGradient")
        app.buttons["Close Now Playing"].tap()
        app.tabBars.buttons["Search"].tap()
        XCTAssertTrue(app.textFields["localSearchField"].isHittable)
        XCTAssertTrue(app.buttons["miniPlayer"].isHittable)
    }

    @MainActor
    func testAlbumPageFromLibraryAndNowPlayingUsesTrackOrder() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-isolated-library", "--ui-test-seed-audio", "--ui-test-seed-album"]
        app.launch()
        XCTAssertTrue(app.buttons["home.search"].waitForExistence(timeout: 20))
        app.tabBars.buttons["Library"].tap()
        app.buttons["Albums"].tap()
        let album = app.buttons["collection.album.After Hours"]
        XCTAssertTrue(album.waitForExistence(timeout: 5))
        album.tap()
        let first = app.buttons["album.track.CI Zulu opener"]
        let second = app.buttons["album.track.CI reference tone"]
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        XCTAssertTrue(second.exists)
        XCTAssertLessThan(first.frame.minY, second.frame.minY, "Track 1 must precede track 2 even when its title sorts later.")
        capture(app, name: "15-AlbumPage")
        app.buttons["album.play"].tap()
        XCTAssertTrue(app.buttons["miniPlayer"].waitForExistence(timeout: 5))
        app.buttons["miniPlayer"].tap()
        XCTAssertTrue(app.staticTexts["nowPlaying.title"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["nowPlaying.title"].label, "CI Zulu opener")
        app.buttons["nowPlaying.album"].tap()
        XCTAssertTrue(app.buttons["player.album.reorder"].waitForExistence(timeout: 5))
        capture(app, name: "16-AlbumFromPlayer")
        app.buttons["player.album.reorder"].tap()
        XCTAssertTrue(app.buttons["album.order.save"].waitForExistence(timeout: 5))
        capture(app, name: "17-ReorderAlbum")
        app.buttons["album.order.cancel"].tap()
        app.buttons["album.done"].tap()
        app.buttons["nowPlaying.next"].tap()
        let nextTrack = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'CI reference tone'"), object: app.staticTexts["nowPlaying.title"])
        XCTAssertEqual(XCTWaiter.wait(for: [nextTrack], timeout: 5), .completed)
    }

    @MainActor
    func testDiscoveryCustomizationFiltersArtistAndStats() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-isolated-library", "--ui-test-seed-audio"]
        app.launch()
        XCTAssertTrue(app.buttons["home.customize"].waitForExistence(timeout: 20))
        app.buttons["home.customize"].tap()
        XCTAssertTrue(app.switches["home.section.mostPlayedSongs"].waitForExistence(timeout: 5))
        app.switches["home.section.mostPlayedSongs"].coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)).tap()
        XCTAssertEqual(app.switches["home.section.mostPlayedSongs"].value as? String, "0")
        capture(app, name: "18-CustomizeHome")
        app.buttons["home.customize.save"].tap()
        app.buttons["home.customize"].tap()
        XCTAssertEqual(app.switches["home.section.mostPlayedSongs"].value as? String, "0")
        app.buttons["home.customize.save"].tap()
        app.buttons["Open settings"].tap()
        XCTAssertTrue(app.buttons["settings.playback"].waitForExistence(timeout: 5))
        app.buttons["settings.playback"].tap()
        XCTAssertTrue(app.switches["playback.balancing"].waitForExistence(timeout: 5))
        capture(app, name: "19-PlaybackSettings")
        app.navigationBars.buttons["Settings"].tap()
        app.buttons["settings.stats"].tap()
        XCTAssertTrue(app.staticTexts["Listening time"].waitForExistence(timeout: 5))
        capture(app, name: "20-ListeningStats")
        app.tabBars.buttons["Search"].tap()
        app.buttons["search.filters"].tap()
        let year = app.textFields["search.filter.year"]
        XCTAssertTrue(year.waitForExistence(timeout: 5))
        year.tap(); year.typeText("2024")
        capture(app, name: "21-SearchFilters")
        app.buttons["search.filter.apply"].tap()
        XCTAssertTrue(app.buttons["song.CI reference tone"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["song.CI second tone"].exists)
        app.tabBars.buttons["Library"].tap()
        app.buttons["Artists"].tap()
        app.buttons["collection.artist.LocalTunes Studio"].tap()
        XCTAssertTrue(app.navigationBars["LocalTunes Studio"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Top songs"].exists)
        capture(app, name: "22-Artist")
        app.tabBars.buttons["Playlists"].tap()
        app.buttons["smart.mostPlayed"].tap()
        XCTAssertTrue(app.navigationBars["Most played"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testSongSwipeEditorAndSleepTimer() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-isolated-library", "--ui-test-seed-audio"]
        app.launch()
        XCTAssertTrue(app.buttons["home.search"].waitForExistence(timeout: 20))
        app.tabBars.buttons["Library"].tap()
        let song = app.buttons["song.CI reference tone"]
        XCTAssertTrue(song.waitForExistence(timeout: 5))
        song.swipeLeft()
        XCTAssertTrue(app.buttons["Next"].waitForExistence(timeout: 5))
        capture(app, name: "23-SwipeActions")
        app.buttons["Next"].tap()
        XCTAssertTrue(app.buttons["miniPlayer"].waitForExistence(timeout: 5))
        app.buttons["miniPlayer"].tap()
        XCTAssertTrue(app.buttons["nowPlaying.playPause"].waitForExistence(timeout: 5))
        capture(app, name: "26-PlayerBeforeOptions")
        let optionsReady = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: app.buttons["nowPlaying.options"])
        XCTAssertEqual(XCTWaiter.wait(for: [optionsReady], timeout: 5), .completed)
        app.buttons["nowPlaying.options"].tap()
        app.buttons["Sleep timer"].tap()
        XCTAssertTrue(app.buttons["sleep.endOfSong"].waitForExistence(timeout: 5))
        capture(app, name: "24-SleepTimer")
        app.buttons["sleep.endOfSong"].tap()
        app.buttons["nowPlaying.options"].tap()
        app.buttons["Sleep timer (on)"].tap()
        XCTAssertTrue(app.buttons["sleep.cancel"].waitForExistence(timeout: 5))
        app.buttons["sleep.cancel"].tap()
        app.buttons["nowPlaying.options"].tap()
        app.buttons["Edit details"].tap()
        XCTAssertTrue(app.textFields["song.edit.title"].waitForExistence(timeout: 5))
        capture(app, name: "25-EditSong")
        app.buttons["song.edit.save"].tap()
        XCTAssertTrue(app.staticTexts["nowPlaying.title"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["nowPlaying.title"].label, "CI reference tone")
    }

    @MainActor
    func testHomeUsesAlbumHistoryThenSongsStatsAndRecentImports() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-isolated-library", "--ui-test-seed-audio", "--ui-test-seed-history"]
        app.launch()
        XCTAssertTrue(app.buttons["home.recent.album.After Hours"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Recently played albums"].exists)
        XCTAssertFalse(app.buttons["Liked songs"].exists)
        capture(app, name: "27-HomeAlbumHistory")
        scrollTo(app.staticTexts["Most played songs"], app: app)
        XCTAssertTrue(app.buttons["home.popular.CI second tone"].exists)
        scrollTo(app.buttons["home.stats"], app: app)
        capture(app, name: "28-HomeSongsAndStats")
        app.buttons["home.stats"].tap()
        XCTAssertTrue(app.staticTexts["Listening time"].waitForExistence(timeout: 5))
        app.navigationBars.buttons["Home"].tap()
        scrollTo(app.staticTexts["Recently added"], app: app)
        XCTAssertTrue(app.tabBars.buttons["Playlists"].exists)
    }

    @MainActor
    func testRightSwipeAddsToQueueWithoutReplacingOrPausingCurrentTrack() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-isolated-library", "--ui-test-seed-audio"]
        app.launch()
        XCTAssertTrue(app.buttons["home.search"].waitForExistence(timeout: 20))
        app.tabBars.buttons["Library"].tap()
        app.buttons["song.CI reference tone"].tap()
        XCTAssertTrue(app.buttons["miniPlayer"].waitForExistence(timeout: 5))
        let row = app.buttons["song.CI second tone"]
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).press(forDuration: 0.05, thenDragTo: row.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)))
        capture(app, name: "29-RightSwipeQueue")
        app.buttons["miniPlayer"].tap()
        XCTAssertTrue(app.staticTexts["nowPlaying.title"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["nowPlaying.title"].label, "CI reference tone")
        let playing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Pause'"), object: app.buttons["nowPlaying.playPause"])
        XCTAssertEqual(XCTWaiter.wait(for: [playing], timeout: 5), .completed)
        app.buttons["nowPlaying.queue"].tap()
        XCTAssertTrue(app.staticTexts["3 tracks"].waitForExistence(timeout: 5))
        capture(app, name: "30-QueueAfterRightSwipe")
    }

    @MainActor
    func testFeaturedArtistsShareSongsAndDuplicateNamesCanMerge() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-isolated-library", "--ui-test-seed-audio", "--ui-test-seed-artists"]
        app.launch()
        XCTAssertTrue(app.buttons["home.search"].waitForExistence(timeout: 20))
        app.tabBars.buttons["Library"].tap()
        app.buttons["Artists"].tap()
        let travis = app.buttons["collection.artist.Travis Scott"]
        scrollTo(travis, app: app)
        travis.tap()
        XCTAssertTrue(app.buttons["song.CI Travis collab"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["song.CI Travis solo"].exists)
        capture(app, name: "31-PrimaryArtistWithFeatures")
        app.navigationBars.buttons["Library"].tap()
        let guest = app.buttons["collection.artist.The Weeknd"]
        scrollTo(guest, app: app)
        guest.tap()
        XCTAssertTrue(app.buttons["song.CI Travis collab"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["song.CI Weeknd solo"].exists)
        capture(app, name: "32-FeaturedArtist")
        app.navigationBars.buttons["Library"].tap()
        let frank = app.buttons["collection.artist.Frank Ocean"]
        for _ in 0..<5 { if frank.isHittable { break }; app.swipeDown() }
        XCTAssertTrue(frank.isHittable)
        frank.tap()
        app.buttons["artist.merge"].tap()
        let alias = app.buttons["artist.merge.FrankOcean"]
        XCTAssertTrue(alias.waitForExistence(timeout: 5))
        alias.tap()
        app.buttons["Merge artist"].tap()
        XCTAssertTrue(app.buttons["song.CI Frank alias"].waitForExistence(timeout: 5))
        capture(app, name: "33-MergedArtist")
        app.navigationBars.buttons["Library"].tap()
        let removed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["collection.artist.FrankOcean"])
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 5), .completed)
    }

    @MainActor
    private func scrollTo(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<7 { if element.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(element.isHittable)
    }

    @MainActor
    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
