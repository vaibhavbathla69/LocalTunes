# LocalTunes

A native, personal, offline iPhone music player. SwiftUI, AVFoundation, MediaPlayer and SQLite; iOS 17 or later. No runtime servers, analytics, streaming subscriptions, online lyrics services or Apple Music permissions. Bring your own unprotected audio files.

### Version 1.5: editorial design

System light/dark appearance, white/OLED-black surfaces, crimson controls, native material navigation and player dock, and five tabs including a local Browse page. Browse features large album cards and the library grid. Listen Now retains the user's history, popularity, stats and recent-import sections. Now Playing adds slowly moving cover-derived color fields, a system volume slider and a stronger play/pause artwork transition. Lyrics expand full-screen with an emphasized active line. Reduce Motion pauses background movement; materials respect system transparency preferences. Lossless badges identify supported lossless source-file extensions, not output quality or Dolby Atmos support.

### Version 1.4.2: word search

Search requires every word you type, in any order and with gaps between them: `drugs should it` finds `Drugs You Should Try It`. Partial words and case-insensitive matching are retained. Song words can match title, artist, album, genre or year; album/artist/genre browsing matches words within the collection name. Extra whitespace is ignored, and `%`, `_` and backslash remain literal characters. Filters, pagination and Play/Shuffle use the same matching rules. Existing libraries need no reimport.

### Version 1.4.1: pixel branding

A lime pixel vinyl/play mark replaces the waveform app icon and appears in Settings. The opaque square source, generation prompt and export instructions are in `branding/`. Re-export assets with `python scripts/make_icon.py` (Pillow is development-only).

### Version 1.4 — album Home, swipe to queue, and artist credits

Home now defaults to Recently played albums → Most played albums → Most played songs → Stats → Recently added. Album shelves open the full album page. Album popularity sums counted track plays; recency uses the last playback date of any track in the album. Stats and ranks refresh while Home is active. Liked-song/playlist shortcuts and the spotlight are removed. Older saved Home layouts migrate to this order; new section visibility/reordering remains customizable, and explicitly pinned items can still be added.

Swipe a song right to append it to the end of the queue, with a short Queued confirmation and haptic feedback. This works in Home, Library, album/artist/playlist lists, and search/browse lists. Swiping left still offers Play Next, Queue and Playlist; liking remains in song options and the player's heart control.

Artist pages use a derived many-to-many credit index rather than exact whole-tag grouping. `feat.`, `ft.`, `featuring`, parenthesized/bracketed title credits, semicolon/NUL/pipe lists and spaced slash lists are recognized. Featured lists also accept spaced ampersands. Main-artist punctuation is preserved (for example AC/DC, Tyler, the Creator, Earth, Wind & Fire). Repeated FLAC ARTIST fields are retained. Tracks appear under every recognized credit, and an artist's filters, queue, albums and stats use the same membership. Repeated credits never double-count one song on one page.

Case, repeated/nonbreaking spaces, common invisible characters and Unicode width/composition differences collapse to one artist key. Normalization and merging keep saved credits and audio unchanged; the index backfills existing imports on update without reimporting. Older FLAC entries also get a one-time local check for repeated ARTIST fields. Missing contributors are restored only when the cached first artist and title still match the source; reviewed or differently edited entries are kept. File tags are never rewritten. Actual misspellings are not guessed: on the preferred artist page, tap the two-person button and choose the duplicate name to merge. Merges persist for future imports and edits. Settings → Library care → Reset artist merges restores original name memberships while retaining automatic normalization. Global listening totals are not doubled when a track has several credited artists.

### Version 1.3 — library and playback tools

