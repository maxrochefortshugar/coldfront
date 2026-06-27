import FanControlCore
import Foundation

final class FakeSMC: FanHardware {
    struct Entry {
        var type: String
        var size: UInt32
        var attributes: UInt8
        var bytes: [UInt8]
    }

    struct WriteEvent: Equatable {
        let operation: FanWriteOperation
        let key: String
        let bytes: [UInt8]
        let reason: String
        let kernReturn: Int32
        let smcResult: UInt8
        let smcStatus: UInt8
    }

    let serviceName = "FakeSMC"
    private(set) var writes: [WriteEvent] = []
    var onBeforeWrite: ((FanWriteOperation, String) -> Void)?
    private var entries: [String: Entry]
    private var tick = 0
    private var pending: [(applyAt: Int, key: String, bytes: [UInt8], releaseSettledFan: Int?)] = []
    private var scriptedRejections: [(operation: FanWriteOperation, key: String, result: FanWriteResult)] = []
    private var releaseSettledFans: Set<Int> = []

    init(entries: [String: Entry]) {
        self.entries = entries
    }

    static func mac165() -> FakeSMC {
        FakeSMC(entries: [
            "FNum": Entry(type: "ui8 ", size: 1, attributes: 0, bytes: [2]),
            "RPlt": Entry(type: "ch8*", size: 8, attributes: 0, bytes: Array("j616c".utf8) + [0, 0, 0]),
            "Ftst": Entry(type: "ui8 ", size: 1, attributes: 0, bytes: [0]),
            "F0Ac": Entry(type: "flt ", size: 4, attributes: 0, bytes: FanEncoding.float32LittleEndian(0)),
            "F0Mn": Entry(type: "flt ", size: 4, attributes: 0, bytes: FanEncoding.float32LittleEndian(1_350)),
            "F0Mx": Entry(type: "flt ", size: 4, attributes: 0, bytes: FanEncoding.float32LittleEndian(5_777)),
            "F0Tg": Entry(type: "flt ", size: 4, attributes: 0, bytes: FanEncoding.float32LittleEndian(0)),
            "F0Md": Entry(type: "ui8 ", size: 1, attributes: 0, bytes: [3]),
            "F1Ac": Entry(type: "flt ", size: 4, attributes: 0, bytes: FanEncoding.float32LittleEndian(0)),
            "F1Mn": Entry(type: "flt ", size: 4, attributes: 0, bytes: FanEncoding.float32LittleEndian(1_350)),
            "F1Mx": Entry(type: "flt ", size: 4, attributes: 0, bytes: FanEncoding.float32LittleEndian(5_777)),
            "F1Tg": Entry(type: "flt ", size: 4, attributes: 0, bytes: FanEncoding.float32LittleEndian(0)),
            "F1Md": Entry(type: "ui8 ", size: 1, attributes: 0, bytes: [3])
        ])
    }

    func advanceTick() {
        tick += 1
        let ready = pending.filter { $0.applyAt <= tick }
        pending.removeAll { $0.applyAt <= tick }
        for item in ready {
            entries[item.key]?.bytes = item.bytes
            if let fan = item.releaseSettledFan {
                releaseSettledFans.insert(fan)
            }
        }
        simulateRamp()
    }

    func read(_ key: FanKey) throws -> FanReading {
        guard let entry = entries[key.stringValue] else {
            throw FanControlError.missingKey(key.stringValue)
        }
        return FanReading(key: key, type: entry.type, size: entry.size, attributes: entry.attributes, bytes: entry.bytes)
    }

    func rejectWrite(operation: FanWriteOperation, key: String, smcResult: UInt8) {
        rejectWrite(operation: operation, key: key, kernReturn: 0, smcResult: smcResult, smcStatus: 0)
    }

    func rejectWrite(operation: FanWriteOperation, key: String, kernReturn: Int32, smcResult: UInt8, smcStatus: UInt8) {
        scriptedRejections.append((
            operation: operation,
            key: key,
            result: FanWriteResult(kernReturn: kernReturn, smcResult: smcResult, smcStatus: smcStatus)
        ))
    }

