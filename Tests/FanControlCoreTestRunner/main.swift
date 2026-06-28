import FanControlCore
import Foundation
import SMCControlTransport

func testCoreBoundary() throws {
    let key = try FanKey("F0Tg")
    try expect(key.stringValue == "F0Tg", "FanKey should preserve four-character keys")
}

func testReadOnlyCSMCHeaderHasNoWriteAPI() throws {
    let header = try repositorySourceText("Sources/CSMC/include/CSMC.h")

    try expect(!header.contains("Write"), "CSMC.h should not expose a Write API")
    try expect(!header.contains("write"), "CSMC.h should not expose a write API")
}

func testSMCControlTransportHasNoPublicRawWriteAPI() throws {
    let source = try smcControlTransportSource()

    try expect(!source.contains("public func write(key"), "SMCControlTransport should not expose public raw write(key:) API")
    try expect(!source.contains("public func write(_ key"), "SMCControlTransport should not expose public raw write key API")
    try expect(!source.contains("package func write(key"), "SMCControlTransport should not expose package raw write(key:) API")
    try expect(!source.contains("package func write(_ key"), "SMCControlTransport should not expose package raw write key API")
}

func testSMCControlTransportExposesPackageFanHardwareOnly() throws {
    let source = try smcControlTransportSource()

    try expect(source.contains("package final class SMCFanHardware: FanHardware"), "SMCControlTransport should expose package-scoped SMCFanHardware conforming to FanHardware")
    try expect(source.contains("package init() throws"), "SMCFanHardware initializer should be package-scoped")
    try expect(source.contains("package func read(_ key: FanKey) throws -> FanReading"), "SMCFanHardware read surface should be package-scoped and typed")
    try expect(source.contains("package func write(_ operation: FanWriteOperation, capability: FanCapability, reason: String) throws -> FanWriteResult"), "SMCFanHardware write surface should accept typed FanWriteOperation only")
}

func testSMCControlTransportKeepsRawWritePrivate() throws {
    let source = try smcControlTransportSource()

    try expect(source.contains("private func privateWrite(key: FanKey, bytes: [UInt8]) throws -> FanWriteResult"), "raw privateWrite helper should be private and typed by FanKey")
    try expect(!source.contains("func write(key"), "SMCControlTransport should not expose unsupported raw write(key:) symbols")
    try expect(!source.contains("func write(_ key"), "SMCControlTransport should not expose unsupported raw write key symbols")
}

func testSMCControlTransportWritesOnlyTypedOperationsFromCapability() throws {
    let source = try smcControlTransportSource()

    try expect(source.contains("switch operation"), "SMCFanHardware write should switch over typed FanWriteOperation")
    try expect(source.contains("case .unlock(let value):"), "SMCFanHardware write should handle unlock operations")
    try expect(source.contains("capability.unlockKey"), "unlock writes should derive Ftst from FanCapability")
    try expect(source.contains("case .mode(let fan, let value):"), "SMCFanHardware write should handle mode operations")
    try expect(source.contains("try capability.modeKey(for: fan)"), "mode writes should derive mode key from FanCapability")
    try expect(source.contains("case .target(let fan, let bytes):"), "SMCFanHardware write should handle target operations")
    try expect(source.contains("try capability.targetKey(for: fan)"), "target writes should derive target key from FanCapability")
    try expect(!source.contains("FanKey(\"F"), "SMCFanHardware write path should not derive write keys from raw caller strings")
}

func testSMCControlTransportKeyDataABILayout() throws {
    let abi = SMCControlTransportABI.self

    try expect(abi.keyDataSize == 80, "SMCKeyData size should match C layout")
    try expect(abi.keyInfoSize == 12, "SMCKeyDataKeyInfo size should include C tail padding")
    try expect(abi.offsets.key == 0, "SMCKeyData.key offset should match C layout")
    try expect(abi.offsets.version == 4, "SMCKeyData.version offset should match C layout")
    try expect(abi.offsets.pLimitData == 12, "SMCKeyData.pLimitData offset should match C layout")
    try expect(abi.offsets.keyInfo == 28, "SMCKeyData.keyInfo offset should match C layout")
    try expect(abi.offsets.result == 40, "SMCKeyData.result offset should match C layout")
    try expect(abi.offsets.status == 41, "SMCKeyData.status offset should match C layout")
    try expect(abi.offsets.data8 == 42, "SMCKeyData.data8 offset should match C layout")
    try expect(abi.offsets.data32 == 44, "SMCKeyData.data32 offset should match C layout")
    try expect(abi.offsets.bytes == 48, "SMCKeyData.bytes offset should match C layout")
    try expect(!abi.acceptsOutputSize(79), "SMC raw call should reject short output")
    try expect(abi.acceptsOutputSize(80), "SMC raw call should accept full key data output")
}

func testPackageDefinesSingleColdfrontExecutable() throws {
    let manifest = try repositorySourceText("Package.swift")

    try expect(manifest.contains("name: \"coldfront\""), "package should be named coldfront")
    try expect(manifest.contains(".executable(name: \"coldfront\", targets: [\"coldfront\"])"), "package should expose one coldfront executable product")
    try expect(!manifest.contains("mlx-chill"), "package manifest should not expose mlx-chill products or targets")
    try expect(!manifest.contains("mlx-chill-control"), "package manifest should not expose mlx-chill-control products or targets")
}

func smcControlTransportSource() throws -> String {
    try repositorySourceText("Sources/SMCControlTransport/SMCControlTransport.swift")
}

func repositorySourceText(_ path: String) throws -> String {
    try String(
        contentsOf: repositoryFileURL(path),
        encoding: .utf8
    )
}