- Artist pages: album shelves, top tracks from local play counts, and the complete artist song list. Open an artist in Library/Search or from Now Playing options.
- Song swipes in lists: right to like, left for Play Next, Queue and Playlist. Long-press retains all actions and adds **Edit details**.
- Smart playlists: Recently added (30 days), Most played (counted plays), Forgotten favourites (liked and not played for 30 days, including never played). These update from the library rather than storing duplicate songs.
- Search filters: combine artist, album, genre and release year. Search text also matches genre/year. Recent queries are stored locally and can be cleared. Filtered Play/Shuffle uses all matching IDs, including later result pages.
- Edit title, artist, album, genre, track, disc, year and artwork in the local index. **Read details from file** refills the editor from tags. New imports read release years; for existing imports use this editor to read or set a missing year, or Settings ? Library care ? **Read missing release years** to fill missing years from your files in bulk. Audio bytes and external source files are unchanged. Changing album clears that song's old custom album rank.
- Now Playing options include **Sleep timer** (5–60 minutes, custom 1–240 minutes, or end of current queue entry), **View artist**, editing and playback settings. Timers are session-only and can be cancelled.
- Settings → Playback: crossfade from 1–8 seconds or Off. Off retains the preloaded native queue for intact album transitions. Crossfade uses an independently prepared player, linear gain ramps, and skips repeat-one/end-of-song timers; if preparation is unavailable, playback follows the normal queue. Pause, seek, queue changes, interruptions and route loss cancel overlaps. Sample-accurate gapless output remains format/device dependent and is not guaranteed.
- Optional volume balancing decodes audio in bounded PCM buffers on this phone, caches RMS/peak measurements, and attenuates louder tracks toward −20 dBFS RMS with peak headroom. It never boosts quiet tracks or changes files; this is not a broadcast LUFS loudness meter. Unmeasurable files retain their original playback level. Analyze the whole library in Settings, or measure tracks on demand when balancing is enabled.
- Customize Home with its sliders button: hide/reorder sections. Pin albums and playlists from their options; reorder/remove pins in the Home editor.
- Settings → Listening stats: local listening time, counted plays, top songs and artists, with a clear control. A play counts after 30 seconds or half the song (minimum 0.5 seconds). Pauses, buffering and seek jumps do not accrue time. Counters start with this update; previous last-played dates remain available. Time checkpoints occur every five seconds and on pause/backgrounding. Deleting a song removes its stats.

FLAC playback uses STREAMINFO sample counts for exact file duration and trims decoder padding at that endpoint. Imports now explicitly read Vorbis comments (including track/disc/year/lyrics) and picture blocks in addition to AVFoundation metadata. Two generated FLAC tones exercise native import, decoding, measurement, queue transitions, overlap and timers. They contain no personal music and are test-target resources only; `scripts/make_test_flac.py` regenerates them with optional developer tools soundfile/mutagen. Neither tool is an app or CI dependency.

The database keeps compatible schema 2 and adds a separate listening table with cascading song deletion; new song fields are optional. Existing album ordering, audio, playlists, favourites and queue state are preserved. Install over the existing app with the same signing identity.

### Version 1.2.1 — simpler labels

Removed decorative slogans, repeated subtitles and album help paragraphs from the main screens. Home, search, playlists and the player keep concise navigation labels, music metadata and controls. Album ordering, library storage and app identity are unchanged.

### Version 1.2 — album pages and correct track order

Tap the album name at the top of Now Playing, or open Library → Albums → an album, to see its artwork, artist, duration and complete numbered track list. Album Play and tapping a track build a queue for that album in disc/track-number order and turn shuffle off; Shuffle remains a separate action.

Albums use embedded disc and track tags, with a conservative filename fallback such as `01 - Song` or `2-03 Song`. Unnumbered tracks follow numbered tracks on their disc. If tags are missing or wrong, open the album's **Reorder tracks** control, drag the handles and **Save**. This saves a local custom order without rewriting audio. Album options can restore disc/track order or reread position tags from existing imported files. A saved order takes effect when you next play the album; existing queues are preserved until you start a new one.

The index migrates transactionally from schema 1 to 2 and keeps a consistent `LibraryData/library-before-v2-<UUID>.sqlite` snapshot before upgrading. Imported files, favourites, playlists and playback state are preserved. Older app versions cannot open a schema-2 index; keep this version or newer after upgrading.

### Version 1.1 — artwork comes first

