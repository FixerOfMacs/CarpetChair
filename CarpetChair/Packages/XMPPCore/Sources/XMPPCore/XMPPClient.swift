import Foundation
import Combine

/// An XMPP client session for one account, observable from SwiftUI.
///
/// `login` resolves the server (SRV, falling back to `domain:5222`), opens the
/// stream, requires STARTTLS, authenticates (SCRAM-SHA-256 > SCRAM-SHA-1 >
/// PLAIN over TLS), binds the resource "CarpetChair", fetches the roster and
/// sends initial presence. Progress and errors are published in
/// `connectionState`.
@MainActor
public final class XMPPClient: ObservableObject {
    // MARK: - Published state

    @Published public private(set) var connectionState: ConnectionState = .disconnected
    /// Sorted by display name.
    @Published public private(set) var roster: [Buddy] = []
    @Published public private(set) var conversations: [BareJID: [ChatMessage]] = [:]
    /// Bare JIDs asking to see our presence; answer with `acceptSubscription` / `declineSubscription`.
    @Published public private(set) var pendingSubscriptionRequests: [JID] = []
    /// Our full JID once a resource is bound.
    @Published public private(set) var boundJID: JID?
    /// Our presence as last sent (`.offline` when not connected).
    @Published public private(set) var ownPresence: PresenceShow = .offline
    @Published public private(set) var ownStatus: String?

    // MARK: - Configuration

    public static let resourceName = "CarpetChair"
    /// Seconds between whitespace keepalives while online.
    public var keepaliveInterval: TimeInterval = 60
    /// Seconds to wait for each server address to answer with a stream header.
    public var connectTimeout: TimeInterval = 15
    /// Seconds allowed from stream open to online.
    public var negotiationTimeout: TimeInterval = 30

    /// Test hook: supplies the SCRAM client nonce.
    var scramNonceProvider: (() -> String)?

    // MARK: - Private state

    private enum Phase {
        case idle
        case connecting
        case negotiating
        case tls
        case authenticating
        case binding
        case online
    }

    /// Thrown when a newer login/logout has replaced the session doing the work.
    private struct Superseded: Error {}

    private struct ResourcePresence {
        var show: PresenceShow
        var status: String?
        var priority: Int
        var received: Date
    }

    private let transportFactory: () -> XMPPTransport
    private let resolver: SRVResolving
    private var transport: XMPPTransport?
    private let parser = XMLStreamParser()
    private var bufferedEvents: [XMLStreamEvent] = []
    private var generation = 0
    private var phase: Phase = .idle
    private var account: JID?
    private var streamHeaderSent = false
    private var sessionTask: Task<Void, Never>?
    private var keepaliveTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var connectAttemptTimedOut = false
    private var stanzaCounter = 0
    private var resourcePresence: [BareJID: [String: ResourcePresence]] = [:]
    private var desiredShow: PresenceShow = .available
    private var desiredStatus: String?

    /// - Parameters:
    ///   - transportFactory: makes a fresh transport for each connection attempt.
    ///   - resolver: SRV lookups.
    public init(transportFactory: @escaping () -> XMPPTransport = { StreamTaskTransport() },
                resolver: SRVResolving = DNSSRVResolver()) {
        self.transportFactory = transportFactory
        self.resolver = resolver
    }

    // MARK: - Public API

    /// Parses `jid` and signs in. An unparsable JID fails immediately.
    public func login(jid: String, password: String, hostOverride: String? = nil, portOverride: Int? = nil) {
        guard let parsed = JID(jid) else {
            tearDown()
            connectionState = .failed(XMPPError.invalidJID.userMessage)
            return
        }
        login(jid: parsed, password: password, hostOverride: hostOverride, portOverride: portOverride)
    }

    /// Signs in, replacing any current session. Watch `connectionState`.
    /// - Parameters:
    ///   - hostOverride: connect to this host instead of looking up SRV records.
    ///   - portOverride: use this port (default 5222); also skips the SRV lookup.
    public func login(jid: JID, password: String, hostOverride: String? = nil, portOverride: Int? = nil) {
        tearDown()
        guard jid.local != nil else {
            connectionState = .failed(XMPPError.invalidJID.userMessage)
            return
        }
        let accountJID = jid.bareJID
        if let previous = account, previous.bare != accountJID.bare {
            conversations = [:]
        }
        account = accountJID
        roster = []
        pendingSubscriptionRequests = []
        boundJID = nil
        phase = .connecting
        connectionState = .connecting

        let host = XMPPClient.normalisedHost(hostOverride)
        let gen = generation
        sessionTask = Task { [weak self] in
            guard let self = self else { return }
            await self.runSession(account: accountJID,
                                  password: password,
                                  hostOverride: host,
                                  portOverride: portOverride,
                                  generation: gen)
        }
    }

