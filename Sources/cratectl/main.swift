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

// cratectl: runs one container on the crate engine, for checking the crate
// backend on a Mac.

import ArgumentParser
import Containerization
import ContainerizationExtras
import ContainerizationOCI
import Foundation
import Logging

/// crate's user-mode network: every container gets the same guest address.
struct CrateUserNetwork: Network {
    mutating func createInterface(_ id: String) throws -> Interface? {
        try CrateNetwork.interface()
    }

    mutating func releaseInterface(_ id: String) throws {}
}

@main
struct CrateCtl: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cratectl",
        abstract: "Run a container on the crate engine"
    )

    @Option(name: .shortAndLong, help: "Kernel (arm64 Image)")
    var kernel: String

    @Option(name: .long, help: "Image store and container root")
    var root: String

    @Option(name: .long, help: "vminit image")
    var initfs: String = "ghcr.io/apple/containerization/vminit:0.54.0"

    @Option(name: .long, help: "cpu backend: auto, jit or hvf")
    var backend: String = "auto"

    @Option(name: .long, help: "CPUs")
    var cpus: Int = 2

    @Option(name: .long, help: "Memory in MiB for the container")
    var memory: UInt64 = 512

    @Option(name: [.customShort("p"), .long], help: "Publish a port, HOST:CONTAINER (tcp, on 127.0.0.1)")
    var publish: [String] = []

    @Option(name: .long, help: "Boot log file")
    var bootLog: String?

    @Option(name: .long, help: "Extra kernel argument")
    var kernelArg: [String] = []

    @Option(name: .long, help: "Container ID")
    var id: String = "demo"

    @Argument(help: "Image reference")
    var image: String

    @Argument(parsing: .captureForPassthrough, help: "Command (default: the image's)")
    var arguments: [String] = []

    func run() async throws {
        var logger = Logger(label: "cratectl")
        logger.logLevel = .info

        let rootURL = URL(fileURLWithPath: root)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let store = try ImageStore(path: rootURL)

        let initPath = rootURL.appendingPathComponent("initfs.ext4")
        let initfsMount: Containerization.Mount
        if FileManager.default.fileExists(atPath: initPath.path) {
            initfsMount = .block(format: "ext4", source: initPath.path, destination: "/", options: ["ro"])
        } else {
            print("pulling \(initfs)")
            let initImage = try await store.getInitImage(reference: initfs)
            initfsMount = try await initImage.initBlock(at: initPath, for: .linuxArm)
        }

        var forwards: [CratePortForward] = []
        for p in publish {
            let parts = p.split(separator: ":").compactMap { UInt16($0) }
            guard parts.count == 2 else {
                throw ValidationError("--publish takes HOST:CONTAINER, not \(p)")
            }
            forwards.append(CratePortForward(hostPort: parts[0], guestPort: parts[1]))
        }
        let cpuBackend: CrateVirtualMachineInstance.CPUBackend =
            switch backend {
            case "jit": .jit
            case "hvf": .hvf
            default: .auto
            }

        var cmdline = Kernel.CommandLine(debug: false, panic: 0)
        cmdline.kernelArgs.append(contentsOf: kernelArg.isEmpty ? ["quiet"] : kernelArg)
        let vmm = CrateVirtualMachineManager(
            kernel: Kernel(path: URL(fileURLWithPath: kernel), platform: .linuxArm, commandline: cmdline),
            initialFilesystem: initfsMount,
            backend: cpuBackend,
            portForwards: forwards,
            logger: logger
        )

        var manager = try ContainerManager(vmm: vmm, network: CrateUserNetwork(), logger: logger)
        print("pulling \(image)")
        let img = try await store.get(reference: image, pull: true)
        try? manager.delete(id)

        let started = ContinuousClock.now
        let container = try await manager.create(
            id,
            image: img,
            rootfsSizeInBytes: 2.gib(),
            networking: true,
            vm: VMResources(cpus: cpus, memoryInBytes: memory.mib() + VMResources.guestMemoryOverhead)
        ) { config in
            config.cpus = cpus
            config.memoryInBytes = memory.mib()
            if !arguments.isEmpty {
                config.process.arguments = arguments
            }
            config.process.stdout = StandardIO.out
            config.process.stderr = StandardIO.err
            config.dns = DNS(nameservers: [CrateNetwork.nameserver])
            if let bootLog {
                config.bootLog = BootLog.file(path: URL(fileURLWithPath: bootLog), append: false)
            }
        }
        defer { try? manager.delete(id) }

        try await container.create()
        print("vm up in \(ContinuousClock.now - started)")
        try await container.start()
        print("container started in \(ContinuousClock.now - started)")
        let status = try await container.wait()
        try await container.stop()
        print("exited: \(status)")
    }
}

/// Copies the container's output to this process's.
final class StandardIO: Writer, @unchecked Sendable {
    static let out = StandardIO(FileHandle.standardOutput)
    static let err = StandardIO(FileHandle.standardError)

    private let handle: FileHandle
    init(_ handle: FileHandle) { self.handle = handle }

    func write(_ data: Data) throws {
        handle.write(data)
    }

    func close() throws {}
}
