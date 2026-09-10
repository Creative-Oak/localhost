import Foundation

/// The handful of system listeners that actually confuse developers.
///
/// This exists because attribution has a blind spot: launchd holds
/// socket-activated sockets, so the owning process of port 5900 reports as
/// `launchd`. That is accurate and useless. For these ports the table is the
/// only thing that can explain the row.
///
/// A port alone is never enough to match. A Flask app on 5000 is not the
/// AirPlay receiver, and calling it one would be exactly the invented label the
/// design forbids — so the process name has to agree too.
public struct KnownDaemon: Hashable, Sendable {
    public let label: String
    public let advice: String?
}

public enum KnownDaemons {
    private struct Entry {
        let port: UInt16
        let processNames: Set<String>
        let label: String
        let advice: String?
    }

    private static let entries: [Entry] = [
        Entry(port: 5000, processNames: ["ControlCenter"],
              label: "AirPlay Receiver",
              advice: "Turn off in System Settings › General › AirDrop & Handoff"),
        Entry(port: 7000, processNames: ["ControlCenter"],
              label: "AirPlay Receiver",
              advice: "Turn off in System Settings › General › AirDrop & Handoff"),
        Entry(port: 5900, processNames: ["launchd", "screensharingd", "ScreensharingAgent"],
              label: "Screen Sharing",
              advice: "Turn off in System Settings › General › Sharing"),
        Entry(port: 3283, processNames: ["ARDAgent", "launchd"],
              label: "Apple Remote Desktop",
              advice: "Turn off in System Settings › General › Sharing"),
        Entry(port: 22, processNames: ["launchd", "sshd", "sshd-keygen-wrapper"],
              label: "Remote Login (SSH)",
              advice: "Turn off in System Settings › General › Sharing"),
        Entry(port: 548, processNames: ["launchd", "AppleFileServer"],
              label: "File Sharing (AFP)",
              advice: "Turn off in System Settings › General › Sharing"),
        Entry(port: 631, processNames: ["cupsd", "launchd"],
              label: "CUPS printing",
              advice: nil),
        Entry(port: 88, processNames: ["kdc", "launchd"],
              label: "Kerberos KDC",
              advice: nil),
    ]

    public static func daemon(port: UInt16, processName: String) -> KnownDaemon? {
        guard let entry = entries.first(where: {
            $0.port == port && $0.processNames.contains(processName)
        }) else { return nil }
        return KnownDaemon(label: entry.label, advice: entry.advice)
    }
}
