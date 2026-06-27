import FanControlCore
import Foundation
import IOKit

private let kernelIndexSMC: UInt32 = 2
private let smcCommandReadBytes: UInt8 = 5
private let smcCommandWriteBytes: UInt8 = 6
private let smcCommandReadKeyInfo: UInt8 = 9

private struct SMCKeyDataVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

private struct SMCKeyDataPLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

private struct SMCKeyDataKeyInfo {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}

private struct SMCKeyData {
    var key: UInt32 = 0
    var version = SMCKeyDataVersion()
    var pLimitData = SMCKeyDataPLimitData()
    var keyInfo = SMCKeyDataKeyInfo()
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes = SMCBytes()
}

private struct SMCBytes {
    var byte0: UInt8 = 0
    var byte1: UInt8 = 0
    var byte2: UInt8 = 0
    var byte3: UInt8 = 0
    var byte4: UInt8 = 0
    var byte5: UInt8 = 0
    var byte6: UInt8 = 0
    var byte7: UInt8 = 0
    var byte8: UInt8 = 0
    var byte9: UInt8 = 0
    var byte10: UInt8 = 0
    var byte11: UInt8 = 0
    var byte12: UInt8 = 0
    var byte13: UInt8 = 0
    var byte14: UInt8 = 0
    var byte15: UInt8 = 0
    var byte16: UInt8 = 0
    var byte17: UInt8 = 0
    var byte18: UInt8 = 0
    var byte19: UInt8 = 0
    var byte20: UInt8 = 0
    var byte21: UInt8 = 0
    var byte22: UInt8 = 0
    var byte23: UInt8 = 0
    var byte24: UInt8 = 0
    var byte25: UInt8 = 0
    var byte26: UInt8 = 0
    var byte27: UInt8 = 0
    var byte28: UInt8 = 0
    var byte29: UInt8 = 0
    var byte30: UInt8 = 0
    var byte31: UInt8 = 0

    init() {}

    init(_ bytes: [UInt8]) {
        self.init()
        withUnsafeMutableBytes(of: &self) { buffer in
            for (index, byte) in bytes.prefix(32).enumerated() {
                buffer[index] = byte
            }
        }
    }

    func array(prefix count: Int) -> [UInt8] {
        var copy = self
        return withUnsafeBytes(of: &copy) { buffer in
            Array(buffer.prefix(count))
        }
    }
}

private struct SMCKeyInfo {
    let dataSize: UInt32
    let dataType: UInt32
    let dataAttributes: UInt8
}

private struct SMCControlTransportError: Error, CustomStringConvertible {
    let description: String
}

