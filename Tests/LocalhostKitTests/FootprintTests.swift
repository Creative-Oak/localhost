import Darwin
import Foundation
import Testing
@testable import LocalhostKit

/// The panel rescans every two seconds for as long as it is open, so anything
/// that accumulates per scan is unbounded in practice.
///
/// Before the pools were added this drifted about 22KB per scan — roughly
/// 39MB per hour of an open menu — from autoreleased Foundation objects with
/// no run loop to drain them off the main thread. Nothing else caught it: the
/// scan was correct, fast, and quietly growing.
@Suite("Memory footprint", .serialized)
struct FootprintTests {
    private func footprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    @Test("repeated scanning does not grow the footprint")
    func scanningDoesNotAccumulate() throws {
        let scanner = ListenerScanner()
        let attributor = ListenerAttributor()

        // Warm up, so first-use allocations are not counted as drift.
        for _ in 0..<20 {
            _ = attributor.present(scanner.scan().listeners)
        }
        let baseline = footprintBytes()
        try #require(baseline > 0, "could not read the task footprint")

        let iterations = 300
        for _ in 0..<iterations {
            _ = attributor.present(scanner.scan().listeners)
        }

        let drift = Double(footprintBytes()) - Double(baseline)
        let megabytes = drift / (1024 * 1024)
        // Unpooled this reached roughly 6.5MB over 300 scans and kept climbing;
        // pooled it settles under a quarter of a megabyte. The threshold sits
        // well clear of both.
        #expect(megabytes < 3.0,
                "footprint grew \(String(format: "%.2f", megabytes))MB over \(iterations) scans")
    }
}
