import SwiftUI
import AppKit

/// Shown when the analytics database cannot be opened.
///
/// Replaces a `fatalError`, which surfaced as "SocialBrain quit unexpectedly"
/// with the reason buried in a crash report. The most likely cause — schema
/// drift after editing a migration — leaves the user's data fully intact, so the
/// worst possible response is a crash that says nothing and invites them to
/// delete things at random.
struct DatabaseUnavailableView: View {
    let error: any Error

    private var databaseDirectory: URL? {
        try? FileManager.default.url(for: .applicationSupportDirectory,
                                     in: .userDomainMask,
                                     appropriateFor: nil,
                                     create: false)
            .appendingPathComponent("SocialBrain", isDirectory: true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Can't open your analytics database", systemImage: "exclamationmark.triangle.fill")
                .font(.title2.bold())
                .foregroundStyle(.orange)

            Text(error.localizedDescription)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                if let directory = databaseDirectory {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([directory])
                    }
                }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(minWidth: 520, minHeight: 260, alignment: .topLeading)
    }
}
