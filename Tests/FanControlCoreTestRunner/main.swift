import FanControlCore
import Foundation

func testCoreBoundary() throws {
    let key = try FanKey("F0Tg")
    try expect(key.stringValue == "F0Tg", "FanKey should preserve four-character keys")
}

func testMac165Capability() throws {
    let capability = FanCapability.mac165ValidatedOneShot
    let mode0 = try capability.modeKey(for: 0)
    let target1 = try capability.targetKey(for: 1)

    try expect(capability.model == "Mac16,5", "model should match local validation")
    try expect(capability.platform == "j616c", "platform should match local validation")
    try expect(capability.fanCount == 2, "fan count should match local validation")
    try expect(mode0.stringValue == "F0Md", "M4 mode key should use uppercase Md")
    try expect(target1.stringValue == "F1Tg", "target key should format fan index")
    try expect(capability.validation.activeControlEnabled == false, "active control should remain disabled")
    try expect(FanEncoding.float32LittleEndian(5777) == [0x00, 0x88, 0xB4, 0x45], "max RPM bytes should match hardware log")
}

func testResolverSucceedsForValidatedMac165Inventory() throws {
    let resolver = try FanCapabilityResolver(hardware: fakeFanInventory(), hostModel: { "Mac16,5" })

    let capability = try resolver.resolve()

    try expect(capability.model == "Mac16,5", "resolver should return Mac16,5 capability")
    try expect(capability.platform == "j616c", "resolver should return validated platform")
    try expect(capability.fanCount == 2, "resolver should preserve fan count")
    try expect(capability.modeKeyFormat == "F%dMd", "resolver should preserve uppercase mode key")
    try expect(capability.unlockAvailable, "resolver should require Ftst for validated capability")
}

func testResolverRejectsWrongModel() throws {
    let resolver = try FanCapabilityResolver(hardware: fakeFanInventory(), hostModel: { "Mac99,9" })

    try expectThrows("wrong model should be unsupported", {
        _ = try resolver.resolve()
    }, matching: { error in
        error as? FanControlError == .unsupportedModel(model: "Mac99,9", platform: "j616c")
    })
}

func testResolverRejectsWrongPlatform() throws {
    let reader = try fakeFanInventory(overrides: ["RPlt": fakePlatformReading("j999x")])
    let resolver = FanCapabilityResolver(hardware: reader, hostModel: { "Mac16,5" })

    try expectThrows("wrong platform should be unsupported", {
        _ = try resolver.resolve()
    }, matching: { error in
        error as? FanControlError == .unsupportedModel(model: "Mac16,5", platform: "j999x")
    })
}

func testResolverRejectsFanCountMismatch() throws {
    let reader = try fakeFanInventory(overrides: ["FNum": fakeReading("FNum", bytes: [1])])
    let resolver = FanCapabilityResolver(hardware: reader, hostModel: { "Mac16,5" })

    try expectThrows("fan count mismatch should be unsafe", {
        _ = try resolver.resolve()
    }, matching: { error in
        guard case .unsafeState(let message) = error as? FanControlError else { return false }
        return message == "fan count mismatch: expected 2, got 1"
    })
}

func testResolverPropagatesMissingPerFanInventoryKey() throws {
    let reader = try fakeFanInventory(failures: ["F1Mx": FanControlError.missingKey("F1Mx")])
    let resolver = FanCapabilityResolver(hardware: reader, hostModel: { "Mac16,5" })

    try expectThrows("missing per-fan inventory key should propagate", {
        _ = try resolver.resolve()
    }, matching: { error in
        error as? FanControlError == .missingKey("F1Mx")
    })
}

func testResolverRejectsLowercaseModePathWhenPresent() throws {
    let reader = try fakeFanInventory(overrides: ["F0md": fakeReading("F0md", bytes: [3])])
    let resolver = FanCapabilityResolver(hardware: reader, hostModel: { "Mac16,5" })

    try expectThrows("lowercase mode path should be unsupported", {
        _ = try resolver.resolve()
    }, matching: { error in
        error as? FanControlError == .unsupportedModel(model: "Mac16,5", platform: "lowercase mode key path not validated")
    })
}

func testResolverPropagatesMissingUppercaseModeKey() throws {
    let reader = try fakeFanInventory(failures: ["F0Md": FanControlError.missingKey("F0Md")])
    let resolver = FanCapabilityResolver(hardware: reader, hostModel: { "Mac16,5" })

    try expectThrows("missing uppercase mode key should propagate", {
        _ = try resolver.resolve()
    }, matching: { error in
        error as? FanControlError == .missingKey("F0Md")
    })
}

func testResolverPropagatesMissingFtst() throws {
    let reader = try fakeFanInventory(failures: ["Ftst": FanControlError.missingKey("Ftst")])
    let resolver = FanCapabilityResolver(hardware: reader, hostModel: { "Mac16,5" })

    try expectThrows("missing Ftst should propagate", {
        _ = try resolver.resolve()
    }, matching: { error in
        error as? FanControlError == .missingKey("Ftst")
    })
}

func testResolverPropagatesUnreadableFtst() throws {
    let reader = try fakeFanInventory(failures: ["Ftst": FakeFanReadError.unreadable("Ftst")])
    let resolver = FanCapabilityResolver(hardware: reader, hostModel: { "Mac16,5" })

    try expectThrows("unreadable Ftst should propagate", {
        _ = try resolver.resolve()
    }, matching: { error in
        error as? FakeFanReadError == .unreadable("Ftst")
    })
}

func testStatusReadsFanCountAndAvailability() throws {
    let smc = FakeSMC.mac165()
    let capability = FanCapability.mac165ValidatedOneShot
    let controller = FanController(hardware: smc, capability: capability, clock: TestClock())

    let status = try controller.status()

    try expect(status.serviceName == "FakeSMC", "status should include service name")
    try expect(status.fanCount == 2, "status should read FNum")
    try expect(status.platform == "j616c", "status should read platform")
    try expect(status.fans.count == 2, "status should include two fans")
    try expect(status.fans[0].mode == 3, "mode should decode")
    try expect(status.activeAvailability.allowed == false, "active control should not be allowed yet")
    try expect(status.activeAvailability.reasons.contains("crash recovery unverified"), "availability should explain crash gate")
}

func testStatusMissingFtstKeepsStatusButBlocksActiveControl() throws {
    let smc = FakeSMC.mac165()
    smc.removeEntry("Ftst")
    let capability = fullyValidatedCapability()
    let controller = FanController(hardware: smc, capability: capability, clock: TestClock())

    let status = try controller.status()

    try expect(status.ftst == nil, "missing Ftst should be reported as unavailable")
    try expect(status.activeAvailability.allowed == false, "missing Ftst should block active control")
    try expect(status.activeAvailability.reasons == ["unlock status unavailable"], "missing Ftst should explain the unlock gate")
}

func testStatusInvalidFtstKeepsStatusButBlocksActiveControl() throws {
    let smc = FakeSMC.mac165()
    smc.setEntry("Ftst", type: "flt ", size: 1, bytes: [0])
    let capability = fullyValidatedCapability()
    let controller = FanController(hardware: smc, capability: capability, clock: TestClock())

    let status = try controller.status()

    try expect(status.ftst == nil, "invalid Ftst should be reported as unavailable")
    try expect(status.activeAvailability.allowed == false, "invalid Ftst should block active control")
    try expect(status.activeAvailability.reasons == ["unlock status unavailable"], "invalid Ftst should explain the unlock gate")
}

func testStatusAllRecoveryFlagsAndGoodHardwareAllowsActiveControl() throws {
    let smc = FakeSMC.mac165()
    let capability = fullyValidatedCapability()
    let controller = FanController(hardware: smc, capability: capability, clock: TestClock())

    let status = try controller.status()

    try expect(status.activeAvailability.allowed, "fully validated good FakeSMC hardware should allow active control")
    try expect(status.activeAvailability.reasons.isEmpty, "fully validated good FakeSMC hardware should not report availability reasons")
}

func testStatusReportsPlatformMismatchAvailabilityReason() throws {
    let smc = FakeSMC.mac165()
    smc.setRawEntryBytes("RPlt", Array("j999x".utf8) + [0, 0, 0])
    let controller = FanController(hardware: smc, capability: fullyValidatedCapability(), clock: TestClock())

    let status = try controller.status()

    try expect(status.platform == "j999x", "status should include the observed platform")
    try expect(status.activeAvailability.allowed == false, "platform mismatch should block active control")
    try expect(status.activeAvailability.reasons.contains("platform mismatch"), "platform mismatch reason should be included")
}

func testStatusReportsFanCountMismatchWithoutReadingAbsentExtraFans() throws {
    let smc = FakeSMC.mac165()
    smc.setRawEntryBytes("FNum", [3])
    let controller = FanController(hardware: smc, capability: fullyValidatedCapability(), clock: TestClock())

    let status = try controller.status()

    try expect(status.fanCount == 3, "status should report observed FNum")
    try expect(status.fans.count == 2, "status should read only capability fan count when FNum is higher")
    try expect(status.activeAvailability.allowed == false, "fan count mismatch should block active control")
    try expect(status.activeAvailability.reasons.contains("fan count mismatch"), "fan count mismatch reason should be included")
}

