#if DEBUG
import AppKit
import Darwin

struct MemoryProbe {
    static var configuration: (output: URL, cycles: Int)? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--memory-probe"), index + 1 < arguments.count else { return nil }
        let cycles = arguments.dropFirst(index + 2).first.flatMap(Int.init) ?? 9
        return (URL(fileURLWithPath: arguments[index + 1]), max(1, cycles))
    }

    private var rows = ["sample,footprint_bytes,peak_bytes,resident_bytes"]

    mutating func sample(_ name: String) {
        var info = task_vm_info_data_t()
        let capacity = MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        var count = mach_msg_type_number_t(capacity)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }
        rows.append("\(name),\(info.phys_footprint),\(info.ledger_phys_footprint_peak),\(info.resident_size)")
    }

    @MainActor
    func write(to file: URL, screen: NSScreen) {
        let pixels = "\(Int(screen.frame.width))x\(Int(screen.frame.height)) @\(screen.backingScaleFactor)x"
        let report = (["# \(pixels)"] + rows).joined(separator: "\n") + "\n"
        try? report.write(to: file, atomically: true, encoding: .utf8)
    }
}
#endif
