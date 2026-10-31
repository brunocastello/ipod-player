import SwiftUI
import UIKit
import MediaPlayer

@main
struct iPlayrApp: App {
    @State var theme: ThemeManager = .init()
    @State private var playerManager: PlaybackController
    @State private var authManager: MusicAccountManager
    @State private var libraryStore: MusicLibraryStore
    @State private var menuPreferences = MenuPreferences()
    @State private var onTheGo = OnTheGoStore()
    @State private var ratings = RatingStore()
    @State private var offlineCacheStatus: OfflineCacheStatus

    init() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        MPMediaLibrary.default().beginGeneratingLibraryChangeNotifications()
        let cacheStatus = OfflineCacheStatus()
        let library = AppleMusicLibraryProvider(status: cacheStatus)
        _offlineCacheStatus = State(initialValue: cacheStatus)
        _libraryStore = State(initialValue: MusicLibraryStore(provider: library))
        _playerManager = State(initialValue: PlaybackController(provider: AppleMusicPlaybackProvider(library: library)))
        _authManager = State(initialValue: MusicAccountManager(providers: [.appleMusic: AppleMusicAccountProvider()]))
    }

    var body: some Scene {
        WindowGroup {
            iPlayrView()
                .environment(theme)
                .environment(playerManager)
                .environment(authManager)
                .environment(libraryStore)
                .environment(menuPreferences)
                .environment(onTheGo)
                .environment(ratings)
                .environment(offlineCacheStatus)
                .onReceive(NotificationCenter.default.publisher(for: .MPMediaLibraryDidChange)) { _ in
                    Task {
                        await libraryStore.invalidate()
                        await libraryStore.prefetchDurations()
                    }
                }
        }
    }
}
