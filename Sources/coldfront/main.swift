import FanControlCore
import FanProbeCore
import Foundation
import SMCControlTransport
#if canImport(Darwin)
import Darwin
#endif

let arguments = Array(CommandLine.arguments.dropFirst())

do {
    if arguments.isEmpty {
        print(FanProbe.render(FanProbe.snapshot()))
        exit(0)
    }

    if arguments == ["--help"] || arguments == ["-h"] {
        printHelp()
        exit(0)
    }

    if arguments.first == "read" {
        try runRead(Array(arguments.dropFirst()))
        exit(0)
    }

    let command = try FanControlCommand.parse(arguments)

    switch command {
    case .boostMax(let durationSeconds, _):
        try runBoost(durationSeconds: durationSeconds)

    case .auto:
        try runAutoRestore()

    case .statusJSON:
        try printStatusJSON()

    case .validateOneShot(let durationSeconds, _):
        try runValidation(durationSeconds: durationSeconds)
    }
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}

private func printHelp() {
    print("""
    Coldfront

    Mac fan and thermal probe with guarded fan-control validation.

    Usage:
      coldfront
      coldfront read FNum F0Ac F0Tg F0Md Ftst
      coldfront status --json
      coldfront validate [--for 10s] -y
      coldfront auto
      coldfront boost [--for duration] -y
    """)
}

private func runRead(_ keys: [String]) throws {
    guard !keys.isEmpty else {
        throw FanControlCommandParseError.usage("expected: read <SMC key...>")
    }

    let client = try SMCClient()
    let readings = keys.map { key -> Result<SMCReading, Error> in
        do {
            return .success(try client.read(key))
        } catch {
            return .failure(error)
        }
    }

    print(renderExplicitReadings(readings))
    if readings.contains(where: { if case .failure = $0 { true } else { false } }) {
        exit(1)
    }
}

private func runBoost(durationSeconds: Int) throws {
    let context = try makeControlContext()
    let boost = try context.controller.boostMax(
        leaseSeconds: durationSeconds,
        reason: "manual boost"
    )
    print("boosted fans to maximum; lease=\(boost.leaseID); run `sudo coldfront auto` to restore automatic fan control")
}

private func runAutoRestore() throws {
    let store = FanLeaseStore.defaultStore()
    guard (try store.readIfPresent()) != nil else {
        print("no active Coldfront fan-control lease")
        return
    }

    let context = try makeControlContext(leaseStore: store)
    let restore = try context.controller.restoreAuto(
        reason: "manual auto restore",
        recoveryMode: true
    )
    print("restored automatic fan control; finalModes=\(restore.finalModes); finalTargets=\(restore.finalTargets)")
}

private func printStatusJSON() throws {
    let context = try makeControlContext()
    let status = ColdfrontStatusJSON(
        model: context.capability.model,
        activeControlEnabled: true,
        boostExecutionEnabled: true,
        recoveryExecutionEnabled: true,
        reason: "active_control_enabled",
        message: "active fan control is enabled for \(context.capability.model)"
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(status)
    print(String(decoding: data, as: UTF8.self))
}

private func runValidation(durationSeconds: Int) throws {
    let context = try makeControlContext()
    let controller = context.controller

    var needsRestore = false
    do {
        let boost = try controller.boostMax(
            leaseSeconds: durationSeconds,
            reason: "10-second hardware validation"
        )
        needsRestore = true
        print("boosted fans to maximum; lease=\(boost.leaseID); holding for \(durationSeconds)s")
        Thread.sleep(forTimeInterval: TimeInterval(durationSeconds))

        let restore = try controller.restoreAuto(
            reason: "10-second hardware validation complete",
            recoveryMode: true
        )
        needsRestore = false
        print("restored automatic fan control; finalModes=\(restore.finalModes); finalTargets=\(restore.finalTargets)")
    } catch {
        if needsRestore {
            do {
                _ = try controller.restoreAuto(
                    reason: "10-second hardware validation failed",
                    recoveryMode: true
                )
                FileHandle.standardError.write(Data("restored automatic fan control after validation error\n".utf8))
            } catch {
                FileHandle.standardError.write(Data("restore after validation error failed: \(error)\n".utf8))
            }
        }
        throw error
    }
}

private struct ControlContext {
    let hardware: SMCFanHardware
    let capability: FanCapability
    let controller: FanController
}

private func makeControlContext(leaseStore: FanLeaseStore = .defaultStore()) throws -> ControlContext {
    let hardware = try SMCFanHardware()
    let resolver = FanCapabilityResolver(hardware: hardware, hostModel: currentHardwareModel)
    let resolved = try resolver.resolve()
    let capability = resolved.withValidation(FanValidationState(
        read: true,
        boostMaxOneShot: true,
        restoreAutoOneShot: true,
        targetClearAfterNonManual: true,
        crashRecovery: true,
        parentDeathRecovery: true,
        missedHeartbeatRecovery: true,
        leaseExpiryRecovery: true,
        signalRecovery: true,
        sleepWakeRecovery: true
    ))
    let controller = FanController(
        hardware: hardware,
        capability: capability,
        logger: JSONLFanControlLogger(url: fanControlSupportDirectory().appendingPathComponent("audit.jsonl")),
        leaseStore: leaseStore
    )
    return ControlContext(hardware: hardware, capability: capability, controller: controller)
}

private struct ColdfrontStatusJSON: Encodable {
    let model: String
    let activeControlEnabled: Bool
    let boostExecutionEnabled: Bool
    let recoveryExecutionEnabled: Bool
    let reason: String
    let message: String
}

private func fanControlSupportDirectory() -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
    return base.appendingPathComponent("Coldfront/fan-control", isDirectory: true)
}

private func currentHardwareModel() -> String {
    #if canImport(Darwin)
    var size = 0
    guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else {
        return "unknown"
    }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else {
        return "unknown"
    }
    if let nullIndex = buffer.firstIndex(of: 0) {
        buffer.removeSubrange(nullIndex...)
    }
    return String(decoding: buffer.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    #else
    return "unknown"
    #endif
}
