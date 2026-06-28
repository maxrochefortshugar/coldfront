import Foundation

public struct HostIdentity: Equatable, Sendable {
    public let model: String
    public let platform: String

    public init(model: String, platform: String) {
        self.model = model
        self.platform = platform
    }
}

public struct FanCapabilityResolver {
    private let hardware: FanReader
    private let hostModel: () -> String

    public init(hardware: FanReader, hostModel: @escaping () -> String) {
        self.hardware = hardware
        self.hostModel = hostModel
    }

    public func resolve() throws -> FanCapability {
        let platform = try ascii(try hardware.read(FanCapability.mac165ValidatedOneShot.platformKey))
        let model = hostModel()
        guard let base = FanCapability.allowlist.first(where: { $0.model == model && $0.platform == platform }) else {
            throw FanControlError.unsupportedModel(model: model, platform: platform)
        }

        let fanCount = Int(try uint8(try hardware.read(base.fanCountKey)))
        guard fanCount == base.fanCount else {
            throw FanControlError.unsafeState("fan count mismatch: expected \(base.fanCount), got \(fanCount)")
        }

        if base.modeKeyFormat != "F%dmd", try probeReadable(String(format: "F%dmd", 0)) {
            throw FanControlError.unsupportedModel(model: model, platform: "lowercase mode key path not validated")
        }
        _ = try hardware.read(base.modeKey(for: 0))
        if base.unlockAvailable {
            _ = try hardware.read(base.unlockKey)
        }

        for index in 0..<fanCount {
            _ = try hardware.read(base.actualKey(for: index))
            _ = try hardware.read(base.minimumKey(for: index))
            _ = try hardware.read(base.maximumKey(for: index))
            _ = try hardware.read(base.targetKey(for: index))
            _ = try hardware.read(base.modeKey(for: index))
        }

        return base.withResolvedHardware(modeKeyFormat: base.modeKeyFormat, unlockAvailable: base.unlockAvailable)
    }

    private func probeReadable(_ key: String) throws -> Bool {
        do {
            _ = try hardware.read(try FanKey(key))
            return true
        } catch {
            return false
        }
    }

    private func ascii(_ reading: FanReading) throws -> String {
        guard let value = String(bytes: reading.bytes.prefix { $0 != 0 }, encoding: .ascii) else {
            throw FanControlError.invalidReading(key: reading.key.stringValue, reason: "not ASCII")
        }
        return value
    }

    private func uint8(_ reading: FanReading) throws -> UInt8 {
        guard let value = reading.bytes.first else {
            throw FanControlError.invalidReading(key: reading.key.stringValue, reason: "missing ui8 byte")
        }
        return value
    }
}
