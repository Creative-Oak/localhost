import Darwin
import Foundation
import LocalhostKit

/// Times each phase of a scan so optimisation targets evidence, not instinct.
enum Benchmark {
    private static func measure(_ label: String, runs: Int = 20, _ body: () -> Void) {
        body()                                        // warm
        var samples: [Double] = []
        for _ in 0..<runs {
            let started = DispatchTime.now().uptimeNanoseconds
            body()
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6)
        }
        samples.sort()
        print(String(format: "  %-34s median %7.3f ms   min %7.3f   max %7.3f",
                     (label as NSString).utf8String!,
                     samples[samples.count / 2], samples[0], samples[samples.count - 1]))
    }

    /// Repeats the scan the way an open menu does, watching resident memory.
    ///
    /// The panel rescans every two seconds for as long as it is open, so a leak
    /// here is unbounded in practice. Worth proving rather than assuming.
    static func soak(iterations: Int, pooled: Bool = false) {
        let scanner = ListenerScanner()
        let attributor = ListenerAttributor()

        func residentBytes() -> UInt64 {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            return result == KERN_SUCCESS ? info.phys_footprint : 0
        }

        let megabyte = 1024.0 * 1024.0
        var baseline: Double = 0
        for iteration in 1...iterations {
            if pooled {
                autoreleasepool {
                    let result = scanner.scan()
                    _ = attributor.present(result.listeners)
                }
            } else {
                let result = scanner.scan()
                _ = attributor.present(result.listeners)
            }
            if iteration == 10 { baseline = Double(residentBytes()) / megabyte }
            if iteration % 100 == 0 || iteration == 10 {
                let now = Double(residentBytes()) / megabyte
                let drift = iteration >= 10 ? now - baseline : 0
                print(String(format: "  scan %5d   footprint %7.2f MB   drift %+6.2f MB", iteration, now, drift))
            }
        }
    }

    static func run() {
        let pcblist = PcbListScanner(source: .pcblistN)
        let pcblist64 = PcbListScanner(source: .pcblist64)
        let libproc = LibprocScanner()
        let scanner = ListenerScanner()
        let resolver = ProjectResolver()
        let containers = ContainerLabels()

        let listeners = scanner.scan().listeners
        let pids = Set(listeners.map(\.process.pid))
        let directories = listeners.compactMap(\.process.workingDirectory)
        print("subjects: \(listeners.count) listeners, \(pids.count) processes, \(directories.count) working directories\n")

        print("discovery")
        measure("sysctl pcblist_n") { _ = try? pcblist.scan() }
        measure("sysctl pcblist64") { _ = try? pcblist64.scan() }
        measure("libproc (oracle)") { _ = libproc.scan() }
        measure("ListenerScanner.scan (both)") { _ = scanner.scan() }

        print("\nper-process facts, summed over \(pids.count) processes")
        measure("PROC_PIDTBSDINFO") { for pid in pids { _ = ProcessDetails.bsdInfo(of: pid) } }
        measure("proc_pidpath") { for pid in pids { _ = ProcessDetails.executablePath(of: pid) } }
        measure("PROC_PIDVNODEPATHINFO") { for pid in pids { _ = ProcessDetails.workingDirectory(of: pid) } }
        measure("KERN_PROCARGS2") { for pid in pids { _ = ProcessDetails.arguments(of: pid) } }

        print("\nattribution, summed over \(listeners.count) rows")
        measure("ProjectResolver") { for directory in directories { _ = resolver.project(for: directory) } }
        measure("GitBranch") {
            for directory in directories {
                guard let project = resolver.project(for: directory) else { continue }
                _ = GitBranch.branch(at: project.root)
            }
        }
        measure("RuntimeIdentifier") {
            for listener in listeners {
                _ = RuntimeIdentifier.runtime(
                    arguments: listener.process.arguments,
                    executablePath: listener.process.executablePath)
            }
        }
        measure("Docker /containers/json", runs: 8) { _ = containers.byPublishedPort() }

        print("\nwhole pipeline, as the menu runs it")
        measure("scan + attribution", runs: 10) {
            let result = scanner.scan()
            _ = ListenerAttributor().present(result.listeners)
        }
    }
}
