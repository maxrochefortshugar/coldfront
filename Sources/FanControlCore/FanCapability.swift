import Foundation

public struct FanValidationState: Equatable, Sendable {
    public let read: Bool
    public let boostMaxOneShot: Bool
    public let restoreAutoOneShot: Bool
    public let targetClearAfterNonManual: Bool
    public let crashRecovery: Bool
    public let parentDeathRecovery: Bool
    public let missedHeartbeatRecovery: Bool
    public let leaseExpiryRecovery: Bool
    public let signalRecovery: Bool
    public let sleepWakeRecovery: Bool

    public init(read: Bool, boostMaxOneShot: Bool, restoreAutoOneShot: Bool, targetClearAfterNonManual: Bool, crashRecovery: Bool, parentDeathRecovery: Bool, missedHeartbeatRecovery: Bool, leaseExpiryRecovery: Bool, signalRecovery: Bool, sleepWakeRecovery: Bool) {
        self.read = read
        self.boostMaxOneShot = boostMaxOneShot
        self.restoreAutoOneShot = restoreAutoOneShot
        self.targetClearAfterNonManual = targetClearAfterNonManual
        self.crashRecovery = crashRecovery
        self.parentDeathRecovery = parentDeathRecovery
        self.missedHeartbeatRecovery = missedHeartbeatRecovery
        self.leaseExpiryRecovery = leaseExpiryRecovery
        self.signalRecovery = signalRecovery
        self.sleepWakeRecovery = sleepWakeRecovery
    }

    public var activeControlEnabled: Bool {
        read
            && boostMaxOneShot
            && restoreAutoOneShot
            && targetClearAfterNonManual
            && crashRecovery
            && parentDeathRecovery
            && missedHeartbeatRecovery
            && leaseExpiryRecovery
            && signalRecovery
            && sleepWakeRecovery
    }
}

public struct FanCapability: Equatable, Sendable {
    public let model: String
    public let platform: String
    public let fanCount: Int
    public let modeKeyFormat: String
    public let unlockAvailable: Bool
    public let manualCommand: UInt8
    public let releaseCommand: UInt8
    public let managedObservedState: UInt8
    public let unlockOn: UInt8
    public let unlockOff: UInt8
    public let maxRPMCeiling: Float
    public let preManualMinimumMultiplier: Float
    public let boostVerificationMultiplier: Float
    public let defaultLeaseSeconds: Int
    public let maxLeaseSeconds: Int
    public let heartbeatSeconds: Int
    public let missedHeartbeatRestoreSeconds: Int
    public let validation: FanValidationState

    public init(model: String, platform: String, fanCount: Int, modeKeyFormat: String, unlockAvailable: Bool, manualCommand: UInt8, releaseCommand: UInt8, managedObservedState: UInt8, unlockOn: UInt8, unlockOff: UInt8, maxRPMCeiling: Float, preManualMinimumMultiplier: Float, boostVerificationMultiplier: Float, defaultLeaseSeconds: Int, maxLeaseSeconds: Int, heartbeatSeconds: Int, missedHeartbeatRestoreSeconds: Int, validation: FanValidationState) {
        self.model = model
        self.platform = platform
        self.fanCount = fanCount
        self.modeKeyFormat = modeKeyFormat
        self.unlockAvailable = unlockAvailable
        self.manualCommand = manualCommand
        self.releaseCommand = releaseCommand
        self.managedObservedState = managedObservedState
        self.unlockOn = unlockOn
        self.unlockOff = unlockOff
        self.maxRPMCeiling = maxRPMCeiling
        self.preManualMinimumMultiplier = preManualMinimumMultiplier
        self.boostVerificationMultiplier = boostVerificationMultiplier
        self.defaultLeaseSeconds = defaultLeaseSeconds
        self.maxLeaseSeconds = maxLeaseSeconds
        self.heartbeatSeconds = heartbeatSeconds
        self.missedHeartbeatRestoreSeconds = missedHeartbeatRestoreSeconds
        self.validation = validation
    }

    public var fingerprint: String {
        "\(model)|\(platform)|\(fanCount)|\(modeKeyFormat)|\(unlockAvailable)"
    }