func repositoryFileURL(_ path: String) throws -> URL {
    let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let currentDirectoryCandidate = currentDirectory.appendingPathComponent(path)
    if FileManager.default.fileExists(atPath: currentDirectoryCandidate.path) {
        return currentDirectoryCandidate
    }

    var sourceFileRoot = URL(fileURLWithPath: #filePath)
    while sourceFileRoot.path != "/" {
        let candidate = sourceFileRoot.appendingPathComponent(path)
        if FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        sourceFileRoot.deleteLastPathComponent()
    }

    throw TestFailure(description: "missing repository file \(path)")
}

func repositoryRootURL() throws -> URL {
    try repositoryFileURL("Package.swift").deletingLastPathComponent()
}

struct ProcessResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

func runColdfrontExecutable(_ arguments: [String]) throws -> ProcessResult {
    let executableURL = try coldfrontExecutableURL()
    return try runProcess(
        executableURL: executableURL,
        arguments: arguments,
        currentDirectoryURL: try repositoryRootURL()
    )
}

func coldfrontExecutableURL() throws -> URL {
    let repoRoot = try repositoryRootURL()
    let buildResult = try runProcess(
        executableURL: URL(fileURLWithPath: "/usr/bin/env"),
        arguments: ["swift", "build", "--product", "coldfront"],
        currentDirectoryURL: repoRoot
    )

    guard buildResult.exitCode == 0 else {
        throw TestFailure(description: "failed to build coldfront: \(buildResult.stderr)\(buildResult.stdout)")
    }

    let executableURL = repoRoot.appendingPathComponent(".build/debug/coldfront")
    guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
        throw TestFailure(description: "missing built coldfront executable at \(executableURL.path)")
    }

    return executableURL
}

func runProcess(executableURL: URL, arguments: [String], currentDirectoryURL: URL) throws -> ProcessResult {
    let process = Process()
    process.executableURL = executableURL
    process.arguments = arguments
    process.currentDirectoryURL = currentDirectoryURL

    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr

    try process.run()
    process.waitUntilExit()

    return ProcessResult(
        exitCode: process.terminationStatus,
        stdout: String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
        stderr: String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    )
}

func testColdfrontExecutableNoLongerRoutesBoostThroughDisabledGate() throws {
    let source = try repositorySourceText("Sources/coldfront/main.swift")

    try expect(!source.contains("case .runBoostMax"), "coldfront should not retain run --boost handling")
    try expect(!source.contains("FanControlCommandContract.disabledActiveControlResponse"), "coldfront boost should not route through disabled active-control output")
}

func testColdfrontExecutableDispatchesBoostAndAutoToController() throws {
    let source = try repositorySourceText("Sources/coldfront/main.swift")

    try expect(source.contains("try runBoost(durationSeconds: durationSeconds)"), "coldfront boost should dispatch to active boost implementation")
    try expect(source.contains("try runAutoRestore()"), "coldfront auto should dispatch to active restore implementation")
    try expect(!source.contains("case .runBoostMax"), "coldfront should not expose run --boost")
}

func testActiveControlResponseFailsBoostCommandWhenExplicitlyDisabled() throws {
    let boost = try FanControlCommand.parse([
        "boost", "--for", "10m", "-y"
    ])

    let boostResponse = try FanControlCommandContract.disabledActiveControlResponse(
        for: boost,
        capability: .mac165ValidatedOneShot
    )

    try expect(boostResponse.exitCode == 1, "disabled boost should exit nonzero")
    try expect(
        boostResponse.stdout == "active fan control is disabled for Mac16,5\n",
        "disabled boost should print the disabled active-control message"
    )
}

func testDisabledStatusJSONResponseIsParseable() throws {
    let status = try FanControlCommand.parse(["status", "--json"])
    let response = try FanControlCommandContract.disabledActiveControlResponse(
        for: status,
        capability: .mac165ValidatedOneShot
    )

    try expect(response.exitCode == 0, "disabled status --json should exit zero")
    let object = try JSONSerialization.jsonObject(with: Data(response.stdout.utf8)) as? [String: Any]
    try expect(object?["model"] as? String == "Mac16,5", "status JSON should include model")
    try expect(object?["activeControlEnabled"] as? Bool == false, "status JSON should disable active control")
    try expect(object?["boostExecutionEnabled"] as? Bool == false, "status JSON should disable boost execution")
    try expect(object?["recoveryExecutionEnabled"] as? Bool == false, "status JSON should disable recovery execution")
    try expect(
        object?["message"] as? String == "active fan control is disabled for Mac16,5",
        "status JSON should include the disabled active-control message"
    )
}

func testControlExecutableStatusJSONReportsEnabledFlags() throws {
    let result = try runColdfrontExecutable(["status", "--json"])

    try expect(result.exitCode == 0, "executable status --json should exit zero")
    let object = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
    let model = object?["model"] as? String
    try expect(model == "Mac16,5" || model == "Mac17,7", "executable status JSON should include an allowlisted model")
    try expect(object?["activeControlEnabled"] as? Bool == true, "executable status JSON should enable active control for validated hardware")
    try expect(object?["boostExecutionEnabled"] as? Bool == true, "executable status JSON should enable boost execution")
    try expect(object?["recoveryExecutionEnabled"] as? Bool == true, "executable status JSON should enable recovery execution")
}

func testReadmeDocumentsBoostAndAutoCommands() throws {
    let source = try repositorySourceText("README.md")
    let normalizedSource = source.replacingOccurrences(
        of: "\\s+",
        with: " ",
        options: .regularExpression
    )

    try expect(
        normalizedSource.contains("sudo .build/release/coldfront boost --for 10m -y"),
        "README should document the active boost command"
    )
    try expect(
        normalizedSource.contains("sudo .build/release/coldfront auto"),
        "README should document the active auto restore command"
    )
}

func testCLIParsesBoundedBoostDuration() throws {
    let command = try FanControlCommand.parse(["boost", "--for", "10m", "-y"])
    let maxCommand = try FanControlCommand.parse(["boost", "--for", "120m", "--yes"])

    try expect(
        command == .boostMax(durationSeconds: 600, acknowledgedRisk: true),
        "boost should parse a bounded minute duration with explicit acknowledgement"
    )
    try expect(
        maxCommand == .boostMax(durationSeconds: 7_200, acknowledgedRisk: true),
        "boost should accept a two-hour duration boundary with explicit acknowledgement"
    )
}

func testCLIParsesStatusJSON() throws {
    let command = try FanControlCommand.parse(["status", "--json"])

    try expect(command == .statusJSON, "status --json should parse as the status JSON command")
}

func testCLIParsesAuto() throws {
    let command = try FanControlCommand.parse(["auto"])

    try expect(command == .auto, "auto should parse as the automatic restore command")
}

func testCLIParsesTenSecondValidationOneShot() throws {
    let command = try FanControlCommand.parse([
        "validate", "--for", "10s", "-y"
    ])

    try expect(
        command == .validateOneShot(durationSeconds: 10, acknowledgedRisk: true),
        "validation should parse an explicit ten second duration"
    )
}

func testCLIRejectsValidationOneShotOverTenSeconds() throws {
    try expectThrows("validation should reject durations above ten seconds", {
        _ = try FanControlCommand.parse([
            "validate", "--for", "11s", "-y"
        ])
    }, matching: { error in
        error as? FanControlCommandParseError == .durationOutOfBounds(seconds: 11, maxSeconds: 10)
    })
}

