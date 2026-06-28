import Foundation
import FanControlCore

struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

struct FakeFanReader: FanReader {
    var serviceName = "FakeFanReader"
    var readings: [String: FanReading]
    var failures: [String: Error] = [:]

    func read(_ key: FanKey) throws -> FanReading {
        let keyName = key.stringValue
        if let failure = failures[keyName] {
            throw failure
        }
        guard let reading = readings[keyName] else {
            throw FanControlError.missingKey(keyName)
        }
        return reading
    }
}

enum FakeFanReadError: Error, Equatable, CustomStringConvertible {
    case unreadable(String)

    var description: String {
        switch self {
        case .unreadable(let key): return "unreadable \(key)"
        }
    }
}

func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() {
        throw TestFailure(description: message)
    }
}

func expectThrows(_ message: String, _ body: () throws -> Void, matching isExpected: (Error) -> Bool) throws {
    do {
        try body()
    } catch {
        if isExpected(error) {
            return
        }
        throw TestFailure(description: "\(message): unexpected error \(error)")
    }
    throw TestFailure(description: "\(message): expected throw")
}

func repoRootFromThisFile() -> URL {
    var url = URL(fileURLWithPath: #filePath)
    while url.path != "/" {
        if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
            return url
        }
        url.deleteLastPathComponent()
    }
    return url
}

func fakeReading(_ key: String, bytes: [UInt8], type: String = "ui8") throws -> FanReading {
    FanReading(key: try FanKey(key), type: type, size: UInt32(bytes.count), attributes: 0, bytes: bytes)
}

func fakePlatformReading(_ value: String = "j616c") throws -> FanReading {
    try fakeReading("RPlt", bytes: Array(value.utf8) + [0], type: "{ch8*")
}

func fakeFanInventory(overrides: [String: FanReading] = [:], failures: [String: Error] = [:]) throws -> FakeFanReader {
    var readings: [String: FanReading] = [
        "RPlt": try fakePlatformReading(),
        "FNum": try fakeReading("FNum", bytes: [2]),
        "F0Md": try fakeReading("F0Md", bytes: [3]),
        "F1Md": try fakeReading("F1Md", bytes: [3]),
        "F0Ac": try fakeReading("F0Ac", bytes: [0, 0, 0, 0], type: "flt "),
        "F1Ac": try fakeReading("F1Ac", bytes: [0, 0, 0, 0], type: "flt "),
        "F0Mn": try fakeReading("F0Mn", bytes: [0, 0, 0, 0], type: "flt "),
        "F1Mn": try fakeReading("F1Mn", bytes: [0, 0, 0, 0], type: "flt "),
        "F0Mx": try fakeReading("F0Mx", bytes: [0, 0, 0, 0], type: "flt "),
        "F1Mx": try fakeReading("F1Mx", bytes: [0, 0, 0, 0], type: "flt "),
        "F0Tg": try fakeReading("F0Tg", bytes: [0, 0, 0, 0], type: "flt "),
        "F1Tg": try fakeReading("F1Tg", bytes: [0, 0, 0, 0], type: "flt "),
        "Ftst": try fakeReading("Ftst", bytes: [0])
    ]
    readings.merge(overrides) { _, new in new }
    return FakeFanReader(readings: readings, failures: failures)
}

func fakeMac177FanInventory(overrides: [String: FanReading] = [:], failures: [String: Error] = [:]) throws -> FakeFanReader {
    var readings: [String: FanReading] = [
        "RPlt": try fakePlatformReading("j714c"),
        "FNum": try fakeReading("FNum", bytes: [2]),
        "F0md": try fakeReading("F0md", bytes: [0]),
        "F1md": try fakeReading("F1md", bytes: [0]),
        "F0Ac": try fakeReading("F0Ac", bytes: [0, 0, 0, 0], type: "flt "),
        "F1Ac": try fakeReading("F1Ac", bytes: [0, 0, 0, 0], type: "flt "),
        "F0Mn": try fakeReading("F0Mn", bytes: [0, 0, 0, 0], type: "flt "),
        "F1Mn": try fakeReading("F1Mn", bytes: [0, 0, 0, 0], type: "flt "),
        "F0Mx": try fakeReading("F0Mx", bytes: [0, 0, 0, 0], type: "flt "),
        "F1Mx": try fakeReading("F1Mx", bytes: [0, 0, 0, 0], type: "flt "),
        "F0Tg": try fakeReading("F0Tg", bytes: [0, 0, 0, 0], type: "flt "),
        "F1Tg": try fakeReading("F1Tg", bytes: [0, 0, 0, 0], type: "flt ")
    ]
    readings.merge(overrides) { _, new in new }
    return FakeFanReader(readings: readings, failures: failures)
}

final class TestClock: FanControlClock {
    var nowUnix: TimeInterval
    private let onSleep: (() -> Void)?

    init(nowUnix: TimeInterval = 1_800_000_000, onSleep: (() -> Void)? = nil) {
        self.nowUnix = nowUnix
        self.onSleep = onSleep
    }

    func sleep(seconds: Double) {
        nowUnix += seconds
        onSleep?()
    }
}
