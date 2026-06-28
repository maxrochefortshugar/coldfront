public enum FanControlCommand: Equatable, Sendable {
    case statusJSON
    case boostMax(durationSeconds: Int, acknowledgedRisk: Bool)
    case auto
    case validateOneShot(durationSeconds: Int, acknowledgedRisk: Bool)

    public static func parse(_ args: [String], maxDurationSeconds: Int = 7_200) throws -> FanControlCommand {
        guard let first = args.first else {
            throw FanControlCommandParseError.usage("expected a fan-control command")
        }

        switch first {
        case "status":
            guard args == ["status", "--json"] else {
                throw FanControlCommandParseError.usage("expected: status --json")
            }
            return .statusJSON

        case "auto":
            guard args.count == 1 else {
                throw FanControlCommandParseError.usage("expected: auto")
            }
            return .auto

        case "boost":
            let options = try parseBoostOptions(Array(args.dropFirst()), maxDurationSeconds: maxDurationSeconds)
            return .boostMax(durationSeconds: options.durationSeconds, acknowledgedRisk: options.acknowledgedRisk)

        case "validate":
            let options = try parseBoostOptions(
                Array(args.dropFirst()),
                maxDurationSeconds: 10,
                defaultDurationSeconds: 10
            )
            return .validateOneShot(durationSeconds: options.durationSeconds, acknowledgedRisk: options.acknowledgedRisk)

        default:
            throw FanControlCommandParseError.unknownArgument(first)
        }
    }

    private static func parseBoostOptions(
        _ args: [String],
        maxDurationSeconds: Int,
        defaultDurationSeconds: Int = 600
    ) throws -> (durationSeconds: Int, acknowledgedRisk: Bool) {
        var durationSeconds = defaultDurationSeconds
        var acknowledgedRisk = false
        var sawDuration = false
        var index = 0

        while index < args.count {
            switch args[index] {
            case "-y", "--yes":
                acknowledgedRisk = true
                index += 1

            case "--for":
                guard !sawDuration else {
                    throw FanControlCommandParseError.usage("--for may only be specified once")
                }
                guard index + 1 < args.count else {
                    throw FanControlCommandParseError.missingDurationValue
                }
                durationSeconds = try parseDuration(args[index + 1])
                guard durationSeconds <= maxDurationSeconds else {
                    throw FanControlCommandParseError.durationOutOfBounds(
                        seconds: durationSeconds,
                        maxSeconds: maxDurationSeconds
                    )
                }
                sawDuration = true
                index += 2

            default:
                throw FanControlCommandParseError.unknownArgument(args[index])
            }
        }

        guard acknowledgedRisk else {
            throw FanControlCommandParseError.missingAcknowledgement
        }
        guard durationSeconds <= maxDurationSeconds else {
            throw FanControlCommandParseError.durationOutOfBounds(
                seconds: durationSeconds,
                maxSeconds: maxDurationSeconds
            )
        }
        return (durationSeconds, acknowledgedRisk)
    }

    private static func parseDuration(_ value: String) throws -> Int {
        guard let unit = value.last, unit == "s" || unit == "m" else {
            throw FanControlCommandParseError.invalidDuration(value)
        }
        let numberText = String(value.dropLast())
        guard !numberText.isEmpty, numberText.allSatisfy(\.isNumber), let amount = Int(numberText), amount > 0 else {
            throw FanControlCommandParseError.invalidDuration(value)
        }

        if unit == "s" {
            return amount
        }

        let multiplied = amount.multipliedReportingOverflow(by: 60)
        guard !multiplied.overflow else {
            throw FanControlCommandParseError.invalidDuration(value)
        }
        return multiplied.partialValue
    }
}

public enum FanControlCommandParseError: Error, Equatable, Sendable, CustomStringConvertible {
    case usage(String)
    case missingAcknowledgement
    case missingDurationValue
    case invalidDuration(String)
    case durationOutOfBounds(seconds: Int, maxSeconds: Int)
    case unknownArgument(String)

    public var description: String {
        switch self {
        case .usage(let message):
            return "usage error: \(message)"
        case .missingAcknowledgement:
            return "missing required acknowledgement: -y or --yes"
        case .missingDurationValue:
            return "missing duration after --for"
        case .invalidDuration(let value):
            return "invalid duration: \(value) (expected a positive integer ending in s or m)"
        case .durationOutOfBounds(let seconds, let maxSeconds):
            return "duration \(seconds)s exceeds maximum \(maxSeconds)s"
        case .unknownArgument(let argument):
            return "unknown argument: \(argument)"
        }
    }
}
