import Foundation
import dnssd

/// One DNS SRV record.
public struct SRVRecord: Equatable, Sendable {
    public var priority: UInt16
    public var weight: UInt16
    public var port: UInt16
    /// Target host name without the trailing dot ("." means "no service").
    public var target: String

    public init(priority: UInt16, weight: UInt16, port: UInt16, target: String) {
        self.priority = priority
        self.weight = weight
        self.port = port
        self.target = target
    }
}

/// A host and port to try connecting to.
public struct XMPPServerAddress: Equatable, Sendable {
    public var host: String
    public var port: Int

    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }
}

/// Looks up SRV records. Injected into `XMPPClient` so tests never touch DNS.
public protocol SRVResolving {
    /// Returns the SRV records for `name` (e.g. `_xmpp-client._tcp.example.com`),
    /// or an empty array on failure or timeout.
    func resolveSRV(_ name: String) async -> [SRVRecord]
}

extension SRVRecord {
    /// Orders records as RFC 2782 describes (priority, then weighted random),
    /// dropping "." targets. With no usable records, falls back to `domain:fallbackPort`.
    public static func connectionOrder(_ records: [SRVRecord], fallbackDomain domain: String, fallbackPort: Int = 5222) -> [XMPPServerAddress] {
        let usable = records.filter { $0.target != "." && !$0.target.isEmpty }
        if usable.isEmpty {
            return [XMPPServerAddress(host: domain, port: fallbackPort)]
        }
        var result: [XMPPServerAddress] = []
        let priorities = Set(usable.map { $0.priority }).sorted()
        for priority in priorities {
            var group = usable.filter { $0.priority == priority }
            while !group.isEmpty {
                var total = 0
                for record in group {
                    total += Int(record.weight)
                }
                var chosenIndex = 0
                if total > 0 {
                    var pick = Int.random(in: 1...total)
                    for (index, record) in group.enumerated() {
                        pick -= Int(record.weight)
                        if pick <= 0 {
                            chosenIndex = index
                            break
                        }
                    }
                }
                let chosen = group.remove(at: chosenIndex)
                result.append(XMPPServerAddress(host: chosen.target, port: Int(chosen.port)))
            }
        }
        return result
    }
}

/// SRV lookups through dnssd's `DNSServiceQueryRecord`.
public final class DNSSRVResolver: SRVResolving {
    public let timeout: TimeInterval

    public init(timeout: TimeInterval = 5) {
        self.timeout = timeout
    }

    public func resolveSRV(_ name: String) async -> [SRVRecord] {
        let queryTimeout = timeout
        return await withCheckedContinuation { (continuation: CheckedContinuation<[SRVRecord], Never>) in
            let query = SRVQuery(name: name, timeout: queryTimeout, continuation: continuation)
            query.start()
        }
    }

    /// Parses SRV rdata: priority, weight, port (big-endian UInt16s), then the
    /// target as an uncompressed DNS name.
    static func parseSRVRecord(_ bytes: [UInt8]) -> SRVRecord? {
        guard bytes.count >= 7 else { return nil }
        let priority = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
        let weight = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
        let port = UInt16(bytes[4]) << 8 | UInt16(bytes[5])
        var labels: [String] = []
        var index = 6
        while index < bytes.count {
            let length = Int(bytes[index])
            index += 1
            if length == 0 {
                break
            }
            if length & 0xC0 != 0 {
                // Compression pointers are not allowed in SRV targets.
                return nil
            }
            if index + length > bytes.count {
                return nil
            }
            labels.append(String(decoding: bytes[index..<(index + length)], as: UTF8.self))
            index += length
        }
        let target = labels.isEmpty ? "." : labels.joined(separator: ".")
        return SRVRecord(priority: priority, weight: weight, port: port, target: target)
    }
}

/// One in-flight query. Everything happens on `queue`; the object keeps itself
/// alive (via `retainedSelf`) until the DNSServiceRef has been deallocated.
private final class SRVQuery {
    private let name: String
    private let timeout: TimeInterval
    private let queue = DispatchQueue(label: "XMPPCore.SRVQuery")
    private var continuation: CheckedContinuation<[SRVRecord], Never>?
    private var serviceRef: DNSServiceRef?
    private var records: [SRVRecord] = []
    private var retainedSelf: Unmanaged<SRVQuery>?

    init(name: String, timeout: TimeInterval, continuation: CheckedContinuation<[SRVRecord], Never>) {
        self.name = name
        self.timeout = timeout
        self.continuation = continuation
    }

    func start() {
        queue.async {
            self.begin()
        }
    }

    private func begin() {
        let unmanaged = Unmanaged.passRetained(self)
        retainedSelf = unmanaged

        var newRef: DNSServiceRef? = nil
        let flags = DNSServiceFlags(kDNSServiceFlagsReturnIntermediates)
        let startError = DNSServiceQueryRecord(&newRef,
                                               flags,
                                               0,
                                               name,
                                               UInt16(kDNSServiceType_SRV),
                                               UInt16(kDNSServiceClass_IN),
                                               srvQueryCallback,
                                               unmanaged.toOpaque())
        guard startError == DNSServiceErrorType(kDNSServiceErr_NoError), let startedRef = newRef else {
            finish()
            return
        }
        serviceRef = startedRef
        let queueError = DNSServiceSetDispatchQueue(startedRef, queue)
        guard queueError == DNSServiceErrorType(kDNSServiceErr_NoError) else {
            finish()
            return
        }
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.finish()
        }
    }

    fileprivate func handle(flags: DNSServiceFlags, errorCode: DNSServiceErrorType, rrtype: UInt16, rdlen: UInt16, rdata: UnsafeRawPointer?) {
        guard continuation != nil else { return }
        if errorCode != DNSServiceErrorType(kDNSServiceErr_NoError) {
            // e.g. kDNSServiceErr_NoSuchRecord: no SRV records for this domain.
            finish()
            return
        }
        let isAdd = (flags & DNSServiceFlags(kDNSServiceFlagsAdd)) != 0
        if rrtype == UInt16(kDNSServiceType_SRV), isAdd, let bytesPointer = rdata, rdlen > 0 {
            let buffer = UnsafeRawBufferPointer(start: bytesPointer, count: Int(rdlen))
            if let record = DNSSRVResolver.parseSRVRecord([UInt8](buffer)) {
                records.append(record)
            }
        }
        let moreComing = (flags & DNSServiceFlags(kDNSServiceFlagsMoreComing)) != 0
        if !moreComing && !records.isEmpty {
            finish()
        }
    }

    private func finish() {
        guard let pending = continuation else { return }
        continuation = nil
        pending.resume(returning: records)

        let refToRelease = serviceRef
        serviceRef = nil
        let selfToRelease = retainedSelf
        retainedSelf = nil
        // Deallocate outside the callback, then drop the self-reference.
        queue.async {
            if let ref = refToRelease {
                DNSServiceRefDeallocate(ref)
            }
            selfToRelease?.release()
        }
    }
}

private let srvQueryCallback: DNSServiceQueryRecordReply = { _, flags, _, errorCode, _, rrtype, _, rdlen, rdata, _, context in
    guard let context = context else { return }
    let query = Unmanaged<SRVQuery>.fromOpaque(context).takeUnretainedValue()
    query.handle(flags: flags, errorCode: errorCode, rrtype: rrtype, rdlen: rdlen, rdata: rdata)
}