    /// Ends the stream (`</stream:stream>`) and closes the connection.
    public func logout() {
        if streamHeaderSent, let currentTransport = transport {
            currentTransport.send(Data("</stream:stream>".utf8))
        }
        tearDown()
        connectionState = .disconnected
        roster = []
        pendingSubscriptionRequests = []
        boundJID = nil
    }

    /// Sends a chat message and appends it to the conversation.
    /// Returns nil (and sends nothing) when not online or the body is blank.
    @discardableResult
    public func send(message body: String, to recipient: JID) -> ChatMessage? {
        guard connectionState == .online, let me = boundJID ?? account else { return nil }
        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return nil
        }
        let stanzaID = makeID("msg")
        let stanza = XMPPElement(name: "message",
                                attributes: ["type": "chat", "to": recipient.description, "id": stanzaID],
                                children: [XMPPElement(name: "body", text: body)])
        write(stanza)
        let message = ChatMessage(from: me, to: recipient, body: body, date: Date(), isFromMe: true, stanzaID: stanzaID)
        conversations[recipient.bare, default: []].append(message)
        return message
    }

    /// The conversation with a contact (any resource).
    public func messages(with jid: JID) -> [ChatMessage] {
        return conversations[jid.bare] ?? []
    }

    /// Adds the contact to the roster, then asks to see their presence.
    public func addBuddy(jid: JID, name: String? = nil, groups: [String] = []) {
        guard connectionState == .online else { return }
        let bare = jid.bareJID
        var item = XMPPElement(name: "item", attributes: ["jid": bare.description])
        if let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmedName.isEmpty {
            item.attributes["name"] = trimmedName
        }
        for group in groups where !group.isEmpty {
            item.children.append(XMPPElement(name: "group", text: group))
        }
        write(rosterSet(item))
        write(XMPPElement(name: "presence", attributes: ["to": bare.description, "type": "subscribe"]))
    }

    /// Removes the contact from the roster (this also cancels subscriptions both ways).
    public func removeBuddy(jid: JID) {
        guard connectionState == .online else { return }
        let bare = jid.bareJID
        write(rosterSet(XMPPElement(name: "item", attributes: ["jid": bare.description, "subscription": "remove"])))
        pendingSubscriptionRequests.removeAll(where: { $0 == bare })
    }

    /// Approves a subscription request, and asks for theirs if we don't have it yet.
    public func acceptSubscription(from jid: JID) {
        guard connectionState == .online else { return }
        let bare = jid.bareJID
        write(XMPPElement(name: "presence", attributes: ["to": bare.description, "type": "subscribed"]))
        let existing = roster.first(where: { $0.jid == bare })
        var subscribedToThem = false
        var alreadyAsked = false
        if let buddy = existing {
            subscribedToThem = buddy.subscription == .to || buddy.subscription == .both
            alreadyAsked = buddy.isAwaitingAuthorization
        }
        if !subscribedToThem && !alreadyAsked {
            write(XMPPElement(name: "presence", attributes: ["to": bare.description, "type": "subscribe"]))
        }
        pendingSubscriptionRequests.removeAll(where: { $0 == bare })
    }

    /// Refuses a subscription request.
    public func declineSubscription(from jid: JID) {
        guard connectionState == .online else { return }
        let bare = jid.bareJID
        write(XMPPElement(name: "presence", attributes: ["to": bare.description, "type": "unsubscribed"]))
        pendingSubscriptionRequests.removeAll(where: { $0 == bare })
    }

    /// Sets our presence (`.available` or `.away`; `.offline` sends unavailable
    /// presence but stays connected). Remembered for the next login too.
    public func setPresence(_ show: PresenceShow, status: String? = nil) {
        desiredShow = show
        desiredStatus = status
        guard connectionState == .online else { return }
        write(presenceElement(show: show, status: status))
        ownPresence = show
        ownStatus = status
    }

    // MARK: - Session

    private func runSession(account: JID, password: String, hostOverride: String?, portOverride: Int?, generation gen: Int) async {
        do {
            try await negotiate(account: account,
                                password: password,
                                hostOverride: hostOverride,
                                portOverride: portOverride,
                                generation: gen)
            while true {
                let stanza = try await nextStanza(gen)
                handleStanza(stanza)
            }
        } catch {
            guard gen == generation else { return }
            fail(error)
        }
    }

    private func negotiate(account: JID, password: String, hostOverride: String?, portOverride: Int?, generation gen: Int) async throws {
        let domain = account.domain

        let targets: [XMPPServerAddress]
        if hostOverride != nil || portOverride != nil {
            targets = [XMPPServerAddress(host: hostOverride ?? domain, port: portOverride ?? 5222)]
        } else {
            let records = await resolver.resolveSRV("_xmpp-client._tcp." + domain)
            try checkGeneration(gen)
            targets = SRVRecord.connectionOrder(records, fallbackDomain: domain)
        }

        try await connect(to: targets, domain: domain, generation: gen)
        phase = .negotiating
        startWatchdog(after: negotiationTimeout, generation: gen, abortsLogin: true)

        // STARTTLS is required.
        let plainFeatures = try await readFeatures(gen)
        guard plainFeatures.child(named: "starttls", xmlns: XMPPNamespace.tls) != nil else {
            throw XMPPError.tlsNotOffered
        }
        write(XMPPElement(name: "starttls", attributes: ["xmlns": XMPPNamespace.tls]))
        let tlsReply = try await nextStanza(gen)
        guard tlsReply.localName == "proceed" else {
            throw XMPPError.tlsRefused
        }
        guard let tlsTransport = transport else {
            throw XMPPError.connectionClosed
        }
        // No read is outstanding here, which startTLS requires.
        phase = .tls
        try await tlsTransport.startTLS(serverName: domain)
        try checkGeneration(gen)
        let secureFeatures = try await restartStream(domain: domain, generation: gen)

        // SASL.
        phase = .authenticating
        connectionState = .authenticating
        try await authenticate(account: account, password: password, features: secureFeatures, generation: gen)
        let sessionFeatures = try await restartStream(domain: domain, generation: gen)

        // Bind, legacy session, roster, presence.
        phase = .binding
        try await bindResource(account: account, features: sessionFeatures, generation: gen)
        try await establishSessionIfRequired(features: sessionFeatures, generation: gen)
        try await fetchRoster(generation: gen)
        sendInitialPresence()

        watchdogTask?.cancel()
        watchdogTask = nil
        phase = .online
        connectionState = .online
        startKeepalive(generation: gen)
    }

    /// Tries each address in turn until one answers with a stream header.
    private func connect(to targets: [XMPPServerAddress], domain: String, generation gen: Int) async throws {
        var lastError: Error = XMPPError.hostNotFound(domain)
        for target in targets {
            try checkGeneration(gen)
            let candidate = transportFactory()
            transport = candidate
            streamHeaderSent = false
            parser.reset()
            bufferedEvents.removeAll()
            startWatchdog(after: connectTimeout, generation: gen, abortsLogin: false)
            do {
                try await candidate.connect(host: target.host, port: target.port)
                try checkGeneration(gen)
                sendStreamHeader(domain: domain)
                try await awaitStreamHeader(gen)
                watchdogTask?.cancel()
                watchdogTask = nil
                return
            } catch {
                watchdogTask?.cancel()
                watchdogTask = nil
                if gen != generation {
                    throw error
                }
                lastError = connectAttemptTimedOut ? XMPPError.timedOut : error
                connectAttemptTimedOut = false
                candidate.close()
                if transport === candidate {
                    transport = nil
                }
                streamHeaderSent = false
            }
        }
        throw lastError
    }

    private func authenticate(account: JID, password: String, features: XMPPElement, generation gen: Int) async throws {
        let mechanismElements = features.child(named: "mechanisms")?.children(named: "mechanism") ?? []
        let offered = mechanismElements.map { $0.text }
        let tlsActive = transport?.isSecure ?? false
        guard let mechanism = SASLMechanism.preferred(from: offered, tlsActive: tlsActive) else {
            throw XMPPError.noSupportedMechanism
        }
        let username = account.local ?? ""

        switch mechanism {
        case .plain:
            writeSASL("auth", mechanism: mechanism, payload: SASL.plainMessage(username: username, password: password))
            let reply = try await nextStanza(gen)
            switch reply.localName {
            case "success":
                return
            case "failure":
                throw saslFailure(reply)
            default:
                throw XMPPError.protocolError("unexpected <\(reply.name)> during sign-in")
            }

        case .scramSHA1, .scramSHA256:
            let algorithm: SCRAMAuthenticator.Algorithm = (mechanism == .scramSHA1) ? .sha1 : .sha256
            let scram = SCRAMAuthenticator(algorithm: algorithm,
                                           username: username,
                                           password: password,
                                           clientNonce: scramNonceProvider?())
            writeSASL("auth", mechanism: mechanism, payload: Data(scram.clientFirstMessage.utf8))
            while true {
                let reply = try await nextStanza(gen)
                switch reply.localName {
                case "challenge":
                    let challenge = try decodeSASLPayload(reply.text)
                    if !scram.hasProducedClientFinal {
                        let clientFinal = try scram.clientFinalMessage(serverFirstMessage: challenge)
                        writeSASL("response", mechanism: nil, payload: Data(clientFinal.utf8))
                    } else {
                        // Some servers send the server-final message as a challenge.
                        try verifyServer(scram, challenge)
                        writeSASL("response", mechanism: nil, payload: nil)
                    }
                case "success":
                    let additionalData = try decodeSASLPayload(reply.text)
                    if !scram.isServerVerified {
                        if additionalData.isEmpty {
                            throw XMPPError.serverSignatureInvalid
                        }
                        try verifyServer(scram, additionalData)
                    }
                    return
                case "failure":
                    throw saslFailure(reply)
                default:
                    throw XMPPError.protocolError("unexpected <\(reply.name)> during sign-in")
                }
            }
        }
    }

    private func verifyServer(_ scram: SCRAMAuthenticator, _ serverFinal: String) throws {
        do {
            try scram.verifyServerFinalMessage(serverFinal)
        } catch SASLError.serverSignatureMismatch {
            throw XMPPError.serverSignatureInvalid
        }
    }

    private func bindResource(account: JID, features: XMPPElement, generation gen: Int) async throws {
        guard features.child(named: "bind") != nil else {
            throw XMPPError.protocolError("the server doesn't support resource binding")
        }
        let id = makeID("bind")
        let bind = XMPPElement(name: "bind",
                              attributes: ["xmlns": XMPPNamespace.bind],
                              children: [XMPPElement(name: "resource", text: XMPPClient.resourceName)])
        write(XMPPElement(name: "iq", attributes: ["type": "set", "id": id], children: [bind]))
        let reply = try await awaitIQReply(id: id, generation: gen)
        guard reply.attribute("type") == "result" else {
            throw XMPPError.bindFailed(stanzaErrorCondition(reply))
        }
        if let jidText = reply.child(named: "bind")?.child(named: "jid")?.text,
           let bound = JID(jidText),
           bound.resource != nil {
            boundJID = bound
        } else {
            boundJID = JID(bare: account.bare, resource: XMPPClient.resourceName)
        }
    }

    /// RFC 3921 session establishment, only when the server offers it without `<optional/>`.
    private func establishSessionIfRequired(features: XMPPElement, generation gen: Int) async throws {
        guard let session = features.child(named: "session"),
              session.xmlns == XMPPNamespace.session,
              session.child(named: "optional") == nil else {
            return
        }
        let id = makeID("session")
        let request = XMPPElement(name: "iq",
                                 attributes: ["type": "set", "id": id],
                                 children: [XMPPElement(name: "session", attributes: ["xmlns": XMPPNamespace.session])])
        write(request)
        let reply = try await awaitIQReply(id: id, generation: gen)
        guard reply.attribute("type") == "result" else {
            throw XMPPError.protocolError("the server refused the session (\(stanzaErrorCondition(reply)))")
        }
    }

    private func fetchRoster(generation gen: Int) async throws {
        let id = makeID("roster")
        let request = XMPPElement(name: "iq",
                                 attributes: ["type": "get", "id": id],
                                 children: [XMPPElement(name: "query", attributes: ["xmlns": XMPPNamespace.roster])])
        write(request)
        let reply = try await awaitIQReply(id: id, generation: gen)
        if reply.attribute("type") == "result", let query = reply.child(named: "query") {
            replaceRoster(with: query.children(named: "item"))
        }
    }

    private func sendInitialPresence() {
        let show: PresenceShow = (desiredShow == .away) ? .away : .available
        write(presenceElement(show: show, status: desiredStatus))
        ownPresence = show
        ownStatus = desiredStatus
    }

    // MARK: - Reading

    private func nextEvent(_ gen: Int) async throws -> XMLStreamEvent {
        while bufferedEvents.isEmpty {
            guard let currentTransport = transport else {
                throw XMPPError.connectionClosed
            }
            let received = try await currentTransport.receive()
            try checkGeneration(gen)
            guard let chunk = received else {
                throw XMPPError.connectionClosed
            }
            let events: [XMLStreamEvent]
            do {
                events = try parser.feed(chunk)
            } catch {
                throw XMPPError.protocolError("the server sent malformed XML")
            }
            bufferedEvents.append(contentsOf: events)
        }
        return bufferedEvents.removeFirst()
    }

    /// The next depth-1 element; stream errors and the end of the stream throw.
    private func nextStanza(_ gen: Int) async throws -> XMPPElement {
        while true {
            let event = try await nextEvent(gen)
            switch event {
            case .element(let element):
                if isStreamElement(element, "error") {
                    throw streamError(from: element)
                }
                return element
            case .streamOpened:
                continue
            case .streamClosed:
                throw XMPPError.connectionClosed
            }
        }
    }

    private func awaitStreamHeader(_ gen: Int) async throws {
        while true {
            let event = try await nextEvent(gen)
            switch event {
            case .streamOpened:
                return
            case .element(let element):
                if isStreamElement(element, "error") {
                    throw streamError(from: element)
                }
            case .streamClosed:
                throw XMPPError.connectionClosed
            }
        }
    }

    private func readFeatures(_ gen: Int) async throws -> XMPPElement {
        while true {
            let element = try await nextStanza(gen)
            if isStreamElement(element, "features") {
                return element
            }
        }
    }

    private func restartStream(domain: String, generation gen: Int) async throws -> XMPPElement {
        parser.reset()
        bufferedEvents.removeAll()
        sendStreamHeader(domain: domain)
        try await awaitStreamHeader(gen)
        return try await readFeatures(gen)
    }

    /// Waits for the result/error with this id, handling other stanzas meanwhile.
    private func awaitIQReply(id: String, generation gen: Int) async throws -> XMPPElement {
        while true {
            let stanza = try await nextStanza(gen)
            if stanza.name == "iq", stanza.attribute("id") == id {
                let type = stanza.attribute("type") ?? ""
                if type == "result" || type == "error" {
                    return stanza
                }
            }
            handleStanza(stanza)
        }
    }

    // MARK: - Incoming stanzas

    private func handleStanza(_ stanza: XMPPElement) {
        switch stanza.name {
        case "message":
            handleMessage(stanza)
        case "presence":
            handlePresence(stanza)
        case "iq":
            handleIQ(stanza)
        default:
            break
        }
    }

    private func handleMessage(_ stanza: XMPPElement) {
        let type = stanza.attribute("type") ?? "normal"
        guard type == "chat" || type == "normal" else { return }
        // Chat-state notifications and receipts have no body.
        guard let body = stanza.child(named: "body")?.text, !body.isEmpty else { return }
        guard let fromText = stanza.attribute("from"), let from = JID(fromText) else { return }
        guard let me = boundJID ?? account else { return }
        let to = stanza.attribute("to").flatMap { JID($0) } ?? me
        let message = ChatMessage(from: from,
                                  to: to,
                                  body: body,
                                  date: XMPPClient.delayedDate(of: stanza) ?? Date(),
                                  isFromMe: false,
                                  stanzaID: stanza.attribute("id"))
        conversations[from.bare, default: []].append(message)
    }

    private func handlePresence(_ stanza: XMPPElement) {
        guard let fromText = stanza.attribute("from"), let from = JID(fromText) else { return }
        let bare = from.bare
        let type = stanza.attribute("type") ?? "available"
        switch type {
        case "available":
            let showText = (stanza.child(named: "show")?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let show: PresenceShow = (showText == "away" || showText == "xa" || showText == "dnd") ? .away : .available
            var status = stanza.child(named: "status")?.text
            if let text = status, text.isEmpty {
                status = nil
            }
            let priorityText = (stanza.child(named: "priority")?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let priority = Int(priorityText) ?? 0
            var resources = resourcePresence[bare] ?? [:]
            resources[from.resource ?? ""] = ResourcePresence(show: show, status: status, priority: priority, received: Date())
            resourcePresence[bare] = resources
            refreshPresence(of: bare)
        case "unavailable":
            if let resource = from.resource {
                var resources = resourcePresence[bare] ?? [:]
                resources[resource] = nil
                resourcePresence[bare] = resources.isEmpty ? nil : resources
            } else {
                resourcePresence[bare] = nil
            }
            refreshPresence(of: bare)
        case "subscribe":
            let requester = JID(bare: bare)
            if !pendingSubscriptionRequests.contains(requester) {
                pendingSubscriptionRequests.append(requester)
            }
        case "unsubscribe":
            pendingSubscriptionRequests.removeAll(where: { $0 == from })
        default:
            // subscribed / unsubscribed / probe / error: roster pushes carry the state.
            break
        }
    }

    private func handleIQ(_ stanza: XMPPElement) {
        let type = stanza.attribute("type") ?? ""
        // Results and errors for requests we don't wait on are ignored.
        guard type == "get" || type == "set" else { return }
        guard let id = stanza.attribute("id") else { return }

        if type == "set", let query = stanza.child(named: "query"), query.xmlns == XMPPNamespace.roster {
            handleRosterPush(stanza, query: query, id: id)
            return
        }
        if type == "get", stanza.child(named: "ping", xmlns: XMPPNamespace.ping) != nil {
            var pong = XMPPElement(name: "iq", attributes: ["type": "result", "id": id])
            if let from = stanza.attribute("from") {
                pong.attributes["to"] = from
            }
            write(pong)
            return
        }

        var reply = XMPPElement(name: "iq", attributes: ["type": "error", "id": id])
        if let from = stanza.attribute("from") {
            reply.attributes["to"] = from
        }
        let condition = XMPPElement(name: "service-unavailable", attributes: ["xmlns": XMPPNamespace.stanzas])
        reply.children = [XMPPElement(name: "error", attributes: ["type": "cancel"], children: [condition])]
        write(reply)
    }

    private func handleRosterPush(_ stanza: XMPPElement, query: XMPPElement, id: String) {
        if let fromText = stanza.attribute("from") {
            // RFC 6121 2.1.6: a push must come from the server (no 'from') or our own bare JID.
            guard let from = JID(fromText), from.isBare, let me = account, from.bare == me.bare else {
                return
            }
        }
        for item in query.children(named: "item") {
            applyRosterItem(item)
        }
        roster = XMPPClient.sortedBuddies(roster)
        write(XMPPElement(name: "iq", attributes: ["type": "result", "id": id]))
    }

    // MARK: - Roster and presence bookkeeping

    private func replaceRoster(with items: [XMPPElement]) {
        var buddies: [Buddy] = []
        for item in items {
            guard let jidText = item.attribute("jid"), let parsed = JID(jidText) else { continue }
            let subscriptionText = item.attribute("subscription") ?? "none"
            if subscriptionText == "remove" {
                continue
            }
            let jid = parsed.bareJID
            if buddies.contains(where: { $0.jid == jid }) {
                continue
            }
            buddies.append(makeBuddy(from: item, jid: jid, subscriptionText: subscriptionText))
        }
        roster = XMPPClient.sortedBuddies(buddies)
    }

    private func applyRosterItem(_ item: XMPPElement) {
        guard let jidText = item.attribute("jid"), let parsed = JID(jidText) else { return }
        let jid = parsed.bareJID
        let subscriptionText = item.attribute("subscription") ?? "none"
        if subscriptionText == "remove" {
            roster.removeAll(where: { $0.jid == jid })
            return
        }
        let buddy = makeBuddy(from: item, jid: jid, subscriptionText: subscriptionText)
        if let index = roster.firstIndex(where: { $0.jid == jid }) {
            roster[index] = buddy
        } else {
            roster.append(buddy)
        }
    }

    private func makeBuddy(from item: XMPPElement, jid: JID, subscriptionText: String) -> Buddy {
        var name = item.attribute("name")
        if let text = name, text.isEmpty {
            name = nil
        }
        let groups = item.children(named: "group").map { $0.text }.filter { !$0.isEmpty }
        let aggregated = aggregatePresence(of: jid.bare)
        return Buddy(jid: jid,
                     name: name,
                     subscription: RosterSubscription(rawValue: subscriptionText) ?? RosterSubscription.none,
                     ask: item.attribute("ask"),
                     groups: groups,
                     presence: aggregated.show,
                     statusText: aggregated.status)
    }

    private func refreshPresence(of bare: BareJID) {
        guard let index = roster.firstIndex(where: { $0.jid.bare == bare }) else { return }
        let aggregated = aggregatePresence(of: bare)
        if roster[index].presence != aggregated.show || roster[index].statusText != aggregated.status {
            roster[index].presence = aggregated.show
            roster[index].statusText = aggregated.status
        }
    }

    /// Best presence over all resources: available beats away, then higher priority, then newer.
    private func aggregatePresence(of bare: BareJID) -> (show: PresenceShow, status: String?) {
        guard let resources = resourcePresence[bare] else {
            return (show: PresenceShow.offline, status: nil)
        }
        var best: ResourcePresence? = nil
        for candidate in resources.values {
            if let current = best {
                if XMPPClient.isBetter(candidate, than: current) {
                    best = candidate
                }
            } else {
                best = candidate
            }
        }
        guard let winner = best else {
            return (show: PresenceShow.offline, status: nil)
        }
        return (show: winner.show, status: winner.status)
    }

    private static func isBetter(_ lhs: ResourcePresence, than rhs: ResourcePresence) -> Bool {
        let lhsRank = lhs.show == .available ? 2 : 1
        let rhsRank = rhs.show == .available ? 2 : 1
        if lhsRank != rhsRank {
            return lhsRank > rhsRank
        }
        if lhs.priority != rhs.priority {
            return lhs.priority > rhs.priority
        }
        return lhs.received > rhs.received
    }

    private static func sortedBuddies(_ buddies: [Buddy]) -> [Buddy] {
        return buddies.sorted { (lhs: Buddy, rhs: Buddy) -> Bool in
            let order = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
            if order != .orderedSame {
                return order == .orderedAscending
            }
            return lhs.jid.bare < rhs.jid.bare
        }
    }

    // MARK: - Teardown and errors

    private func tearDown() {
        generation += 1
        sessionTask?.cancel()
        sessionTask = nil
        keepaliveTask?.cancel()
        keepaliveTask = nil
        watchdogTask?.cancel()
        watchdogTask = nil
        connectAttemptTimedOut = false
        transport?.close()
        transport = nil
        streamHeaderSent = false
        parser.reset()
        bufferedEvents.removeAll()
        phase = .idle
        resourcePresence.removeAll()
        ownPresence = .offline
        ownStatus = nil
        if roster.contains(where: { $0.presence != .offline }) {
            roster = roster.map { (buddy: Buddy) -> Buddy in
                var offline = buddy
                offline.presence = .offline
                offline.statusText = nil
                return offline
            }
        }
    }

    private func fail(_ error: Error) {
        let message = userMessage(for: error)
        tearDown()
        connectionState = .failed(message)
    }

    private func checkGeneration(_ gen: Int) throws {
        if gen != generation {
            throw Superseded()
        }
    }

    private func startWatchdog(after seconds: TimeInterval, generation gen: Int, abortsLogin: Bool) {
        watchdogTask?.cancel()
        connectAttemptTimedOut = false
        let nanoseconds = UInt64(max(seconds, 0.001) * 1_000_000_000)
        watchdogTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            if Task.isCancelled {
                return
            }
            guard let self = self, self.generation == gen else { return }
            if abortsLogin {
                if self.phase != .online {
                    self.fail(XMPPError.timedOut)
                }
            } else {
                // Abandon this address; connect(to:) moves on to the next one.
                self.connectAttemptTimedOut = true
                self.transport?.close()
            }
        }
    }

    private func startKeepalive(generation gen: Int) {
        keepaliveTask?.cancel()
        let nanoseconds = UInt64(max(keepaliveInterval, 1) * 1_000_000_000)
        keepaliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: nanoseconds)
                if Task.isCancelled {
                    return
                }
                guard let self = self, self.generation == gen, self.connectionState == .online else { return }
                self.transport?.send(Data(" ".utf8))
            }
        }
    }

    private func userMessage(for error: Error) -> String {
        let duringTLS = phase == .tls
        let wasOnline = phase == .online
        if let xmppError = error as? XMPPError {
            if xmppError == .connectionClosed {
                if duringTLS {
                    return XMPPError.tlsFailed("").userMessage
                }
                if wasOnline {
                    return XMPPError.connectionLost.userMessage
                }
            }
            return xmppError.userMessage
        }
        if let transportError = error as? TransportError {
            switch transportError {
            case .hostNotFound(let host):
                return XMPPError.hostNotFound(host).userMessage
            case .tlsFailed(let detail):
                return XMPPError.tlsFailed(detail).userMessage
            case .timedOut:
                return XMPPError.timedOut.userMessage
            case .closed:
                if duringTLS {
                    return XMPPError.tlsFailed("").userMessage
                }
                return wasOnline ? XMPPError.connectionLost.userMessage : XMPPError.connectionClosed.userMessage
            case .connectionFailed(let detail):
                if duringTLS {
                    return XMPPError.tlsFailed(detail).userMessage
                }
                return wasOnline ? XMPPError.connectionLost.userMessage : XMPPError.connectionFailed(detail).userMessage
            }
        }
        if let saslError = error as? SASLError {
            switch saslError {
            case .noSupportedMechanism:
                return XMPPError.noSupportedMechanism.userMessage
            case .serverSignatureMismatch, .missingServerSignature:
                return XMPPError.serverSignatureInvalid.userMessage
            case .serverError(let detail):
                if detail == "invalid-proof" || detail == "unknown-user" {
                    return XMPPError.authenticationFailed(condition: "not-authorized", text: nil).userMessage
                }
                return XMPPError.authenticationFailed(condition: detail, text: nil).userMessage
            default:
                return XMPPError.protocolError("the server sent an invalid sign-in challenge").userMessage
            }
        }
        return error.localizedDescription
    }

    // MARK: - Writing helpers

    private func write(_ element: XMPPElement) {
        transport?.send(Data(element.xmlString.utf8))
    }

    private func sendStreamHeader(domain: String) {
        let header = "<?xml version='1.0'?>"
            + "<stream:stream to='" + XMLEscaping.escapeAttribute(domain) + "'"
            + " xmlns='jabber:client' xmlns:stream='http://etherx.jabber.org/streams'"
            + " version='1.0' xml:lang='en'>"
        transport?.send(Data(header.utf8))
        streamHeaderSent = true
    }

    private func writeSASL(_ name: String, mechanism: SASLMechanism?, payload: Data?) {
        var element = XMPPElement(name: name, attributes: ["xmlns": XMPPNamespace.sasl])
        if let mechanism = mechanism {
            element.attributes["mechanism"] = mechanism.rawValue
        }
        if let payload = payload {
            element.text = payload.isEmpty ? "=" : payload.base64EncodedString()
        }
        write(element)
    }

    private func rosterSet(_ item: XMPPElement) -> XMPPElement {
        let query = XMPPElement(name: "query", attributes: ["xmlns": XMPPNamespace.roster], children: [item])
        return XMPPElement(name: "iq", attributes: ["type": "set", "id": makeID("roster")], children: [query])
    }

    private func presenceElement(show: PresenceShow, status: String?) -> XMPPElement {
        var presence = XMPPElement(name: "presence")
        switch show {
        case .available:
            break
        case .away:
            presence.children.append(XMPPElement(name: "show", text: "away"))
        case .offline:
            presence.attributes["type"] = "unavailable"
        }
        if let status = status, !status.isEmpty {
            presence.children.append(XMPPElement(name: "status", text: status))
        }
        return presence
    }

    private func makeID(_ prefix: String) -> String {
        stanzaCounter += 1
        return prefix + "-" + String(stanzaCounter)
    }

    private func decodeSASLPayload(_ text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "=" {
            return ""
        }
        guard let data = Data(base64Encoded: trimmed) else {
            throw XMPPError.protocolError("the server sent invalid SASL data")
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func saslFailure(_ element: XMPPElement) -> XMPPError {
        let condition = element.children.first(where: { $0.name != "text" })?.name ?? ""
        return .authenticationFailed(condition: condition, text: element.child(named: "text")?.text)
    }

    private func stanzaErrorCondition(_ stanza: XMPPElement) -> String {
        guard let error = stanza.child(named: "error") else { return "unknown error" }
        return error.children.first(where: { $0.name != "text" })?.name ?? "unknown error"
    }

    private func isStreamElement(_ element: XMPPElement, _ localName: String) -> Bool {
        if element.name == "stream:" + localName {
            return true
        }
        return element.localName == localName && element.xmlns == XMPPNamespace.streams
    }

    private func streamError(from element: XMPPElement) -> XMPPError {
        let condition = element.children.first(where: { $0.name != "text" })?.name ?? "undefined-condition"
        return .streamError(condition: condition, text: element.child(named: "text")?.text)
    }

    private static func normalisedHost(_ host: String?) -> String? {
        guard let host = host else { return nil }
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func delayedDate(of stanza: XMPPElement) -> Date? {
        guard let delay = stanza.child(named: "delay", xmlns: XMPPNamespace.delay),
              let stamp = delay.attribute("stamp") else {
            return nil
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: stamp) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: stamp)
    }
}
