import Foundation

public struct FanControlCommandResponse: Equatable, Sendable {
    public let stdout: String
    public let exitCode: Int32

    public init(stdout: String, exitCode: Int32) {
        self.stdout = stdout
        self.exitCode = exitCode
    }
}

public enum FanControlCommandContract {
    public static func disabledActiveControlResponse(
        for command: FanControlCommand,
        capability: FanCapability
    ) throws -> FanControlCommandResponse {
        switch command {
        case .boostMax:
            return FanControlCommandResponse(
                stdout: "\(disabledActiveControlMessage(model: capability.model))\n",
                exitCode: 1
            )

        case .statusJSON:
            return FanControlCommandResponse(
                stdout: "\(try disabledStatusJSON(capability: capability))\n",
                exitCode: 0
            )

        case .auto:
            throw FanControlCommandContractError.unsupportedDisabledActiveControlCommand("auto")

        case .validateOneShot:
            throw FanControlCommandContractError.unsupportedDisabledActiveControlCommand("validate")
        }
    }

    public static func disabledStatusJSON(capability: FanCapability) throws -> String {
        let payload = DisabledStatusJSON(
            model: capability.model,
            activeControlEnabled: false,
            boostExecutionEnabled: false,
            recoveryExecutionEnabled: false,
            reason: "active_control_disabled",
            message: disabledActiveControlMessage(model: capability.model)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)
        return String(decoding: data, as: UTF8.self)
    }

    public static func disabledActiveControlMessage(model: String) -> String {
        "active fan control is disabled for \(model)"
    }
}

private struct DisabledStatusJSON: Encodable {
    let model: String
    let activeControlEnabled: Bool
    let boostExecutionEnabled: Bool
    let recoveryExecutionEnabled: Bool
    let reason: String
    let message: String
}

public enum FanControlCommandContractError: Error, Equatable, Sendable, CustomStringConvertible {
    case unsupportedDisabledActiveControlCommand(String)

    public var description: String {
        switch self {
        case .unsupportedDisabledActiveControlCommand(let command):
            return "unsupported disabled active-control command: \(command)"
        }
    }
}
