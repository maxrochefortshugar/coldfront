import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct FanWriteAuditEvent: Equatable, Sendable, Codable {
    public let timestampUnix: TimeInterval
    public let serviceName: String
    public let capabilityFingerprint: String
    public let leaseID: UUID?
    public let key: String
    public let oldRaw: [UInt8]
    public let newRaw: [UInt8]
    public let kernReturn: Int32
    public let smcResult: UInt8
    public let smcStatus: UInt8
    public let reason: String

    public init(
        timestampUnix: TimeInterval,
        serviceName: String,
        capabilityFingerprint: String,
        leaseID: UUID?,
        key: String,
        oldRaw: [UInt8],
        newRaw: [UInt8],
        kernReturn: Int32,
        smcResult: UInt8,
        smcStatus: UInt8,
        reason: String
    ) {
        self.timestampUnix = timestampUnix
        self.serviceName = serviceName
        self.capabilityFingerprint = capabilityFingerprint
        self.leaseID = leaseID
        self.key = key
        self.oldRaw = oldRaw
        self.newRaw = newRaw
        self.kernReturn = kernReturn
        self.smcResult = smcResult
        self.smcStatus = smcStatus
        self.reason = reason
    }

    enum CodingKeys: String, CodingKey {
        case timestampUnix
        case serviceName
        case capabilityFingerprint
        case leaseID
        case key
        case oldRaw
        case newRaw
        case kernReturn
        case smcResult
        case smcStatus
        case reason
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.timestampUnix = try container.decode(TimeInterval.self, forKey: .timestampUnix)
        self.serviceName = try container.decode(String.self, forKey: .serviceName)
        self.capabilityFingerprint = try container.decode(String.self, forKey: .capabilityFingerprint)
        self.leaseID = try container.decodeIfPresent(UUID.self, forKey: .leaseID)
        self.key = try container.decode(String.self, forKey: .key)
        self.oldRaw = try container.decode([UInt8].self, forKey: .oldRaw)
        self.newRaw = try container.decode([UInt8].self, forKey: .newRaw)
        self.kernReturn = try container.decode(Int32.self, forKey: .kernReturn)
        self.smcResult = try container.decode(UInt8.self, forKey: .smcResult)
        self.smcStatus = try container.decode(UInt8.self, forKey: .smcStatus)
        self.reason = try container.decode(String.self, forKey: .reason)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(timestampUnix, forKey: .timestampUnix)
        try container.encode(serviceName, forKey: .serviceName)
        try container.encode(capabilityFingerprint, forKey: .capabilityFingerprint)
        if let leaseID {
            try container.encode(leaseID, forKey: .leaseID)
        } else {
            try container.encodeNil(forKey: .leaseID)
        }
        try container.encode(key, forKey: .key)
        try container.encode(oldRaw, forKey: .oldRaw)
        try container.encode(newRaw, forKey: .newRaw)
        try container.encode(kernReturn, forKey: .kernReturn)
        try container.encode(smcResult, forKey: .smcResult)
        try container.encode(smcStatus, forKey: .smcStatus)
        try container.encode(reason, forKey: .reason)
    }
}

package protocol FanControlLogger: AnyObject {
    func record(_ event: FanWriteAuditEvent) throws
}

package final class InMemoryFanControlLogger: FanControlLogger {
    package private(set) var events: [FanWriteAuditEvent] = []

    package init() {}

    package func record(_ event: FanWriteAuditEvent) throws {
        events.append(event)
    }
}

package final class JSONLFanControlLogger: FanControlLogger {
    private let url: URL
    private let encoder: JSONEncoder
    private let lock = NSLock()

    package init(url: URL, encoder: JSONEncoder = JSONEncoder()) {
        self.url = url
        self.encoder = encoder
    }

    package func record(_ event: FanWriteAuditEvent) throws {
        lock.lock()
        defer { lock.unlock() }

        var data = try encoder.encode(event)
        data.append(0x0A)
        try append(data)
    }

    private func append(_ data: Data) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let fd = open(url.path, O_APPEND | O_CREAT | O_WRONLY, 0o644)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

        do {
            try data.withUnsafeBytes { buffer in
                guard var pointer = buffer.baseAddress else { return }
                var remaining = buffer.count

                while remaining > 0 {
                    let written = write(fd, pointer, remaining)
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    if written == 0 { throw POSIXError(.EIO) }
                    pointer = pointer.advanced(by: written)
                    remaining -= written
                }
            }
        } catch {
            _ = close(fd)
            throw error
        }

        guard close(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