package final class SMCFanHardware: FanHardware {
    package let serviceName: String
    private let connection: io_connect_t

    package init() throws {
        let opened = try Self.openConnection()
        serviceName = opened.serviceName
        connection = opened.connection
    }

    deinit {
        IOServiceClose(connection)
    }

    package func read(_ key: FanKey) throws -> FanReading {
        let keyInfo = try readKeyInfo(key)
        try validateSMCSize(keyInfo.dataSize, key: key)

        var input = SMCKeyData()
        input.key = key.rawValue
        input.keyInfo.dataSize = keyInfo.dataSize
        input.data8 = smcCommandReadBytes

        let callResult = rawCall(input)
        guard callResult.kernReturn == KERN_SUCCESS else {
            throw FanControlError.invalidReading(key: key.stringValue, reason: "SMC read failed: kernReturn \(callResult.kernReturn)")
        }
        guard callResult.output.result == 0 else {
            throw FanControlError.invalidReading(key: key.stringValue, reason: "SMC read rejected: 0x\(String(format: "%02X", callResult.output.result))")
        }

        return FanReading(
            key: key,
            type: fourCCString(keyInfo.dataType),
            size: keyInfo.dataSize,
            attributes: keyInfo.dataAttributes,
            bytes: callResult.output.bytes.array(prefix: Int(keyInfo.dataSize))
        )
    }

    package func write(_ operation: FanWriteOperation, capability: FanCapability, reason: String) throws -> FanWriteResult {
        switch operation {
        case .unlock(let value):
            guard capability.unlockAvailable else {
                throw FanControlError.unsafeState("unlock key unavailable")
            }
            return try privateWrite(key: capability.unlockKey, bytes: [value])

        case .mode(let fan, let value):
            try validateFanIndex(fan, capability: capability)
            return try privateWrite(key: try capability.modeKey(for: fan), bytes: [value])

        case .target(let fan, let bytes):
            try validateFanIndex(fan, capability: capability)
            return try privateWrite(key: try capability.targetKey(for: fan), bytes: bytes)
        }
    }

    private func privateWrite(key: FanKey, bytes: [UInt8]) throws -> FanWriteResult {
        let keyInfo = try readKeyInfo(key)
        try validateSMCSize(keyInfo.dataSize, key: key)
        guard keyInfo.dataSize == UInt32(bytes.count) else {
            throw FanControlError.invalidReading(
                key: key.stringValue,
                reason: "write size mismatch: key size \(keyInfo.dataSize), requested \(bytes.count)"
            )
        }

        var input = SMCKeyData()
        input.key = key.rawValue
        input.keyInfo.dataSize = keyInfo.dataSize
        input.keyInfo.dataType = keyInfo.dataType
        input.keyInfo.dataAttributes = keyInfo.dataAttributes
        input.data8 = smcCommandWriteBytes
        input.bytes = SMCBytes(bytes)

        let callResult = rawCall(input)
        return FanWriteResult(
            kernReturn: Int32(callResult.kernReturn),
            smcResult: callResult.output.result,
            smcStatus: callResult.output.status
        )
    }

    private func readKeyInfo(_ key: FanKey) throws -> SMCKeyInfo {
        var input = SMCKeyData()
        input.key = key.rawValue
        input.data8 = smcCommandReadKeyInfo

        let callResult = rawCall(input)
        guard callResult.kernReturn == KERN_SUCCESS else {
            throw FanControlError.invalidReading(key: key.stringValue, reason: "SMC key info failed: kernReturn \(callResult.kernReturn)")
        }
        guard callResult.output.result == 0 else {
            throw FanControlError.missingKey(key.stringValue)
        }

        return SMCKeyInfo(
            dataSize: callResult.output.keyInfo.dataSize,
            dataType: callResult.output.keyInfo.dataType,
            dataAttributes: callResult.output.keyInfo.dataAttributes
        )
    }

    private func rawCall(_ input: SMCKeyData) -> (kernReturn: kern_return_t, output: SMCKeyData) {
        var input = input
        var output = SMCKeyData()
        var outputSize = MemoryLayout<SMCKeyData>.size
        let kernReturn = withUnsafePointer(to: &input) { inputPointer in
            withUnsafeMutablePointer(to: &output) { outputPointer in
                IOConnectCallStructMethod(
                    connection,
                    kernelIndexSMC,
                    inputPointer,
                    MemoryLayout<SMCKeyData>.size,
                    outputPointer,
                    &outputSize
                )
            }
        }
        return (kernReturn, output)
    }

    private func validateFanIndex(_ fan: Int, capability: FanCapability) throws {
        guard fan >= 0 && fan < capability.fanCount else {
            throw FanControlError.unsafeState("unsupported fan index \(fan)")
        }
    }

    private func validateSMCSize(_ size: UInt32, key: FanKey) throws {
        guard size <= 32 else {
            throw FanControlError.invalidReading(key: key.stringValue, reason: "SMC key size \(size) exceeds 32 bytes")
        }
    }

    private static func openConnection() throws -> (serviceName: String, connection: io_connect_t) {
        let serviceNames = ["AppleSMC", "AppleSMCKeysEndpoint"]
        var lastResult: kern_return_t = kIOReturnNotFound

        for serviceName in serviceNames {
            guard let matching = IOServiceMatching(serviceName) else {
                continue
            }

            let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
            guard service != IO_OBJECT_NULL else {
                continue
            }
            defer { IOObjectRelease(service) }

            var connection: io_connect_t = IO_OBJECT_NULL
            lastResult = IOServiceOpen(service, mach_task_self_, 0, &connection)
            if lastResult == KERN_SUCCESS {
                return (serviceName, connection)
            }
        }

        throw SMCControlTransportError(description: "failed to open AppleSMC user client: \(lastResult)")
    }
}

private func fourCCString(_ value: UInt32) -> String {
    let bytes: [UInt8] = [
        UInt8((value >> 24) & 0xFF),
        UInt8((value >> 16) & 0xFF),
        UInt8((value >> 8) & 0xFF),
        UInt8(value & 0xFF)
    ]
    return String(bytes: bytes, encoding: .ascii) ?? "????"
}
