import Darwin
import Foundation

/// Reads a process's current working directory from the kernel.
///
/// Ghostty only reports a surface's `pwd` through shell integration's
/// OSC 7, and the app disables that integration (its scripts are GPLv3).
/// The foreground process's cwd is the reliable way to follow `cd` in a
/// terminal pane, so a new tab or split can start where the old shell is.
enum ProcessWorkingDirectory {
    static func path(of pid: Int) -> String? {
        guard let pid = Int32(exactly: pid) else { return nil }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else {
            return nil
        }
        return withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            let path = raw.prefix { $0 != 0 }
            guard !path.isEmpty else { return nil }
            return String(decoding: path, as: UTF8.self)
        }
    }
}