func testCLIUsesDefaultBoostDuration() throws {
    let command = try FanControlCommand.parse(["boost", "-y"])

    try expect(
        command == .boostMax(durationSeconds: 600, acknowledgedRisk: true),
        "boost should default to a 600 second duration"
    )
}

func testCLIRejectsMissingAcknowledgement() throws {
    try expectThrows("boost should reject missing acknowledgement", {
        _ = try FanControlCommand.parse(["boost", "--for", "10m"])
    }, matching: { _ in true })
    try expectThrows("old long acknowledgement should be removed", {
        _ = try FanControlCommand.parse(["boost", "--for", "10m", "--i-understand-active-fan-control"])
    }, matching: { error in
        error as? FanControlCommandParseError == .unknownArgument("--i-understand-active-fan-control")
    })
}

func testCLIRejectsLeaseOverTwoHours() throws {
    try expectThrows("boost should reject duration above two hours", {
        _ = try FanControlCommand.parse(["boost", "--for", "121m", "-y"])
    }, matching: { _ in true })
}

func testCLIRejectsRunCommand() throws {
    try expectThrows("run should not be part of the initial active interface", {
        _ = try FanControlCommand.parse(["run", "--boost", "--for", "1s", "-y", "--", "echo", "hello"])
    }, matching: { error in
        error as? FanControlCommandParseError == .unknownArgument("run")
    })
}

func testCLIRejectsUnknownDurationUnit() throws {
    try expectThrows("boost should reject unknown duration unit", {
        _ = try FanControlCommand.parse(["boost", "--for", "1h", "-y"])
    }, matching: { _ in true })

    try expectThrows("boost should reject fractional minute duration", {
        _ = try FanControlCommand.parse(["boost", "--for", "1.5m", "-y"])
    }, matching: { _ in true })
}

func testCLIRejectsZeroDuration() throws {
    try expectThrows("boost should reject zero duration", {
        _ = try FanControlCommand.parse(["boost", "--for", "0s", "-y"])
    }, matching: { _ in true })
}

