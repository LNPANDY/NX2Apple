import Foundation

/// The processes a process started. A Mac game app's executable (dm/mac/launcher.c) runs the host, dmhost, as its child, and the host
/// is the one that posts and observes the distributed notifications of a paused game (org.nxnative.paused.<pid>, engine patch 0121,
/// LNPANDY/NX2Apple#952) with its own process ID. The launcher knows the app's process ID, so it looks the host up here.
package enum ProcessTree {
    /// The IDs of the running processes whose parent is `parent`, empty when there are none or the list cannot be read.
    package static func children(of parent: pid_t) -> [pid_t] {
        guard parent > 0 else { return [] }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }
        let stride = MemoryLayout<kinfo_proc>.stride
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 32)   // room for processes started meanwhile
        size = processes.count * stride
        guard sysctl(&mib, UInt32(mib.count), &processes, &size, nil, 0) == 0 else { return [] }
        return processes.prefix(size / stride).filter { $0.kp_eproc.e_ppid == parent && $0.kp_proc.p_pid > 0 }.map(\.kp_proc.p_pid)
    }
}
