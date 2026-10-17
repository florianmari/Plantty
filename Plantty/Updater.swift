import Sparkle

/// Sparkle's standard updater. Feed URL, public key and background checks are set in Info.plist.
enum Updater {
    static let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    static func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