func testStatusReportsEveryValidationGateReason() throws {
    let smc = FakeSMC.mac165()
    let capability = FanCapability.mac165ValidatedOneShot.withValidation(validationState(
        read: false,
        boostMaxOneShot: false,
        restoreAutoOneShot: false,
        targetClearAfterNonManual: false,
        crashRecovery: false,
        parentDeathRecovery: false,
        missedHeartbeatRecovery: false,
        leaseExpiryRecovery: false,
        signalRecovery: false,
        sleepWakeRecovery: false
    ))
    let controller = FanController(hardware: smc, capability: capability, clock: TestClock())

    let status = try controller.status()

    try expect(status.activeAvailability.allowed == false, "unverified validation gates should block active control")
    try expect(status.activeAvailability.reasons.contains("read validation unverified"), "read gate should be explained")
    try expect(status.activeAvailability.reasons.contains("boost max one-shot unverified"), "boost validation gate should be explained")
    try expect(status.activeAvailability.reasons.contains("restore auto one-shot unverified"), "restore validation gate should be explained")
    try expect(status.activeAvailability.reasons.contains("target clear after non-manual unverified"), "target clear validation gate should be explained")
    try expect(status.activeAvailability.reasons.contains("crash recovery unverified"), "crash recovery gate should be explained")
    try expect(status.activeAvailability.reasons.contains("parent-death recovery unverified"), "parent-death recovery gate should be explained")
    try expect(status.activeAvailability.reasons.contains("missed-heartbeat recovery unverified"), "missed-heartbeat recovery gate should be explained")
    try expect(status.activeAvailability.reasons.contains("lease-expiry recovery unverified"), "lease-expiry recovery gate should be explained")
    try expect(status.activeAvailability.reasons.contains("signal recovery unverified"), "signal recovery gate should be explained")
    try expect(status.activeAvailability.reasons.contains("sleep/wake recovery unverified"), "sleep/wake recovery gate should be explained")
}

func testStatusReportsEveryNonRecoveryValidationGate() throws {
    let smc = FakeSMC.mac165()
    let capability = FanCapability.mac165ValidatedOneShot.withValidation(validationState(
        read: false,
        boostMaxOneShot: false,
        restoreAutoOneShot: false,
        targetClearAfterNonManual: false,
        crashRecovery: true,
        parentDeathRecovery: true,
        missedHeartbeatRecovery: true,
        leaseExpiryRecovery: true,
        signalRecovery: true,
        sleepWakeRecovery: true
    ))
    let controller = FanController(hardware: smc, capability: capability, clock: TestClock())

    let status = try controller.status()

    try expect(status.activeAvailability.allowed == false, "non-recovery validation gates should block active control")
    try expect(status.activeAvailability.reasons.contains("read validation unverified"), "read gate should be explained")
    try expect(status.activeAvailability.reasons.contains("boost max one-shot unverified"), "boost gate should be explained")
    try expect(status.activeAvailability.reasons.contains("restore auto one-shot unverified"), "restore gate should be explained")
    try expect(status.activeAvailability.reasons.contains("target clear after non-manual unverified"), "target clear gate should be explained")
}

func testStatusRejectsWrongTargetType() throws {
    try expectStatusInvalidReading("wrong target type should fail status", key: "F0Tg", reason: "expected flt size == 4") {
        $0.setEntry("F0Tg", type: "ui8 ", size: 4, bytes: FanEncoding.float32LittleEndian(2_000))
    }
}

func testStatusRejectsWrongTargetSize() throws {
    try expectStatusInvalidReading("wrong target size should fail status", key: "F0Tg") {
        $0.setEntry("F0Tg", type: "flt ", size: 8, bytes: FanEncoding.float32LittleEndian(2_000) + [0, 0, 0, 0])
    }
}

func testStatusRejectsWrongModeType() throws {
    try expectStatusInvalidReading("wrong mode type should fail status", key: "F0Md", reason: "expected ui8 size == 1") {
        $0.setEntry("F0Md", type: "flt ", size: 1, bytes: [3])
    }
}

func testStatusRejectsWrongModeSize() throws {
    try expectStatusInvalidReading("wrong mode size should fail status", key: "F0Md") {
        $0.setEntry("F0Md", type: "ui8 ", size: 2, bytes: [3, 0])
    }
}

func testStatusRejectsWrongFanCountType() throws {
    try expectStatusInvalidReading("wrong FNum type should fail status", key: "FNum", reason: "expected ui8 size == 1") {
        $0.setEntry("FNum", type: "flt ", size: 1, bytes: [2])
    }
}

func testStatusRejectsWrongFanCountSize() throws {
    try expectStatusInvalidReading("wrong FNum size should fail status", key: "FNum") {
        $0.setEntry("FNum", type: "ui8 ", size: 2, bytes: [2, 0])
    }
}

func testStatusRejectsWrongPlatformType() throws {
    try expectStatusInvalidReading("wrong RPlt type should fail status", key: "RPlt", reason: "expected ch8* ASCII bytes") {
        $0.setEntry("RPlt", type: "ui8 ", size: 6, bytes: Array("j616c".utf8) + [0])
    }
}

func testStatusRejectsPlatformSizeMismatch() throws {
    try expectStatusInvalidReading("RPlt size mismatch should fail status", key: "RPlt") {
        $0.setEntry("RPlt", type: "ch8*", size: 8, bytes: Array("j616c".utf8) + [0])
    }
}

func testStatusReportsFanMinMaxOutOfBounds() throws {
    let smc = FakeSMC.mac165()
    smc.setRawEntryBytes("F0Mx", FanEncoding.float32LittleEndian(20_000))
    let capability = fullyValidatedCapability()
    let controller = FanController(hardware: smc, capability: capability, clock: TestClock())

    let status = try controller.status()

    try expect(status.activeAvailability.allowed == false, "out-of-bounds fan min/max should block active control")
    try expect(status.activeAvailability.reasons.contains("fan min/max out of bounds"), "out-of-bounds fan min/max reason should be included")
}

func testLeaseRoundTripsCapturedPreBoostBytesAndHeartbeatUpdates() throws {
    let store = FanLeaseStore(directory: temporaryDirectory("lease-roundtrip"))
    let lease = testLease(
        heartbeatAtUnix: 1_800_000_005,
        capturedFans: [
            CapturedFanState(index: 0, modeRaw: [3], targetRaw: [0x00, 0x00, 0x7A, 0x45]),
            CapturedFanState(index: 1, modeRaw: [3], targetRaw: [0x00, 0x80, 0xBB, 0x45])
        ]
    )

    try store.claim(lease)

    try expect(store.read() == lease, "lease should round-trip all captured pre-boost bytes")
    try store.heartbeat(leaseID: lease.id, nowUnix: 1_800_000_020)
    let updated = try store.read()
    try expect(updated.id == lease.id, "heartbeat should preserve lease identity")
    try expect(updated.capturedFans == lease.capturedFans, "heartbeat should preserve captured fan bytes")
    try expect(updated.heartbeatAtUnix == 1_800_000_020, "heartbeat should update heartbeat timestamp")
}

func testDuplicateLeaseClaimFails() throws {
    let store = FanLeaseStore(directory: temporaryDirectory("lease-duplicate"))
    try store.claim(testLease())

    try expectThrows("duplicate lease claim should fail", {
        try store.claim(testLease(id: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!))
    }, matching: { error in
        error as? FanLeaseStoreError == .leaseAlreadyExists
    })
}

func testLeaseClaimFailureDoesNotPublishPartialCurrentLease() throws {
    let directory = temporaryDirectory("lease-claim-failure")
    let store = FanLeaseStore(
        directory: directory,
        persistenceHooks: FanLeaseStorePersistenceHooks(failBeforeClaimPublish: TestFailure(description: "forced claim publish failure"))
    )

    try expectThrows("forced claim publish failure should throw", {
        try store.claim(testLease())
    }, matching: { error in
        (error as? TestFailure)?.description == "forced claim publish failure"
    })

    try expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("current-lease.json").path), "failed claim should not publish a partial current lease")
}

func testLeaseHeartbeatRequiresMatchingLeaseID() throws {
    let store = FanLeaseStore(directory: temporaryDirectory("lease-heartbeat-id-match"))
    let lease = testLease(heartbeatAtUnix: 1_800_000_000)
    try store.claim(lease)

    try store.heartbeat(leaseID: lease.id, nowUnix: 1_800_000_020)

    try expect(try store.read().heartbeatAtUnix == 1_800_000_020, "matching heartbeat should update current lease")
}

func testStaleLeaseHeartbeatDoesNotClobberNewLease() throws {
    let store = FanLeaseStore(directory: temporaryDirectory("lease-stale-heartbeat"))
    let first = testLease(id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!, heartbeatAtUnix: 1_800_000_000)
    let second = testLease(id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!, heartbeatAtUnix: 1_800_000_030)
    try store.claim(first)
    try store.overwriteForRecovery(second, replacingLeaseID: first.id)

    try expectThrows("stale heartbeat should fail identity guard", {
        try store.heartbeat(leaseID: first.id, nowUnix: 1_800_000_060)
    }, matching: { error in
        error as? FanLeaseStoreError == .leaseIdentityMismatch
    })

    try expect(try store.read() == second, "stale heartbeat should not rewrite newer lease")
}

