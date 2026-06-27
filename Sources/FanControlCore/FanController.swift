import Foundation
#if canImport(Darwin)
import Darwin
#endif

package final class FanController {
    private let hardware: FanHardware
    private let capability: FanCapability
    private let clock: FanControlClock
    private let logger: FanControlLogger
    private let leaseStore: FanLeaseStore
    private let processInspector: any FanProcessInspecting

    package init(
        hardware: FanHardware,
        capability: FanCapability,
        clock: FanControlClock = SystemFanControlClock(),
        // Active write construction must inject a durable logger; this default is for read/status paths and tests.
        logger: FanControlLogger = InMemoryFanControlLogger(),
        leaseStore: FanLeaseStore = .defaultStore(),
        processInspector: any FanProcessInspecting = SystemFanProcessInspector()
    ) {
        self.hardware = hardware
        self.capability = capability
        self.clock = clock
        self.logger = logger
        self.leaseStore = leaseStore
        self.processInspector = processInspector
    }

    package func status() throws -> FanControlStatus {
        let fanCount = Int(try readUInt8(capability.fanCountKey))
        let platform = try readASCII(capability.platformKey)
        let statusFanCount = min(fanCount, capability.fanCount)
        let fans = try (0..<statusFanCount).map { try readFan($0) }
        let ftst: UInt8?
        let unlockStatusUnavailable: Bool
        if capability.unlockAvailable {
            do {
                ftst = try readUInt8(capability.unlockKey)
                unlockStatusUnavailable = false
            } catch {
                ftst = nil
                unlockStatusUnavailable = true
            }
        } else {
            ftst = nil
            unlockStatusUnavailable = false
        }

        return FanControlStatus(
            serviceName: hardware.serviceName,
            platform: platform,
            fanCount: fanCount,
            fans: fans,
            ftst: ftst,
            activeAvailability: availability(
                fanCount: fanCount,
                platform: platform,
                fans: fans,
                unlockStatusUnavailable: unlockStatusUnavailable
            )
        )
    }

    package func recoveryDecision(nowUnix: TimeInterval? = nil, currentParentPID: Int32? = nil) throws -> FanRecoveryDecision {
        let lease: FanLease
        do {
            guard let currentLease = try leaseStore.readIfPresent() else {
                return FanRecoveryDecision(shouldRestore: false, reason: .noLease)
            }
            lease = currentLease
        } catch FanLeaseStoreError.corruptLease, FanLeaseStoreError.unreadableLease {
            return FanRecoveryDecision(shouldRestore: true, reason: .corruptLease)
        }

        if lease.capabilityFingerprint != capability.fingerprint {
            return FanRecoveryDecision(shouldRestore: true, reason: .capabilityMismatch)
        }

        let observedNow = nowUnix ?? clock.nowUnix
        if observedNow >= lease.expiresAtUnix {
            return FanRecoveryDecision(shouldRestore: true, reason: .expiredLease)
        }

        if observedNow - lease.heartbeatAtUnix >= TimeInterval(capability.missedHeartbeatRestoreSeconds) {
            return FanRecoveryDecision(shouldRestore: true, reason: .missedHeartbeat)
        }

        if let currentParentPID, currentParentPID != lease.parentPID {
            return FanRecoveryDecision(shouldRestore: true, reason: .parentExited)
        }
        if currentParentPID == nil {
            guard let ownerProcessInfo = processInspector.ownerProcessInfo(pid: lease.ownerPID),
                  let observedParentPID = ownerProcessInfo.parentPID
            else {
                return FanRecoveryDecision(shouldRestore: true, reason: .parentExited)
            }
            if observedParentPID != lease.parentPID {
                return FanRecoveryDecision(shouldRestore: true, reason: .parentExited)
            }
            if let expectedStartTime = lease.ownerStartTimeUnix {
                guard let observedStartTime = ownerProcessInfo.startTimeUnix,
                      observedStartTime == expectedStartTime
                else {
                    return FanRecoveryDecision(shouldRestore: true, reason: .parentExited)
                }
            }
        }

        return FanRecoveryDecision(shouldRestore: false, reason: .activeLease)
    }

    package func boostMax(leaseSeconds: Int, reason: String) throws -> FanBoostResult {
        guard capability.validation.activeControlEnabled else {
            throw FanControlError.activeControlDisabled(model: capability.model)
        }
        guard leaseSeconds > 0 && leaseSeconds <= capability.maxLeaseSeconds else {
            throw FanControlError.unsafeState("lease duration outside allowed range")
        }

        let snapshot = try status()
        try validateBoostStatus(snapshot)
        let lease = try createLease(from: snapshot, leaseSeconds: leaseSeconds, reason: reason)
        try leaseStore.claim(lease)

        do {
            if capability.unlockAvailable {
                try write(.unlock(value: capability.unlockOn), lease: lease, reason: "boost unlock: \(reason)")
                try pollUnlock(value: capability.unlockOn)
            }
            try requestTargetsToMax(snapshot, lease: lease, reason: "boost pre-manual target: \(reason)")
            try waitForSafePreManualTargets(snapshot)
            try writeManualModes(snapshot, lease: lease, reason: "boost manual mode: \(reason)")
            try pollManualModes(snapshot)
            try requestTargetsToMax(snapshot, lease: lease, reason: "boost max target: \(reason)")
            try pollTargetsAtMax(snapshot)
            let maxActualRPM = try verifyBoostRamp(snapshot)
            return FanBoostResult(leaseID: lease.id, verified: true, maxActualRPM: maxActualRPM)
        } catch {
            privateRollbackAfterBoostFailure(snapshot: snapshot, lease: lease, reason: "boost failed: \(error)")
            throw error
        }
    }

    @discardableResult
    package func restoreAuto(reason: String, recoveryMode: Bool = false) throws -> FanRestoreResult {
        let lease: FanLease
        do {
            guard let currentLease = try leaseStore.readIfPresent() else {
                if recoveryMode {
                    throw FanControlError.leaseRequired("recovery requested without lease")
                }
                return FanRestoreResult(restored: true, finalModes: [], finalTargets: [])
            }
            lease = currentLease
        } catch FanLeaseStoreError.corruptLease {
            throw FanControlError.restoreFailed("lease corrupt; restore requires operator intervention")
        } catch FanLeaseStoreError.unreadableLease {
            throw FanControlError.restoreFailed("lease unreadable; restore requires operator intervention")
        }

        guard lease.capabilityFingerprint == capability.fingerprint else {
            throw FanControlError.unsafeState("lease capability fingerprint mismatch")
        }

        let snapshot = try status()
        guard snapshot.fanCount == capability.fanCount,
              snapshot.fans.count == capability.fanCount
        else {
            throw FanControlError.unsafeState("fan count mismatch during restore")
        }
        let capturedTargets = try capturedTargetsByFanIndex(lease)

        for fan in snapshot.fans {
            try write(.target(fan: fan.index, bytes: FanEncoding.float32LittleEndian(fan.maximumRPM)), lease: lease, reason: "restore protective high target: \(reason)")
        }
        for fan in snapshot.fans {
            try write(.mode(fan: fan.index, value: capability.releaseCommand), lease: lease, reason: "restore release mode: \(reason)")
        }
        if capability.unlockAvailable {
            try write(.unlock(value: capability.unlockOff), lease: lease, reason: "restore unlock off: \(reason)")
            try pollUnlock(value: capability.unlockOff)
        }

        try pollNoManualModes(snapshot)
        try pollManagedModes(snapshot)

        for fan in snapshot.fans {
            let targetRaw = capturedTargets[fan.index]!
            try write(.target(fan: fan.index, bytes: targetRaw), lease: lease, reason: "restore captured target: \(reason)")
        }

        try pollManagedSettle(snapshot: snapshot, capturedTargets: capturedTargets)
        let finalStatus = try status()
        try leaseStore.clear(leaseID: lease.id)
        return FanRestoreResult(
            restored: true,
            finalModes: finalStatus.fans.map(\.mode),
            finalTargets: finalStatus.fans.map(\.targetRPM)
        )
    }

    private func availability(fanCount: Int, platform: String, fans: [FanStatus], unlockStatusUnavailable: Bool) -> ActiveAvailability {
        var reasons: [String] = []
        if platform != capability.platform { reasons.append("platform mismatch") }
        if fanCount != capability.fanCount { reasons.append("fan count mismatch") }
        if unlockStatusUnavailable { reasons.append("unlock status unavailable") }
        if !capability.validation.read { reasons.append("read validation unverified") }
        if !capability.validation.boostMaxOneShot { reasons.append("boost max one-shot unverified") }
        if !capability.validation.restoreAutoOneShot { reasons.append("restore auto one-shot unverified") }
        if !capability.validation.targetClearAfterNonManual { reasons.append("target clear after non-manual unverified") }
        if !capability.validation.crashRecovery { reasons.append("crash recovery unverified") }
        if !capability.validation.parentDeathRecovery { reasons.append("parent-death recovery unverified") }
        if !capability.validation.missedHeartbeatRecovery { reasons.append("missed-heartbeat recovery unverified") }
        if !capability.validation.leaseExpiryRecovery { reasons.append("lease-expiry recovery unverified") }
        if !capability.validation.signalRecovery { reasons.append("signal recovery unverified") }
        if !capability.validation.sleepWakeRecovery { reasons.append("sleep/wake recovery unverified") }
        if fans.contains(where: { $0.minimumRPM <= 0 || $0.maximumRPM <= $0.minimumRPM || $0.maximumRPM > capability.maxRPMCeiling }) {
            reasons.append("fan min/max out of bounds")
        }
        return ActiveAvailability(allowed: reasons.isEmpty && capability.validation.activeControlEnabled, reasons: reasons)
    }

    private func readFan(_ index: Int) throws -> FanStatus {
        let actual = try readFloat(capability.actualKey(for: index))
        let minimum = try readFloat(capability.minimumKey(for: index))
        let maximum = try readFloat(capability.maximumKey(for: index))
        let targetKey = try capability.targetKey(for: index)
        let modeKey = try capability.modeKey(for: index)
        let target = try readFloatReading(targetKey)
        let mode = try readUInt8Reading(modeKey)

        return FanStatus(
            index: index,
            actualRPM: actual,
            minimumRPM: minimum,
            maximumRPM: maximum,
            targetRPM: target.value,
            targetRaw: target.reading.bytes,
            mode: mode.value,
            modeRaw: mode.reading.bytes
        )
    }

    private func readFloat(_ key: FanKey) throws -> Float {
        try readFloatReading(key).value
    }

    private func readFloatReading(_ key: FanKey) throws -> (reading: FanReading, value: Float) {
        let reading = try hardware.read(key)
        guard reading.type == "flt ",
              reading.size == 4,
              reading.bytes.count == 4,
              let value = FanEncoding.floatValue(reading.bytes)
        else {
            throw FanControlError.invalidReading(key: key.stringValue, reason: "expected flt size == 4")
        }
        return (reading, value)
    }

    private func readUInt8(_ key: FanKey) throws -> UInt8 {
        try readUInt8Reading(key).value
    }

    private func readUInt8Reading(_ key: FanKey) throws -> (reading: FanReading, value: UInt8) {
        let reading = try hardware.read(key)
        guard reading.type == "ui8 ",
              reading.size == 1,
              reading.bytes.count == 1,
              let value = reading.bytes.first
        else {
            throw FanControlError.invalidReading(key: key.stringValue, reason: "expected ui8 size == 1")
        }
        return (reading, value)
    }

    private func readASCII(_ key: FanKey) throws -> String {
        let reading = try hardware.read(key)
        guard reading.type == "ch8*",
              reading.size > 0,
              reading.bytes.count == Int(reading.size),
              let value = String(bytes: reading.bytes.prefix { $0 != 0 }, encoding: .ascii),
              !value.isEmpty
        else {
            throw FanControlError.invalidReading(key: key.stringValue, reason: "expected ch8* ASCII bytes")
        }
        return value
    }

    private func validateBoostStatus(_ status: FanControlStatus) throws {
        guard status.activeAvailability.allowed else {
            throw FanControlError.unsafeState("active fan control unavailable: \(status.activeAvailability.reasons.joined(separator: ", "))")
        }
        guard status.fanCount == capability.fanCount, status.fans.count == capability.fanCount else {
            throw FanControlError.unsafeState("fan count mismatch")
        }
        guard !status.fans.contains(where: { $0.mode == capability.manualCommand }) else {
            throw FanControlError.unsafeState("refusing to boost while a fan is already manual")
        }
        if capability.unlockAvailable {
            guard status.ftst == capability.unlockOff else {
                throw FanControlError.unsafeState("refusing to boost while Ftst is already unlocked")
            }
        }
    }

    private func createLease(from status: FanControlStatus, leaseSeconds: Int, reason: String) throws -> FanLease {
        let ownerPID = Int32(ProcessInfo.processInfo.processIdentifier)
        guard let ownerInfo = processInspector.ownerProcessInfo(pid: ownerPID),
              let parentPID = ownerInfo.parentPID
        else {
            throw FanControlError.unsafeState("owner process identity unavailable")
        }
        let now = clock.nowUnix
        return FanLease(
            id: UUID(),
            capabilityFingerprint: capability.fingerprint,
            ownerPID: ownerPID,
            ownerStartTimeUnix: ownerInfo.startTimeUnix,
            parentPID: parentPID,
            createdAtUnix: now,
            expiresAtUnix: now + TimeInterval(leaseSeconds),
            heartbeatAtUnix: now,
            phase: .created,
            capturedFans: status.fans.map {
                CapturedFanState(index: $0.index, modeRaw: $0.modeRaw, targetRaw: $0.targetRaw)
            },
            reason: reason
        )
    }

    private func requestTargetsToMax(_ status: FanControlStatus, lease: FanLease, reason: String) throws {
        for fan in status.fans {
            try write(.target(fan: fan.index, bytes: FanEncoding.float32LittleEndian(fan.maximumRPM)), lease: lease, reason: reason)
        }
    }

    private func writeManualModes(_ status: FanControlStatus, lease: FanLease, reason: String) throws {
        for fan in status.fans {
            try write(.mode(fan: fan.index, value: capability.manualCommand), lease: lease, reason: reason)
        }
    }

    private func waitForSafePreManualTargets(_ status: FanControlStatus) throws {
        try poll(description: "safe pre-manual fan targets") {
            for fan in status.fans {
                let target = try readFloat(capability.targetKey(for: fan.index))
                let safeFloor = max(fan.minimumRPM * capability.preManualMinimumMultiplier, 1)
                guard target >= safeFloor && target < fan.maximumRPM else {
                    return false
                }
            }
            return true
        }
    }

    private func pollUnlock(value: UInt8) throws {
        try poll(description: "Ftst readback \(value)") {
            try readUInt8(capability.unlockKey) == value
        }
    }

    private func pollManualModes(_ status: FanControlStatus) throws {
        try poll(description: "manual fan mode readback") {
            for fan in status.fans {
                guard try readUInt8(capability.modeKey(for: fan.index)) == capability.manualCommand else {
                    return false
                }
            }
            return true
        }
    }

    private func pollNoManualModes(_ status: FanControlStatus) throws {
        try poll(description: "non-manual fan mode readback") {
            for fan in status.fans {
                guard try readUInt8(capability.modeKey(for: fan.index)) != capability.manualCommand else {
                    return false
                }
            }
            return true
        }
    }

    private func pollManagedModes(_ status: FanControlStatus) throws {
        try poll(description: "managed fan mode readback") {
            for fan in status.fans {
                guard try readUInt8(capability.modeKey(for: fan.index)) == capability.managedObservedState else {
                    return false
                }
            }
            if capability.unlockAvailable {
                guard try readUInt8(capability.unlockKey) == capability.unlockOff else {
                    return false
                }
            }
            return true
        }
    }

    private func pollTargetsAtMax(_ status: FanControlStatus) throws {
        try poll(description: "max fan target readback") {
            for fan in status.fans {
                let bytes = try hardware.read(capability.targetKey(for: fan.index)).bytes
                guard bytes == FanEncoding.float32LittleEndian(fan.maximumRPM) else {
                    return false
                }
            }
            return true
        }
    }

    private func verifyBoostRamp(_ status: FanControlStatus) throws -> Float {
        var maxActualRPM: Float = 0
        try poll(description: "boost actual RPM ramp", timeoutSeconds: 30) {
            var allVerified = true
            var observedMax = maxActualRPM
            for fan in status.fans {
                let actual = try readFloat(capability.actualKey(for: fan.index))
                observedMax = max(observedMax, actual)
                let threshold = fan.maximumRPM * capability.boostVerificationMultiplier
                if actual < threshold {
                    allVerified = false
                }
            }
            maxActualRPM = observedMax
            return allVerified
        }
        return maxActualRPM
    }

    private func pollManagedSettle(snapshot: FanControlStatus, capturedTargets: [Int: [UInt8]]) throws {
        try poll(description: "managed fan restore settle", timeoutSeconds: 30) {
            if capability.unlockAvailable {
                guard try readUInt8(capability.unlockKey) == capability.unlockOff else {
                    return false
                }
            }
            for fan in snapshot.fans {
                guard try readUInt8(capability.modeKey(for: fan.index)) == capability.managedObservedState else {
                    return false
                }
                guard let targetRaw = capturedTargets[fan.index],
                      try hardware.read(capability.targetKey(for: fan.index)).bytes == targetRaw
                else {
                    return false
                }
                let actual = try readFloat(capability.actualKey(for: fan.index))
                let capturedTarget = FanEncoding.floatValue(targetRaw) ?? 0
                let idleCeiling = max(fan.minimumRPM, capturedTarget)
                guard actual <= idleCeiling else {
                    return false
                }
            }
            return true
        }
    }

    private func privateRollbackAfterBoostFailure(snapshot: FanControlStatus, lease: FanLease, reason: String) {
        for fan in snapshot.fans {
            try? write(.target(fan: fan.index, bytes: FanEncoding.float32LittleEndian(fan.maximumRPM)), lease: lease, reason: "rollback high target: \(reason)")
        }
        for fan in snapshot.fans {
            try? write(.mode(fan: fan.index, value: capability.releaseCommand), lease: lease, reason: "rollback release mode: \(reason)")
        }
        if capability.unlockAvailable {
            try? write(.unlock(value: capability.unlockOff), lease: lease, reason: "rollback unlock off: \(reason)")
            try? pollUnlock(value: capability.unlockOff)
        }
    }

    private func poll(description: String, timeoutSeconds: Double = 5, intervalSeconds: Double = 1, condition: () throws -> Bool) throws {
        var elapsed = 0.0
        while true {
            if try condition() { return }
            guard elapsed < timeoutSeconds else {
                throw FanControlError.timeout(description)
            }
            clock.sleep(seconds: intervalSeconds)
            elapsed += intervalSeconds
        }
    }

    private func write(_ operation: FanWriteOperation, lease: FanLease, reason: String) throws {
        let key = try key(for: operation)
        let oldRaw = try hardware.read(key).bytes
        let newRaw = newRawBytes(for: operation)
        let result = try hardware.write(operation, capability: capability, reason: reason)
        try logger.record(FanWriteAuditEvent(
            timestampUnix: clock.nowUnix,
            serviceName: hardware.serviceName,
            capabilityFingerprint: capability.fingerprint,
            leaseID: lease.id,
            key: key.stringValue,
            oldRaw: oldRaw,
            newRaw: newRaw,
            kernReturn: result.kernReturn,
            smcResult: result.smcResult,
            smcStatus: result.smcStatus,
            reason: reason
        ))
        if result.kernReturn != 0 {
            throw FanControlError.writeRejected(key: key.stringValue, smcResult: result.smcResult)
        }
        if result.smcResult != 0 {
            throw FanControlError.writeRejected(key: key.stringValue, smcResult: result.smcResult)
        }
        if result.smcStatus != 0 {
            throw FanControlError.writeRejected(key: key.stringValue, smcResult: result.smcStatus)
        }
    }

    private func key(for operation: FanWriteOperation) throws -> FanKey {
        switch operation {
        case .unlock:
            return capability.unlockKey
        case .mode(let fan, _):
            return try capability.modeKey(for: fan)
        case .target(let fan, _):
            return try capability.targetKey(for: fan)
        }
    }

    private func newRawBytes(for operation: FanWriteOperation) -> [UInt8] {
        switch operation {
        case .unlock(let value), .mode(_, let value):
            return [value]
        case .target(_, let bytes):
            return bytes
        }
    }

    private func capturedTargetsByFanIndex(_ lease: FanLease) throws -> [Int: [UInt8]] {
        var targets: [Int: [UInt8]] = [:]
        for fan in lease.capturedFans {
            guard targets[fan.index] == nil else {
                throw FanControlError.restoreFailed("lease contains duplicate captured target for fan \(fan.index)")
            }
            guard fan.targetRaw.count == 4,
                  FanEncoding.floatValue(fan.targetRaw) != nil
            else {
                throw FanControlError.restoreFailed("lease contains invalid captured target for fan \(fan.index)")
            }
            targets[fan.index] = fan.targetRaw
        }
        let expectedIndices = Set(0..<capability.fanCount)
        guard Set(targets.keys) == expectedIndices else {
            throw FanControlError.restoreFailed("lease captured fan indices do not match capability fan count")
        }
        return targets
    }
}

public struct SystemFanProcessInspector: FanProcessInspecting {
    public init() {}

    public func ownerProcessInfo(pid: Int32) -> FanOwnerProcessInfo? {
        #if canImport(Darwin)
        var processInfo = proc_bsdinfo()
        let byteCount = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &processInfo, Int32(MemoryLayout<proc_bsdinfo>.size))
        guard byteCount == Int32(MemoryLayout<proc_bsdinfo>.size) else {
            return nil
        }
        let startTime = TimeInterval(processInfo.pbi_start_tvsec) + TimeInterval(processInfo.pbi_start_tvusec) / 1_000_000
        return FanOwnerProcessInfo(pid: pid, parentPID: Int32(processInfo.pbi_ppid), startTimeUnix: startTime)
        #else
        return nil
        #endif
    }
}
