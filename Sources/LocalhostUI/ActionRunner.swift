import AppKit
import LocalhostKit

/// Performs the actions that `ListenerAction` only describes.
///
/// Everything here is reversible or inert. The one action that is not —
/// signalling a process — deliberately does not live in this type; it goes
/// through `ListenerStore`, which owns the confirmation and the identity
/// re-check.
@MainActor
enum ActionRunner {
    /// Performing an action in a *chosen* app also makes that app the default,
    /// so the preference is set by using it rather than by finding a setting.
    static func open(_ row: ListenerPresentation, inBrowser choice: AppChoice) {
        guard let url = row.localURL else { return }
        ExternalApps.preferredBrowser = choice
        ExternalApps.open(url, in: choice)
    }

    static func open(_ row: ListenerPresentation, inTerminal choice: AppChoice) {
        guard let folder = row.folderToReveal else { return }
        ExternalApps.preferredTerminal = choice
        ExternalApps.openInTerminal(folder, using: choice)
    }

    static func perform(_ action: ListenerAction, on row: ListenerPresentation) {
        switch action {
        case .openInBrowser:
            guard let url = row.localURL else { return }
            ExternalApps.open(url, in: ExternalApps.preferredBrowser)
        case .copyURL:
            guard let url = row.localURL else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
        case .copyPort:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(String(row.listener.port), forType: .string)
        case .openInTerminal:
            guard let folder = row.folderToReveal else { return }
            ExternalApps.openInTerminal(folder, using: nil)
        case .copyStartCommand:
            guard let command = row.startCommand else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command.shellCommand, forType: .string)
        case .revealInFinder:
            guard let folder = row.folderToReveal else { return }
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path)
        case .terminate:
            // Never performed here. The caller must confirm first.
            assertionFailure("termination must go through ListenerStore")
        }
    }
}
