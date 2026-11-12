import Foundation
import Combine
import AVFoundation
import MediaPlayer
import UIKit
import OSLog

@MainActor
final class PlaybackService: ObservableObject {
    @Published private(set) var queue = PlaybackQueue()
    @Published private(set) var currentSong: Song?
    @Published private(set) var isPlaying = false
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published var errorMessage: String?

    private var player = AVQueuePlayer()
    private let db: LibraryDatabase
    private let paths: LibraryPaths
    private let logger = Logger(subsystem: "LocalTunes", category: "Playback")
    private var observations: [NSKeyValueObservation] = []
    private var statusObservation: NSKeyValueObservation?
    private var notifications: [NSObjectProtocol] = []
    private var timeObserver: Any?
    private var remoteTargets: [(MPRemoteCommand, Any)] = []
    private var itemEntries: [ObjectIdentifier: QueueEntry] = [:]
    private var itemSongs: [ObjectIdentifier: Song] = [:]
    private var handledItem: ObjectIdentifier?
    private var generation = 0
    private var isRebuilding = false
    private var refillGeneration: Int?
    private var lastSavedPosition: Double = -100
    private var resumeAfterInterruption = false

    init(db: LibraryDatabase, paths: LibraryPaths) {
        self.db = db; self.paths = paths
        configurePlayer()
        observeNotifications()
        configureRemoteCommands()
    }