func testStaleLeaseClearDoesNotDeleteNewLease() throws {
    let store = FanLeaseStore(directory: temporaryDirectory("lease-stale-clear"))
    let first = testLease(id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
    let second = testLease(id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!)
    try store.claim(first)
    try store.overwriteForRecovery(second, replacingLeaseID: first.id)

    try expectThrows("stale clear should fail identity guard", {
        try store.clear(leaseID: first.id)
    }, matching: { error in
        error as? FanLeaseStoreError == .leaseIdentityMismatch
    })

    try expect(try store.read() == second, "stale clear should not delete newer lease")
}

func testLeaseClearRemovesMatchingLease() throws {
    let store = FanLeaseStore(directory: temporaryDirectory("lease-clear-matching"))
    let lease = testLease()
    try store.claim(lease)

    try store.clear(leaseID: lease.id)

    try expect(try store.readIfPresent() == nil, "matching clear should remove current lease")
}

func testLeaseOverwriteForRecoveryRequiresExpectedLeaseID() throws {
    let store = FanLeaseStore(directory: temporaryDirectory("lease-recovery-overwrite-id"))
    let first = testLease(id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
    let second = testLease(id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!)
    try store.claim(first)

    try expectThrows("recovery overwrite should fail identity guard", {
        try store.overwriteForRecovery(second, replacingLeaseID: second.id)
    }, matching: { error in
        error as? FanLeaseStoreError == .leaseIdentityMismatch
    })

    try expect(try store.read() == first, "failed recovery overwrite should preserve current lease")
}

func testRecoveryDecisionNoLease() throws {
    let controller = leaseDecisionController(store: FanLeaseStore(directory: temporaryDirectory("lease-no-current")))

    let decision = try controller.recoveryDecision(nowUnix: 1_800_000_000, currentParentPID: 100)

    try expect(decision == FanRecoveryDecision(shouldRestore: false, reason: .noLease), "missing lease should not restore")
}

func testRecoveryDecisionCorruptLeaseRestoresFailClosed() throws {
    let directory = temporaryDirectory("lease-corrupt-current")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("{\"id\":\"truncated\"".utf8).write(to: directory.appendingPathComponent("current-lease.json"))
    let controller = leaseDecisionController(store: FanLeaseStore(directory: directory))

    let decision = try controller.recoveryDecision(nowUnix: 1_800_000_014, currentParentPID: 100)

    try expect(decision == FanRecoveryDecision(shouldRestore: true, reason: .corruptLease), "corrupt lease should restore fail-closed")
}

func testRecoveryDecisionActiveLease() throws {
    let store = FanLeaseStore(directory: temporaryDirectory("lease-active"))
    try store.claim(testLease(expiresAtUnix: 1_800_000_100, heartbeatAtUnix: 1_800_000_000, parentPID: 100))
    let controller = leaseDecisionController(store: store)

    let decision = try controller.recoveryDecision(nowUnix: 1_800_000_014, currentParentPID: 100)

    try expect(decision == FanRecoveryDecision(shouldRestore: false, reason: .activeLease), "active lease should not restore")
}

func testRecoveryDecisionMissedHeartbeatRestores() throws {
    let store = FanLeaseStore(directory: temporaryDirectory("lease-missed-heartbeat"))
    try store.claim(testLease(expiresAtUnix: 1_800_000_100, heartbeatAtUnix: 1_800_000_000, parentPID: 100))
    let controller = leaseDecisionController(store: store)

    let decision = try controller.recoveryDecision(nowUnix: 1_800_000_016, currentParentPID: 100)

    try expect(decision == FanRecoveryDecision(shouldRestore: true, reason: .missedHeartbeat), "missed heartbeat should restore")
}

func testRecoveryDecisionExpiredLeaseRestoresAtBoundary() throws {
    let store = FanLeaseStore(directory: temporaryDirectory("lease-expired"))
    try store.claim(testLease(expiresAtUnix: 1_800_000_100, heartbeatAtUnix: 1_800_000_090, parentPID: 100))
    let controller = leaseDecisionController(store: store)

    let decision = try controller.recoveryDecision(nowUnix: 1_800_000_100, currentParentPID: 100)

    try expect(decision == FanRecoveryDecision(shouldRestore: true, reason: .expiredLease), "expired lease should restore at now >= expiresAtUnix")
}

func testRecoveryDecisionExpiredLeaseTrumpsMissedHeartbeat() throws {
    let store = FanLeaseStore(directory: temporaryDirectory("lease-expired-over-heartbeat"))
    try store.claim(testLease(expiresAtUnix: 1_800_000_100, heartbeatAtUnix: 1_800_000_000, parentPID: 100))
    let controller = leaseDecisionController(store: store)

    let decision = try controller.recoveryDecision(nowUnix: 1_800_000_100, currentParentPID: 100)

    try expect(decision == FanRecoveryDecision(shouldRestore: true, reason: .expiredLease), "expired lease should trump missed heartbeat")
}

func testRecoveryDecisionParentPIDChangeRestores() throws {
    let store = FanLeaseStore(directory: temporaryDirectory("lease-parent-changed"))
    try store.claim(testLease(expiresAtUnix: 1_800_000_100, heartbeatAtUnix: 1_800_000_000, parentPID: 100))
    let controller = leaseDecisionController(store: store)

    let decision = try controller.recoveryDecision(nowUnix: 1_800_000_014, currentParentPID: 200)

    try expect(decision == FanRecoveryDecision(shouldRestore: true, reason: .parentExited), "parent PID change should restore")
}

func testRecoveryDecisionMissedHeartbeatTrumpsParentPIDChange() throws {
    let store = FanLeaseStore(directory: temporaryDirectory("lease-heartbeat-over-parent"))
    try store.claim(testLease(expiresAtUnix: 1_800_000_100, heartbeatAtUnix: 1_800_000_000, parentPID: 100))
    let controller = leaseDecisionController(store: store)

    let decision = try controller.recoveryDecision(nowUnix: 1_800_000_016, currentParentPID: 200)

    try expect(decision == FanRecoveryDecision(shouldRestore: true, reason: .missedHeartbeat), "missed heartbeat should trump parent PID change")
}

func testRecoveryDecisionCapabilityMismatchRestoresBeforeOtherReasons() throws {
    let store = FanLeaseStore(directory: temporaryDirectory("lease-capability-mismatch"))
    try store.claim(testLease(capabilityFingerprint: "old-fingerprint", expiresAtUnix: 1_800_000_000, heartbeatAtUnix: 1_799_999_000, parentPID: 100))
    let controller = leaseDecisionController(store: store)

    let decision = try controller.recoveryDecision(nowUnix: 1_800_000_100, currentParentPID: 200)

    try expect(decision == FanRecoveryDecision(shouldRestore: true, reason: .capabilityMismatch), "capability mismatch should trump expiry, heartbeat, and parent checks")
}

func testRecoveryDecisionOmittedParentInfoInspectsOwnerProcess() throws {
    let store = FanLeaseStore(directory: temporaryDirectory("lease-parent-inspected"))
    try store.claim(testLease(expiresAtUnix: 1_800_000_100, heartbeatAtUnix: 1_800_000_000, parentPID: 100))
    let controller = leaseDecisionController(
        store: store,
        processInspector: TestProcessInspector(ownerProcesses: [
            42: FanOwnerProcessInfo(pid: 42, parentPID: 100, startTimeUnix: nil)
        ])
    )

    let decision = try controller.recoveryDecision(nowUnix: 1_800_000_014, currentParentPID: nil)

    try expect(decision == FanRecoveryDecision(shouldRestore: false, reason: .activeLease), "omitted parent PID should inspect stored owner process")
}

func testRecoveryDecisionOmittedParentInfoDoesNotSilentlySkipUninspectableOwner() throws {
    let store = FanLeaseStore(directory: temporaryDirectory("lease-parent-uninspectable"))
    try store.claim(testLease(expiresAtUnix: 1_800_000_100, heartbeatAtUnix: 1_800_000_000, parentPID: 100))
    let controller = leaseDecisionController(store: store, processInspector: TestProcessInspector(ownerProcesses: [:]))

    let decision = try controller.recoveryDecision(nowUnix: 1_800_000_014, currentParentPID: nil)

    try expect(decision == FanRecoveryDecision(shouldRestore: true, reason: .parentExited), "uninspectable owner should restore fail-closed")
}

func testRecoveryDecisionOwnerParentChangeRestores() throws {
    let store = FanLeaseStore(directory: temporaryDirectory("lease-owner-parent-changed"))
    try store.claim(testLease(expiresAtUnix: 1_800_000_100, heartbeatAtUnix: 1_800_000_000, parentPID: 100))
    let controller = leaseDecisionController(
        store: store,
        processInspector: TestProcessInspector(ownerProcesses: [
            42: FanOwnerProcessInfo(pid: 42, parentPID: 200, startTimeUnix: nil)
        ])
    )

    let decision = try controller.recoveryDecision(nowUnix: 1_800_000_014, currentParentPID: nil)

    try expect(decision == FanRecoveryDecision(shouldRestore: true, reason: .parentExited), "changed owner parent should restore")
}

func testRecoveryDecisionOwnerPIDReuseStartTimeMismatchRestores() throws {
    let store = FanLeaseStore(directory: temporaryDirectory("lease-owner-pid-reuse"))
    try store.claim(testLease(ownerStartTimeUnix: 1_700_000_000, expiresAtUnix: 1_800_000_100, heartbeatAtUnix: 1_800_000_000, parentPID: 100))
    let controller = leaseDecisionController(
        store: store,
        processInspector: TestProcessInspector(ownerProcesses: [
            42: FanOwnerProcessInfo(pid: 42, parentPID: 100, startTimeUnix: 1_700_000_500)
        ])
    )

    let decision = try controller.recoveryDecision(nowUnix: 1_800_000_014, currentParentPID: nil)

    try expect(decision == FanRecoveryDecision(shouldRestore: true, reason: .parentExited), "owner PID reuse-shaped identity mismatch should restore")
}

func testAuditEventRecordsWriteDetails() throws {
    let logger = InMemoryFanControlLogger()
    let oldBytes = [UInt8](arrayLiteral: 0)
    let newBytes = [UInt8](arrayLiteral: 1)
    let event = FanWriteAuditEvent(
        timestampUnix: 1,
        serviceName: "FakeSMC",
        capabilityFingerprint: "Mac16,5|j616c|2|F%dMd|true",
        leaseID: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
        key: "Ftst",
        oldRaw: oldBytes,
        newRaw: newBytes,
        kernReturn: 0,
        smcResult: 0,
        smcStatus: 0,
        reason: "test"
    )

    try logger.record(event)

    try expect(logger.events.count == 1, "logger should retain event")
    try expect(logger.events[0].capabilityFingerprint == "Mac16,5|j616c|2|F%dMd|true", "capability fingerprint should be captured")
    try expect(logger.events[0].leaseID == UUID(uuidString: "33333333-3333-3333-3333-333333333333")!, "lease ID should be captured")
    try expect(logger.events[0].oldRaw == oldBytes, "old bytes should be captured")
    try expect(logger.events[0].newRaw == newBytes, "new bytes should be captured")
}

func testJSONLAuditLoggerEncodesTask5FieldNames() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("fan-audit-\(UUID().uuidString)")
        .appendingPathExtension("jsonl")
    defer { try? FileManager.default.removeItem(at: url) }

    let logger = JSONLFanControlLogger(url: url)
    try logger.record(FanWriteAuditEvent(
        timestampUnix: 1,
        serviceName: "FakeSMC",
        capabilityFingerprint: "Mac16,5|j616c|2|F%dMd|true",
        leaseID: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
        key: "Ftst",
        oldRaw: [0],
        newRaw: [1],
        kernReturn: 0,
        smcResult: 0,
        smcStatus: 0,
        reason: "test"
    ))

    let data = try Data(contentsOf: url)
    let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
    try expect(lines.count == 1, "JSONL logger should write one event line")

    let object = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any]
    let keys = Set(object?.keys ?? [String: Any]().keys)
    try expect(keys == [
        "timestampUnix",
        "serviceName",
        "capabilityFingerprint",
        "leaseID",
        "key",
        "oldRaw",
        "newRaw",
        "kernReturn",
        "smcResult",
        "smcStatus",
        "reason"
    ], "JSONL audit event should encode exact Task 5 field names")
}

