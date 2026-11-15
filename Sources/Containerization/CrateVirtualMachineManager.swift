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
import Foundation
import Logging
import NIOCore

/// Creates virtual machines on the crate engine. crate runs one machine per
/// process, so several containers share one through a ``LinuxPod``.
public struct CrateVirtualMachineManager: VirtualMachineManager {
    private let kernel: Kernel
    private let initialFilesystem: Mount
    private let backend: CrateVirtualMachineInstance.CPUBackend
    private let jitRegion: CrateJITRegion?
    private let portForwards: [CratePortForward]
    private let group: EventLoopGroup?
    private let logger: Logger?

    public init(
        kernel: Kernel,
        initialFilesystem: Mount,
        backend: CrateVirtualMachineInstance.CPUBackend = .auto,
        jitRegion: CrateJITRegion? = nil,
        portForwards: [CratePortForward] = [],
        group: EventLoopGroup? = nil,
        logger: Logger? = nil
    ) {
        self.kernel = kernel
        self.initialFilesystem = initialFilesystem
        self.backend = backend
        self.jitRegion = jitRegion
        self.portForwards = portForwards
        self.group = group
        self.logger = logger
    }

    public func create(config: some VMCreationConfig) throws -> any VirtualMachineInstance {
        let vmConfig = config.configuration
        if vmConfig.nestedVirtualization {
            throw ContainerizationError(.unsupported, message: "crate has no nested virtualization")
        }
        return try CrateVirtualMachineInstance(
            group: group,
            logger: logger,
            with: { c in
                c.cpus = vmConfig.cpus
                c.memoryInBytes = vmConfig.memoryInBytes
                c.mountsByID = vmConfig.mountsByID
                c.interfaces = vmConfig.interfaces
                c.bootLog = vmConfig.bootLog
                c.kernel = self.kernel
                c.initialFilesystem = self.initialFilesystem
                c.backend = self.backend
                c.jitRegion = self.jitRegion
                c.portForwards = self.portForwards
            })
    }
}
#endif
