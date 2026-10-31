import Foundation
import MusicKit

actor AppleMusicLibraryProvider: LibraryProvider {
    private var songCache: [Song]?
    private var songTask: Task<[Song], Error>?
    private var durationPrefetchTask: Task<Void, Never>?
    private var unmatchedDurationIDs: Set<String> = []
    private let prefetchStatus: OfflineCacheStatus

    init(status: OfflineCacheStatus) {
        prefetchStatus = status
        unmatchedDurationIDs = PlaybackDurationCache.unmatchedIDs()
    }

    func albums() async throws -> [LibraryItem] {
        var request = MusicLibraryRequest<Album>()
        request.sort(by: \.title, ascending: true)
        return try await Self.drain(request.response().items).map(Self.item)
    }

    func playlists() async throws -> [LibraryItem] {
        let request = MusicLibraryRequest<Playlist>()
        return try await Self.drain(request.response().items).map(Self.item)
    }

    func artists() async throws -> [LibraryItem] {
        var request = MusicLibraryRequest<Artist>()
        request.sort(by: \.name, ascending: true)
        return try await Self.drain(request.response().items).map(Self.item)
    }

    func genres() async throws -> [LibraryItem] {
        var request = MusicLibraryRequest<Genre>()
        request.sort(by: \.name, ascending: true)
        return try await Self.drain(request.response().items).map(Self.item)
    }

    func songs() async throws -> [LibraryItem] {
        try await librarySongs().map(Self.item)
    }

    func composers() async throws -> [LibraryItem] {
        let names = try await librarySongs().compactMap {
            $0.composerName?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return Set(names.filter { !$0.isEmpty })
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { LibraryItem(id: $0, title: $0) }
    }

    func albumTracks(id: String) async throws -> [LibraryItem] {
        let album = try await album(id: id)
        return Array(try await album.with(.tracks, preferredSource: .library).tracks ?? []).map(Self.item)
    }

    func playlistTracks(id: String) async throws -> [LibraryItem] {
        var request = MusicLibraryRequest<Playlist>()
        request.filter(matching: \.id, equalTo: MusicItemID(id))
        guard let playlist = try await request.response().items.first else {
            throw MusicLibraryError.playlistNotFound
        }
        return Array(try await playlist.with(.tracks, preferredSource: .library).tracks ?? []).map(Self.item)
    }

    func artistAlbums(id: String) async throws -> [LibraryItem] {
        var request = MusicLibraryRequest<Artist>()
        request.filter(matching: \.id, equalTo: MusicItemID(id))
        guard let artist = try await request.response().items.first else {
            throw MusicLibraryError.artistNotFound
        }

        var byRelationship = MusicLibraryRequest<Album>()
        byRelationship.filter(matching: \.artists, contains: artist)
        byRelationship.sort(by: \.title, ascending: true)
        let albums = try await Self.drain(byRelationship.response().items)
        guard albums.isEmpty else { return albums.map(Self.item) }

        var byName = MusicLibraryRequest<Album>()
        byName.filter(matching: \.artistName, equalTo: artist.name)
        byName.sort(by: \.title, ascending: true)
        return try await Self.drain(byName.response().items).map(Self.item)
    }

    func genreArtists(id: String) async throws -> [LibraryItem] {
        var request = MusicLibraryRequest<Genre>()
        request.filter(matching: \.id, equalTo: MusicItemID(id))
        guard let genre = try await request.response().items.first else {
            throw MusicLibraryError.genreNotFound
        }
        var artists = MusicLibraryRequest<Artist>()
        artists.filter(matching: \.genres, contains: genre)
        artists.sort(by: \.name, ascending: true)
        return try await Self.drain(artists.response().items).map(Self.item)
    }

    func composerSongs(name: String) async throws -> [LibraryItem] {
        try await librarySongs()
            .filter { $0.composerName?.trimmingCharacters(in: .whitespacesAndNewlines) == name }
            .map(Self.item)
    }

    func album(id: String) async throws -> Album {
        var request = MusicLibraryRequest<Album>()
        request.filter(matching: \.id, equalTo: MusicItemID(id))
        guard let album = try await request.response().items.first else {
            throw MusicLibraryError.albumNotFound
        }
        return album
    }

    func playlist(id: String) async throws -> Playlist {
        var request = MusicLibraryRequest<Playlist>()
        request.filter(matching: \.id, equalTo: MusicItemID(id))
        guard let playlist = try await request.response().items.first else {
            throw MusicLibraryError.playlistNotFound
        }
        return playlist
    }

    func songs(ids: [String]) async throws -> [Song] {
        guard !ids.isEmpty else { return [] }
        var request = MusicLibraryRequest<Song>()
        request.filter(matching: \.id, memberOf: ids.map { MusicItemID($0) })
        let found = try await Self.drain(request.response().items)
        let byID = Dictionary(found.map { ($0.id.rawValue, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { byID[$0] }
    }

    func songs(matchingTitle title: String) async throws -> [Song] {
        var request = MusicLibraryRequest<Song>()
        request.filter(matching: \.title, equalTo: title)
        return try await Self.drain(request.response().items)
    }

    func prefetchDurations() async {
        guard MusicAuthorization.currentStatus == .authorized else { return }
        while !Task.isCancelled {
            if let songs = try? await librarySongs() {
                startDurationPrefetchIfNeeded(for: songs)
                return
            }
            await prefetchStatus.pause()
            try? await Task.sleep(for: .seconds(30))
        }
    }

    func invalidateCache() {
        songCache = nil
        songTask = nil
        durationPrefetchTask?.cancel()
        durationPrefetchTask = nil
        unmatchedDurationIDs = []
        PlaybackDurationCache.clearUnmatched()
    }

    private func librarySongs() async throws -> [Song] {
        if let songCache {
            startDurationPrefetchIfNeeded(for: songCache)
            return songCache
        }
        if let songTask {
            let songs = try await songTask.value
            startDurationPrefetchIfNeeded(for: songs)
            return songs
        }
        let task = Task {
            var request = MusicLibraryRequest<Song>()
            request.sort(by: \.title, ascending: true)
            return try await Self.drain(request.response().items)
        }
        songTask = task
        defer { if songTask == task { songTask = nil } }
        let songs = try await task.value
        if songTask == task { songCache = songs }
        startDurationPrefetchIfNeeded(for: songs)
        return songs
    }

    /// Fills the persistent duration cache in the background for library songs
    /// whose metadata reports no duration. Runs at most once per cache load and
    /// stops quickly when the catalog is unreachable (e.g. offline).
    private func startDurationPrefetchIfNeeded(for songs: [Song]) {
        guard durationPrefetchTask == nil else { return }
        durationPrefetchTask = Task { [weak self] in
            guard let self else { return }
            await self.prefetchMissingDurations(for: songs)
            await self.finishDurationPrefetch()
        }
    }

    private func finishDurationPrefetch() {
        durationPrefetchTask = nil
    }

    private func prefetchMissingDurations(for songs: [Song]) async {
        for song in songs {
            if let duration = song.duration, duration > 0 {
                PlaybackDurationCache.set(duration, for: song.id.rawValue)
            }
        }

        var pending = pendingDurations(in: songs)
        guard !pending.isEmpty else {
            await prefetchStatus.reset()
            return
        }
        await prefetchStatus.begin()
        await prefetchStatus.update(total: pending.count)

        while !Task.isCancelled {
            var consecutiveFailures = 0
            for song in pending {
                if Task.isCancelled { return }
                let libraryID = song.id.rawValue

                switch await catalogLookup(for: song) {
                case .found(let duration, let catalogID):
                    PlaybackDurationCache.set(duration, for: libraryID)
                    PlaybackDurationCache.set(duration, for: catalogID)
                    await prefetchStatus.advance()
                    consecutiveFailures = 0
                case .notFound:
                    unmatchedDurationIDs.insert(libraryID)
                    PlaybackDurationCache.markUnmatched(libraryID)
                    await prefetchStatus.advance()
                    consecutiveFailures = 0
                case .unavailable:
                    consecutiveFailures += 1
                    if consecutiveFailures >= 3 { break }
                }
                try? await Task.sleep(for: .milliseconds(150))
            }
            if Task.isCancelled { return }

            pending = pendingDurations(in: songs)
            if pending.isEmpty {
                await prefetchStatus.finish()
                return
            }
            await prefetchStatus.pause()
            try? await Task.sleep(for: .seconds(30))
            if Task.isCancelled { return }
            await prefetchStatus.begin()
            await prefetchStatus.update(total: pending.count)
        }
    }

    private func pendingDurations(in songs: [Song]) -> [Song] {
        songs.filter {
            guard ($0.duration ?? 0) <= 0 else { return false }
            let id = $0.id.rawValue
            return PlaybackDurationCache.duration(for: id) == nil && !unmatchedDurationIDs.contains(id)
        }
    }

    private enum CatalogDurationResult {
        case found(TimeInterval, catalogID: String)
        case notFound
        case unavailable
    }

    private func catalogLookup(for song: Song) async -> CatalogDurationResult {
        if let isrc = song.isrc, !isrc.isEmpty {
            do {
                let request = MusicCatalogResourceRequest<Song>(matching: \.isrc, equalTo: isrc)
                let items = try await request.response().items
                if let match = items.first, let duration = match.duration, duration > 0 {
                    return .found(duration, catalogID: match.id.rawValue)
                }
            } catch {
                return .unavailable
            }
        }
        do {
            let request = MusicCatalogSearchRequest(term: "\(song.title) \(song.artistName)", types: [Song.self])
            let response = try await request.response()
            if let match = Self.bestCatalogMatch(
                in: Array(response.songs),
                title: song.title,
                artistName: song.artistName,
                albumTitle: song.albumTitle
            ), let duration = match.duration, duration > 0 {
                return .found(duration, catalogID: match.id.rawValue)
            }
            return .notFound
        } catch {
            return .unavailable
        }
    }

    private static func bestCatalogMatch(in songs: [Song], title: String, artistName: String, albumTitle: String?) -> Song? {
        let titleKey = normalized(title)
        let artistKey = normalized(artistName)
        let candidates = songs.filter {
            normalized($0.title) == titleKey && normalized($0.artistName) == artistKey
        }
        if let albumTitle {
            let albumKey = normalized(albumTitle)
            if let match = candidates.first(where: { normalized($0.albumTitle ?? "") == albumKey }) {
                return match
            }
        }
        return candidates.first
    }

    private static func normalized(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func drain<T: MusicItem>(_ firstBatch: MusicItemCollection<T>) async throws -> [T] {
        try await drainPages(first: firstBatch, elements: { Array($0) }) { batch in
            batch.hasNextBatch ? try await batch.nextBatch() : nil
        }
    }

    private static func item(_ album: Album) -> LibraryItem {
        LibraryItem(id: album.id.rawValue, title: album.title, subtitle: album.artistName,
                    artwork: album.artwork.map(ArtworkRef.appleMusic))
    }

    private static func item(_ playlist: Playlist) -> LibraryItem {
        LibraryItem(id: playlist.id.rawValue, title: playlist.name,
                    artwork: playlist.artwork.map(ArtworkRef.appleMusic))
    }

    private static func item(_ artist: Artist) -> LibraryItem {
        LibraryItem(id: artist.id.rawValue, title: artist.name,
                    artwork: artist.artwork.map(ArtworkRef.appleMusic))
    }

    private static func item(_ genre: Genre) -> LibraryItem {
        LibraryItem(id: genre.id.rawValue, title: genre.name)
    }

    private static func item(_ song: Song) -> LibraryItem {
        LibraryItem(id: song.id.rawValue, title: song.title, subtitle: song.artistName,
                    artwork: song.artwork.map(ArtworkRef.appleMusic))
    }

    private static func item(_ track: Track) -> LibraryItem {
        LibraryItem(id: track.id.rawValue, title: track.title, subtitle: track.artistName,
                    artwork: track.artwork.map(ArtworkRef.appleMusic))
    }
}
