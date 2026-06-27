import Foundation

package final class FanController {
    private let hardware: FanHardware
    private let capability: FanCapability
    private let clock: FanControlClock

    package init(hardware: FanHardware, capability: FanCapability, clock: FanControlClock = SystemFanControlClock()) {
        self.hardware = hardware
        self.capability = capability
        self.clock = clock
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
}
