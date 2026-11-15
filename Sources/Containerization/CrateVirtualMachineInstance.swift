//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the Containerization project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

#if canImport(CrateEngine)
import ContainerizationError
import ContainerizationExtras
import CrateEngine
import Foundation
import Logging
import NIOCore
import NIOPosix
import Synchronization

/// A port on the host forwarded into the guest by the crate backend's
/// user-mode network.
public struct CratePortForward: Sendable, Hashable {
    public enum Proto: Sendable, Hashable {
        case tcp
        case udp
    }

    public var proto: Proto
    /// The host address to bind; nil for every interface.
    public var hostAddress: String?
    public var hostPort: UInt16
    public var guestPort: UInt16

    public init(proto: Proto = .tcp, hostAddress: String? = "127.0.0.1", hostPort: UInt16, guestPort: UInt16) {
        self.proto = proto
        self.hostAddress = hostAddress
        self.hostPort = hostPort
        self.guestPort = guestPort
    }
}

/// Executable memory for crate's translator, prepared by the app. Needed on
/// iOS, where only an attached debugger can make memory executable.
public struct CrateJITRegion: @unchecked Sendable {
    public var executable: UnsafeMutableRawPointer
    public var writable: UnsafeMutableRawPointer
    public var size: Int

    public init(executable: UnsafeMutableRawPointer, writable: UnsafeMutableRawPointer, size: Int) {
        self.executable = executable
        self.writable = writable
        self.size = size
    }
}

/// The user-mode network crate gives the guest.
public enum CrateNetwork {
    /// The guest's address on it.
    public static let guestAddress = "10.0.2.15"
    public static let prefixLength: UInt8 = 24
    /// The host, as the guest sees it, and its default route.
    public static let gateway = "10.0.2.2"
    /// The DNS forwarder on the host side.
    public static let nameserver = "10.0.2.3"

    /// The interface to hand a container so vminitd configures eth0 for it.
    public static func interface() throws -> NATInterface {
        NATInterface(
            ipv4Address: try CIDRv4("\(guestAddress)/\(prefixLength)"),
            ipv4Gateway: try IPv4Address(gateway)
        )
    }
}

/// A virtual machine on the crate engine: Apple's Hypervisor framework on a
/// Mac, crate's own arm64 translator where there is no hypervisor (iOS).
///
/// crate allows one machine per process.
public final class CrateVirtualMachineInstance: Sendable {
    public typealias Agent = Vminitd

    /// The guest's vsock context ID.
    static let guestCID: UInt64 = 3

    public enum CPUBackend: Sendable {
        /// The Hypervisor framework when the process may use it, otherwise the translator.
        case auto
        case jit
        case hvf
    }

    public struct Configuration: Sendable {
        public var cpus: Int = 4
        public var memoryInBytes: UInt64 = 1024.mib()
        public var mountsByID: [String: [Mount]] = [:]
        public var interfaces: [any Interface] = []
        public var kernel: Kernel?
        public var initialFilesystem: Mount?
        public var bootLog: BootLog?
        public var backend: CPUBackend = .auto
        public var jitRegion: CrateJITRegion?
        public var portForwards: [CratePortForward] = []
        /// How long to wait for the guest's agent after starting.
        public var agentTimeout: Duration = .seconds(180)

        public init() {}
    }

    private let _mounts: Mutex<[String: [AttachedFilesystem]]>
    public var mounts: [String: [AttachedFilesystem]] {
        _mounts.withLock { $0 }
    }

    public var state: VirtualMachineInstanceState {
        machine.withLock { box in
            guard let m = box.pointer else {
                return .stopped
            }
            switch crate_machine_state(m) {
            case CRATE_STATE_CREATED: return .starting
            case CRATE_STATE_RUNNING: return .running
            case CRATE_STATE_PAUSED: return .running
            case CRATE_STATE_STOPPED: return .stopped
            default: return .unknown
            }
        }
    }

    private let config: Configuration
    private let machine: Mutex<MachineBox>
    private let console: ConsoleSink
    private let lock: AsyncLock
    private let group: EventLoopGroup
    private let ownsGroup: Bool
    private let timeSyncer: TimeSyncer
    private let logger: Logger?