func testJSONLAuditLoggerEncodesNilLeaseIDAsNull() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("fan-audit-\(UUID().uuidString)")
        .appendingPathExtension("jsonl")
    defer { try? FileManager.default.removeItem(at: url) }

    let logger = JSONLFanControlLogger(url: url)
    try logger.record(FanWriteAuditEvent(
        timestampUnix: 1,
        serviceName: "FakeSMC",
        capabilityFingerprint: "Mac16,5|j616c|2|F%dMd|true",
        leaseID: nil,
        key: "Ftst",
        oldRaw: [0],
        newRaw: [1],
        kernReturn: 0,
        smcResult: 0,
        smcStatus: 0,
        reason: "nil lease"
    ))

    let data = try Data(contentsOf: url)
    let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
    try expect(lines.count == 1, "JSONL logger should write one event line")

    let object = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any]
    try expect(object?.keys.contains("leaseID") == true, "nil leaseID should be present in JSON schema")
    try expect(object?["leaseID"] is NSNull, "nil leaseID should encode as JSON null")
}

func testJSONLAuditLoggerAppendsTwoParseableLines() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("fan-audit-\(UUID().uuidString)")
        .appendingPathExtension("jsonl")
    defer { try? FileManager.default.removeItem(at: url) }

    let logger = JSONLFanControlLogger(url: url)
    try logger.record(FanWriteAuditEvent(
        timestampUnix: 1,
        serviceName: "FakeSMC",
        capabilityFingerprint: "first",
        leaseID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        key: "Ftst",
        oldRaw: [0],
        newRaw: [1],
        kernReturn: 0,
        smcResult: 0,
        smcStatus: 0,
        reason: "first"
    ))
    try logger.record(FanWriteAuditEvent(
        timestampUnix: 2,
        serviceName: "FakeSMC",
        capabilityFingerprint: "second",
        leaseID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
        key: "F0Md",
        oldRaw: [2],
        newRaw: [3],
        kernReturn: 0,
        smcResult: 0,
        smcStatus: 0,
        reason: "second"
    ))

    let data = try Data(contentsOf: url)
    let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
    try expect(lines.count == 2, "JSONL logger should preserve first line and append second line")

    let first = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any]
    let second = try JSONSerialization.jsonObject(with: Data(lines[1].utf8)) as? [String: Any]
    try expect(first?["capabilityFingerprint"] as? String == "first", "first JSONL event should be preserved")
    try expect(second?["capabilityFingerprint"] as? String == "second", "second JSONL event should be appended")
}

func testJSONLAuditLoggerCreatesMissingParentDirectory() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("missing")
    let url = root
        .appendingPathComponent("subdir")
        .appendingPathComponent("fan-audit")
        .appendingPathExtension("jsonl")
    try? FileManager.default.removeItem(at: root)
    defer { try? FileManager.default.removeItem(at: root) }

    let logger = JSONLFanControlLogger(url: url)
    try logger.record(FanWriteAuditEvent(
        timestampUnix: 1,
        serviceName: "FakeSMC",
        capabilityFingerprint: "created-parent-directory",
        leaseID: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
        key: "Ftst",
        oldRaw: [0],
        newRaw: [1],
        kernReturn: 0,
        smcResult: 0,
        smcStatus: 0,
        reason: "missing parent directory"
    ))

    try expect(FileManager.default.fileExists(atPath: url.path), "JSONL logger should create audit log file")

    let data = try Data(contentsOf: url)
    let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
    try expect(lines.count == 1, "JSONL logger should write one JSONL line after creating parent directories")

    let object = try JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any]
    try expect(object?["capabilityFingerprint"] as? String == "created-parent-directory", "JSONL line should be parseable")
}

func testFakeSMCDelayedFtstReadback() throws {
    let smc = FakeSMC.mac165()
    let first = try smc.write(.unlock(value: 1), capability: .mac165ValidatedOneShot, reason: "test unlock")
    try expect(first.smcResult == 0, "Ftst write should be accepted")

    let immediate = try smc.read(try FanKey("Ftst"))
    try expect(immediate.bytes == [0], "first readback should still be delayed")

    smc.advanceTick()
    smc.advanceTick()
    smc.advanceTick()

    let settled = try smc.read(try FanKey("Ftst"))
    try expect(settled.bytes == [1], "readback should eventually become 1")
}

func testFakeSMCRejectsManualBeforeUnlockSettles() throws {
    let smc = FakeSMC.mac165()
    let result = try smc.write(.mode(fan: 0, value: 1), capability: .mac165ValidatedOneShot, reason: "manual too early")
    try expect(result.smcResult == 0x82, "manual mode should be rejected before unlock")
}

func testFakeSMCRejectsManualWithoutSafePreManualTarget() throws {
    let smc = FakeSMC.mac165()
    let unlock = try smc.write(.unlock(value: 1), capability: .mac165ValidatedOneShot, reason: "unlock")
    try expect(unlock.smcResult == 0, "Ftst unlock should be accepted")

    smc.advanceTick()
    smc.advanceTick()
    smc.advanceTick()

    let result = try smc.write(.mode(fan: 0, value: 1), capability: .mac165ValidatedOneShot, reason: "manual without safe target")
    try expect(result.smcResult == 0x82, "manual mode should be rejected without a safe pre-manual target")
}

