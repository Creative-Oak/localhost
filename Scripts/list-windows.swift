// Lists on-screen windows belonging to a pid.
//
// Used to prove that a modal actually appeared. `CGWindowListCopyWindowInfo`
// needs no accessibility permission — it is the same information screencapture
// uses — and it reports only this app's own windows here.
//
//   swift Scripts/list-windows.swift <pid>
import AppKit
import Foundation

guard CommandLine.arguments.count > 1, let target = Int(CommandLine.arguments[1]) else {
    print("usage: list-windows.swift <pid>"); exit(1)
}
let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
let mine = windows.filter { ($0[kCGWindowOwnerPID as String] as? Int) == target }
print("windows owned by pid \(target): \(mine.count)")
for window in mine {
    let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let width = bounds["Width"] as? Double ?? 0
    let height = bounds["Height"] as? Double ?? 0
    let name = window[kCGWindowName as String] as? String ?? ""
    let layer = window[kCGWindowLayer as String] as? Int ?? 0
    print(String(format: "  %.0fx%.0f  layer %d  %@", width, height, layer, name))
}
