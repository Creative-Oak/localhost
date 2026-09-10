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
    static func perform(_ action: ListenerAction, on row: ListenerPresentation) {
        switch action {
        case .openInBrowser:
            guard let url = row.localURL else { return }
            NSWorkspace.shared.open(url)
        case .copyURL:
            guard let url = row.localURL else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
        case .copyPort:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(String(row.listener.port), forType: .string)
        case .revealInFinder:
            guard let folder = row.folderToReveal else { return }
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path)
        case .terminate:
            // Never performed here. The caller must confirm first.
            assertionFailure("termination must go through ListenerStore")
        }
    }
}