func testFakeSMCRejectsManualUntilAllFansHaveSafeTargets() throws {
    let smc = FakeSMC.mac165()
    _ = try smc.write(.unlock(value: 1), capability: .mac165ValidatedOneShot, reason: "unlock")
    smc.advanceTick()
    smc.advanceTick()
    smc.advanceTick()

    let fan0Maximum = FanEncoding.floatValue(try smc.read(try FanKey("F0Mx")).bytes) ?? 0
    _ = try smc.write(.target(fan: 0, bytes: FanEncoding.float32LittleEndian(fan0Maximum)), capability: .mac165ValidatedOneShot, reason: "fan 0 safe pre-manual target")
    smc.advanceTick()
    smc.advanceTick()

    let blocked = try smc.write(.mode(fan: 0, value: 1), capability: .mac165ValidatedOneShot, reason: "manual before all fans safe")
    try expect(blocked.smcResult == 0x82, "manual mode should be rejected until every fan has a safe pre-manual target")

    let fan1Maximum = FanEncoding.floatValue(try smc.read(try FanKey("F1Mx")).bytes) ?? 0
    _ = try smc.write(.target(fan: 1, bytes: FanEncoding.float32LittleEndian(fan1Maximum)), capability: .mac165ValidatedOneShot, reason: "fan 1 safe pre-manual target")
    smc.advanceTick()
    smc.advanceTick()

    let accepted = try smc.write(.mode(fan: 0, value: 1), capability: .mac165ValidatedOneShot, reason: "manual after all fans safe")
    try expect(accepted.smcResult == 0, "manual mode should be accepted after every fan has a safe pre-manual target")
}

func testFakeSMCRejectsManagedObservedModeWrite() throws {
    let smc = FakeSMC.mac165()

    let result = try smc.write(.mode(fan: 0, value: 3), capability: .mac165ValidatedOneShot, reason: "managed observed state is not a command")

    try expect(result.smcResult == 0x82, "managed observed state write should be rejected")
}

func testFakeSMCReleaseModeSettlesBackToManaged() throws {
    let smc = FakeSMC.mac165()

    let result = try smc.write(.mode(fan: 0, value: 0), capability: .mac165ValidatedOneShot, reason: "release fan")
    try expect(result.smcResult == 0, "release mode write should be accepted")

    smc.advanceTick()
    smc.advanceTick()

    let intermediate = try smc.read(try FanKey("F0Md"))
    try expect(intermediate.bytes == [0], "release should first read back as release mode")

    smc.advanceTick()
    smc.advanceTick()

    let settled = try smc.read(try FanKey("F0Md"))
    try expect(settled.bytes == [3], "release should settle back to managed mode")
}

func testFakeSMCPreManualTargetWriteDoesNotStickImmediately() throws {
    let smc = FakeSMC.mac165()
    let maxBytes = FanEncoding.float32LittleEndian(5_777)

    let result = try smc.write(.target(fan: 0, bytes: maxBytes), capability: .mac165ValidatedOneShot, reason: "target before manual")
    try expect(result.smcResult == 0, "pre-manual target write should be accepted")

    let readback = try smc.read(try FanKey("F0Tg"))
    try expect(readback.bytes != maxBytes, "pre-manual target write should not immediately stick")
}

func testFakeSMCPreManualTargetWriteSettlesToSafeGuardValue() throws {
    let smc = FakeSMC.mac165()
    let maxBytes = FanEncoding.float32LittleEndian(5_777)

    let result = try smc.write(.target(fan: 0, bytes: maxBytes), capability: .mac165ValidatedOneShot, reason: "target before manual")
    try expect(result.smcResult == 0, "pre-manual target write should be accepted")

    smc.advanceTick()
    smc.advanceTick()

    let settled = FanEncoding.floatValue(try smc.read(try FanKey("F0Tg")).bytes) ?? 0
    let minimum = FanEncoding.floatValue(try smc.read(try FanKey("F0Mn")).bytes) ?? 0
    let maximum = FanEncoding.floatValue(try smc.read(try FanKey("F0Mx")).bytes) ?? 0
    try expect(settled >= minimum * 0.95, "pre-manual target should settle to at least 95% of minimum")
    try expect(settled < maximum, "pre-manual target should settle below maximum")
}

func testFakeSMCRejectsUnsafePreManualTargetRequests() throws {
    let minimum = FanEncoding.floatValue(try FakeSMC.mac165().read(try FanKey("F0Mn")).bytes) ?? 0
    let unsafeTargets: [(String, [UInt8])] = [
        ("zero", FanEncoding.float32LittleEndian(0)),
        ("nan", FanEncoding.float32LittleEndian(.nan)),
        ("malformed", [0x00, 0x01]),
        ("below safe floor", FanEncoding.float32LittleEndian(minimum * 0.94))
    ]

    for (label, bytes) in unsafeTargets {
        let smc = FakeSMC.mac165()

        let result = try smc.write(.target(fan: 0, bytes: bytes), capability: .mac165ValidatedOneShot, reason: "unsafe pre-manual \(label)")
        try expect(result.smcResult == 0x82, "unsafe pre-manual \(label) target write should be rejected")
        smc.advanceTick()
        smc.advanceTick()

        let settled = FanEncoding.floatValue(try smc.read(try FanKey("F0Tg")).bytes) ?? 0
        try expect(settled < minimum * 0.95, "unsafe pre-manual \(label) target should not settle to the safe guard")
    }
}

func testFakeSMCSettlesValidPreManualTargetToSafeGuard() throws {
    let smc = FakeSMC.mac165()
    let maximum = FanEncoding.floatValue(try smc.read(try FanKey("F0Mx")).bytes) ?? 0

    let result = try smc.write(.target(fan: 0, bytes: FanEncoding.float32LittleEndian(maximum)), capability: .mac165ValidatedOneShot, reason: "valid high pre-manual target")
    try expect(result.smcResult == 0, "valid high pre-manual target write should be accepted")

    smc.advanceTick()
    smc.advanceTick()

    let settled = FanEncoding.floatValue(try smc.read(try FanKey("F0Tg")).bytes) ?? 0
    let minimum = FanEncoding.floatValue(try smc.read(try FanKey("F0Mn")).bytes) ?? 0
    try expect(settled >= minimum * 0.95, "valid high pre-manual target should settle to at least 95% of minimum")
    try expect(settled < maximum, "valid high pre-manual target should settle below maximum")
}

func testFakeSMCDelaysFtstOffReadback() throws {
    let smc = FakeSMC.mac165()
    _ = try smc.write(.unlock(value: 1), capability: .mac165ValidatedOneShot, reason: "unlock")
    smc.advanceTick()
    smc.advanceTick()
    smc.advanceTick()

    let onReadback = try smc.read(try FanKey("Ftst"))
    try expect(onReadback.bytes == [1], "Ftst should read back on after settling")

    let off = try smc.write(.unlock(value: 0), capability: .mac165ValidatedOneShot, reason: "lock")
    try expect(off.smcResult == 0, "Ftst lock should be accepted")

    let immediate = try smc.read(try FanKey("Ftst"))
    try expect(immediate.bytes == [1], "Ftst off readback should be delayed")

    smc.advanceTick()
    smc.advanceTick()
    smc.advanceTick()

    let settled = try smc.read(try FanKey("Ftst"))
    try expect(settled.bytes == [0], "Ftst should read back off after delay")
}

func testFakeSMCRejectsManualZeroTargetWrite() throws {
    let smc = FakeSMC.mac165()
    try settleManualMode(smc, fan: 0)
    let safeBytes = FanEncoding.float32LittleEndian(2_000)
    _ = try smc.write(.target(fan: 0, bytes: safeBytes), capability: .mac165ValidatedOneShot, reason: "safe target")

    let result = try smc.write(.target(fan: 0, bytes: FanEncoding.float32LittleEndian(0)), capability: .mac165ValidatedOneShot, reason: "zero target")

    try expect(result.smcResult == 0x82, "zero manual target should be rejected")
    try expect(try smc.read(try FanKey("F0Tg")).bytes == safeBytes, "zero target should not overwrite previous safe target")
}

func testFakeSMCAllowsTargetClearOnlyAfterManagedMode() throws {
    let smc = FakeSMC.mac165()
    try settleManualMode(smc, fan: 0)

    let blocked = try smc.write(.target(fan: 0, bytes: FanEncoding.float32LittleEndian(0)), capability: .mac165ValidatedOneShot, reason: "zero target while manual")
    try expect(blocked.smcResult == 0x82, "zero target should be rejected while fan is manual")

    let release = try smc.write(.mode(fan: 0, value: 0), capability: .mac165ValidatedOneShot, reason: "release fan")
    try expect(release.smcResult == 0, "release mode write should be accepted")
    smc.advanceTick()
    smc.advanceTick()
    smc.advanceTick()
    smc.advanceTick()

    let mode = try smc.read(try FanKey("F0Md"))
    try expect(mode.bytes == [3], "fan mode should settle back to managed before clearing target")

    let clear = try smc.write(.target(fan: 0, bytes: FanEncoding.float32LittleEndian(0)), capability: .mac165ValidatedOneShot, reason: "clear target after managed")
    try expect(clear.smcResult == 0, "zero target should be accepted after fan is managed")
    try expect(try smc.read(try FanKey("F0Tg")).bytes == FanEncoding.float32LittleEndian(0), "zero target should clear readback after managed mode")
}