func testCLIRejectsNegativeDuration() throws {
    try expectThrows("boost should reject negative duration", {
        _ = try FanControlCommand.parse(["boost", "--for", "-1s", "-y"])
    }, matching: { _ in true })
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

func testMac177Capability() throws {
    let capability = FanCapability.mac177M5MaxLowercaseMode
    let mode0 = try capability.modeKey(for: 0)
    let target1 = try capability.targetKey(for: 1)

    try expect(capability.model == "Mac17,7", "model should match local M5 validation")
    try expect(capability.platform == "j714c", "platform should match local M5 validation")
    try expect(capability.fanCount == 2, "fan count should match local M5 validation")
    try expect(mode0.stringValue == "F0md", "M5 mode key should use lowercase md")
    try expect(target1.stringValue == "F1Tg", "target key should format fan index")
    try expect(capability.unlockAvailable == false, "M5 path should not require Ftst")
    try expect(capability.managedObservedState == 0, "M5 managed state should match lowercase mode reads")
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

func testResolverSucceedsForValidatedMac177Inventory() throws {
    let resolver = try FanCapabilityResolver(hardware: fakeMac177FanInventory(), hostModel: { "Mac17,7" })

    let capability = try resolver.resolve()

    try expect(capability.model == "Mac17,7", "resolver should return Mac17,7 capability")
    try expect(capability.platform == "j714c", "resolver should return M5 platform")
    try expect(capability.fanCount == 2, "resolver should preserve M5 fan count")
    try expect(capability.modeKeyFormat == "F%dmd", "resolver should preserve lowercase mode key")
    try expect(capability.unlockAvailable == false, "resolver should preserve no-unlock M5 path")
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

func testStatusMac177DoesNotRequireFtstForActiveControl() throws {
    let smc = FakeSMC.mac177()
    let capability = FanCapability.mac177M5MaxLowercaseMode.withValidation(validationState())
    let controller = FanController(hardware: smc, capability: capability, clock: TestClock())

    let status = try controller.status()

    try expect(status.platform == "j714c", "status should read M5 platform")
    try expect(status.ftst == nil, "M5 no-unlock path should not report Ftst")
    try expect(status.fans.map(\.mode) == [0, 0], "status should read lowercase M5 mode keys")
    try expect(status.activeAvailability.allowed, "fully validated M5 no-unlock hardware should allow active control")
    try expect(status.activeAvailability.reasons.isEmpty, "M5 no-unlock status should not report availability reasons")
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

func testBoostClearsLeaseWhenFirstWriteRejected() throws {
    let smc = FakeSMC.mac165()
    let store = FanLeaseStore(directory: temporaryDirectory("boost-first-write-rejected"))
    smc.rejectWrite(
        operation: .unlock(value: 1),
        key: "Ftst",
        kernReturn: -536_870_207,
        smcResult: 0,
        smcStatus: 0
    )
    let controller = boostController(smc: smc, store: store)

    try expectThrows("boost should throw first write rejection", {
        _ = try controller.boostMax(leaseSeconds: 60, reason: "first write rejected")
    }, matching: { error in
        error as? FanControlError == .writeRejected(key: "Ftst", smcResult: 0)
    })

    try expect(try store.readIfPresent() == nil, "first-write rejection should clear lease because no hardware write was accepted")
}

func testBoostRetriesTransientManualModeRejection() throws {
    let smc = FakeSMC.mac165()
    let store = FanLeaseStore(directory: temporaryDirectory("boost-retry-transient-manual"))
    let clock = TestClock(onSleep: { smc.advanceTick() })
    smc.rejectNextWrite(
        operation: .mode(fan: 0, value: activeTestCapability().manualCommand),
        key: "F0Md",
        smcResult: 0x82
    )
    let controller = boostController(smc: smc, store: store, clock: clock)

    _ = try controller.boostMax(leaseSeconds: 60, reason: "transient manual rejection")

    let fan0ManualWrites = smc.writes.filter {
        $0.operation == .mode(fan: 0, value: activeTestCapability().manualCommand)
    }
    try expect(fan0ManualWrites.count == 2, "transient manual rejection should be retried once before succeeding")
    try expect(fan0ManualWrites[0].smcResult == 0x82, "first manual write should capture transient SMC rejection")
    try expect(fan0ManualWrites[1].smcResult == 0, "second manual write should succeed")
    try expect(try smc.read(try FanKey("F0Md")).bytes == [activeTestCapability().manualCommand], "fan 0 should end in manual mode")
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

func testBoostUsesMac177LowercaseModeSequenceWithoutPreManualReadback() throws {
    let smc = FakeSMC.mac177()
    let store = FanLeaseStore(directory: temporaryDirectory("boost-mac177-sequence"))
    let clock = TestClock(onSleep: { smc.advanceTick() })
    let logger = InMemoryFanControlLogger()
    let capability = FanCapability.mac177M5MaxLowercaseMode.withValidation(validationState())
    let controller = boostController(smc: smc, store: store, capability: capability, clock: clock, logger: logger)

    let result = try controller.boostMax(leaseSeconds: 60, reason: "test M5 sequence")
    let lease = try store.read()

    try expect(result.leaseID == lease.id, "M5 boost result should identify active lease")
    try expect(result.verified, "M5 boost should report verified ramp")
    try expect(result.maxActualRPM >= 7_826 * capability.boostVerificationMultiplier, "M5 boost should observe actual RPM above verification threshold")

    let expectedPrefix: [FanWriteOperation] = [
        .target(fan: 0, bytes: FanEncoding.float32LittleEndian(7_826)),
        .target(fan: 1, bytes: FanEncoding.float32LittleEndian(7_826)),
        .mode(fan: 0, value: capability.manualCommand),
        .mode(fan: 1, value: capability.manualCommand),
        .target(fan: 0, bytes: FanEncoding.float32LittleEndian(7_826)),
        .target(fan: 1, bytes: FanEncoding.float32LittleEndian(7_826))
    ]
    try expect(Array(smc.writes.prefix(expectedPrefix.count)).map(\.operation) == expectedPrefix, "M5 boost should use target/manual/max sequence without Ftst")
    try expect(try smc.read(try FanKey("F0md")).bytes == [capability.manualCommand], "M5 boost should poll fan 0 lowercase manual readback")
    try expect(try smc.read(try FanKey("F1md")).bytes == [capability.manualCommand], "M5 boost should poll fan 1 lowercase manual readback")
    try expect(try smc.read(try FanKey("F0Tg")).bytes == FanEncoding.float32LittleEndian(7_826), "M5 boost should confirm fan 0 max target after manual")
    try expect(try smc.read(try FanKey("F1Tg")).bytes == FanEncoding.float32LittleEndian(7_826), "M5 boost should confirm fan 1 max target after manual")
    try expect(!logger.events.contains { $0.key == "Ftst" }, "M5 boost should not write Ftst")
    try expect(logger.events.map(\.key) == smc.writes.map(\.key), "M5 boost should audit every hardware write")
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

func testRestoreUsesCapturedLeaseTargetsNotCurrentTargets() throws {
    let smc = FakeSMC.mac165()
    let store = FanLeaseStore(directory: temporaryDirectory("restore-captured-targets"))
    let logger = InMemoryFanControlLogger()
    let lease = try installBoostedLeaseState(smc: smc, store: store, capturedTargetRaw: FanEncoding.float32LittleEndian(0))
    let controller = restoreController(smc: smc, store: store, logger: logger)

    let result = try controller.restoreAuto(reason: "test restore")

    try expect(result.restored, "restore should report restored")
    try expect(result.finalModes == [activeTestCapability().managedObservedState, activeTestCapability().managedObservedState], "restore should return final managed modes")
    try expect(result.finalTargets == [0, 0], "restore should return final captured target RPMs")

    let operations = smc.writes.map(\.operation)
    guard let release0 = operations.firstIndex(of: .mode(fan: 0, value: activeTestCapability().releaseCommand)),
          let release1 = operations.firstIndex(of: .mode(fan: 1, value: activeTestCapability().releaseCommand)),
          let clear0 = operations.firstIndex(of: .target(fan: 0, bytes: FanEncoding.float32LittleEndian(0))),
          let clear1 = operations.firstIndex(of: .target(fan: 1, bytes: FanEncoding.float32LittleEndian(0)))
    else {
        throw TestFailure(description: "restore should write release modes and captured zero targets")
    }
    try expect(release0 < clear0, "fan 0 captured target clear should happen after release mode write")
    try expect(release1 < clear1, "fan 1 captured target clear should happen after release mode write")
    try expect(smc.writes.filter { $0.operation == .target(fan: 0, bytes: FanEncoding.float32LittleEndian(5_777)) }.count == 1, "fan 0 should only receive the protective high target, not current max as restore target")
    try expect(smc.writes.filter { $0.operation == .target(fan: 1, bytes: FanEncoding.float32LittleEndian(5_777)) }.count == 1, "fan 1 should only receive the protective high target, not current max as restore target")
    try expect(logger.events.map(\.key) == smc.writes.map(\.key), "restore should audit every hardware write")
    try expect(logger.events.allSatisfy { $0.leaseID == lease.id }, "restore audit events should include lease ID")
}

func testRestoreNeverClearsTargetWhileManual() throws {
    let smc = FakeSMC.mac165()
    let store = FanLeaseStore(directory: temporaryDirectory("restore-never-clears-manual"))
    _ = try installBoostedLeaseState(smc: smc, store: store, capturedTargetRaw: FanEncoding.float32LittleEndian(0))
    var clearedWhileManual: [Int] = []
    smc.onBeforeWrite = { operation, _ in
        guard case .target(let fan, let bytes) = operation,
              bytes == FanEncoding.float32LittleEndian(0),
              let mode = smc.rawEntryBytes("F\(fan)Md")?.first,
              mode == activeTestCapability().manualCommand
        else { return }
        clearedWhileManual.append(fan)
    }
    let controller = restoreController(smc: smc, store: store)

    _ = try controller.restoreAuto(reason: "test restore")

    try expect(clearedWhileManual.isEmpty, "restore should not clear captured targets while a fan still reads manual")
}

func testRestoreClearsLeaseOnlyAfterManagedSettle() throws {
    let smc = FakeSMC.mac165()
    let store = FanLeaseStore(directory: temporaryDirectory("restore-clear-after-managed-settle"))
    _ = try installBoostedLeaseState(smc: smc, store: store, capturedTargetRaw: FanEncoding.float32LittleEndian(0), actualRPM: 5_777)
    var sawManagedSettledWithLease = false
    let clock = TestClock(onSleep: {
        smc.advanceTick()
        if (try? store.readIfPresent()) != nil,
           restoreHardwareSettled(smc) {
            sawManagedSettledWithLease = true
        }
    })
    let controller = restoreController(smc: smc, store: store, clock: clock)

    _ = try controller.restoreAuto(reason: "test restore")

    try expect(sawManagedSettledWithLease, "restore should keep lease while managed mode, unlock, target, and idle RPM settle")
    try expect(try store.readIfPresent() == nil, "restore should clear lease after managed settle")
    try expect(restoreHardwareSettled(smc), "restore should leave hardware in managed settled state")
}

func testAutoNoopsWhenNoLeaseExists() throws {
    let smc = FakeSMC.mac165()
    let store = FanLeaseStore(directory: temporaryDirectory("restore-no-lease-noop"))
    let controller = restoreController(smc: smc, store: store)

    let result = try controller.restoreAuto(reason: "no lease")

    try expect(result == FanRestoreResult(restored: true, finalModes: [], finalTargets: []), "missing lease should return restored empty result")
    try expect(smc.writes.isEmpty, "missing lease restore should not write hardware")
}

func testRestoreRecoveryModeRequiresLease() throws {
    let smc = FakeSMC.mac165()
    let store = FanLeaseStore(directory: temporaryDirectory("restore-recovery-no-lease"))
    let controller = restoreController(smc: smc, store: store)

    try expectThrows("recovery restore should require a lease", {
        _ = try controller.restoreAuto(reason: "recovery", recoveryMode: true)
    }, matching: { error in
        error as? FanControlError == .leaseRequired("recovery requested without lease")
    })

    try expect(smc.writes.isEmpty, "recovery restore without lease should not write hardware")
}

func testRestoreFingerprintMismatchDoesNotWriteOrClearLease() throws {
    let smc = FakeSMC.mac165()
    let store = FanLeaseStore(directory: temporaryDirectory("restore-fingerprint-mismatch"))
    let lease = try installBoostedLeaseState(smc: smc, store: store, capabilityFingerprint: "old-fingerprint")
    let controller = restoreController(smc: smc, store: store)

    try expectThrows("restore should reject mismatched lease capability", {
        _ = try controller.restoreAuto(reason: "mismatch")
    }, matching: { error in
        guard case .unsafeState(let message) = error as? FanControlError else { return false }
        return message.contains("capability fingerprint")
    })

    try expect(smc.writes.isEmpty, "capability mismatch restore should not write hardware")
    try expect(try store.readIfPresent() == lease, "capability mismatch restore should not clear lease")
}

func testRestoreCorruptLeaseFailsClosedWithoutClearing() throws {
    let smc = FakeSMC.mac165()
    let directory = temporaryDirectory("restore-corrupt-lease")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("{\"id\":\"truncated\"".utf8).write(to: directory.appendingPathComponent("current-lease.json"))
    let store = FanLeaseStore(directory: directory)
    let controller = restoreController(smc: smc, store: store)

    try expectThrows("restore should fail closed on corrupt lease", {
        _ = try controller.restoreAuto(reason: "corrupt")
    }, matching: { error in
        guard case .restoreFailed(let message) = error as? FanControlError else { return false }
        return message.contains("lease")
    })

    try expect(smc.writes.isEmpty, "corrupt lease restore should not write hardware")
    try expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("current-lease.json").path), "corrupt lease restore should not clear lease")
}

func testRestoreLowFNumFailsClosedBeforeWritingOrClearingLease() throws {
    let smc = FakeSMC.mac165()
    let store = FanLeaseStore(directory: temporaryDirectory("restore-low-fnum"))
    let lease = try installBoostedLeaseState(smc: smc, store: store)
    smc.setRawEntryBytes("FNum", [1])
    let controller = restoreController(smc: smc, store: store)

    try expectThrows("restore should reject low FNum before writes", {
        _ = try controller.restoreAuto(reason: "low fnum")
    }, matching: { error in
        guard case .unsafeState(let message) = error as? FanControlError else { return false }
        return message.contains("fan count mismatch")
    })

    try expect(smc.writes.isEmpty, "low FNum restore should not write hardware")
    try expect(try store.readIfPresent() == lease, "low FNum restore should not clear lease")
}

func testRestoreExtraCapturedFanFailsClosedBeforeWritingOrClearingLease() throws {
    let smc = FakeSMC.mac165()
    let store = FanLeaseStore(directory: temporaryDirectory("restore-extra-captured-fan"))
    let capturedFans = [
        CapturedFanState(index: 0, modeRaw: [activeTestCapability().managedObservedState], targetRaw: FanEncoding.float32LittleEndian(0)),
        CapturedFanState(index: 1, modeRaw: [activeTestCapability().managedObservedState], targetRaw: FanEncoding.float32LittleEndian(0)),
        CapturedFanState(index: 2, modeRaw: [activeTestCapability().managedObservedState], targetRaw: FanEncoding.float32LittleEndian(0))
    ]
    let lease = try installBoostedLeaseState(smc: smc, store: store, capturedFans: capturedFans)
    let controller = restoreController(smc: smc, store: store)

    try expectThrows("restore should reject extra captured fan before writes", {
        _ = try controller.restoreAuto(reason: "extra fan")
    }, matching: { error in
        guard case .restoreFailed(let message) = error as? FanControlError else { return false }
        return message.contains("captured fan indices")
    })

    try expect(smc.writes.isEmpty, "extra captured fan restore should not write hardware")
    try expect(try store.readIfPresent() == lease, "extra captured fan restore should not clear lease")
}

func testRestoreDuplicateCapturedFanFailsClosedBeforeWritingOrClearingLease() throws {
    let smc = FakeSMC.mac165()
    let store = FanLeaseStore(directory: temporaryDirectory("restore-duplicate-captured-fan"))
    let capturedFans = [
        CapturedFanState(index: 0, modeRaw: [activeTestCapability().managedObservedState], targetRaw: FanEncoding.float32LittleEndian(0)),
        CapturedFanState(index: 0, modeRaw: [activeTestCapability().managedObservedState], targetRaw: FanEncoding.float32LittleEndian(0)),
        CapturedFanState(index: 1, modeRaw: [activeTestCapability().managedObservedState], targetRaw: FanEncoding.float32LittleEndian(0))
    ]
    let lease = try installBoostedLeaseState(smc: smc, store: store, capturedFans: capturedFans)
    let controller = restoreController(smc: smc, store: store)

    try expectThrows("restore should reject duplicate captured fan before writes", {
        _ = try controller.restoreAuto(reason: "duplicate fan")
    }, matching: { error in
        guard case .restoreFailed(let message) = error as? FanControlError else { return false }
        return message.contains("duplicate")
    })

    try expect(smc.writes.isEmpty, "duplicate captured fan restore should not write hardware")
    try expect(try store.readIfPresent() == lease, "duplicate captured fan restore should not clear lease")
}

func testRestoreMissingCapturedFanFailsClosedBeforeWritingOrClearingLease() throws {
    let smc = FakeSMC.mac165()
    let store = FanLeaseStore(directory: temporaryDirectory("restore-missing-captured-fan"))
    let capturedFans = [
        CapturedFanState(index: 0, modeRaw: [activeTestCapability().managedObservedState], targetRaw: FanEncoding.float32LittleEndian(0))
    ]
    let lease = try installBoostedLeaseState(smc: smc, store: store, capturedFans: capturedFans)
    let controller = restoreController(smc: smc, store: store)

    try expectThrows("restore should reject missing captured fan before writes", {
        _ = try controller.restoreAuto(reason: "missing fan")
    }, matching: { error in
        guard case .restoreFailed(let message) = error as? FanControlError else { return false }
        return message.contains("captured fan indices")
    })

    try expect(smc.writes.isEmpty, "missing captured fan restore should not write hardware")
    try expect(try store.readIfPresent() == lease, "missing captured fan restore should not clear lease")
}

func testRestoreEmptyCapturedTargetFailsClosedBeforeWritingOrClearingLease() throws {
    let smc = FakeSMC.mac165()
    let store = FanLeaseStore(directory: temporaryDirectory("restore-empty-captured-target"))
    let lease = try installBoostedLeaseState(smc: smc, store: store, capturedTargetRaw: [])
    let controller = restoreController(smc: smc, store: store)

    try expectThrows("restore should reject empty captured target before writes", {
        _ = try controller.restoreAuto(reason: "empty target")
    }, matching: { error in
        guard case .restoreFailed(let message) = error as? FanControlError else { return false }
        return message.contains("captured target")
    })

    try expect(smc.writes.isEmpty, "empty captured target restore should not write hardware")
    try expect(try store.readIfPresent() == lease, "empty captured target restore should not clear lease")
}

func testRestoreNaNCapturedTargetFailsClosedBeforeWritingOrClearingLease() throws {
    let smc = FakeSMC.mac165()
    let store = FanLeaseStore(directory: temporaryDirectory("restore-nan-captured-target"))
    let lease = try installBoostedLeaseState(smc: smc, store: store, capturedTargetRaw: FanEncoding.float32LittleEndian(.nan))
    let controller = restoreController(smc: smc, store: store)

    try expectThrows("restore should reject NaN captured target before writes", {
        _ = try controller.restoreAuto(reason: "nan target")
    }, matching: { error in
        guard case .restoreFailed(let message) = error as? FanControlError else { return false }
        return message.contains("captured target")
    })

    try expect(smc.writes.isEmpty, "NaN captured target restore should not write hardware")
    try expect(try store.readIfPresent() == lease, "NaN captured target restore should not clear lease")
}

func testRestoreAboveMaximumCapturedTargetFailsClosedBeforeWritingOrClearingLease() throws {
    try expectMalformedCapturedLeaseFailsClosedBeforeWritingOrClearingLease(
        directoryName: "restore-above-maximum-captured-target",
        capturedFans: capturedFans(modeRaw: [activeTestCapability().managedObservedState], targetRaw: FanEncoding.float32LittleEndian(6_000)),
        restoreReason: "above maximum target",
        expectedMessage: "captured target"
    )
}

func testRestoreNegativeCapturedTargetFailsClosedBeforeWritingOrClearingLease() throws {
    try expectMalformedCapturedLeaseFailsClosedBeforeWritingOrClearingLease(
        directoryName: "restore-negative-captured-target",
        capturedFans: capturedFans(modeRaw: [activeTestCapability().managedObservedState], targetRaw: FanEncoding.float32LittleEndian(-1)),
        restoreReason: "negative target",
        expectedMessage: "captured target"
    )
}

func testRestoreBelowMinimumNonzeroCapturedTargetFailsClosedBeforeWritingOrClearingLease() throws {
    try expectMalformedCapturedLeaseFailsClosedBeforeWritingOrClearingLease(
        directoryName: "restore-below-minimum-captured-target",
        capturedFans: capturedFans(modeRaw: [activeTestCapability().managedObservedState], targetRaw: FanEncoding.float32LittleEndian(1_000)),
        restoreReason: "below minimum target",
        expectedMessage: "captured target"
    )
}

func testRestoreEmptyCapturedModeFailsClosedBeforeWritingOrClearingLease() throws {
    try expectMalformedCapturedLeaseFailsClosedBeforeWritingOrClearingLease(
        directoryName: "restore-empty-captured-mode",
        capturedFans: capturedFans(modeRaw: [], targetRaw: FanEncoding.float32LittleEndian(0)),
        restoreReason: "empty mode",
        expectedMessage: "captured mode"
    )
}

func testRestoreManualCapturedModeFailsClosedBeforeWritingOrClearingLease() throws {
    try expectMalformedCapturedLeaseFailsClosedBeforeWritingOrClearingLease(
        directoryName: "restore-manual-captured-mode",
        capturedFans: capturedFans(modeRaw: [activeTestCapability().manualCommand], targetRaw: FanEncoding.float32LittleEndian(0)),
        restoreReason: "manual mode",
        expectedMessage: "captured mode"
    )
}

func testRestoreConvergesFromPartialRollbackState() throws {
    let smc = FakeSMC.mac165()
    let store = FanLeaseStore(directory: temporaryDirectory("restore-partial-rollback"))
    _ = try installPartialRollbackLeaseState(smc: smc, store: store, capturedTargetRaw: FanEncoding.float32LittleEndian(0))
    let controller = restoreController(smc: smc, store: store)

    let result = try controller.restoreAuto(reason: "partial rollback")

    try expect(result.restored, "partial rollback restore should report restored")
    try expect(result.finalModes == [activeTestCapability().managedObservedState, activeTestCapability().managedObservedState], "partial rollback restore should converge both fans to managed")
    try expect(result.finalTargets == [0, 0], "partial rollback restore should converge both fans to captured target")
    try expect(try store.readIfPresent() == nil, "partial rollback restore should clear lease after convergence")
}

func testRestoreAuditsRejectedWritesBeforeThrowing() throws {
    let smc = FakeSMC.mac165()
    let store = FanLeaseStore(directory: temporaryDirectory("restore-rejected-write-audit"))
    let logger = InMemoryFanControlLogger()
    let lease = try installBoostedLeaseState(smc: smc, store: store)
    smc.rejectWrite(operation: .mode(fan: 1, value: activeTestCapability().releaseCommand), key: "F1Md", smcResult: 0x84)
    let controller = restoreController(smc: smc, store: store, logger: logger)

    try expectThrows("restore should throw rejected release write", {
        _ = try controller.restoreAuto(reason: "rejected release")
    }, matching: { error in
        error as? FanControlError == .writeRejected(key: "F1Md", smcResult: 0x84)
    })

    guard let rejected = logger.events.first(where: { $0.key == "F1Md" && $0.smcResult == 0x84 }) else {
        throw TestFailure(description: "rejected restore write should be audited before throw")
    }
    try expect(rejected.leaseID == lease.id, "rejected restore write audit should include lease ID")
    try expect(try store.readIfPresent() == lease, "rejected restore should leave lease for later recovery")
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
        .appendingPathComponent("coldfront-fan-control-tests", isDirectory: true)
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

func restoreController(
    smc: FakeSMC,
    store: FanLeaseStore,
    capability: FanCapability = activeTestCapability(),
    clock: FanControlClock? = nil,
    logger: InMemoryFanControlLogger = InMemoryFanControlLogger()
) -> FanController {
    FanController(
        hardware: smc,
        capability: capability,
        clock: clock ?? TestClock(onSleep: { smc.advanceTick() }),
        logger: logger,
        leaseStore: store,
        processInspector: TestProcessInspector(ownerProcesses: [:])
    )
}

func capturedFans(modeRaw: [UInt8], targetRaw: [UInt8]) -> [CapturedFanState] {
    (0..<activeTestCapability().fanCount).map {
        CapturedFanState(index: $0, modeRaw: modeRaw, targetRaw: targetRaw)
    }
}

func expectMalformedCapturedLeaseFailsClosedBeforeWritingOrClearingLease(
    directoryName: String,
    capturedFans: [CapturedFanState],
    restoreReason: String,
    expectedMessage: String
) throws {
    let smc = FakeSMC.mac165()
    let store = FanLeaseStore(directory: temporaryDirectory(directoryName))
    let lease = try installBoostedLeaseState(smc: smc, store: store, capturedFans: capturedFans)
    let controller = restoreController(smc: smc, store: store)

    try expectThrows("restore should reject \(restoreReason) before writes", {
        _ = try controller.restoreAuto(reason: restoreReason)
    }, matching: { error in
        guard case .restoreFailed(let message) = error as? FanControlError else { return false }
        return message.contains(expectedMessage)
    })

    try expect(smc.writes.isEmpty, "\(restoreReason) restore should not write hardware")
    try expect(try store.readIfPresent() == lease, "\(restoreReason) restore should not clear lease")
}

@discardableResult
func installBoostedLeaseState(
    smc: FakeSMC,
    store: FanLeaseStore,
    capabilityFingerprint: String = activeTestCapability().fingerprint,
    capturedTargetRaw: [UInt8] = FanEncoding.float32LittleEndian(0),
    actualRPM: Float = 5_777,
    capturedFans: [CapturedFanState]? = nil
) throws -> FanLease {
    let maxBytes = FanEncoding.float32LittleEndian(5_777)
    smc.setRawEntryBytes("Ftst", [activeTestCapability().unlockOn])
    for fan in 0..<activeTestCapability().fanCount {
        smc.setRawEntryBytes("F\(fan)Md", [activeTestCapability().manualCommand])
        smc.setRawEntryBytes("F\(fan)Tg", maxBytes)
        smc.setRawEntryBytes("F\(fan)Ac", FanEncoding.float32LittleEndian(actualRPM))
    }
    let lease = testLease(
        capabilityFingerprint: capabilityFingerprint,
        phase: .boosted,
        capturedFans: capturedFans ?? (0..<activeTestCapability().fanCount).map {
            CapturedFanState(index: $0, modeRaw: [activeTestCapability().managedObservedState], targetRaw: capturedTargetRaw)
        }
    )
    try store.claim(lease)
    smc.clearWrites()
    return lease
}

@discardableResult
func installPartialRollbackLeaseState(
    smc: FakeSMC,
    store: FanLeaseStore,
    capturedTargetRaw: [UInt8]
) throws -> FanLease {
    let maxBytes = FanEncoding.float32LittleEndian(5_777)
    smc.setRawEntryBytes("Ftst", [activeTestCapability().unlockOff])
    smc.setRawEntryBytes("F0Md", [activeTestCapability().manualCommand])
    smc.setRawEntryBytes("F0Tg", maxBytes)
    smc.setRawEntryBytes("F0Ac", maxBytes)
    _ = try smc.write(.mode(fan: 0, value: activeTestCapability().releaseCommand), capability: activeTestCapability(), reason: "pre-settled partial release")
    for _ in 0..<4 { smc.advanceTick() }
    smc.setRawEntryBytes("F1Md", [activeTestCapability().manualCommand])
    smc.setRawEntryBytes("F1Tg", maxBytes)
    smc.setRawEntryBytes("F1Ac", maxBytes)
    let lease = testLease(
        phase: .boosted,
        capturedFans: (0..<activeTestCapability().fanCount).map {
            CapturedFanState(index: $0, modeRaw: [activeTestCapability().managedObservedState], targetRaw: capturedTargetRaw)
        }
    )
    try store.claim(lease)
    smc.clearWrites()
    return lease
}

func restoreHardwareSettled(_ smc: FakeSMC) -> Bool {
    guard smc.rawEntryBytes("Ftst") == [activeTestCapability().unlockOff] else { return false }
    for fan in 0..<activeTestCapability().fanCount {
        guard smc.rawEntryBytes("F\(fan)Md") == [activeTestCapability().managedObservedState],
              smc.rawEntryBytes("F\(fan)Tg") == FanEncoding.float32LittleEndian(0),
              let actualBytes = smc.rawEntryBytes("F\(fan)Ac"),
              let minimumBytes = smc.rawEntryBytes("F\(fan)Mn"),
              let actual = FanEncoding.floatValue(actualBytes),
              let minimum = FanEncoding.floatValue(minimumBytes),
              actual <= minimum
        else {
            return false
        }
    }
    return true
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
    ("Read-only CSMC header has no write API", testReadOnlyCSMCHeaderHasNoWriteAPI),
    ("SMCControlTransport has no public raw write API", testSMCControlTransportHasNoPublicRawWriteAPI),
    ("SMCControlTransport exposes package FanHardware only", testSMCControlTransportExposesPackageFanHardwareOnly),
    ("SMCControlTransport keeps raw write private", testSMCControlTransportKeepsRawWritePrivate),
    ("SMCControlTransport writes only typed operations from capability", testSMCControlTransportWritesOnlyTypedOperationsFromCapability),
    ("SMCControlTransport SMCKeyData ABI layout", testSMCControlTransportKeyDataABILayout),
    ("Package defines single coldfront executable", testPackageDefinesSingleColdfrontExecutable),
    ("Coldfront executable no longer routes boost through disabled gate", testColdfrontExecutableNoLongerRoutesBoostThroughDisabledGate),
    ("Coldfront executable dispatches boost and auto to controller", testColdfrontExecutableDispatchesBoostAndAutoToController),
    ("Disabled active-control response fails boost command", testActiveControlResponseFailsBoostCommandWhenExplicitlyDisabled),
    ("Disabled status JSON response is parseable", testDisabledStatusJSONResponseIsParseable),
    ("Coldfront executable status JSON reports enabled flags", testControlExecutableStatusJSONReportsEnabledFlags),
    ("README documents boost and auto commands", testReadmeDocumentsBoostAndAutoCommands),
    ("CLI parses bounded boost duration", testCLIParsesBoundedBoostDuration),
    ("CLI parses status JSON", testCLIParsesStatusJSON),
    ("CLI parses auto", testCLIParsesAuto),
    ("CLI parses ten second validation", testCLIParsesTenSecondValidationOneShot),
    ("CLI rejects validation over ten seconds", testCLIRejectsValidationOneShotOverTenSeconds),
    ("CLI uses default boost duration", testCLIUsesDefaultBoostDuration),
    ("CLI rejects missing acknowledgement", testCLIRejectsMissingAcknowledgement),
    ("CLI rejects lease over two hours", testCLIRejectsLeaseOverTwoHours),
    ("CLI rejects run command", testCLIRejectsRunCommand),
    ("CLI rejects unknown duration unit", testCLIRejectsUnknownDurationUnit),
    ("CLI rejects zero duration", testCLIRejectsZeroDuration),
    ("CLI rejects negative duration", testCLIRejectsNegativeDuration),
    ("Mac16,5 capability", testMac165Capability),
    ("Mac17,7 capability", testMac177Capability),
    ("Resolver succeeds for validated Mac16,5 inventory", testResolverSucceedsForValidatedMac165Inventory),
    ("Resolver succeeds for validated Mac17,7 inventory", testResolverSucceedsForValidatedMac177Inventory),
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
    ("Status Mac17,7 does not require Ftst for active control", testStatusMac177DoesNotRequireFtstForActiveControl),
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
    ("Boost clears lease when first write rejected", testBoostClearsLeaseWhenFirstWriteRejected),
    ("Boost retries transient manual mode rejection", testBoostRetriesTransientManualModeRejection),
    ("Boost refuses preexisting unlock before lease claim", testBoostRefusesPreexistingUnlockBeforeLeaseClaim),
    ("Boost audits and rejects nonzero kernReturn before rollback", testBoostAuditsAndRejectsNonzeroKernReturnBeforeRollback),
    ("Boost uses hardware validated sequence", testBoostUsesHardwareValidatedSequence),
    ("Boost uses Mac17,7 lowercase mode sequence without pre-manual readback", testBoostUsesMac177LowercaseModeSequenceWithoutPreManualReadback),
    ("Boost refuses when active control disabled", testBoostRefusesWhenActiveControlDisabled),
    ("Restore uses captured lease targets not current targets", testRestoreUsesCapturedLeaseTargetsNotCurrentTargets),
    ("Restore never clears target while manual", testRestoreNeverClearsTargetWhileManual),
    ("Restore clears lease only after managed settle", testRestoreClearsLeaseOnlyAfterManagedSettle),
    ("Restore noops when no lease exists", testAutoNoopsWhenNoLeaseExists),
    ("Restore recovery mode requires lease", testRestoreRecoveryModeRequiresLease),
    ("Restore fingerprint mismatch does not write or clear lease", testRestoreFingerprintMismatchDoesNotWriteOrClearLease),
    ("Restore corrupt lease fails closed without clearing", testRestoreCorruptLeaseFailsClosedWithoutClearing),
    ("Restore low FNum fails closed before writing or clearing lease", testRestoreLowFNumFailsClosedBeforeWritingOrClearingLease),
    ("Restore extra captured fan fails closed before writing or clearing lease", testRestoreExtraCapturedFanFailsClosedBeforeWritingOrClearingLease),
    ("Restore duplicate captured fan fails closed before writing or clearing lease", testRestoreDuplicateCapturedFanFailsClosedBeforeWritingOrClearingLease),
    ("Restore missing captured fan fails closed before writing or clearing lease", testRestoreMissingCapturedFanFailsClosedBeforeWritingOrClearingLease),
    ("Restore empty captured target fails closed before writing or clearing lease", testRestoreEmptyCapturedTargetFailsClosedBeforeWritingOrClearingLease),
    ("Restore NaN captured target fails closed before writing or clearing lease", testRestoreNaNCapturedTargetFailsClosedBeforeWritingOrClearingLease),
    ("Restore above-maximum captured target fails closed before writing or clearing lease", testRestoreAboveMaximumCapturedTargetFailsClosedBeforeWritingOrClearingLease),
    ("Restore negative captured target fails closed before writing or clearing lease", testRestoreNegativeCapturedTargetFailsClosedBeforeWritingOrClearingLease),
    ("Restore below-minimum nonzero captured target fails closed before writing or clearing lease", testRestoreBelowMinimumNonzeroCapturedTargetFailsClosedBeforeWritingOrClearingLease),
    ("Restore empty captured mode fails closed before writing or clearing lease", testRestoreEmptyCapturedModeFailsClosedBeforeWritingOrClearingLease),
    ("Restore manual captured mode fails closed before writing or clearing lease", testRestoreManualCapturedModeFailsClosedBeforeWritingOrClearingLease),
    ("Restore converges from partial rollback state", testRestoreConvergesFromPartialRollbackState),
    ("Restore audits rejected writes before throwing", testRestoreAuditsRejectedWritesBeforeThrowing)
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