    package func withValidation(_ validation: FanValidationState) -> FanCapability {
        FanCapability(model: model, platform: platform, fanCount: fanCount, modeKeyFormat: modeKeyFormat, unlockAvailable: unlockAvailable, manualCommand: manualCommand, releaseCommand: releaseCommand, managedObservedState: managedObservedState, unlockOn: unlockOn, unlockOff: unlockOff, maxRPMCeiling: maxRPMCeiling, preManualMinimumMultiplier: preManualMinimumMultiplier, boostVerificationMultiplier: boostVerificationMultiplier, defaultLeaseSeconds: defaultLeaseSeconds, maxLeaseSeconds: maxLeaseSeconds, heartbeatSeconds: heartbeatSeconds, missedHeartbeatRestoreSeconds: missedHeartbeatRestoreSeconds, validation: validation)
    }

    package func withResolvedHardware(modeKeyFormat: String, unlockAvailable: Bool) -> FanCapability {
        FanCapability(model: model, platform: platform, fanCount: fanCount, modeKeyFormat: modeKeyFormat, unlockAvailable: unlockAvailable, manualCommand: manualCommand, releaseCommand: releaseCommand, managedObservedState: managedObservedState, unlockOn: unlockOn, unlockOff: unlockOff, maxRPMCeiling: maxRPMCeiling, preManualMinimumMultiplier: preManualMinimumMultiplier, boostVerificationMultiplier: boostVerificationMultiplier, defaultLeaseSeconds: defaultLeaseSeconds, maxLeaseSeconds: maxLeaseSeconds, heartbeatSeconds: heartbeatSeconds, missedHeartbeatRestoreSeconds: missedHeartbeatRestoreSeconds, validation: validation)
    }

    public static let mac165ValidatedOneShot = FanCapability(
        model: "Mac16,5",
        platform: "j616c",
        fanCount: 2,
        modeKeyFormat: "F%dMd",
        unlockAvailable: true,
        manualCommand: 1,
        releaseCommand: 0,
        managedObservedState: 3,
        unlockOn: 1,
        unlockOff: 0,
        maxRPMCeiling: 10_000,
        preManualMinimumMultiplier: 0.95,
        boostVerificationMultiplier: 0.85,
        defaultLeaseSeconds: 600,
        maxLeaseSeconds: 7_200,
        heartbeatSeconds: 2,
        missedHeartbeatRestoreSeconds: 15,
        validation: FanValidationState(
            read: true,
            boostMaxOneShot: true,
            restoreAutoOneShot: true,
            targetClearAfterNonManual: true,
            crashRecovery: false,
            parentDeathRecovery: false,
            missedHeartbeatRecovery: false,
            leaseExpiryRecovery: false,
            signalRecovery: false,
            sleepWakeRecovery: false
        )
    )

    public static let mac177M5MaxLowercaseMode = FanCapability(
        model: "Mac17,7",
        platform: "j714c",
        fanCount: 2,
        modeKeyFormat: "F%dmd",
        unlockAvailable: false,
        manualCommand: 1,
        releaseCommand: 0,
        managedObservedState: 0,
        unlockOn: 0,
        unlockOff: 0,
        maxRPMCeiling: 10_000,
        preManualMinimumMultiplier: 0.95,
        boostVerificationMultiplier: 0.85,
        defaultLeaseSeconds: 600,
        maxLeaseSeconds: 7_200,
        heartbeatSeconds: 2,
        missedHeartbeatRestoreSeconds: 15,
        validation: FanValidationState(
            read: true,
            boostMaxOneShot: true,
            restoreAutoOneShot: true,
            targetClearAfterNonManual: true,
            crashRecovery: false,
            parentDeathRecovery: false,
            missedHeartbeatRecovery: false,
            leaseExpiryRecovery: false,
            signalRecovery: false,
            sleepWakeRecovery: false
        )
    )

    public static let allowlist = [mac165ValidatedOneShot, mac177M5MaxLowercaseMode]

    public func key(_ format: String, fan index: Int) throws -> FanKey {
        try FanKey(String(format: format, index))
    }

    public func actualKey(for index: Int) throws -> FanKey { try key("F%dAc", fan: index) }
    public func minimumKey(for index: Int) throws -> FanKey { try key("F%dMn", fan: index) }
    public func maximumKey(for index: Int) throws -> FanKey { try key("F%dMx", fan: index) }
    public func targetKey(for index: Int) throws -> FanKey { try key("F%dTg", fan: index) }
    public func modeKey(for index: Int) throws -> FanKey { try key(modeKeyFormat, fan: index) }
    public var unlockKey: FanKey { try! FanKey("Ftst") }
    public var fanCountKey: FanKey { try! FanKey("FNum") }
    public var platformKey: FanKey { try! FanKey("RPlt") }
}