    func setRawEntryBytes(_ key: String, _ bytes: [UInt8]) {
        if var entry = entries[key] {
            entry.bytes = bytes
            entry.size = UInt32(bytes.count)
            entries[key] = entry
        } else {
            entries[key] = Entry(type: "raw ", size: UInt32(bytes.count), attributes: 0, bytes: bytes)
        }
    }

    func setEntry(_ key: String, type: String, size: UInt32, bytes: [UInt8]) {
        entries[key] = Entry(type: type, size: size, attributes: 0, bytes: bytes)
    }

    func removeEntry(_ key: String) {
        entries.removeValue(forKey: key)
    }

    func rawEntryBytes(_ key: String) -> [UInt8]? {
        entries[key]?.bytes
    }

    func write(_ operation: FanWriteOperation, capability: FanCapability, reason: String) throws -> FanWriteResult {
        let key: FanKey
        let bytes: [UInt8]
        switch operation {
        case .unlock(let value):
            key = capability.unlockKey
            bytes = [value]
        case .mode(let fan, let value):
            key = try capability.modeKey(for: fan)
            bytes = [value]
        case .target(let fan, let value):
            key = try capability.targetKey(for: fan)
            bytes = value
        }

        guard entries[key.stringValue] != nil else {
            throw FanControlError.missingKey(key.stringValue)
        }
        onBeforeWrite?(operation, key.stringValue)

        if let rejection = scriptedRejections.first(where: { $0.operation == operation && $0.key == key.stringValue }) {
            return record(operation, key: key, bytes: bytes, reason: reason, result: rejection.result)
        }

        if case .mode(_, let value) = operation {
            if value == capability.manualCommand {
                guard entries["Ftst"]?.bytes == [capability.unlockOn],
                      allFansHaveSafePreManualTargetReadback(capability: capability)
                else {
                    return record(operation, key: key, bytes: bytes, reason: reason, result: 0x82)
                }
            } else if value != capability.releaseCommand {
                return record(operation, key: key, bytes: bytes, reason: reason, result: 0x82)
            }
        }

        if key.stringValue == "Ftst" {
            pending.append((applyAt: tick + 3, key: key.stringValue, bytes: bytes, releaseSettledFan: nil))
            return record(operation, key: key, bytes: bytes, reason: reason, result: 0)
        }

        if key.stringValue.hasSuffix("Md") {
            if case .mode(_, 0) = operation {
                if case .mode(let fan, _) = operation {
                    releaseSettledFans.remove(fan)
                    pending.append((applyAt: tick + 2, key: key.stringValue, bytes: [0], releaseSettledFan: nil))
                    pending.append((applyAt: tick + 4, key: key.stringValue, bytes: [3], releaseSettledFan: fan))
                } else {
                    pending.append((applyAt: tick + 2, key: key.stringValue, bytes: [0], releaseSettledFan: nil))
                    pending.append((applyAt: tick + 4, key: key.stringValue, bytes: [3], releaseSettledFan: nil))
                }
            } else {
                if case .mode(let fan, _) = operation {
                    releaseSettledFans.remove(fan)
                }
                pending.append((applyAt: tick + 2, key: key.stringValue, bytes: bytes, releaseSettledFan: nil))
            }
            return record(operation, key: key, bytes: bytes, reason: reason, result: 0)
        }

        if case .target(let fan, _) = operation {
            if entries["F\(fan)Md"]?.bytes != [capability.manualCommand] {
                if validManagedTargetClear(bytes, fan: fan, capability: capability) {
                    releaseSettledFans.remove(fan)
                } else if validPreManualTargetRequest(bytes, fan: fan, capability: capability) {
                    pending.append((applyAt: tick + 2, key: key.stringValue, bytes: preManualTargetGuardBytes(fan: fan, capability: capability), releaseSettledFan: nil))
                    return record(operation, key: key, bytes: bytes, reason: reason, result: 0)
                } else {
                    return record(operation, key: key, bytes: bytes, reason: reason, result: 0x82)
                }
            }

            if entries["F\(fan)Md"]?.bytes == [capability.manualCommand] {
                guard validManualTarget(bytes, fan: fan) else {
                    return record(operation, key: key, bytes: bytes, reason: reason, result: 0x82)
                }
            }
        }

        entries[key.stringValue]?.bytes = bytes
        return record(operation, key: key, bytes: bytes, reason: reason, result: 0)
    }