    struct MachineBox: @unchecked Sendable {
        var pointer: OpaquePointer?
    }

    public convenience init(
        group: EventLoopGroup? = nil,
        logger: Logger? = nil,
        with: (inout Configuration) throws -> Void
    ) throws {
        var config = Configuration()
        try with(&config)
        try self.init(group: group, config: config, logger: logger)
    }

    init(group: EventLoopGroup?, config: Configuration, logger: Logger?) throws {
        if let group {
            self.ownsGroup = false
            self.group = group
        } else {
            self.ownsGroup = true
            self.group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        }
        self.config = config
        self.lock = .init()
        self.logger = logger
        self.timeSyncer = .init(logger: logger)
        self.console = try ConsoleSink(bootLog: config.bootLog)

        let allocator = Character.blockDeviceTagAllocator()
        if config.initialFilesystem?.isBlock == true {
            _ = try allocator.allocate()
        }
        var attachments: [String: [AttachedFilesystem]] = [:]
        for (id, mounts) in config.mountsByID {
            attachments[id] = try mounts.map { try AttachedFilesystem(mount: $0, allocator: allocator) }
        }
        self._mounts = Mutex(attachments)
        self.machine = Mutex(MachineBox(pointer: nil))
    }

    deinit {
        machine.withLock { box in
            if let m = box.pointer {
                crate_machine_free(m)
                box.pointer = nil
            }
        }
    }

    static func check(_ status: crate_status, _ what: String) throws {
        guard status == CRATE_OK else {
            let detail = crate_last_error().map { String(cString: $0) } ?? ""
            let code: ContainerizationError.Code = status == CRATE_ERR_TIMEOUT ? .timeout : .internalError
            throw ContainerizationError(code, message: "\(what): \(detail)")
        }
    }

    /// The disks in the order the guest sees them: vda, vdb, ...
    private func disks() throws -> [(path: String, readOnly: Bool)] {
        guard let initial = config.initialFilesystem else {
            throw ContainerizationError(.invalidArgument, message: "rootfs cannot be nil")
        }
        guard initial.isBlock else {
            throw ContainerizationError(.unsupported, message: "crate boots from a block rootfs only")
        }
        var disks = [(path: initial.source, readOnly: true)]
        // The same order the attachments were allocated in.
        for (_, mounts) in config.mountsByID {
            for mount in mounts {
                if case .virtiofs = mount.runtimeOptions {
                    throw ContainerizationError(.unsupported, message: "crate has no virtiofs; mount \(mount.source) as a block device")
                }
                if mount.isBlock {
                    disks.append((path: mount.source, readOnly: mount.options.contains("ro")))
                }
            }
        }
        return disks
    }

