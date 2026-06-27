public enum FanControlCommand: Equatable, Sendable {
    case statusJSON
    case boostMax(durationSeconds: Int, acknowledgedRisk: Bool)
    case auto
    case runBoostMax(durationSeconds: Int, workload: [String], acknowledgedRisk: Bool)
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
            guard args.count >= 2, args[1] == "max" else {
                throw FanControlCommandParseError.usage("expected: boost max [--for duration] --i-understand-active-fan-control")
            }
            let options = try parseBoostOptions(Array(args.dropFirst(2)), maxDurationSeconds: maxDurationSeconds)
            return .boostMax(durationSeconds: options.durationSeconds, acknowledgedRisk: options.acknowledgedRisk)

        case "run":
            guard args.count >= 3, args[1] == "--boost", args[2] == "max" else {
                throw FanControlCommandParseError.usage("expected: run --boost max [--for duration] --i-understand-active-fan-control -- <workload...>")
            }
            guard let delimiterIndex = args.dropFirst(3).firstIndex(of: "--") else {
                throw FanControlCommandParseError.missingRunDelimiter
            }
            let controlArgs = Array(args[3..<delimiterIndex])
            let workload = Array(args[(delimiterIndex + 1)...])
            guard !workload.isEmpty else {
                throw FanControlCommandParseError.emptyWorkload
            }
            let options = try parseBoostOptions(controlArgs, maxDurationSeconds: maxDurationSeconds)
            return .runBoostMax(
                durationSeconds: options.durationSeconds,
                workload: workload,
                acknowledgedRisk: options.acknowledgedRisk
            )

        case "validate":
            guard args.count >= 2, args[1] == "one-shot" else {
                throw FanControlCommandParseError.usage("expected: validate one-shot [--for 10s] --i-understand-active-fan-control")
            }
            let options = try parseBoostOptions(
                Array(args.dropFirst(2)),
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
            case "--i-understand-active-fan-control":
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
    case missingRunDelimiter
    case emptyWorkload
    case unknownArgument(String)

    public var description: String {
        switch self {
        case .usage(let message):
            return "usage error: \(message)"
        case .missingAcknowledgement:
            return "missing required acknowledgement: --i-understand-active-fan-control"
        case .missingDurationValue:
            return "missing duration after --for"
        case .invalidDuration(let value):
            return "invalid duration: \(value) (expected a positive integer ending in s or m)"
        case .durationOutOfBounds(let seconds, let maxSeconds):
            return "duration \(seconds)s exceeds maximum \(maxSeconds)s"
        case .missingRunDelimiter:
            return "missing run workload delimiter: --"
        case .emptyWorkload:
            return "run workload must not be empty"
        case .unknownArgument(let argument):
            return "unknown argument: \(argument)"
        }
    }
}
