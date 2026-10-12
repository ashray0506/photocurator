import SwiftUI

@main
struct PhotoCuratorApp: App {
    @StateObject private var scanner = LibraryScanner()

    var body: some Scene {
        WindowGroup("PhotoCurator") {
            ScanView()
                .environmentObject(scanner)
                .frame(minWidth: 820, minHeight: 600)
        }
        .windowToolbarStyle(.unified)

        Settings {
            SettingsView()
                .environmentObject(scanner)
        }
    }
}
