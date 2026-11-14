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
    @Published private(set) var crossfadeSeconds = min(8, max(0, UserDefaults.standard.double(forKey: "crossfade.seconds")))
    @Published private(set) var volumeBalancing = UserDefaults.standard.bool(forKey: "volume.balancing")
    @Published private(set) var sleepTimer = SleepTimerState()
    @Published private(set) var isCrossfading = false
    @Published private(set) var analysisProgress: String?

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
    private var wantsPlayback = false
    private var preparedFade: (player: AVQueuePlayer, entry: QueueEntry, song: Song, ready: Bool)?
    private var fadePreparation: NSKeyValueObservation?
    private var fadingPlayer: AVQueuePlayer?
    private var fadeTask: Task<Void, Never>?
    private var sleepTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    private var measuring: Set<String> = []
    private var gains: [String: Float] = [:]
    private var listeningTask: Task<Void, Never>?
    private var statsSongID: String?
    private var statsEntryID: String?
    private var pendingSeconds: Double = 0
    private var pendingPlays = 0
    private var heardInEntry: Double = 0
    private var countedEntry = false
    private var lastTickTime = ProcessInfo.processInfo.systemUptime
    private var lastTickPosition: Double = 0
    #if DEBUG
    var activePlayerCount: Int {
        [player, fadingPlayer].compactMap { $0 }.filter { $0.timeControlStatus == .playing }.count
    }
    var crossfadeDiagnostics: String {
        "position=\(position)/\(duration), playing=\(isPlaying), overlap=\(isCrossfading), active=\(activePlayerCount), prepared=\(preparedFade != nil), prerolled=\(preparedFade?.ready ?? false), incomingStatus=\(preparedFade?.player.status.rawValue ?? -1)"
    }
    #endif

    init(db: LibraryDatabase, paths: LibraryPaths) {
        self.db = db; self.paths = paths
        configurePlayer()
        observeNotifications()
        configureRemoteCommands()
    }

    private func configurePlayer() {
        player.actionAtItemEnd = .advance
        player.automaticallyWaitsToMinimizeStalling = false
        observations.append(player.observe(\.currentItem, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in await self?.currentItemChanged() }
        })
        observations.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor in
                guard let self else { return }
                guard self.player === player else { return }
                self.isPlaying = player.timeControlStatus == .playing
                self.updateNowPlaying()
            }
        })
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in self?.tick(time.seconds) }
        }
    }

    deinit {
        fadeTask?.cancel(); sleepTask?.cancel(); analysisTask?.cancel()
        fadingPlayer?.pause(); preparedFade?.player.pause()
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
                let checkpoint = try await db.state("position.v2", as: PlaybackPosition.self)
                let legacy = try await db.state("position", as: Double.self)
                let savedPosition = checkpoint?.entryID == queue.currentID ? (checkpoint?.seconds ?? queue.position) : (checkpoint == nil ? (legacy ?? queue.position) : queue.position)
                await rebuild(autoplay: false, seekTo: savedPosition)
            }
        } catch { wantsPlayback = false; report(error) }
    }

    func play(ids: [String], startingAt id: String? = nil, shuffled: Bool? = nil) async {
        if let shuffled { queue.shuffle = shuffled }
        queue.replace(ids, startAt: id.flatMap { ids.firstIndex(of: $0) } ?? 0)
        saveQueue()
        await rebuild(autoplay: true)
    }

    func toggle() async { if wantsPlayback && (player.currentItem != nil || isRebuilding) { pause() } else { await resume() } }

    func resume() async {
        synchronizeCurrentItem()
        if sleepTimer.expired(at: Date(), currentEntry: queue.currentID) { pauseForTimer(); return }
        guard queue.current != nil else { return }
        wantsPlayback = true
        do {
            try activateSession()
            if player.currentItem == nil || position >= duration - 0.1 { await rebuild(autoplay: true) }
            else { await replaceUpcoming(); player.play(); updateNowPlaying() }
        } catch { wantsPlayback = false; report(error) }
    }

    func pause() {
        synchronizeCurrentItem()
        accountListening(player.currentTime().seconds)
        enqueueListening()
        cancelFade()
        wantsPlayback = false
        resumeAfterInterruption = false
        player.pause(); isPlaying = false; savePosition(); updateNowPlaying()
    }

    func seek(_ value: Double) {
        synchronizeCurrentItem()
        cancelFade()
        guard value.isFinite, duration > 0 else { return }
        let target = min(max(value, 0), duration)
        position = target; queue.position = target
        resetTick(target)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in self?.updateNowPlaying(); await self?.replaceUpcoming() }
        }
        savePosition()
    }

    func next() async {
        synchronizeCurrentItem()
        guard let entry = queue.following(automatic: false) else { pause(); seek(0); return }
        queue.currentID = entry.id; queue.position = 0
        saveQueue(); await rebuild(autoplay: true)
    }

    func previous() async {
        synchronizeCurrentItem()
        if position > 3 { seek(0); return }
        guard let index = queue.currentIndex, !queue.entries.isEmpty else { return }
        let previous = index > 0 ? index - 1 : (queue.repeatMode == .all ? queue.entries.count - 1 : 0)
        queue.currentID = queue.entries[previous].id; queue.position = 0
        saveQueue(); await rebuild(autoplay: true)
    }

    @discardableResult
    func append(_ id: String, next: Bool) async -> String {
        synchronizeCurrentItem()
        let wasEmpty = queue.current == nil
        queue.position = position
        let entryID = queue.append(id, next: next); saveQueue()
        if wasEmpty { await rebuild(autoplay: false) } else { await replaceUpcoming() }
        return entryID
    }

    func jump(to entryID: String) async {
        guard queue.entries.contains(where: { $0.id == entryID }) else { return }
        queue.currentID = entryID; queue.position = 0; saveQueue()
        await rebuild(autoplay: true)
    }

    func remove(entryIDs: Set<String>) async {
        synchronizeCurrentItem()
        let old = queue.currentID, playing = wantsPlayback
        queue.position = position
        queue.remove(entryIDs: entryIDs); saveQueue()
        if old != queue.currentID { await rebuild(autoplay: playing) }
        else { await replaceUpcoming() }
    }

    func removeSong(_ id: String) async {
        await remove(entryIDs: Set(queue.entries.filter { $0.songID == id }.map(\.id)))
    }

    func move(from offsets: IndexSet, to destination: Int) async {
        synchronizeCurrentItem()
        queue.position = position
        queue.move(from: offsets, to: destination); saveQueue(); await replaceUpcoming()
    }

    func toggleShuffle() async { synchronizeCurrentItem(); queue.position = position; queue.toggleShuffle(); saveQueue(); await replaceUpcoming() }
    func cycleRepeat() async { synchronizeCurrentItem(); queue.position = position; queue.repeatMode = queue.repeatMode.next; saveQueue(); await replaceUpcoming() }

    func refreshSong(_ song: Song) {
        if currentSong?.id == song.id { currentSong = song; updateNowPlaying() }
        for key in Array(itemSongs.keys) where itemSongs[key]?.id == song.id { itemSongs[key] = song }
    }

    func savePosition() {
        enqueueListening()
        queue.position = position
        let checkpoint = PlaybackPosition(entryID: queue.currentID, seconds: position)
        lastSavedPosition = position
        Task { do { try await db.setState("position.v2", value: checkpoint) } catch { report(error) } }
    }

    private func saveQueue() {
        let snapshot = queue
        Task {
            do {
                try await db.savePlaybackQueue(snapshot)
            } catch { report(error) }
        }
    }

    private func activateSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [])
        try session.setActive(true)
    }

    private func rebuild(autoplay: Bool, seekTo: Double = 0) async {
        let restartingFinishedEntry = duration > 0 && position >= duration - 0.1 && seekTo == 0
        accountListening(player.currentTime().seconds); enqueueListening(); cancelFade()
        let timerExpired = sleepTimer.expired(at: Date(), currentEntry: queue.currentID)
        if timerExpired { clearSleepState() }
        wantsPlayback = autoplay && !timerExpired
        generation += 1
        let token = generation
        isRebuilding = true
        player.pause(); player.removeAllItems()
        itemEntries.removeAll(); itemSongs.removeAll(); handledItem = nil
        position = 0; duration = 0
        guard let entry = queue.current else {
            wantsPlayback = false
            currentSong = nil; isPlaying = false; isRebuilding = false
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        do {
            guard let song = try await db.song(entry.songID) else { throw LibraryError.message("This song is no longer in the library.") }
            guard token == generation else { return }
            currentSong = song; duration = song.duration
            beginListening(song: song, entry: entry, forceNew: restartingFinishedEntry)
            await loadGain(song)
            guard token == generation else { return }
            player.volume = gain(song)
            guard FileManager.default.fileExists(atPath: paths.audioURL(for: song).path) else {
                throw LibraryError.message("The audio file is missing. Reimport the original file to repair this song.")
            }
            // Configure the audio pipeline before either player starts preparing.
            // Reconfiguring it after incoming preroll can interrupt that preroll.
            if wantsPlayback { try activateSession() }
            let item = makeItem(song, entry: entry)
            handledItem = ObjectIdentifier(item)
            player.insert(item, after: nil)
            observeStatus(item)
            let target = seekTo.isFinite ? min(max(0, seekTo), max(0, song.duration - 0.05)) : 0
            position = target
            resetTick(target)
            if target > 0 { await player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }
            guard token == generation else { return }
            isRebuilding = false
            await fillUpcoming()
            guard token == generation else { return }
            if wantsPlayback {
                player.play()
                try await db.recordPlay(song.id)
            }
            updateNowPlaying(loadArtwork: true)
        } catch {
            guard token == generation else { return }
            isRebuilding = false; isPlaying = false; wantsPlayback = false; report(error)
        }
    }

    private func makeItem(_ song: Song, entry: QueueEntry) -> AVPlayerItem {
        let item = audioItem(song)
        itemEntries[ObjectIdentifier(item)] = entry
        itemSongs[ObjectIdentifier(item)] = song
        return item
    }

    private func audioItem(_ song: Song) -> AVPlayerItem {
        let url = paths.audioURL(for: song)
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 5
        if url.pathExtension.lowercased() == "flac", let exact = try? FLACMetadata.duration(url) {
            item.forwardPlaybackEndTime = CMTime(seconds: exact, preferredTimescale: 1_000_000)
        }
        return item
    }

    private func fillUpcoming() async {
        guard !isRebuilding, sleepTimer.entryID == nil, player.items().count < 2, let entry = queue.following(automatic: true) else { return }
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
            await loadGain(song)
            guard token == generation else { return }
            if crossfadeSeconds > 0, entry.id != queue.currentID, queue.repeatMode != .one {
                let incoming = AVQueuePlayer(items: [audioItem(song)])
                incoming.automaticallyWaitsToMinimizeStalling = false; incoming.volume = 0
                preparedFade = (incoming, entry, song, false)
                // AVPlayer throws an Objective-C exception if preroll is called before readiness.
                fadePreparation = incoming.observe(\.status, options: [.initial, .new]) { [weak self, weak incoming] _, _ in
                    Task { @MainActor in
                        guard let self, let incoming, self.preparedFade?.player === incoming,
                              incoming.status == .readyToPlay else { return }
                        self.fadePreparation?.invalidate(); self.fadePreparation = nil
                        incoming.preroll(atRate: 1) { [weak self, weak incoming] finished in
                            Task { @MainActor in
                                guard let self, let incoming, self.preparedFade?.player === incoming else { return }
                                self.preparedFade?.ready = finished
                            }
                        }
                    }
                }
            }
        } catch { report(error) }
    }

    private func replaceUpcoming() async {
        cancelFade()
        if isRebuilding {
            await rebuild(autoplay: wantsPlayback, seekTo: position)
            return
        }
        generation += 1
        let current = player.currentItem
        for item in player.items() where item !== current {
            player.remove(item)
            itemEntries.removeValue(forKey: ObjectIdentifier(item)); itemSongs.removeValue(forKey: ObjectIdentifier(item))
        }
        await fillUpcoming()
        updateNowPlaying()
    }

    private func currentItemChanged() async {
        guard !isRebuilding else { return }
        guard player.currentItem != nil else {
            enqueueListening()
            if sleepTimer.entryID != nil { clearSleepState() }
            wantsPlayback = false
            isPlaying = false; position = duration; savePosition(); updateNowPlaying(); return
        }
        synchronizeCurrentItem()
        await fillUpcoming()
    }

    /// Reconcile synchronously before user edits as KVO delivery may trail a natural transition.
    private func synchronizeCurrentItem() {
        guard !isRebuilding, let item = player.currentItem else { return }
        let key = ObjectIdentifier(item)
        guard key != handledItem, let entry = itemEntries[key], let song = itemSongs[key] else { return }
        enqueueListening()
        if sleepTimer.expired(at: Date(), currentEntry: entry.id) { pauseForTimer(); return }
        handledItem = key
        queue.currentID = entry.id; queue.position = 0
        currentSong = song; duration = song.duration; position = 0
        beginListening(song: song, entry: entry, forceNew: true)
        if !isCrossfading { player.volume = gain(song) }
        fadePreparation?.invalidate(); fadePreparation = nil
        preparedFade?.player.cancelPendingPrerolls(); preparedFade?.player.pause(); preparedFade = nil
        let valid = Set(player.items().map(ObjectIdentifier.init))
        itemEntries = itemEntries.filter { valid.contains($0.key) }
        itemSongs = itemSongs.filter { valid.contains($0.key) }
        observeStatus(item); saveQueue()
        Task { do { try await db.recordPlay(song.id) } catch { report(error) } }
        updateNowPlaying(loadArtwork: true)
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

    private func tick(_ observedSeconds: Double) {
        let seconds = player.currentTime().seconds
        guard !isRebuilding, seconds.isFinite, player.currentItem != nil else { return }
        synchronizeCurrentItem()
        accountListening(seconds)
        position = max(0, seconds)
        if let item = player.currentItem {
            let end = item.forwardPlaybackEndTime.seconds
            let actual = end.isFinite && end > 0 ? end : item.duration.seconds
            if actual.isFinite, actual > 0 { duration = actual }
        }
        if isPlaying && abs(position - lastSavedPosition) >= 10 { savePosition() }
        if sleepTimer.expired(at: Date(), currentEntry: queue.currentID) { pauseForTimer(); return }
        if isPlaying { startCrossfadeIfReady() }
    }

    private func updateNowPlaying(loadArtwork: Bool = false) {
        let commands = MPRemoteCommandCenter.shared()
        commands.changeShuffleModeCommand.currentShuffleType = queue.shuffle ? .items : .off
        commands.changeRepeatModeCommand.currentRepeatType = queue.repeatMode == .one ? .one : (queue.repeatMode == .all ? .all : .off)
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
                    self.resumeAfterInterruption = self.wantsPlayback
                    self.accountListening(self.player.currentTime().seconds); self.enqueueListening(); self.cancelFade()
                    self.wantsPlayback = false
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
                self.savePosition(); self.cancelFade(); self.player.pause()
            }
        })
        notifications.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.cancelFade()
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

    func setCrossfade(_ seconds: Double) async {
        crossfadeSeconds = seconds.isFinite ? min(8, max(0, seconds)) : 0
        UserDefaults.standard.set(crossfadeSeconds, forKey: "crossfade.seconds")
        await replaceUpcoming()
    }

    func setVolumeBalancing(_ enabled: Bool) async {
        volumeBalancing = enabled; UserDefaults.standard.set(enabled, forKey: "volume.balancing")
        if let song = currentSong { await loadGain(song); if !isCrossfading { player.volume = gain(song) } }
    }

    private func gain(_ song: Song?) -> Float {
        guard volumeBalancing, let song else { return 1 }
        return gains[song.fingerprint] ?? 1
    }

    private func loadGain(_ song: Song) async {
        guard volumeBalancing, gains[song.fingerprint] == nil else { return }
        do {
            if let measurement = try await db.state("loudness.\(song.fingerprint)", as: LoudnessMeasurement.self) { gains[song.fingerprint] = measurement.gain }
            else { requestMeasurement(song) }
        } catch { report(error) }
    }

    private func requestMeasurement(_ song: Song) {
        guard !measuring.contains(song.fingerprint) else { return }
        measuring.insert(song.fingerprint)
        Task { [weak self] in
            guard let self else { return }
            defer { measuring.remove(song.fingerprint) }
            do { try await measure(song) } catch { logger.error("Audio analysis: \(error.localizedDescription, privacy: .public)") }
        }
    }

    private func measure(_ song: Song) async throws {
        let measurement: LoudnessMeasurement
        if let cached = try await db.state("loudness.\(song.fingerprint)", as: LoudnessMeasurement.self) { measurement = cached }
        else {
            measurement = try await AudioAnalysisService.shared.measure(paths.audioURL(for: song))
            try await db.setState("loudness.\(song.fingerprint)", value: measurement)
        }
        gains[song.fingerprint] = measurement.gain
        if currentSong?.id == song.id, !isCrossfading { player.volume = gain(song) }
    }

    func analyzeLibrary() {
        guard analysisTask == nil else { return }
        analysisProgress = "Starting"
        analysisTask = Task { [weak self] in
            guard let self else { return }
            defer { analysisProgress = nil; analysisTask = nil }
            do {
                let ids = try await db.allIDs()
                var failures = 0
                for (index, id) in ids.enumerated() {
                    try Task.checkCancellation()
                    analysisProgress = "\(index + 1) / \(ids.count)"
                    if let song = try await db.song(id) {
                        do { try await measure(song) }
                        catch is CancellationError { throw CancellationError() }
                        catch { failures += 1 }
                    }
                }
                if failures > 0 { errorMessage = "Could not measure \(failures) files. Playback volume stays unchanged for those files." }
            } catch is CancellationError { }
            catch { report(error) }
        }
    }
    func cancelAnalysis() { analysisTask?.cancel() }

    private func cancelFade() {
        fadePreparation?.invalidate(); fadePreparation = nil
        fadeTask?.cancel(); fadeTask = nil
        fadingPlayer?.pause(); fadingPlayer?.removeAllItems(); fadingPlayer = nil
        preparedFade?.player.cancelPendingPrerolls(); preparedFade?.player.pause(); preparedFade?.player.removeAllItems(); preparedFade = nil
        isCrossfading = false; player.volume = gain(currentSong)
    }

    private func startCrossfadeIfReady() {
        guard !isCrossfading, sleepTimer.entryID == nil, crossfadeSeconds > 0,
              let prepared = preparedFade, prepared.ready, prepared.player.status == .readyToPlay,
              prepared.entry.id == queue.following(automatic: true)?.id,
              let item = prepared.player.currentItem, item.status == .readyToPlay, queue.repeatMode != .one else { return }
        let length = min(crossfadeSeconds, min(duration / 2, prepared.song.duration / 2))
        let remaining = duration - position
        guard length >= 0.25, remaining <= length, remaining > 0.1 else { return }
        let outgoing = player, outgoingGain = gain(currentSong)
        observations.removeAll(); statusObservation = nil
        if let observer = timeObserver { outgoing.removeTimeObserver(observer); timeObserver = nil }
        for next in outgoing.items() where next !== outgoing.currentItem { outgoing.remove(next) }
        outgoing.actionAtItemEnd = .pause
        preparedFade = nil; fadingPlayer = outgoing; player = prepared.player
        generation += 1; isCrossfading = true
        itemEntries[ObjectIdentifier(item)] = prepared.entry; itemSongs[ObjectIdentifier(item)] = prepared.song
        configurePlayer(); synchronizeCurrentItem()
        player.volume = 0; player.playImmediately(atRate: 1)
        let started = ProcessInfo.processInfo.systemUptime
        fadeTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let progress = min(1, (ProcessInfo.processInfo.systemUptime - started) / remaining)
                outgoing.volume = outgoingGain * Float(1 - progress)
                player.volume = gain(currentSong) * Float(progress)
                if progress >= 1 {
                    outgoing.pause(); outgoing.removeAllItems(); fadingPlayer = nil; isCrossfading = false; fadeTask = nil
                    await fillUpcoming(); return
                }
                // Avoid the cross-module Clock specialization crash: swiftlang/swift#86204.
                do { try await Task.sleep(nanoseconds: 40_000_000) } catch { return }
            }
        }
    }

    func setSleepTimer(minutes: Int? = nil, endOfSong: Bool = false) async {
        clearSleepState()
        if endOfSong { sleepTimer.entryID = queue.currentID }
        else if let minutes, minutes > 0 { sleepTimer.deadline = Date().addingTimeInterval(Double(min(minutes, 1440)) * 60) }
        await replaceUpcoming()
        if sleepTimer.deadline != nil {
            sleepTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                    guard let self else { return }
                    if sleepTimer.expired(at: Date(), currentEntry: queue.currentID) { pauseForTimer(); return }
                }
            }
        }
    }
    private func clearSleepState() { sleepTask?.cancel(); sleepTask = nil; sleepTimer = SleepTimerState() }
    private func pauseForTimer() { clearSleepState(); pause() }

    private func resetTick(_ seconds: Double) {
        lastTickTime = ProcessInfo.processInfo.systemUptime; lastTickPosition = seconds.isFinite ? seconds : 0
    }
    private func beginListening(song: Song, entry: QueueEntry, forceNew: Bool = false) {
        if forceNew || statsEntryID != entry.id {
            enqueueListening(); statsSongID = song.id; statsEntryID = entry.id
            heardInEntry = 0; countedEntry = false
        }
        resetTick(0)
    }
    private func accountListening(_ seconds: Double) {
        let now = ProcessInfo.processInfo.systemUptime
        defer { lastTickTime = now; if seconds.isFinite { lastTickPosition = seconds } }
        guard isPlaying, player.rate > 0, seconds.isFinite, statsSongID != nil else { return }
        let delta = seconds - lastTickPosition
        guard delta >= 0, delta <= 1.5 else { return } // A seek is never listening time.
        let elapsed = max(0, min(delta, now - lastTickTime))
        pendingSeconds += elapsed; heardInEntry += elapsed
        if !countedEntry, heardInEntry >= min(30, max(0.5, duration / 2)) { pendingPlays += 1; countedEntry = true }
        if pendingSeconds >= 5 { enqueueListening() }
    }
    private func enqueueListening() {
        guard let id = statsSongID, pendingSeconds > 0 || pendingPlays > 0 else { return }
        let seconds = pendingSeconds, plays = pendingPlays, previous = listeningTask
        pendingSeconds = 0; pendingPlays = 0
        listeningTask = Task {
            await previous?.value
            do { try await db.recordListening(id, seconds: seconds, plays: plays) } catch { report(error) }
        }
    }
    func flushListening() async {
        accountListening(player.currentTime().seconds); enqueueListening(); await listeningTask?.value
    }
    func clearListeningHistory() async throws {
        await flushListening(); try await db.clearListening()
        heardInEntry = 0; countedEntry = false
    }

    private func report(_ error: Error) {
        logger.error("\(error.localizedDescription, privacy: .public)")
        errorMessage = error.localizedDescription
    }
}
