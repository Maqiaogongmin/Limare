import Foundation
import Darwin

/// Kernel boundary for untrusted Agent/stdio descendants. No secret/config IPC authority.
/// `basePolicy` is the unchanged text of openai/codex 092d3acd6bec3e3a14bdc7e7a2810ab628ab759d,
/// codex-rs/sandboxing/src/seatbelt_base_policy.sbpl (Apache-2.0, Copyright 2025 OpenAI; see
/// LICENSES/codex-Apache-2.0.txt and LICENSES/codex-NOTICE.txt). Modified by Limare: `profile`
/// appends the workspace/temp write, network and reserved-path rules.
enum MCPExecutionPolicy {
    /// `unconfined` is Full access or an approved escalation, which Codex runs outside its
    /// sandbox (danger-full-access, require_escalated): the command may write anywhere, open
    /// apps and URLs, and use AppleScript and other macOS services. Only the reserved-root
    /// denials stay, so Limare's own data is not read or changed by accident; the Keychain is
    /// guarded by its own access control, as it is for Codex and Claude Code.
    static func profile(workspace: URL, unconfined: Bool = false, protectedRoots: [URL]? = nil) throws -> String {
        let workspace = TestStorageBootstrap.canonicalize(workspace)
        guard workspace.path != "/" else { throw MCPHostControlError.protectedInfrastructure }
        let roots = protectedRoots ?? MCPInfrastructureBoundary.protectedRoots
        try MCPInfrastructureBoundary.requireAgentFileAccess(to: workspace, roots: roots)
        func quoted(_ path: String) throws -> String {
            guard !path.unicodeScalars.contains(where: { $0.value < 32 }) else { throw MCPHostControlError.protectedInfrastructure }
            return "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        func kernelPath(_ url: URL) throws -> String {
            var existing = url
            var components: [String] = []
            while !FileManager.default.fileExists(atPath: existing.path) && existing.path != "/" {
                components.insert(existing.lastPathComponent, at: 0)
                existing.deleteLastPathComponent()
            }
            guard let resolved = realpath(existing.path, nil) else { throw MCPHostControlError.protectedInfrastructure }
            defer { free(resolved) }
            // Foundation may normalize /private/var back to /var; Seatbelt needs the
            // kernel spelling. Preserve realpath's bytes, like the mother's OS normalization.
            return components.reduce(String(cString: resolved)) { ($0 as NSString).appendingPathComponent($1) }
        }
        var policy: String
        if unconfined {
            policy = "(version 1)\n(allow default)\n"
        } else {
            // Runtime/dependency reads remain available; writes are confined to workspace/temp.
            // Temp is both $TMPDIR and /tmp, as in Codex's workspace-write roots: zsh writes
            // here-documents under /tmp (TMPPREFIX), so without it every `<<EOF` fails.
            policy = basePolicy + "\n(allow file-read*)\n"
            for root in [workspace, URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath(), URL(fileURLWithPath: "/tmp")] {
                policy += "(allow file-write* (subpath " + (try quoted(kernelPath(root))) + "))\n"
            }
            // Network as in Codex's seatbelt network policy: inbound too, so a dev server
            // (vite, python -m http.server) can listen and be reached from the browser.
            policy += "(allow network-outbound network-inbound network-bind system-socket)\n"
            policy += "(allow mach-lookup (global-name \"com.apple.mDNSResponder\") (global-name \"com.apple.trustd.agent\"))\n"
        }
        // A preexisting alias of a reserved file is invisible to path rules; refuse to launch.
        guard try MCPInfrastructureBoundary.aliasedProtectedFiles(roots: roots).isEmpty else {
            throw MCPHostControlError.protectedInfrastructure
        }
        for root in roots {
            // Creation of new aliases is denied by the kernel for the reserved source paths.
            policy += "(deny file-read* file-write* (subpath " + (try quoted(kernelPath(root))) + "))\n"
        }
        // Confined, no SecurityServer/securityd, launch-services, AppleEvents or parent task
        // controls are granted.
        return policy
    }

    static func launch(executable: String, arguments: [String], workspace: URL, unconfined: Bool = false) throws -> (URL, [String]) {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec") else {
            throw MCPHostControlError.protectedInfrastructure
        }
        let policy = try profile(workspace: workspace, unconfined: unconfined)
        return (URL(fileURLWithPath: "/usr/bin/sandbox-exec"), ["-p", policy, executable] + arguments)
    }

    private static let basePolicy = #"""
(version 1)

; inspired by Chrome's sandbox policy:
; https://source.chromium.org/chromium/chromium/src/+/main:sandbox/policy/mac/common.sb;l=273-319;drc=7b3962fe2e5fc9e2ee58000dc8fbf3429d84d3bd
; https://source.chromium.org/chromium/chromium/src/+/main:sandbox/policy/mac/renderer.sb;l=64;drc=7b3962fe2e5fc9e2ee58000dc8fbf3429d84d3bd