    private func makeMachine() throws -> OpaquePointer {
        guard let kernel = config.kernel, let initial = config.initialFilesystem else {
            throw ContainerizationError(.invalidArgument, message: "kernel and rootfs are required")
        }
        guard let c = crate_config_new("virt") else {
            try Self.check(CRATE_ERR_INVALID_ARGUMENT, "crate_config_new")
            fatalError()
        }
        defer { crate_config_free(c) }

        let backend: crate_cpu_backend
        switch config.backend {
        case .auto: backend = CRATE_CPU_AUTO
        case .jit: backend = CRATE_CPU_JIT
        case .hvf: backend = CRATE_CPU_HVF
        }
        try Self.check(crate_config_set_cpu_backend(c, backend), "cpu backend")
        try Self.check(crate_config_set_cpus(c, UInt32(config.cpus)), "cpus")
        let twoMiB: UInt64 = 2 << 20
        let memory = (config.memoryInBytes + twoMiB - 1) & ~(twoMiB - 1)
        try Self.check(crate_config_set_memory(c, memory), "memory")
        if let region = config.jitRegion {
            try Self.check(crate_config_set_jit_region(c, region.executable, region.writable, region.size), "jit region")
        }
        try Self.check(crate_config_set_kernel(c, kernel.path.path), "kernel")
        try Self.check(crate_config_set_cmdline(c, kernel.linuxCommandline(initialFilesystem: initial)), "cmdline")

        for disk in try disks() {
            let flags: UInt32 = disk.readOnly ? UInt32(CRATE_DISK_READ_ONLY) : 0
            try Self.check(crate_config_add_disk(c, disk.path, flags), "disk \(disk.path)")
        }

        if !config.interfaces.isEmpty {
            guard config.interfaces.count == 1 else {
                throw ContainerizationError(.unsupported, message: "crate has one user-mode network")
            }
            var index: UInt32 = 0
            try Self.check(crate_config_add_network(c, &index), "network")
            if let mac = config.interfaces[0].macAddress {
                let bytes = mac.bytes
                try bytes.withUnsafeBufferPointer {
                    try Self.check(crate_config_set_network_mac(c, index, $0.baseAddress), "mac")
                }
            }
            for f in config.portForwards {
                let proto = f.proto == .tcp ? CRATE_TCP : CRATE_UDP
                try Self.check(
                    crate_config_add_port_forward(c, index, proto, f.hostAddress ?? "", f.hostPort, f.guestPort),
                    "port forward \(f.hostPort)")
            }
        }

        // hvc0: the console the kernel and vminitd log to.
        var callbacks = crate_console_callbacks()
        callbacks.size = MemoryLayout<crate_console_callbacks>.size
        callbacks.context = Unmanaged.passUnretained(console).toOpaque()
        callbacks.output = { context, _, bytes, length in
            guard let context, let bytes else { return }
            let sink = Unmanaged<ConsoleSink>.fromOpaque(context).takeUnretainedValue()
            sink.write(UnsafeRawBufferPointer(start: bytes, count: length))
        }
        var consoleIndex: UInt32 = 0
        try Self.check(crate_config_add_console(c, CRATE_CONSOLE_VIRTIO, &callbacks, &consoleIndex), "console")

        try Self.check(crate_config_add_vsock(c, Self.guestCID), "vsock")

        var m: OpaquePointer?
        try Self.check(crate_machine_create(c, &m), "create machine")
        guard let m else {
            throw ContainerizationError(.internalError, message: "crate returned no machine")
        }
        return m
    }

    private func pointer() throws -> OpaquePointer {
        guard let m = machine.withLock({ $0.pointer }) else {
            throw ContainerizationError(.invalidState, message: "vm is not running")
        }
        return m
    }

    /// Connects to a guest vsock port, as a FileHandle the caller closes.
    private func connect(_ port: UInt32, timeout: UInt32 = 5000) async throws -> FileHandle {
        let box = MachineBox(pointer: try pointer())
        let fd: Int32 = try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                var fd: Int32 = -1
                let status = crate_vsock_connect(box.pointer, port, timeout, &fd)
                do {
                    try Self.check(status, "vsock port \(port)")
                    cont.resume(returning: fd)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: false)
    }

