# Physical iPhone acceptance checklist

CI verifies compilation and automated logic; it cannot prove daily-use reliability on your hardware. Start with copies of a few files and back up before the full collection.

- Install with a free Apple Account and enable required trust/Developer Mode. Open with airplane mode enabled after installation.
- Import tagged MP3, AAC/M4A, ALAC, WAV and a missing-tag file. Check title, artist, album, genre, track extraction, duration and artwork. Try your own FLAC/other container separately.
- Import identical bytes with a different filename: one library entry. Import different bytes with the same basename: distinct entries. Try corrupt, empty, protected, very long and oversized files. Confirm errors preserve originals and remove partial app files.
- Select several files, import a nested local folder, use a third-party Files provider and scan a USB-transferred Import folder. Include multiple same-name songs and ambiguous LRCs. Cancel during a large copy, lock/unlock, switch apps, return and restart after force termination. Reimport to resume safely.
- Play a song after the 100th row to verify pagination and full-result queue construction. Search Unicode and literal %, _ and backslash characters. Browse same-title albums from different artists (current documented grouping limitation).
- Play, pause, seek rapidly, skip rapidly, previous before/after three seconds, shuffle off/on, repeat one/all/off, last song ending, repeat boundary, add next, duplicate queue entries, reorder/delete current/upcoming entries. Restart and confirm paused queue/position restoration.
- Play locked for 30 minutes. Use lock-screen and Control Center play/pause/seek/skip/artwork. Test AirPods, wired controls, Bluetooth connect/disconnect, route picker and removal while paused/playing.
- Receive/decline/answer a phone call, trigger Siri/alarm/navigation audio, pause explicitly during an interruption and confirm it stays paused. Where available, use Settings → Developer → Reset Media Services; confirm the app rebuilds audio objects and waits for the user to press Play.
- Compare album transition timing for ALAC/AAC/MP3. Gapless is best effort; record audible padding/gaps and use consistently encoded lossless files as an alternative.
- Read embedded plain lyrics, UTF-8/UTF-16 LRC, repeated timestamps, offsets, missing and malformed lyrics. Tap lines to seek, drag to stop following, restore follow and test Reduce Motion. Attach/edit/save/clear lyrics, restart and reimport without overriding manual edits.
- Create/rename/reorder/delete playlists, add/remove/reorder songs, favourite/unfavourite and restart. Delete a playing song and confirm queue/playlist cleanup plus preservation of the original source.
- With at least 10 GB imported, measure import time, free-space reporting, memory, launch/search/scroll latency and battery use using representative files. Check low-space failures. Artwork should be cached; source copies in Import count toward storage until you delete them.
- Enable VoiceOver and large Dynamic Type; inspect smallest/largest iPhone sizes, landscape, screen contrast, button labels and sheet dismissal. Visual layout still needs physical or simulator screenshot review.
- Prepare an index backup, copy all documented files off device, restore to a separate test installation and confirm audio/lyrics/playlist/queue consistency. Keep the primary library until verification finishes.
- Refresh before seven days, verify the original library survives. Install a newer IPA over it using the same account/identity. Test expiry/re-signing without uninstalling. Never change the only production app identity as a test.

Report the commit SHA, iOS version, iPhone model, source codec/container and exact steps for any failure. Share sanitized logs/metadata only; personal audio does not need to enter GitHub.