func testFakeSMCRejectsManualAboveMaximumTargetWrite() throws {
    let smc = FakeSMC.mac165()
    try settleManualMode(smc, fan: 0)
    let safeBytes = FanEncoding.float32LittleEndian(2_000)
    _ = try smc.write(.target(fan: 0, bytes: safeBytes), capability: .mac165ValidatedOneShot, reason: "safe target")

    let result = try smc.write(.target(fan: 0, bytes: FanEncoding.float32LittleEndian(5_778)), capability: .mac165ValidatedOneShot, reason: "above maximum target")

    try expect(result.smcResult == 0x82, "above-maximum manual target should be rejected")
    try expect(try smc.read(try FanKey("F0Tg")).bytes == safeBytes, "above-maximum target should not overwrite previous safe target")
}

func testFakeSMCRejectsManualNonFiniteTargetWrite() throws {
    let smc = FakeSMC.mac165()
    try settleManualMode(smc, fan: 0)
    let safeBytes = FanEncoding.float32LittleEndian(2_000)
    _ = try smc.write(.target(fan: 0, bytes: safeBytes), capability: .mac165ValidatedOneShot, reason: "safe target")

    let result = try smc.write(.target(fan: 0, bytes: FanEncoding.float32LittleEndian(.nan)), capability: .mac165ValidatedOneShot, reason: "non-finite target")

    try expect(result.smcResult == 0x82, "non-finite manual target should be rejected")
    try expect(try smc.read(try FanKey("F0Tg")).bytes == safeBytes, "non-finite target should not overwrite previous safe target")
}

func testFakeSMCPostManualTargetWriteSticks() throws {
    let smc = FakeSMC.mac165()
    let maxBytes = FanEncoding.float32LittleEndian(5_777)

    try settleManualMode(smc, fan: 0)

    let result = try smc.write(.target(fan: 0, bytes: maxBytes), capability: .mac165ValidatedOneShot, reason: "target after manual")
    try expect(result.smcResult == 0, "post-manual target write should be accepted")

    let readback = try smc.read(try FanKey("F0Tg"))
    try expect(readback.bytes == maxBytes, "post-manual target write should stick")

    smc.advanceTick()
    let actual = FanEncoding.floatValue(try smc.read(try FanKey("F0Ac")).bytes) ?? 0
    try expect(actual > 0, "post-manual target should drive ramp")
}

func testFakeSMCScriptedModeWriteRejection() throws {
    let smc = FakeSMC.mac165()
    smc.rejectWrite(operation: .mode(fan: 1, value: 1), key: "F1Md", smcResult: 0x84)

    let result = try smc.write(.mode(fan: 1, value: 1), capability: .mac165ValidatedOneShot, reason: "scripted rejection")

    try expect(result.smcResult == 0x84, "scripted F1Md=1 rejection should be returned")
    try expect(smc.writes.last?.key == "F1Md", "scripted rejection should still record the target key")
}

func testFakeSMCRawEntryBytesHelperMutatesAndReadsTargets() throws {
    let smc = FakeSMC.mac165()
    let fan0Target = FanEncoding.float32LittleEndian(2_222)
    let fan1Target = FanEncoding.float32LittleEndian(3_333)

    smc.setRawEntryBytes("F0Tg", fan0Target)
    smc.setRawEntryBytes("F1Tg", fan1Target)

    try expect(smc.rawEntryBytes("F0Tg") == fan0Target, "raw helper should read mutated F0Tg bytes")
    try expect(smc.rawEntryBytes("F1Tg") == fan1Target, "raw helper should read mutated F1Tg bytes")
    try expect(try smc.read(try FanKey("F0Tg")).bytes == fan0Target, "raw helper should mutate readable F0Tg entry")
    try expect(try smc.read(try FanKey("F1Tg")).bytes == fan1Target, "raw helper should mutate readable F1Tg entry")
}

func testBoostCreatesLeaseBeforeFirstWrite() throws {
    let smc = FakeSMC.mac165()
    let store = FanLeaseStore(directory: temporaryDirectory("boost-lease-before-write"))
    var leasePresentBeforeFirstWrite: Bool?
    smc.onBeforeWrite = { _, _ in
        if leasePresentBeforeFirstWrite == nil {
            leasePresentBeforeFirstWrite = ((try? store.readIfPresent()) != nil)
        }
    }
    let controller = boostController(smc: smc, store: store)

    _ = try controller.boostMax(leaseSeconds: 60, reason: "test boost")

    try expect(leasePresentBeforeFirstWrite == true, "boost should claim lease before first hardware write")
    let lease = try store.readIfPresent()
    try expect(lease != nil, "boost should leave active lease for Task 8 restore")
    try expect(lease?.capturedFans.count == 2, "boost lease should capture every fan")
    try expect(lease?.capturedFans[0].modeRaw == [3], "boost lease should capture pre-boost mode bytes")
    try expect(lease?.capturedFans[0].targetRaw == FanEncoding.float32LittleEndian(0), "boost lease should capture pre-boost target bytes")
    try expect(lease?.ownerStartTimeUnix == 1_700_000_000, "boost lease should capture owner process start time when inspectable")
}

func testBoostRestoresOnWriteFailureAfterLeaseCreation() throws {
    let smc = FakeSMC.mac165()
    let store = FanLeaseStore(directory: temporaryDirectory("boost-rollback-after-write-failure"))
    smc.rejectWrite(operation: .mode(fan: 1, value: 1), key: "F1Md", smcResult: 0x84)
    let controller = boostController(smc: smc, store: store)

    try expectThrows("boost should throw original write rejection", {
        _ = try controller.boostMax(leaseSeconds: 60, reason: "test boost failure")
    }, matching: { error in
        error as? FanControlError == .writeRejected(key: "F1Md", smcResult: 0x84)
    })

    try expect(smc.writes.contains { $0.operation == .unlock(value: 0) }, "boost failure should restore Ftst")
    try expect(smc.writes.contains { $0.operation == .mode(fan: 0, value: 0) }, "boost failure should release fan 0")
    try expect(smc.writes.contains { $0.operation == .mode(fan: 1, value: 0) }, "boost failure should release fan 1")
    try expect(try store.readIfPresent() != nil, "failed boost should leave lease for recovery rather than silently clearing it")
}

func testBoostRefusesPreexistingUnlockBeforeLeaseClaim() throws {
    let smc = FakeSMC.mac165()
    smc.setRawEntryBytes("Ftst", [1])
    let store = FanLeaseStore(directory: temporaryDirectory("boost-preexisting-unlock"))
    let controller = boostController(smc: smc, store: store)

    try expectThrows("boost should refuse preexisting Ftst unlock", {
        _ = try controller.boostMax(leaseSeconds: 60, reason: "preexisting unlock")
    }, matching: { error in
        guard case .unsafeState(let message) = error as? FanControlError else { return false }
        return message.contains("Ftst")
    })

    try expect(smc.writes.isEmpty, "preexisting Ftst unlock should refuse before hardware writes")
    try expect(try store.readIfPresent() == nil, "preexisting Ftst unlock should refuse before lease claim")
}

func testBoostAuditsAndRejectsNonzeroKernReturnBeforeRollback() throws {
    let smc = FakeSMC.mac165()
    let store = FanLeaseStore(directory: temporaryDirectory("boost-kern-return-rejection"))
    let clock = TestClock(onSleep: { smc.advanceTick() })
    let logger = InMemoryFanControlLogger()
    smc.rejectWrite(
        operation: .mode(fan: 1, value: 1),
        key: "F1Md",
        kernReturn: -536_870_212,
        smcResult: 0,
        smcStatus: 0
    )
    let controller = boostController(smc: smc, store: store, clock: clock, logger: logger)

    try expectThrows("boost should reject nonzero kernReturn write", {
        _ = try controller.boostMax(leaseSeconds: 60, reason: "kern failure")
    }, matching: { error in
        error as? FanControlError == .writeRejected(key: "F1Md", smcResult: 0)
    })

    let lease = try store.readIfPresent()
    try expect(lease != nil, "failed kernReturn boost should leave lease for recovery")
    guard let failedEventIndex = logger.events.firstIndex(where: { $0.key == "F1Md" && $0.kernReturn != 0 }) else {
        throw TestFailure(description: "failed write audit event should exist")
    }
    let failedEvent = logger.events[failedEventIndex]
    try expect(failedEvent.key == "F1Md", "failed write audit should include key")
    try expect(failedEvent.oldRaw == [3], "failed write audit should include old mode bytes")
    try expect(failedEvent.newRaw == [1], "failed write audit should include requested mode bytes")
    try expect(failedEvent.kernReturn == -536_870_212, "failed write audit should include kernReturn")
    try expect(failedEvent.smcResult == 0, "failed write audit should include smcResult")
    try expect(failedEvent.smcStatus == 0, "failed write audit should include smcStatus")
    try expect(failedEvent.leaseID == lease?.id, "failed write audit should include lease ID")

    if let firstRollbackIndex = logger.events.firstIndex(where: { $0.reason.hasPrefix("rollback ") }) {
        try expect(failedEventIndex < firstRollbackIndex, "failed write audit should be recorded before rollback events")
    } else {
        throw TestFailure(description: "rollback audit events should exist after failed write")
    }
}

