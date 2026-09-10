import Darwin
import Foundation
// Ground truth: port 31337, addr 127.0.0.1, pid 52929, uid 501 (from lsof/libproc)
var size = 0
sysctlbyname("net.inet.tcp.pcblist_n", nil, &size, nil, 0)
var buf = [UInt8](repeating: 0, count: size + 16384); size = buf.count
sysctlbyname("net.inet.tcp.pcblist_n", &buf, &size, nil, 0)
func hex(_ raw: UnsafeRawBufferPointer, _ off: Int, _ len: Int) {
    for r in stride(from: 0, to: len, by: 8) {
        let bytes = (0..<min(8, len - r)).map { String(format: "%02x", raw[off + r + $0]) }
        let u32a = raw.loadUnaligned(fromByteOffset: off + r, as: UInt32.self)
        let u32b = raw.loadUnaligned(fromByteOffset: off + r + 4, as: UInt32.self)
        print(String(format: "   +%3d  %@   u32=%-12u %-12u", r, bytes.joined(separator: " "), u32a, u32b))
    }
}
buf.withUnsafeBytes { raw in
    var off = Int(raw.loadUnaligned(as: UInt32.self))
    while off + 8 <= size {
        let len = Int(raw.loadUnaligned(fromByteOffset: off, as: UInt32.self))
        let kind = raw.loadUnaligned(fromByteOffset: off + 4, as: UInt32.self)
        if len < 8 { break }
        if kind == 0x010 {
            // scan the whole record for the big-endian port 31337 (0x7a69)
            for probe in stride(from: 8, to: len - 1, by: 1) {
                if raw.loadUnaligned(fromByteOffset: off + probe, as: UInt16.self) == UInt16(31337).bigEndian {
                    print("=== XSO_INPCB record (len \(len)) — port 31337 found at +\(probe) ===")
                    hex(raw, off, len)
                    // 127.0.0.1 = 0x7f000001 big-endian
                    for p2 in stride(from: 8, to: len - 3, by: 1) where raw.loadUnaligned(fromByteOffset: off + p2, as: UInt32.self) == UInt32(0x7f000001).bigEndian {
                        print("   -> 127.0.0.1 at +\(p2)")
                    }
                    let sOff = off + ((len + 7) & ~7)
                    let sLen = Int(raw.loadUnaligned(fromByteOffset: sOff, as: UInt32.self))
                    print("=== next record kind=0x\(String(raw.loadUnaligned(fromByteOffset: sOff + 4, as: UInt32.self), radix:16)) len=\(sLen) ===")
                    hex(raw, sOff, sLen)
                    for p2 in stride(from: 8, to: sLen - 3, by: 4) {
                        let v = raw.loadUnaligned(fromByteOffset: sOff + p2, as: UInt32.self)
                        if v == 52929 { print("   -> pid 52929 at +\(p2)") }
                        if v == 501 { print("   -> uid 501 at +\(p2)") }
                    }
                    exit(0)
                }
            }
        }
        off += (len + 7) & ~7
    }
    print("port 31337 not found — is the test listener still running?")
}
