import Foundation
import FanControlCore
import SMCControlTransport
#if canImport(Darwin)
import Darwin
#endif

do {
    let command = try FanControlCommand.parse(Array(CommandLine.arguments.dropFirst()))
    let capability = FanCapability.mac165ValidatedOneShot

    switch command {
    case .boostMax, .runBoostMax:
        guard capability.validation.activeControlEnabled else {
            let response = try FanControlCommandContract.disabledActiveControlResponse(
                for: command,
                capability: capability
            )
            print(response.stdout, terminator: "")
            exit(response.exitCode)
        }

        print(FanControlCommandContract.disabledActiveControlMessage(model: capability.model))

    case .auto:
        let store = FanLeaseStore.defaultStore()
        guard let lease = try store.readIfPresent() else {
            print("no active MLX & Chill fan-control lease; no recovery write attempted")
            exit(0)
        }

        guard lease.capabilityFingerprint == capability.fingerprint else {
            print("lease capability fingerprint mismatch; no recovery write attempted")
            exit(1)
        }

        print("auto is recovery-only for compatible existing MLX & Chill leases; recovery write execution remains disabled until recovery validation is complete")

    case .statusJSON:
        let response = try FanControlCommandContract.disabledActiveControlResponse(
            for: command,
            capability: capability
        )
        print(response.stdout, terminator: "")
        exit(response.exitCode)

    case .validateOneShot(let durationSeconds, _):
        try runValidationOneShot(durationSeconds: durationSeconds)
    }
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}

private func runValidationOneShot(durationSeconds: Int) throws {
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
        leaseStore: .defaultStore()
    )

    var needsRestore = false
    do {
        let boost = try controller.boostMax(
            leaseSeconds: durationSeconds,
            reason: "10-second hardware validation one-shot"
        )
        needsRestore = true
        print("boosted fans to maximum; lease=\(boost.leaseID); holding for \(durationSeconds)s")
        Thread.sleep(forTimeInterval: TimeInterval(durationSeconds))

        let restore = try controller.restoreAuto(
            reason: "10-second hardware validation one-shot complete",
            recoveryMode: true
        )
        needsRestore = false
        print("restored automatic fan control; finalModes=\(restore.finalModes); finalTargets=\(restore.finalTargets)")
    } catch {
        if needsRestore {
            do {
                _ = try controller.restoreAuto(
                    reason: "10-second hardware validation one-shot failed",
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

private func fanControlSupportDirectory() -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
    return base.appendingPathComponent("MLXChill/fan-control", isDirectory: true)
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