func testBoostUsesHardwareValidatedSequence() throws {
    let smc = FakeSMC.mac165()
    let store = FanLeaseStore(directory: temporaryDirectory("boost-validated-sequence"))
    let clock = TestClock(onSleep: { smc.advanceTick() })
    let logger = InMemoryFanControlLogger()
    let controller = boostController(smc: smc, store: store, clock: clock, logger: logger)

    let result = try controller.boostMax(leaseSeconds: 60, reason: "test sequence")
    let lease = try store.read()

    try expect(result.leaseID == lease.id, "boost result should identify active lease")
    try expect(result.verified, "boost should report verified ramp")
    try expect(result.maxActualRPM >= 5_777 * activeTestCapability().boostVerificationMultiplier, "boost should observe actual RPM above verification threshold")

    let expectedPrefix: [FanWriteOperation] = [
        .unlock(value: activeTestCapability().unlockOn),
        .target(fan: 0, bytes: FanEncoding.float32LittleEndian(5_777)),
        .target(fan: 1, bytes: FanEncoding.float32LittleEndian(5_777)),
        .mode(fan: 0, value: activeTestCapability().manualCommand),
        .mode(fan: 1, value: activeTestCapability().manualCommand),
        .target(fan: 0, bytes: FanEncoding.float32LittleEndian(5_777)),
        .target(fan: 1, bytes: FanEncoding.float32LittleEndian(5_777))
    ]
    try expect(Array(smc.writes.prefix(expectedPrefix.count)).map(\.operation) == expectedPrefix, "boost should use validated unlock/target/manual/max sequence")
    try expect(try smc.read(try FanKey("Ftst")).bytes == [activeTestCapability().unlockOn], "boost should poll until unlock reads back on")
    try expect(try smc.read(try FanKey("F0Md")).bytes == [activeTestCapability().manualCommand], "boost should poll fan 0 manual readback")
    try expect(try smc.read(try FanKey("F1Md")).bytes == [activeTestCapability().manualCommand], "boost should poll fan 1 manual readback")
    try expect(try smc.read(try FanKey("F0Tg")).bytes == FanEncoding.float32LittleEndian(5_777), "boost should confirm fan 0 max target after manual")
    try expect(try smc.read(try FanKey("F1Tg")).bytes == FanEncoding.float32LittleEndian(5_777), "boost should confirm fan 1 max target after manual")
    try expect(logger.events.map(\.key) == smc.writes.map(\.key), "boost should audit every hardware write")
    try expect(logger.events.allSatisfy { $0.leaseID == lease.id }, "boost write audit events should include the lease id")
}

func testBoostRefusesWhenActiveControlDisabled() throws {
    let smc = FakeSMC.mac165()
    let store = FanLeaseStore(directory: temporaryDirectory("boost-active-control-disabled"))
    let controller = boostController(smc: smc, store: store, capability: .mac165ValidatedOneShot)

    try expectThrows("boost should refuse disabled active control", {
        _ = try controller.boostMax(leaseSeconds: 60, reason: "disabled boost")
    }, matching: { error in
        error as? FanControlError == .activeControlDisabled(model: "Mac16,5")
    })

    try expect(smc.writes.isEmpty, "disabled boost should not write hardware")
    try expect(try store.readIfPresent() == nil, "disabled boost should not claim a lease")
}

func settleManualMode(_ smc: FakeSMC, fan: Int) throws {
    let capability = FanCapability.mac165ValidatedOneShot
    _ = try smc.write(.unlock(value: capability.unlockOn), capability: capability, reason: "unlock")
    smc.advanceTick()
    smc.advanceTick()
    smc.advanceTick()

    for index in 0..<capability.fanCount {
        let maximum = FanEncoding.floatValue(try smc.read(try FanKey("F\(index)Mx")).bytes) ?? 0
        _ = try smc.write(.target(fan: index, bytes: FanEncoding.float32LittleEndian(maximum)), capability: capability, reason: "safe pre-manual target")
        smc.advanceTick()
        smc.advanceTick()
    }

    let manual = try smc.write(.mode(fan: fan, value: capability.manualCommand), capability: capability, reason: "manual")
    try expect(manual.smcResult == 0, "manual mode should be accepted after safe pre-manual target")
    smc.advanceTick()
    smc.advanceTick()
}

func fullyValidatedCapability() -> FanCapability {
    FanCapability.mac165ValidatedOneShot.withValidation(validationState())
}

func activeTestCapability() -> FanCapability {
    fullyValidatedCapability()
}

func testLease(
    id: UUID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
    capabilityFingerprint: String = fullyValidatedCapability().fingerprint,
    ownerPID: Int32 = 42,
    ownerStartTimeUnix: TimeInterval? = nil,
    createdAtUnix: TimeInterval = 1_800_000_000,
    expiresAtUnix: TimeInterval = 1_800_000_600,
    heartbeatAtUnix: TimeInterval = 1_800_000_000,
    parentPID: Int32 = 100,
    phase: FanLeasePhase = .created,
    capturedFans: [CapturedFanState] = [
        CapturedFanState(index: 0, modeRaw: [3], targetRaw: FanEncoding.float32LittleEndian(2_000))
    ],
    reason: String = "test lease"
) -> FanLease {
    FanLease(
        id: id,
        capabilityFingerprint: capabilityFingerprint,
        ownerPID: ownerPID,
        ownerStartTimeUnix: ownerStartTimeUnix,
        parentPID: parentPID,
        createdAtUnix: createdAtUnix,
        expiresAtUnix: expiresAtUnix,
        heartbeatAtUnix: heartbeatAtUnix,
        phase: phase,
        capturedFans: capturedFans,
        reason: reason
    )
}

func temporaryDirectory(_ name: String) -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("mlx-chill-fan-control-tests", isDirectory: true)
        .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.removeItem(at: root)
    return root
}

struct TestProcessInspector: FanProcessInspecting {
    let ownerProcesses: [Int32: FanOwnerProcessInfo]

    func ownerProcessInfo(pid: Int32) -> FanOwnerProcessInfo? {
        ownerProcesses[pid]
    }
}

func leaseDecisionController(store: FanLeaseStore, processInspector: any FanProcessInspecting = TestProcessInspector(ownerProcesses: [
    42: FanOwnerProcessInfo(pid: 42, parentPID: 100, startTimeUnix: nil)
])) -> FanController {
    FanController(
        hardware: FakeSMC.mac165(),
        capability: fullyValidatedCapability(),
        clock: TestClock(nowUnix: 1_800_000_000),
        leaseStore: store,
        processInspector: processInspector
    )
}

func boostController(
    smc: FakeSMC,
    store: FanLeaseStore,
    capability: FanCapability = activeTestCapability(),
    clock: FanControlClock? = nil,
    logger: InMemoryFanControlLogger = InMemoryFanControlLogger()
) -> FanController {
    let ownerPID = Int32(ProcessInfo.processInfo.processIdentifier)
    return FanController(
        hardware: smc,
        capability: capability,
        clock: clock ?? TestClock(onSleep: { smc.advanceTick() }),
        logger: logger,
        leaseStore: store,
        processInspector: TestProcessInspector(ownerProcesses: [
            ownerPID: FanOwnerProcessInfo(pid: ownerPID, parentPID: 100, startTimeUnix: 1_700_000_000)
        ])
    )
}

func validationState(
    read: Bool = true,
    boostMaxOneShot: Bool = true,
    restoreAutoOneShot: Bool = true,
    targetClearAfterNonManual: Bool = true,
    crashRecovery: Bool = true,
    parentDeathRecovery: Bool = true,
    missedHeartbeatRecovery: Bool = true,
    leaseExpiryRecovery: Bool = true,
    signalRecovery: Bool = true,
    sleepWakeRecovery: Bool = true
) -> FanValidationState {
    FanValidationState(
        read: read,
        boostMaxOneShot: boostMaxOneShot,
        restoreAutoOneShot: restoreAutoOneShot,
        targetClearAfterNonManual: targetClearAfterNonManual,
        crashRecovery: crashRecovery,
        parentDeathRecovery: parentDeathRecovery,
        missedHeartbeatRecovery: missedHeartbeatRecovery,
        leaseExpiryRecovery: leaseExpiryRecovery,
        signalRecovery: signalRecovery,
        sleepWakeRecovery: sleepWakeRecovery
    )
}

func expectStatusInvalidReading(_ message: String, key: String, reason: String, mutate: (FakeSMC) -> Void) throws {
    let smc = FakeSMC.mac165()
    mutate(smc)
    let controller = FanController(hardware: smc, capability: fullyValidatedCapability(), clock: TestClock())

    try expectThrows(message, {
        _ = try controller.status()
    }, matching: { error in
        error as? FanControlError == .invalidReading(key: key, reason: reason)
    })
}

func expectStatusInvalidReading(_ message: String, key: String, mutate: (FakeSMC) -> Void) throws {
    let smc = FakeSMC.mac165()
    mutate(smc)
    let controller = FanController(hardware: smc, capability: fullyValidatedCapability(), clock: TestClock())

    try expectThrows(message, {
        _ = try controller.status()
    }, matching: { error in
        guard case .invalidReading(let actualKey, _) = error as? FanControlError else { return false }
        return actualKey == key
    })
}