    private func waitForAgent() async throws -> FileHandle {
        let deadline = ContinuousClock.now + config.agentTimeout
        var lastError: Error?
        while ContinuousClock.now < deadline {
            if state == .stopped {
                throw ContainerizationError(.internalError, message: "the vm stopped while booting\(console.tail())")
            }
            do {
                return try await connect(Vminitd.port, timeout: 1000)
            } catch {
                lastError = error
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        throw ContainerizationError(
            .timeout, message: "failed to get a connection to agent socket: \(String(describing: lastError))\(console.tail())")
    }
}

extension CrateVirtualMachineInstance: VirtualMachineInstance {
    public func start() async throws {
        try await lock.withLock { _ in
            guard self.machine.withLock({ $0.pointer }) == nil else {
                throw ContainerizationError(.invalidState, message: "virtual machine is not stopped \(self.state)")
            }
            let m = try self.makeMachine()
            self.machine.withLock { $0.pointer = m }
            do {
                try Self.check(crate_machine_start(m), "start")
                let agent = try await Vminitd(connection: try await self.waitForAgent(), group: self.group)
                await self.timeSyncer.start(context: agent)
            } catch {
                self.machine.withLock { box in
                    if let m = box.pointer {
                        crate_machine_free(m)
                        box.pointer = nil
                    }
                }
                throw error
            }
        }
    }

    public func stop() async throws {
        try await lock.withLock { _ in
            guard let m = self.machine.withLock({ $0.pointer }) else {
                throw ContainerizationError(.invalidState, message: "vm is not running")
            }
            try await self.timeSyncer.close()
            if self.ownsGroup {
                try await self.group.shutdownGracefully()
            }
            _ = crate_machine_kill(m)
            _ = crate_machine_wait(m, 10_000)
            self.machine.withLock { box in
                if let m = box.pointer {
                    crate_machine_free(m)
                    box.pointer = nil
                }
            }
        }
    }

    public func dialAgent() async throws -> Vminitd {
        try await lock.withLock { _ in
            do {
                return try await Vminitd(connection: try await self.connect(Vminitd.port), group: self.group)
            } catch let err as ContainerizationError {
                throw err
            } catch {
                throw ContainerizationError(.internalError, message: "failed to dial agent", cause: error)
            }
        }
    }

    public func dial(_ port: UInt32) async throws -> FileHandle {
        try await lock.withLock { _ in
            try await self.connect(port)
        }
    }

    public func listen(_ port: UInt32) throws -> VsockListener {
        let m = try pointer()
        let box = MachineBox(pointer: m)
        let stream = VsockListener(port: port, stopListen: { port in
            _ = crate_vsock_unlisten(box.pointer, port)
            ListenerRegistry.shared.remove(port)
        })
        let context = ListenerRegistry.shared.add(port, stream)
        let status = crate_vsock_listen(
            m, port,
            { context, _, fd in
                guard let context else {
                    close(fd)
                    return
                }
                let box = Unmanaged<ListenerBox>.fromOpaque(context).takeUnretainedValue()
                let fh = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
                if case .terminated = box.listener.yield(fh) {
                    try? fh.close()
                }
            }, context)
        if status != CRATE_OK {
            ListenerRegistry.shared.remove(port)
            try Self.check(status, "vsock listen \(port)")
        }
        return stream
    }
}

/// Keeps each listener alive while crate may still call into it.
final class ListenerBox: @unchecked Sendable {
    let listener: VsockListener
    init(_ listener: VsockListener) { self.listener = listener }
}

final class ListenerRegistry: Sendable {
    static let shared = ListenerRegistry()
    private let boxes = Mutex<[UInt32: ListenerBox]>([:])

    func add(_ port: UInt32, _ listener: VsockListener) -> UnsafeMutableRawPointer {
        let box = ListenerBox(listener)
        boxes.withLock { $0[port] = box }
        return Unmanaged.passUnretained(box).toOpaque()
    }

    func remove(_ port: UInt32) {
        // crate stops calling the acceptor before unlisten returns.
        _ = boxes.withLock { $0.removeValue(forKey: port) }
    }
}

/// Where the guest's console goes: the boot log, and the last lines kept for
/// error messages.
final class ConsoleSink: @unchecked Sendable {
    private let handle: FileHandle?
    private let recent = Mutex<[UInt8]>([])
    private static let keep = 4096

    init(bootLog: BootLog?) throws {
        switch bootLog?.base {
        case .file(let path, let append):
            if !FileManager.default.fileExists(atPath: path.path) || !append {
                FileManager.default.createFile(atPath: path.path, contents: nil)
            }
            let h = try FileHandle(forWritingTo: path)
            if append { h.seekToEndOfFile() }
            self.handle = h
        case .fileHandle(let h):
            self.handle = h
        case .none:
            self.handle = nil
        }
    }

    func write(_ bytes: UnsafeRawBufferPointer) {
        handle?.write(Data(bytes))
        recent.withLock { buf in
            buf.append(contentsOf: bytes)
            if buf.count > Self.keep {
                buf.removeFirst(buf.count - Self.keep)
            }
        }
    }

    /// The console's last output, for an error message.
    func tail() -> String {
        let text = recent.withLock { String(decoding: $0, as: UTF8.self) }
        return text.isEmpty ? "" : "\nconsole:\n\(text)"
    }
}
#endif
