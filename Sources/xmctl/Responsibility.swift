import Darwin
import Foundation

/// macOS attributes Bluetooth (TCC) access to the *responsible* process — the app that
/// launched us (Terminal, an IDE, …). If that app has no NSBluetoothAlwaysUsageDescription,
/// the kernel kills us on first IOBluetooth use. Re-spawning ourselves with responsibility
/// disclaimed makes xmctl its own responsible process, so TCC uses xmctl's embedded Info.plist
/// and prompts for xmctl itself.
///
/// `responsibility_spawnattrs_setdisclaim` is private but long-standing (used by LLDB, Chromium,
/// Qt Creator, …). We look it up dynamically and simply skip the re-spawn if it is missing.
enum Responsibility {
    private static let marker = "XMCTL_DISCLAIMED"

    static func disclaimIfNeeded() {
        guard getenv(marker) == nil else { return }

        typealias SetDisclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim")
        else { return } // RTLD_DEFAULT is (void*)-2 on Darwin
        let setDisclaim = unsafeBitCast(sym, to: SetDisclaim.self)

        var attr: posix_spawnattr_t?
        guard posix_spawnattr_init(&attr) == 0 else { return }
        defer { posix_spawnattr_destroy(&attr) }
        guard setDisclaim(&attr, 1) == 0 else { return }

        setenv(marker, "1", 1)
        let path = ProcessInfo.processInfo.arguments[0]
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let argv = CommandLine.unsafeArgv
        var pid: pid_t = 0
        guard posix_spawn(&pid, resolved, nil, &attr, argv, environ) == 0 else {
            unsetenv(marker) // fall back to running in-process
            return
        }

        // Forward Ctrl-C to the child, then mirror its exit status.
        signal(SIGINT, SIG_IGN)
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        let low = status & 0x7f
        if low == 0 { exit((status >> 8) & 0xff) } // exited normally
        exit(128 + low) // killed by a signal
    }
}