let tests: [(String, () throws -> Void)] = [
    ("Core boundary", testCoreBoundary),
    ("Mac16,5 capability", testMac165Capability),
    ("Resolver succeeds for validated Mac16,5 inventory", testResolverSucceedsForValidatedMac165Inventory),
    ("Resolver rejects wrong model", testResolverRejectsWrongModel),
    ("Resolver rejects wrong platform", testResolverRejectsWrongPlatform),
    ("Resolver rejects fan count mismatch", testResolverRejectsFanCountMismatch),
    ("Resolver propagates missing per-fan inventory key", testResolverPropagatesMissingPerFanInventoryKey),
    ("Resolver rejects lowercase mode path when present", testResolverRejectsLowercaseModePathWhenPresent),
    ("Resolver propagates missing uppercase mode key", testResolverPropagatesMissingUppercaseModeKey),
    ("Resolver propagates missing Ftst", testResolverPropagatesMissingFtst),
    ("Resolver propagates unreadable Ftst", testResolverPropagatesUnreadableFtst),
    ("Status reads fan count and availability", testStatusReadsFanCountAndAvailability),
    ("Status missing Ftst keeps status but blocks active control", testStatusMissingFtstKeepsStatusButBlocksActiveControl),
    ("Status invalid Ftst keeps status but blocks active control", testStatusInvalidFtstKeepsStatusButBlocksActiveControl),
    ("Status all recovery flags and good hardware allows active control", testStatusAllRecoveryFlagsAndGoodHardwareAllowsActiveControl),
    ("Status reports platform mismatch availability reason", testStatusReportsPlatformMismatchAvailabilityReason),
    ("Status reports fan count mismatch without reading absent extra fans", testStatusReportsFanCountMismatchWithoutReadingAbsentExtraFans),
    ("Status reports every validation gate reason", testStatusReportsEveryValidationGateReason),
    ("Status reports every non-recovery validation gate", testStatusReportsEveryNonRecoveryValidationGate),
    ("Status rejects wrong target type", testStatusRejectsWrongTargetType),
    ("Status rejects wrong target size", testStatusRejectsWrongTargetSize),
    ("Status rejects wrong mode type", testStatusRejectsWrongModeType),
    ("Status rejects wrong mode size", testStatusRejectsWrongModeSize),
    ("Status rejects wrong FNum type", testStatusRejectsWrongFanCountType),
    ("Status rejects wrong FNum size", testStatusRejectsWrongFanCountSize),
    ("Status rejects wrong RPlt type", testStatusRejectsWrongPlatformType),
    ("Status rejects RPlt size mismatch", testStatusRejectsPlatformSizeMismatch),
    ("Status reports fan min/max out of bounds", testStatusReportsFanMinMaxOutOfBounds),
    ("Lease round-trips captured pre-boost bytes and heartbeat updates", testLeaseRoundTripsCapturedPreBoostBytesAndHeartbeatUpdates),
    ("Duplicate lease claim fails", testDuplicateLeaseClaimFails),
    ("Lease claim failure does not publish partial current lease", testLeaseClaimFailureDoesNotPublishPartialCurrentLease),
    ("Lease heartbeat requires matching lease ID", testLeaseHeartbeatRequiresMatchingLeaseID),
    ("Stale lease heartbeat does not clobber new lease", testStaleLeaseHeartbeatDoesNotClobberNewLease),
    ("Stale lease clear does not delete new lease", testStaleLeaseClearDoesNotDeleteNewLease),
    ("Lease clear removes matching lease", testLeaseClearRemovesMatchingLease),
    ("Lease overwrite for recovery requires expected lease ID", testLeaseOverwriteForRecoveryRequiresExpectedLeaseID),
    ("Recovery decision no lease", testRecoveryDecisionNoLease),
    ("Recovery decision corrupt lease restores fail closed", testRecoveryDecisionCorruptLeaseRestoresFailClosed),
    ("Recovery decision active lease", testRecoveryDecisionActiveLease),
    ("Recovery decision missed heartbeat restores", testRecoveryDecisionMissedHeartbeatRestores),
    ("Recovery decision expired lease restores at boundary", testRecoveryDecisionExpiredLeaseRestoresAtBoundary),
    ("Recovery decision expired lease trumps missed heartbeat", testRecoveryDecisionExpiredLeaseTrumpsMissedHeartbeat),
    ("Recovery decision parent PID change restores", testRecoveryDecisionParentPIDChangeRestores),
    ("Recovery decision missed heartbeat trumps parent PID change", testRecoveryDecisionMissedHeartbeatTrumpsParentPIDChange),
    ("Recovery decision capability mismatch restores before other reasons", testRecoveryDecisionCapabilityMismatchRestoresBeforeOtherReasons),
    ("Recovery decision omitted parent info inspects owner process", testRecoveryDecisionOmittedParentInfoInspectsOwnerProcess),
    ("Recovery decision omitted parent info does not silently skip uninspectable owner", testRecoveryDecisionOmittedParentInfoDoesNotSilentlySkipUninspectableOwner),
    ("Recovery decision owner parent change restores", testRecoveryDecisionOwnerParentChangeRestores),
    ("Recovery decision owner PID reuse start time mismatch restores", testRecoveryDecisionOwnerPIDReuseStartTimeMismatchRestores),
    ("Audit event records write details", testAuditEventRecordsWriteDetails),
    ("JSONL audit logger encodes Task 5 field names", testJSONLAuditLoggerEncodesTask5FieldNames),
    ("JSONL audit logger encodes nil leaseID as null", testJSONLAuditLoggerEncodesNilLeaseIDAsNull),
    ("JSONL audit logger appends two parseable lines", testJSONLAuditLoggerAppendsTwoParseableLines),
    ("JSONL audit logger creates missing parent directory", testJSONLAuditLoggerCreatesMissingParentDirectory),
    ("FakeSMC delayed Ftst readback", testFakeSMCDelayedFtstReadback),
    ("FakeSMC rejects early manual", testFakeSMCRejectsManualBeforeUnlockSettles),
    ("FakeSMC rejects manual without safe pre-manual target", testFakeSMCRejectsManualWithoutSafePreManualTarget),
    ("FakeSMC rejects manual until all fans have safe targets", testFakeSMCRejectsManualUntilAllFansHaveSafeTargets),
    ("FakeSMC rejects managed observed mode write", testFakeSMCRejectsManagedObservedModeWrite),
    ("FakeSMC release mode settles back to managed", testFakeSMCReleaseModeSettlesBackToManaged),
    ("FakeSMC pre-manual target write does not stick immediately", testFakeSMCPreManualTargetWriteDoesNotStickImmediately),
    ("FakeSMC pre-manual target write settles to safe guard value", testFakeSMCPreManualTargetWriteSettlesToSafeGuardValue),
    ("FakeSMC rejects unsafe pre-manual target requests", testFakeSMCRejectsUnsafePreManualTargetRequests),
    ("FakeSMC settles valid pre-manual target to safe guard", testFakeSMCSettlesValidPreManualTargetToSafeGuard),
    ("FakeSMC delays Ftst off readback", testFakeSMCDelaysFtstOffReadback),
    ("FakeSMC rejects manual zero target write", testFakeSMCRejectsManualZeroTargetWrite),
    ("FakeSMC allows target clear only after managed mode", testFakeSMCAllowsTargetClearOnlyAfterManagedMode),
    ("FakeSMC rejects manual above maximum target write", testFakeSMCRejectsManualAboveMaximumTargetWrite),
    ("FakeSMC rejects manual non-finite target write", testFakeSMCRejectsManualNonFiniteTargetWrite),
    ("FakeSMC post-manual target write sticks", testFakeSMCPostManualTargetWriteSticks),
    ("FakeSMC scripted mode write rejection", testFakeSMCScriptedModeWriteRejection),
    ("FakeSMC raw entry bytes helper mutates and reads targets", testFakeSMCRawEntryBytesHelperMutatesAndReadsTargets),
    ("Boost creates lease before first write", testBoostCreatesLeaseBeforeFirstWrite),
    ("Boost restores on write failure after lease creation", testBoostRestoresOnWriteFailureAfterLeaseCreation),
    ("Boost refuses preexisting unlock before lease claim", testBoostRefusesPreexistingUnlockBeforeLeaseClaim),
    ("Boost audits and rejects nonzero kernReturn before rollback", testBoostAuditsAndRejectsNonzeroKernReturnBeforeRollback),
    ("Boost uses hardware validated sequence", testBoostUsesHardwareValidatedSequence),
    ("Boost refuses when active control disabled", testBoostRefusesWhenActiveControlDisabled)
]

var failures = 0
for (name, test) in tests {
    do {
        try test()
        print("PASS \(name)")
    } catch {
        failures += 1
        print("FAIL \(name): \(error)")
    }
}

if failures == 0 {
    print("PASS \(tests.count)/\(tests.count) tests")
} else {
    print("FAIL \(failures)/\(tests.count) tests")
    exit(1)
}