Home has a visible search shortcut, spotlight card and artwork shelves. Search is the second tab and always shows a text field; Library also has its own visible filter. Home, Search, Library and Playlists are the four tabs; Settings is the gear button on Home or Library. The floating mini-player sits above the tabs, so navigation stays accessible during playback.

Now Playing, Lyrics, collection headers and the mini-player use gradients extracted from album artwork. Colors are sampled from a tiny thumbnail on a background actor and cached; gradients animate between tracks and respect Reduce Motion. Missing covers get stable album-specific palettes. Albums and artists use an artwork grid, and playlists have illustrated covers and collection headers. All themes work offline.

Install the new IPA over the existing app with the same Sideloadly account and identifier settings. Version 1.1 keeps the same bundle ID and library schema.

**An unsigned IPA cannot be installed directly. Sideloadly must sign it with your Apple Account first.** A free account normally means a seven-day signing period. The player works offline after installation; building, initial signing and refreshing require an internet connection. Keep original music and backups.

## Get the app from GitHub on Windows

1. Open [this repository's Actions page](https://github.com/vaibhavbathla69/LocalTunes/actions).
2. Select **Build iPhone IPA** in the left column.
3. Select **Run workflow**, choose `main`, then **Run workflow**. A push to `main` also starts it automatically.
4. Open the newest run and wait for a green check. Allow roughly 5–15 minutes for simulator startup, tests and device compilation. If it fails, expand the red step and download `build-diagnostics`; never install an artifact from a different commit assuming it contains new changes.
5. At the bottom of the successful run, under **Artifacts**, click **LocalTunes-unsigned-IPA**. Sign into GitHub if the download is disabled.
6. Extract the downloaded ZIP with Windows Explorer. Inside is `LocalTunes-unsigned.ipa`. Do not unzip or rename the IPA itself.

The macOS workflow selects Xcode 16.4, installs XcodeGen, generates the project, resolves dependencies (there are no external app packages), chooses an installed iPhone simulator compatible with the selected SDK, runs XCTest, and builds Release for `generic/platform=iOS` with signing disabled. It packages `Payload/LocalTunes.app` into an IPA and verifies the ZIP. No Apple credentials or certificates are needed in GitHub. Public repository standard runners are generally free; private repository Actions usage is subject to your account's allowance and pricing. Artifacts expire after 14 days; run the workflow again if necessary.

## Install using Sideloadly on Windows 11

1. Download the current Windows version from the [official Sideloadly website](https://sideloadly.io/). Follow its current prerequisites: its website links the required **web versions of iTunes and iCloud**; Microsoft Store versions may conflict. Restart Windows if the installer requests it. Apple Devices may be used for file sharing once the device is recognized, but follow Sideloadly's own driver instructions for signing.
2. Connect the iPhone by USB. Unlock it, tap **Trust This Computer**, and enter its passcode. Confirm Sideloadly lists the correct device.
3. Open Sideloadly. Drag `LocalTunes-unsigned.ipa` onto its IPA area and enter your Apple Account email. Leave app identifier settings at their default for the first installation. Record any custom identifier if you set one.
4. Enable Sideloadly's **automatic refresh** option if available, then click **Start**. Enter your Apple password and two-factor code only in Sideloadly's Apple authentication flow. Never put credentials in this repository, VS Code settings or GitHub secrets for this project.
5. If the phone requests trust for the developer, open **Settings → General → VPN & Device Management**, select the developer account and trust it. Exact wording varies with iOS. If iOS asks to verify the developer, connect to the internet for that step.
6. If prompted for Developer Mode, open **Settings → Privacy & Security → Developer Mode**, enable it, restart, then confirm enabling it after reboot. See [Apple's Developer Mode instructions](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device). If the switch is unavailable, attempt installation first and follow Sideloadly's current troubleshooting guidance.
7. Open LocalTunes. It starts with an empty collection; it includes no demo songs.

Free provisioning can impose limits on concurrently active sideloaded apps and newly registered app identifiers. Apple and Sideloadly can change these rules; authentication, device restrictions or service outages can prevent signing even when the IPA compiles. See the [official Sideloadly FAQ](https://sideloadly.io/faq). A paid membership, App Store Connect and a local Mac are not part of this workflow.

## Import a music library

For an entirely offline import, place source files in **On My iPhone**, on attached local storage accessible to Files, or transfer them over USB. Selecting a cloud-provider file may cause that provider to download it; LocalTunes itself never uploads audio.

- Tap **+ → Audio and lyric files** in Home or Library. In Files, use Select to choose several files. Supported picker types include audio and text; a provider may filter LRC files, so use a folder or attach the lyric manually if needed.
- For nested music folders and sidecar lyrics, choose **+ → Import a folder** and grant access to the folder. Folder selection capabilities vary by Files provider.
- For a 10 GB collection, use USB: open Apple Devices (or iTunes file sharing if that is your installed device-management setup), select the iPhone, open **Files / File Sharing → LocalTunes**, and add a folder named **Import**. Put music subfolders and LRC files inside it. On macOS, use Finder → iPhone → Files → LocalTunes. Open **Settings → Scan shared Import folder** in the app.
- The app creates `Music`, `Import` and `LibraryData` inside Documents, visible in Files under On My iPhone → LocalTunes. If a PC utility can only transfer a folder as a unit, transfer the whole Import folder.
- Keep the app foregrounded for a long import. iOS can suspend a backgrounded import; returning resumes the task if the process survived. If the app was terminated, reimport the same folder: exact hashes skip completed songs. Tap Cancel to stop between chunks/files.
- Imports copy source audio into `Music/<UUID>.<extension>`, extract tags and create cached artwork. The original files are preserved. After checking playback, delete redundant **source copies in Import** to recover space; the app does not do that automatically. Allow space for both source and app copies during import.
- Progress shows file count, current filename and copy progress. The results list added songs, exact duplicates, attached lyrics and up to 100 errors. Storage is shown in Settings. Corrupt, unsupported, protected or unplayable files are reported and skipped.
- Long-press a song to favourite it, play next, add to queue/playlist, or delete the app's copy. Deletion requires confirmation and does not delete the external original.

MP3, AAC/M4A, ALAC (usually inside M4A), PCM WAV, AIFF and CAF are passed to the iOS decoder. Other recognized extensions, including FLAC, are attempted when the OS/container supports them. An extension is not a guarantee of codec compatibility. DRM-protected Apple Music downloads, Ogg/Vorbis and unusual encodings may need conversion to unprotected M4A/ALAC or MP3 on your computer. No conversion or DRM bypass is implemented.

## Playback, queue and lyrics

Tap a song to play its entire current filtered list from that song. Play/Shuffle uses all matching database IDs, including songs beyond the current 100-row page. Home contains recently played, recently added, favourites and playlist access. Library groups songs by album title, artist or genre; Search has song, album and artist scopes. Playlists support creation, renaming, deleting, adding/removing songs and reordering songs or playlists with Edit.

Tap the persistent mini-player to open Now Playing. Use the slider to seek, heart to favourite, shuffle/repeat buttons, Lyrics, output selector, or queue button. Repeat cycles off → all → one. Previous restarts the current song after three seconds; otherwise it goes to the previous entry. Long-press songs for Play Next or Add to Queue. Queue entries have independent IDs, so the same song can be queued more than once. Queue Edit supports reordering and deletion.

Playback uses an audio session configured for music and continues when locked or backgrounded. Control Center, lock-screen metadata/artwork and compatible headphone commands use MediaPlayer. Losing a headphone route pauses playback. Interruptions resume only when the system permits it and the app had been playing; explicit Pause cancels that intent. Restoring the app restores its queue and position **paused**. Position checkpoints run every 10 playback seconds and on pause/backgrounding; force termination or power loss can lose the latest few seconds. Two AVPlayerItems are preloaded for smooth transitions. **Sample-accurate gapless playback is not promised**, especially for MP3 encoder padding or mixed codecs; use consistently encoded ALAC/AAC for the most reliable transitions and test your albums on the phone.

Embedded lyrics are read through AVFoundation's lyrics and metadata APIs when the container exposes them. For sidecars, name `Song.mp3` and `Song.lrc` alike, or use the song title or `Artist - Title`. Select both files or import their parent folder. More than one matching song produces an ambiguity error; attach manually instead. Manually saved lyrics are protected from later automatic imports.

LRC accepts `[mm:ss]`, `[mm:ss.xx]`, `[mm:ss.xxx]`, multiple timestamps per line and millisecond `[offset:...]` tags. Lines are sorted and co-timed translations are combined. The active line highlights and scrolls automatically; drag to read elsewhere, then tap Follow Lyrics to resume. Tap any timed line to seek. Plain text remains scrollable and selectable. In Lyrics → **…**, attach a UTF-8/UTF-16 text/LRC file or paste/edit lyrics. The limit is 4 MB. Unsupported embedded binary SYLT frames or container-specific lyric tags may not be exposed by AVFoundation; export them as an LRC/text sidecar and attach it. No online lyric lookup occurs.

## Refresh before seven days and update safely

Sideloadly documents a seven-day period for a normal free account. Automatic refresh requires its daemon to be running and the paired phone reachable over USB or configured Wi-Fi. Keep the computer on periodically and check that refreshing succeeded; a practical manual routine is to refresh every five or six days. See [Sideloadly's refresh instructions](https://sideloadly.io/faq.html).

To refresh manually, connect/unlock the phone and sign/install the same IPA again using the **same Apple Account and app identifier**. To update, download the newest green build and install that IPA **over the existing app** using the same settings. Sideloadly specifically documents same-account, same-bundle-ID overwrite installation for preserving local progress. Do not delete the installed app first. Do not change the identifier or switch accounts expecting the same container. Free-signing expiry generally blocks launching; it is not a reason to uninstall. Back up first: preservation depends on iOS recognizing the same app identity and is not an absolute guarantee.

## Back up and restore

Audio files are local and deliberately excluded from automatic iCloud device backup to avoid silently uploading your collection. Keep your originals. For a complete manual backup:

1. Finish/cancel imports, pause playback and open Settings → **Prepare index backup for file sharing**. This uses SQLite's online backup API, so the snapshot includes committed WAL contents.
2. Copy `LibraryIndex-backup.sqlite`, the entire `Music` folder, and `LibraryData/Artwork` and `LibraryData/Lyrics` to your computer using Files/USB file sharing. Keep their relative paths. The snapshot contains songs, favourites, playlists and queue state; audio and lyric/artwork files are separate. The auto-follow preference is a device UserDefaults setting rather than part of the index snapshot.
3. To restore, back up the target installation first and force-close LocalTunes. Replace `Music`, `LibraryData/Artwork`, and `LibraryData/Lyrics` with the backup copies. Put a copy of `LibraryIndex-backup.sqlite` into `LibraryData` named **library.sqlite**. Remove that target's old `library.sqlite-wal` and `library.sqlite-shm` **only while the app is closed and after backing up the target**; they belong to the old database. Launch the app. If your file-sharing tool cannot manipulate nested folders, assemble and replace the entire LibraryData folder on the PC while the app is closed. Do not restore while the app is running.

Schema version 2 is created transactionally. Unknown newer schemas produce a recovery message; the app never destroys/recreates a database on migration failure. Settings can check for missing audio without removing entries. Reimporting a byte-identical original repairs a missing managed file. Crash-interrupted staging/orphan files are not automatically deleted; back up first before manual cleanup. If metadata is intact, unindexed audio can be recovered by selecting its managed file for reimport, then removing the old orphan after verifying the new copy. Never manually rename managed files without updating the index.

## Develop in VS Code on Windows

Install VS Code, Git for Windows and optionally a Swift syntax extension. Clone this repository (or use the existing workspace):

```powershell
git clone https://github.com/vaibhavbathla69/LocalTunes.git
cd LocalTunes
code .
```

Edit Swift files; there is no npm install, web server or WebView. Native iOS frameworks and Xcode are not available on Windows, so Windows cannot compile/run this app or supply full iOS type checking. Commit and push to run macOS verification:

```powershell
git add .
git commit -m "Describe your change"
git push origin main
```

If starting from an empty GitHub repository in another workspace, use `git init -b main`, `git add .`, `git commit -m "Initial app"`, `git remote add origin YOUR_REPOSITORY_URL`, then `git push -u origin main`. Never add personal audio, credentials, private keys, profiles or certificates. `.gitignore` excludes common audio and signing files; review staged changes before committing.

Set the display name and bundle identifier in **Config/App.xcconfig** before the first installation. Keep the identifier unchanged for updates. The target/scheme and IPA filename remain LocalTunes even if you change the display name. Version/build are in `project.yml`. Xcode projects are generated and ignored; edit XcodeGen configuration, not generated files. The pixel icon and Settings brand mark can be exported from the selected artwork with `python -m pip install Pillow` and `python scripts/make_icon.py`; Pillow is development-only, not an app dependency. See `branding/README.md` for the original generation prompt.

```text
Config/                     Display name, bundle ID, Info.plist/background/file sharing
LocalTunes/App/             Bootstrap and application coordination
LocalTunes/Models/          Song/playlist models and pure queue operations
LocalTunes/Persistence/     Actor-isolated SQLite store and backup
LocalTunes/Services/        Imports, metadata, lyrics parsing, playback, paths
LocalTunes/Views/           Native tabs, lists, artwork cache, player, lyrics, settings
LocalTunes/Resources/       App icon and accent asset catalog
LocalTunesTests/            Queue, SQLite indexing, import, lyric and fallback XCTest
.github/workflows/ios.yml   Simulator tests + unsigned physical-iPhone IPA
scripts/                    Compatible simulator selection and icon generation
docs/                       Architecture and device acceptance checklist
```

## Validation and practical limits

Compilation and XCTest run on GitHub-hosted macOS, not locally on Windows. See the newest [Actions run](https://github.com/vaibhavbathla69/LocalTunes/actions) for the exact verified commit; this README is not a claim that unpushed changes passed. Tests cover queue operations/persistence, paged SQLite queries, duplicates, literal search, fallback metadata, generated WAV importing, corrupt input cleanup, safe backups, unknown-schema refusal and lyric timing. XCUITest checks navigation, playlist creation, real imported-audio playback, queue and lyrics; its screenshots are exported into `build-diagnostics`. Synthetic audio is generated during tests through the real importer. UI test seeding is guarded by DEBUG and explicit isolated-test arguments and is absent from Release; normal launches contain no songs. See [the physical-device checklist](docs/DEVICE_TESTING.md) before relying on a large daily-use library. Bluetooth, lock-screen behavior, 10 GB performance, signing, migration/restore and audio transitions require real-device acceptance testing.

There is no waveform analysis, equalizer, ReplayGain, smart playlists, tag editor or guaranteed sample-accurate gapless decoder. Album grouping currently uses album title; different artists' albums with the same title appear together. Search uses bound SQLite LIKE queries with indexed ordering and lazy pages; substring searches scan metadata, so very large indexes may need future FTS migration. Audio is never loaded wholesale; artwork is downsampled to 900 px/180 px with a bounded memory cache. Artist/genre group summaries and playlist IDs stay in memory; huge individual playlists load their metadata, not their audio. The app cannot overcome iOS signing expiry, Files provider restrictions or system suspension of long background imports.

## Implementation phases

1. **Foundation:** XcodeGen config, five-tab native shell, Song/Playlist/Queue models, SQLite schema, unsigned macOS build. Initial CI detected a missing icon; the next Phase 1 build fixed it and produced an IPA.
2. **Import/index:** ImportService, MetadataExtractor, LibraryPaths, sidecar matching, duplicate and missing-file repair, progress/errors and safe source preservation.
3. **Playback:** PlaybackService implements AVQueuePlayer, persisted queue/position, audio session, remote controls, interruptions/routes and media-service reset handling.
4. **Features/UI:** LibraryModel and SwiftUI views connect importing, browsing, local search, lyrics, playlists, favourites, queue management and storage.
5. **Polish/verification:** Artwork caching, native dark styling/accessibility, test coverage, index backup, device checklist and Windows documentation. Each phase's committed source is verified via CI; real-device checks remain separate.
