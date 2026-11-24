import Foundation
import Darwin
import IOKit.ps

// MARK: - CPU load (overall + per core), same counters Activity Monitor reads

struct CPULoad {
    var user = 0.0, system = 0.0          // fractions of total capacity, 0...1
    var cores: [Double] = []              // busy fraction per core
    var total: Double { user + system }
}

final class CPUSampler {
    private var last: [(user: UInt32, system: UInt32, idle: UInt32)] = []

    private func ticks() -> [(user: UInt32, system: UInt32, idle: UInt32)] {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS, let info else { return [] }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)) }
        return (0..<Int(count)).map { i in
            let b = i * Int(CPU_STATE_MAX)
            func t(_ s: Int32) -> UInt32 { UInt32(bitPattern: info[b + Int(s)]) }
            return (t(CPU_STATE_USER) &+ t(CPU_STATE_NICE), t(CPU_STATE_SYSTEM), t(CPU_STATE_IDLE))
        }
    }

    func sample() -> CPULoad? {
        let now = ticks()
        defer { last = now }
        guard !now.isEmpty, now.count == last.count else { return nil }
        var load = CPULoad(), u = 0.0, s = 0.0, all = 0.0
        for (a, b) in zip(last, now) {
            let du = Double(b.user &- a.user), ds = Double(b.system &- a.system), di = Double(b.idle &- a.idle)
            let sum = du + ds + di
            load.cores.append(sum > 0 ? (du + ds) / sum : 0)
            u += du; s += ds; all += sum
        }
        if all > 0 { load.user = u / all; load.system = s / all }
        return load
    }
}

// MARK: - Memory, using Activity Monitor's categories

struct MemInfo {
    var total = Double(ProcessInfo.processInfo.physicalMemory)
    var app = 0.0, wired = 0.0, compressed = 0.0, cached = 0.0
    var used: Double { app + wired + compressed }
    var free: Double { max(total - used - cached, 0) }

    static func read() -> MemInfo {
        var m = MemInfo()
        var stats = vm_statistics64()
        var size = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &size) }
        }
        guard kr == KERN_SUCCESS else { return m }
        let page = Double(vm_kernel_page_size)
        m.app = Double(stats.internal_page_count) * page - Double(stats.purgeable_count) * page
        m.wired = Double(stats.wire_count) * page
        m.compressed = Double(stats.compressor_page_count) * page
        m.cached = (Double(stats.external_page_count) + Double(stats.purgeable_count)) * page
        return m
    }
}

func gigabytes(_ bytes: Double) -> String {
    bytes >= 1_073_741_824 ? String(format: "%.1f GB", bytes / 1_073_741_824) : String(format: "%.0f MB", bytes / 1_048_576)
}

// MARK: - Power source

func runningOnCharger() -> Bool {
    let blob = IOPSCopyPowerSourcesInfo().takeRetainedValue()
    guard let type = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String? else { return false }
    return type == "AC Power"
}