    private func record(_ operation: FanWriteOperation, key: FanKey, bytes: [UInt8], reason: String, result: UInt8) -> FanWriteResult {
        record(operation, key: key, bytes: bytes, reason: reason, result: FanWriteResult(kernReturn: 0, smcResult: result, smcStatus: 0))
    }

    private func record(_ operation: FanWriteOperation, key: FanKey, bytes: [UInt8], reason: String, result: FanWriteResult) -> FanWriteResult {
        writes.append(WriteEvent(
            operation: operation,
            key: key.stringValue,
            bytes: bytes,
            reason: reason,
            kernReturn: result.kernReturn,
            smcResult: result.smcResult,
            smcStatus: result.smcStatus
        ))
        return result
    }

    private func validManualTarget(_ bytes: [UInt8], fan: Int) -> Bool {
        guard let target = FanEncoding.floatValue(bytes),
              let minimum = FanEncoding.floatValue(entries["F\(fan)Mn"]?.bytes ?? []),
              let maximum = FanEncoding.floatValue(entries["F\(fan)Mx"]?.bytes ?? [])
        else { return false }
        return target >= minimum && target <= maximum
    }

    private func validManagedTargetClear(_ bytes: [UInt8], fan: Int, capability: FanCapability) -> Bool {
        guard releaseSettledFans.contains(fan),
              entries["F\(fan)Md"]?.bytes == [capability.managedObservedState],
              let target = FanEncoding.floatValue(bytes)
        else { return false }
        return target == 0
    }

    private func validPreManualTargetRequest(_ bytes: [UInt8], fan: Int, capability: FanCapability) -> Bool {
        guard let target = FanEncoding.floatValue(bytes),
              let minimum = FanEncoding.floatValue(entries["F\(fan)Mn"]?.bytes ?? []),
              let maximum = FanEncoding.floatValue(entries["F\(fan)Mx"]?.bytes ?? [])
        else { return false }
        let nearMaximum = maximum * 0.95
        return target >= minimum && target >= nearMaximum && target <= maximum
    }

    private func safePreManualTargetReadback(fan: Int, capability: FanCapability) -> Bool {
        guard let target = FanEncoding.floatValue(entries["F\(fan)Tg"]?.bytes ?? []),
              let minimum = FanEncoding.floatValue(entries["F\(fan)Mn"]?.bytes ?? []),
              let maximum = FanEncoding.floatValue(entries["F\(fan)Mx"]?.bytes ?? [])
        else { return false }
        let safeFloor = max(minimum * capability.preManualMinimumMultiplier, 1)
        return target >= safeFloor && target < maximum
    }

    private func allFansHaveSafePreManualTargetReadback(capability: FanCapability) -> Bool {
        for fan in 0..<capability.fanCount {
            guard safePreManualTargetReadback(fan: fan, capability: capability) else { return false }
        }
        return true
    }

    private func preManualTargetGuardBytes(fan: Int, capability: FanCapability) -> [UInt8] {
        let minimum = FanEncoding.floatValue(entries["F\(fan)Mn"]?.bytes ?? []) ?? 1
        let maximum = FanEncoding.floatValue(entries["F\(fan)Mx"]?.bytes ?? []) ?? max(minimum + 1, 2)
        let safeFloor = max(minimum * capability.preManualMinimumMultiplier, 1)
        let safeTarget = min(safeFloor, maximum.nextDown)
        return FanEncoding.float32LittleEndian(safeTarget)
    }

    private func simulateRamp() {
        for index in 0..<2 {
            guard entries["F\(index)Md"]?.bytes == [1],
                  let target = FanEncoding.floatValue(entries["F\(index)Tg"]?.bytes ?? []),
                  target > 0
            else { continue }
            let actualKey = "F\(index)Ac"
            let current = FanEncoding.floatValue(entries[actualKey]?.bytes ?? []) ?? 0
            entries[actualKey]?.bytes = FanEncoding.float32LittleEndian(min(target, current + 2_000))
        }
    }
}