; start with closed-by-default
(deny default)

; child processes inherit the policy of their parent
(allow process-exec)
(allow process-fork)
(allow signal (target same-sandbox))

; process-info
(allow process-info* (target same-sandbox))

(allow file-write-data
  (require-all
    (path "/dev/null")
    (vnode-type CHARACTER-DEVICE)))

; sysctls permitted.
(allow sysctl-read
  (sysctl-name "hw.activecpu")
  (sysctl-name "hw.busfrequency_compat")
  (sysctl-name "hw.byteorder")
  (sysctl-name "hw.cacheconfig")
  (sysctl-name "hw.cachelinesize_compat")
  (sysctl-name "hw.cpufamily")
  (sysctl-name "hw.cpufrequency_compat")
  (sysctl-name "hw.cputype")
  (sysctl-name "hw.l1dcachesize_compat")
  (sysctl-name "hw.l1icachesize_compat")
  (sysctl-name "hw.l2cachesize_compat")
  (sysctl-name "hw.l3cachesize_compat")
  (sysctl-name "hw.logicalcpu_max")
  (sysctl-name "hw.machine")
  (sysctl-name "hw.model")
  (sysctl-name "hw.memsize")
  (sysctl-name "hw.ncpu")
  (sysctl-name "hw.nperflevels")
  ; Chrome locks these CPU feature detection down a bit more tightly,
  ; but mostly for fingerprinting concerns which isn't an issue for codex.
  (sysctl-name-prefix "hw.optional.arm.")
  (sysctl-name-prefix "hw.optional.armv8_")
  (sysctl-name "hw.packages")
  (sysctl-name "hw.pagesize_compat")
  (sysctl-name "hw.pagesize")
  (sysctl-name "hw.physicalcpu")
  (sysctl-name "hw.physicalcpu_max")
  (sysctl-name "hw.logicalcpu")
  (sysctl-name "hw.cpufrequency")
  (sysctl-name "hw.tbfrequency_compat")
  (sysctl-name "hw.vectorunit")
  (sysctl-name "machdep.cpu.brand_string")
  (sysctl-name "kern.argmax")
  (sysctl-name "kern.hostname")
  (sysctl-name "kern.maxfilesperproc")
  (sysctl-name "kern.maxproc")
  (sysctl-name "kern.osproductversion")
  (sysctl-name "kern.osrelease")
  (sysctl-name "kern.ostype")
  (sysctl-name "kern.osvariant_status")
  (sysctl-name "kern.osversion")
  (sysctl-name "kern.secure_kernel")
  ; Python's ProcessPoolExecutor queries this through sysconf(_SC_SEM_NSEMS_MAX).
  (sysctl-name "kern.sysv.semmns")
  (sysctl-name "kern.usrstack64")
  (sysctl-name "kern.version")
  (sysctl-name "sysctl.proc_cputype")
  (sysctl-name "vm.loadavg")
  (sysctl-name-prefix "hw.perflevel")
  (sysctl-name-prefix "kern.proc.pgrp.")
  (sysctl-name-prefix "kern.proc.pid.")
  (sysctl-name-prefix "net.routetable.")
)

; Allow Java to read some CPU info. This is misclassified as a "write" because
; userspace passes a memory buffer to the sysctl, but conceptually it is a read.
(allow sysctl-write
  (sysctl-name "kern.grade_cputype"))

; IOKit
(allow iokit-open
  (iokit-registry-entry-class "RootDomainUserClient")
)

; needed to look up user info, see https://crbug.com/792228
(allow mach-lookup
  (global-name "com.apple.system.opendirectoryd.libinfo")
)

; Needed for python multiprocessing on MacOS for the SemLock
(allow ipc-posix-sem)

; Needed for PyTorch/libomp on macOS to register OpenMP runtimes.
(allow ipc-posix-shm-read-data
  ipc-posix-shm-write-create
  ipc-posix-shm-write-unlink
  (ipc-posix-name-regex #"^/__KMP_REGISTERED_LIB_[0-9]+$"))

(allow mach-lookup
  (global-name "com.apple.PowerManagement.control")
)

; allow openpty()
(allow pseudo-tty)
(allow file-read* file-write* file-ioctl (literal "/dev/ptmx"))
(allow file-read* file-write*
  (require-all
    (regex #"^/dev/ttys[0-9]+")
    (extension "com.apple.sandbox.pty")))
; PTYs created before entering seatbelt may lack the extension; allow ioctl
; on those slave ttys so interactive shells detect a TTY and remain functional.
(allow file-ioctl (regex #"^/dev/ttys[0-9]+"))

"""#
}
