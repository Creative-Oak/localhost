import AppKit
import Foundation
import SwiftUI
import Testing
@testable import LocalhostKit
@testable import LocalhostUI

/// Layout assertions made by rendering the real panel.
///
/// These exist because the whole list once collapsed to a single row and every
/// one of the other tests still passed: they check data, and the bug was that
/// `ScrollView` reports no intrinsic height. The panel was visibly broken and
/// invisibly correct.
@MainActor
@Suite("Panel layout")
struct PanelLayoutTests {
    private func rows(_ count: Int, port: UInt16 = 3000) -> [ListenerPresentation] {
        (0..<count).map { index in
            ListenerPresentation(
                listener: Listener(
                    port: port + UInt16(index),
                    addresses: ["127.0.0.1"],
                    families: [.ipv4],
                    process: ProcessIdentity(
                        pid: pid_t(100 + index),
                        startedAt: 1,
                        uid: getuid(),
                        name: "node",
                        workingDirectory: "/tmp")),
                attribution: .project(
                    name: "project-\(index)",
                    root: URL(fileURLWithPath: "/tmp/project-\(index)"),
                    source: .packageJSON),
                runtime: Runtime(name: "Next.js", version: "16.2.12"),
                branch: "main")
        }
    }

    private func render(
        _ rows: [ListenerPresentation],
        maximumListHeight: CGFloat = .infinity
    ) -> NSImage? {
        let store = ListenerStore(rows: rows, oracle: .verified(matched: rows.count))
        let renderer = ImageRenderer(
            content: MenuContent(store: store, scans: false, maximumListHeight: maximumListHeight))
        renderer.scale = 1
        return renderer.nsImage
    }

    @Test("the panel grows with the number of rows")
    func heightScalesWithRowCount() throws {
        let small = try #require(render(rows(2)))
        let large = try #require(render(rows(20)))

        // The collapse bug produced the same height for both.
        #expect(large.size.height > small.size.height * 2,
                "2 rows: \(small.size.height)pt, 20 rows: \(large.size.height)pt")
    }

    @Test("every row is actually laid out")
    func allRowsAreDrawn() throws {
        let count = 20
        let image = try #require(render(rows(count)))
        // Each row carries two lines of text, so it cannot be under ~24pt.
        let floor = CGFloat(count) * 24
        #expect(image.size.height > floor,
                "\(count) rows rendered \(image.size.height)pt, expected more than \(floor)pt")
    }

    @Test("the list stops growing once it should scroll")
    func heightIsClampedWhenScrolling() throws {
        let clamped = try #require(render(rows(40), maximumListHeight: 300))
        // 300pt of list plus header, search field, disclosure and footer.
        #expect(clamped.size.height < 460, "clamped panel was \(clamped.size.height)pt")
    }

    /// Draws into a bitmap whose layout we control. `tiffRepresentation` can
    /// hand back a planar rep, where `bitmapData` is a single colour plane and
    /// indexing it as interleaved RGBA reads past the end of every row.
    private func pixels(of image: NSImage) -> (bytes: UnsafeMutablePointer<UInt8>, width: Int, height: Int, stride: Int)? {
        let width = Int(image.size.width)
        let height = Int(image.size.height)
        guard width > 0, height > 0,
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: width * 4, bitsPerPixel: 32)
        else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()

        guard let bytes = rep.bitmapData else { return nil }
        return (bytes, width, height, rep.bytesPerRow)
    }

    @Test("the rows themselves draw ink")
    func rowsAreNotBlank() throws {
        let image = try #require(render(rows(6)))
        let raster = try #require(pixels(of: image))

        // Sample only the row band. Checking the whole panel would pass on the
        // header alone, and the bug being guarded against is rows that occupy
        // space without drawing anything.
        let top = 70
        let bottom = raster.height - 40
        try #require(bottom > top)

        var shades = Set<UInt8>()
        for y in stride(from: top, to: bottom, by: 2) {
            for x in stride(from: 12, to: raster.width - 12, by: 2) {
                shades.insert(raster.bytes[y * raster.stride + x * 4])
            }
        }
        // Antialiased text produces a spread of shades; an empty band gives one.
        #expect(shades.count > 8, "row band had \(shades.count) distinct shades — rows look blank")
    }
}

@MainActor
@Suite("Panel search")
struct PanelSearchTests {
    private func row(port: UInt16, label: String, runtime: String?) -> ListenerPresentation {
        ListenerPresentation(
            listener: Listener(
                port: port,
                addresses: ["127.0.0.1"],
                families: [.ipv4],
                process: ProcessIdentity(
                    pid: 1, startedAt: 1, uid: getuid(), name: "node", workingDirectory: "/tmp")),
            attribution: .project(
                name: label, root: URL(fileURLWithPath: "/tmp"), source: .packageJSON),
            runtime: runtime.map { Runtime(name: $0) },
            branch: "main")
    }

    @Test("a port nobody holds is reported free, not merely absent")
    func freePortIsAnswered() {
        let rows = [row(port: 3001, label: "rilo", runtime: "Next.js")]
        #expect(ListenerSearch.freePort(in: "3000", rows: rows) == 3000)
    }

    @Test("a port that is held is not reported free")
    func heldPortIsNotFree() {
        let rows = [row(port: 3000, label: "campo", runtime: "Next.js")]
        #expect(ListenerSearch.freePort(in: "3000", rows: rows) == nil)
    }

    @Test("a name query is never mistaken for a port")
    func nameQueryIsNotAPort() {
        #expect(ListenerSearch.port(in: "campo") == nil)
        #expect(ListenerSearch.port(in: "") == nil)
        #expect(ListenerSearch.port(in: "99999") == nil, "beyond the port range")
    }

    @Test("matches port, project, process, runtime and branch", arguments: [
        "3000", "campo", "node", "next", "main",
    ])
    func matchesEveryField(query: String) {
        let rows = [row(port: 3000, label: "campo", runtime: "Next.js")]
        #expect(ListenerSearch.filter(rows, query: query).count == 1, "query: \(query)")
    }

    @Test("an unrelated query matches nothing")
    func unrelatedQueryMatchesNothing() {
        let rows = [row(port: 3000, label: "campo", runtime: "Next.js")]
        #expect(ListenerSearch.filter(rows, query: "postgres").isEmpty)
    }
}