    private func configurePlayer() {
        player.actionAtItemEnd = .advance
        player.automaticallyWaitsToMinimizeStalling = true
        observations.append(player.observe(\.currentItem, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in await self?.currentItemChanged() }
        })
        observations.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor in
                guard let self else { return }
                self.isPlaying = player.timeControlStatus == .playing
                self.updateNowPlaying()
            }
        })
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in self?.tick(time.seconds) }
        }
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        notifications.forEach(NotificationCenter.default.removeObserver)
        for (command, target) in remoteTargets { command.removeTarget(target) }
    }

    func restore() async {
        do {
            if let saved = try await db.state("queue", as: PlaybackQueue.self) {
                queue = saved
                let valid = Set(try await db.allIDs())
                queue.remove(entryIDs: Set(queue.entries.filter { !valid.contains($0.songID) }.map(\.id)))
                let savedPosition = try await db.state("position", as: Double.self) ?? queue.position
                await rebuild(autoplay: false, seekTo: savedPosition)
            }
        } catch { report(error) }
    }

    func play(ids: [String], startingAt id: String? = nil) async {
        queue.replace(ids, startAt: id.flatMap { ids.firstIndex(of: $0) } ?? 0)
        saveQueue()
        await rebuild(autoplay: true)
    }

    func toggle() async { if isPlaying { pause() } else { await resume() } }

    func resume() async {
        guard queue.current != nil else { return }
        do {
            try activateSession()
            if player.currentItem == nil || position >= duration - 0.1 { await rebuild(autoplay: true) }
            else { player.play(); updateNowPlaying() }
        } catch { report(error) }
    }

    func pause() {
        resumeAfterInterruption = false
        player.pause(); isPlaying = false; savePosition(); updateNowPlaying()
    }

    func seek(_ value: Double) {
        guard value.isFinite, duration > 0 else { return }
        let target = min(max(value, 0), duration)
        position = target; queue.position = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in self?.updateNowPlaying() }
        }
        savePosition()
    }

    func next() async {
        guard let entry = queue.following(automatic: false) else { pause(); seek(0); return }
        queue.currentID = entry.id; queue.position = 0
        saveQueue(); await rebuild(autoplay: true)
    }

    func previous() async {
        if position > 3 { seek(0); return }
        guard let index = queue.currentIndex, !queue.entries.isEmpty else { return }
        let previous = index > 0 ? index - 1 : (queue.repeatMode == .all ? queue.entries.count - 1 : 0)
        queue.currentID = queue.entries[previous].id; queue.position = 0
        saveQueue(); await rebuild(autoplay: true)
    }

    func append(_ id: String, next: Bool) async {
        let wasEmpty = queue.current == nil
        queue.position = position
        queue.append(id, next: next); saveQueue()
        if wasEmpty { await rebuild(autoplay: false) } else { await replaceUpcoming() }
    }

    func jump(to entryID: String) async {
        guard queue.entries.contains(where: { $0.id == entryID }) else { return }
        queue.currentID = entryID; queue.position = 0; saveQueue()
        await rebuild(autoplay: true)
    }

    func remove(entryIDs: Set<String>) async {
        let old = queue.currentID, playing = isPlaying
        queue.position = position
        queue.remove(entryIDs: entryIDs); saveQueue()
        if old != queue.currentID { await rebuild(autoplay: playing) }
        else { await replaceUpcoming() }
    }

    func removeSong(_ id: String) async {
        await remove(entryIDs: Set(queue.entries.filter { $0.songID == id }.map(\.id)))
    }

    func move(from offsets: IndexSet, to destination: Int) async {
        queue.position = position
        queue.move(from: offsets, to: destination); saveQueue(); await replaceUpcoming()
    }

    func toggleShuffle() async { queue.position = position; queue.toggleShuffle(); saveQueue(); await replaceUpcoming() }
    func cycleRepeat() async { queue.position = position; queue.repeatMode = queue.repeatMode.next; saveQueue(); await replaceUpcoming() }

    func refreshSong(_ song: Song) {
        if currentSong?.id == song.id { currentSong = song; updateNowPlaying() }
    }

    func savePosition() {
        queue.position = position
        let value = position
        lastSavedPosition = value
        Task { do { try await db.setState("position", value: value) } catch { report(error) } }
    }

    private func saveQueue() {
        let snapshot = queue
        Task {
            do {
                try await db.setState("queue", value: snapshot)
                try await db.setState("position", value: snapshot.position)
            } catch { report(error) }
        }
    }

    private func activateSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [])
        try session.setActive(true)
    }

    private func rebuild(autoplay: Bool, seekTo: Double = 0) async {
        generation += 1
        let token = generation
        isRebuilding = true
        player.pause(); player.removeAllItems()
        itemEntries.removeAll(); itemSongs.removeAll(); handledItem = nil
        position = 0; duration = 0
        guard let entry = queue.current else {
            currentSong = nil; isPlaying = false; isRebuilding = false
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        do {
            guard let song = try await db.song(entry.songID) else { throw LibraryError.message("This song is no longer in the library.") }
            guard token == generation else { return }
            currentSong = song; duration = song.duration
            guard FileManager.default.fileExists(atPath: paths.audioURL(for: song).path) else {
                throw LibraryError.message("The audio file is missing. Reimport the original file to repair this song.")
            }
            let item = makeItem(song, entry: entry)
            handledItem = ObjectIdentifier(item)
            player.insert(item, after: nil)
            observeStatus(item)
            let target = seekTo.isFinite ? min(max(0, seekTo), max(0, song.duration - 0.05)) : 0
            position = target
            if target > 0 { await player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }
            guard token == generation else { return }
            isRebuilding = false
            await fillUpcoming()
            guard token == generation else { return }
            if autoplay {
                try activateSession(); player.play()
                try await db.recordPlay(song.id)
            }
            updateNowPlaying(loadArtwork: true)
        } catch {
            guard token == generation else { return }
            isRebuilding = false; isPlaying = false; report(error)
        }
    }

    private func makeItem(_ song: Song, entry: QueueEntry) -> AVPlayerItem {
        let item = AVPlayerItem(url: paths.audioURL(for: song))
        itemEntries[ObjectIdentifier(item)] = entry
        itemSongs[ObjectIdentifier(item)] = song
        return item
    }

    private func fillUpcoming() async {
        guard !isRebuilding, player.items().count < 2, let entry = queue.following(automatic: true) else { return }
        let token = generation
        guard refillGeneration != token else { return }
        refillGeneration = token
        defer { if refillGeneration == token { refillGeneration = nil } }
        do {
            guard let song = try await db.song(entry.songID), token == generation,
                  player.items().count < 2, queue.following(automatic: true)?.id == entry.id else { return }
            // Leave a missing upcoming item for a clear error at transition; never silently erase it.
            let item = makeItem(song, entry: entry)
            if player.canInsert(item, after: player.items().last) { player.insert(item, after: player.items().last) }
        } catch { report(error) }
    }

    private func replaceUpcoming() async {
        generation += 1
        let current = player.currentItem
        for item in player.items() where item !== current {
            player.remove(item)
            itemEntries.removeValue(forKey: ObjectIdentifier(item)); itemSongs.removeValue(forKey: ObjectIdentifier(item))
        }
        await fillUpcoming()
    }

    private func currentItemChanged() async {
        guard !isRebuilding else { return }
        guard let item = player.currentItem else {
            isPlaying = false; position = duration; savePosition(); updateNowPlaying(); return
        }
        let key = ObjectIdentifier(item)
        guard key != handledItem, let entry = itemEntries[key], let song = itemSongs[key] else { return }
        handledItem = key
        queue.currentID = entry.id; queue.position = 0
        currentSong = song; duration = song.duration; position = 0
        let valid = Set(player.items().map(ObjectIdentifier.init))
        itemEntries = itemEntries.filter { valid.contains($0.key) }
        itemSongs = itemSongs.filter { valid.contains($0.key) }
        observeStatus(item); saveQueue()
        do { try await db.recordPlay(song.id) } catch { report(error) }
        updateNowPlaying(loadArtwork: true)
        await fillUpcoming()
    }

    private func observeStatus(_ item: AVPlayerItem) {
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor in
                guard let self, self.player.currentItem === item else { return }
                self.pause(); self.report(item.error ?? LibraryError.message("Unable to decode this audio file. Try another encoding."))
            }
        }
    }

    private func tick(_ seconds: Double) {
        guard !isRebuilding, seconds.isFinite, player.currentItem != nil else { return }
        position = max(0, seconds)
        if let actual = player.currentItem?.duration.seconds, actual.isFinite, actual > 0 { duration = actual }
        if isPlaying && abs(position - lastSavedPosition) >= 10 { savePosition() }
    }

    private func updateNowPlaying(loadArtwork: Bool = false) {
        guard let song = currentSong else { return }
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyTitle] = song.title
        info[MPMediaItemPropertyArtist] = song.artist
        info[MPMediaItemPropertyAlbumTitle] = song.album
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        if loadArtwork {
            info.removeValue(forKey: MPMediaItemPropertyArtwork)
            if let path = song.artworkPath, let image = UIImage(contentsOfFile: paths.documents.appendingPathComponent(path).path) {
                info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        func register(_ command: MPRemoteCommand, action: @escaping @MainActor (MPRemoteCommandEvent) async -> Void) {
            command.isEnabled = true
            let target = command.addTarget { [weak self] event in
                guard self != nil else { return .commandFailed }
                Task { @MainActor in await action(event) }
                return .success
            }
            remoteTargets.append((command, target))
        }
        register(center.playCommand) { [weak self] _ in await self?.resume() }
        register(center.pauseCommand) { [weak self] _ in self?.pause() }
        register(center.togglePlayPauseCommand) { [weak self] _ in await self?.toggle() }
        register(center.nextTrackCommand) { [weak self] _ in await self?.next() }
        register(center.previousTrackCommand) { [weak self] _ in await self?.previous() }
        register(center.changePlaybackPositionCommand) { [weak self] event in
            if let event = event as? MPChangePlaybackPositionCommandEvent { self?.seek(event.positionTime) }
        }
        register(center.changeShuffleModeCommand) { [weak self] event in
            guard let self, let event = event as? MPChangeShuffleModeCommandEvent else { return }
            if (event.shuffleType != .off) != self.queue.shuffle { await self.toggleShuffle() }
        }
        register(center.changeRepeatModeCommand) { [weak self] event in
            guard let self, let event = event as? MPChangeRepeatModeCommandEvent else { return }
            self.queue.repeatMode = event.repeatType == .one ? .one : (event.repeatType == .all ? .all : .off)
            self.saveQueue(); await self.replaceUpcoming()
        }
    }

    private func observeNotifications() {
        let center = NotificationCenter.default
        notifications.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in
                guard let self, let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                if type == .began {
                    self.resumeAfterInterruption = self.isPlaying
                    self.player.pause(); self.isPlaying = false; self.savePosition()
                } else {
                    let options = AVAudioSession.InterruptionOptions(rawValue: note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
                    let shouldResume = self.resumeAfterInterruption && options.contains(.shouldResume)
                    self.resumeAfterInterruption = false
                    if shouldResume { await self.resume() }
                }
            }
        })
        notifications.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in
                let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { self?.pause() }
            }
        })
        notifications.append(center.addObserver(forName: AVAudioSession.mediaServicesWereLostNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.savePosition(); self.player.pause()
            }
        })
        notifications.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.observations.removeAll(); self.statusObservation = nil
                if let observer = self.timeObserver { self.player.removeTimeObserver(observer); self.timeObserver = nil }
                self.player = AVQueuePlayer()
                self.configurePlayer()
                do { try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default) } catch { self.report(error) }
                await self.rebuild(autoplay: false, seekTo: self.position)
                self.errorMessage = "The system audio service restarted. Tap Play to continue."
            }
        })
        notifications.append(center.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in
                guard let self, let item = note.object as? AVPlayerItem, self.player.currentItem === item else { return }
                self.pause(); self.report(item.error ?? LibraryError.message("Playback failed before this song ended."))
            }
        })
    }

    private func report(_ error: Error) {
        logger.error("\(error.localizedDescription, privacy: .public)")
        errorMessage = error.localizedDescription
    }
}
