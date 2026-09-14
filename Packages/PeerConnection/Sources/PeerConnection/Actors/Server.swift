//
//  Server.swift
//  PeerConnection
//
//  The listener side of the connection, from Apple's "Connecting iPadOS and
//  visionOS apps over the local network" sample. In this demo the iPhone is
//  the server and the Apple Vision Pro is the client.
//

import Network
import OSLog

/// The server publishes a Bonjour service, accepts every inbound connection,
/// and keeps the one the client opens a stream on. Actor isolation ensures
/// thread-safe network operations without data races.
public actor Server<Message: PeerToPeerMessage>: PeerMessagingManager {
    private let logger = Logger(subsystem: PeerConnectionLogging.subsystem,
                                category: "Server")

    /// TLS identity for this device, cached and reused across connections.
    private var localIdentity: sec_identity_t?
    /// Current device ID, used to detect when to regenerate the identity.
    private var currentDeviceID: String?

    /// The connection carrying the live stream, if any. The demo is exactly
    /// one iPhone and one Apple Vision Pro, so one peer.
    private var currentConnectionInfo: (connection: QuicConnection, stream: QuicStream<Message>)? = nil

    /// One servicing task per inbound connection, keyed by the connection.
    ///
    /// One client reaches this listener over several network paths at once -
    /// link-local, unique-local, and global IPv6 plus IPv4, over both
    /// infrastructure Wi-Fi and peer-to-peer, because the parameters include
    /// both. Each path arrives as its own connection with its own completed
    /// TLS handshake, but the client keeps exactly one and opens its stream
    /// there. Servicing only the first arrival, as the sample does, lets the
    /// two ends pick different connections; when they disagree the client's
    /// connection is never given a stream and the demo never connects. So
    /// every arrival is serviced, the one that opens a stream becomes live,
    /// and the rest are ended.
    ///
    /// Ending one means cancelling its task: in this API a connection has no
    /// cancel of its own and lives exactly as long as the task awaiting its
    /// streams.
    private var serviceTasksByConnection: [ObjectIdentifier: Task<Void, Never>] = [:]

    /// Whether the live connection's stop has been reported. A failure can
    /// surface from both the connection's state and the stream's error; the
    /// controller needs to hear it once.
    private var didReportStop = false

    /// The task that receives messages from the connected peer.
    private var messageReceiveTask: Task<Void, Never>? = nil

    // Received messages.
    public let receivedMessages: AsyncStream<Message>
    private let receivedMessageContinuation: AsyncStream<Message>.Continuation

    // General state update events for the `NetworkListener` and `NetworkConnection`.
    public let networkUpdateEvents: AsyncStream<NetworkEvent>
    private let networkUpdateContinuation: AsyncStream<NetworkEvent>.Continuation

    public init() {
        // Create more than one asynchronous stream for pushing events and messages to the controller.
        // Continuations let the actor relay values, and streams let the controller consume them.
        (self.networkUpdateEvents, self.networkUpdateContinuation) = AsyncStream.makeStream(of: NetworkEvent.self)
        (self.receivedMessages, self.receivedMessageContinuation) = AsyncStream.makeStream(of: Message.self)
    }

    /// Publishes the Bonjour service and waits for incoming client connections.
    /// - Parameter id: The pairing ID, which must match on both devices.
    public func start(with id: String) async throws {
        // Get the TLS local identity before running the `NetworkListener`.
        fetchLocalIdentity(for: id)

        // Use cached local identity.
        guard let localIdentity else {
            networkUpdateContinuation.yield(.tlsFailed(TLSError.localIdentityDoesNotExist))
            return
        }

        // Create the `NetworkListener` using Bonjour and QUIC, and use the local identity to configure TLS.
        try await NetworkListener(
            for: .bonjour(
                name: NetworkServiceConstants.listenerName,
                type: NetworkServiceConstants.serviceType,
                txtRecord: createTXTRecord(with: id)
            ), using: .parameters {
                QUIC(alpn: [NetworkServiceConstants.alpn])
                    .idleTimeout(NetworkServiceConstants.idleTimeoutInterval)
                    .tls.localIdentity(localIdentity)
                    .tls.peerAuthentication(.required)
                    .tls.certificateValidator { metadata, trustResult in
                        let isVerified = CertificateTrustManager.verifyCertificate(metadata: metadata,
                                                                                    trustResult: trustResult)
                        if !isVerified {
                            self.networkUpdateContinuation.yield(.tlsFailed(TLSError.certificateVerificationFailed))
                        }
                        return isVerified
                    }
            }
                .peerToPeerIncluded(true)
                .multipathServiceType(.disabled)
        )
        .onStateUpdate { _, state in
            self.handleListenerStateUpdates(state)
        }
        .run { connection in
            // Observe the connection's state to know when it cancels or fails.
            connection.onStateUpdate { connection, state in
                switch state {
                case .cancelled:
                    self.reportStopIfLive(connection,
                                          error: nil)
                case .failed(let error):
                    self.reportStopIfLive(connection,
                                          error: error)
                default: break
                }
            }

            // Service the connection in a task of its own, so it can be ended
            // on its own once the client's choice is known.
            let key = ObjectIdentifier(connection)
            let serviceTask = Task {
                await self.getInboundStreams(on: connection)
            }
            self.serviceTasksByConnection[key] = serviceTask
            self.logger.log("Inbound connection accepted; \(self.serviceTasksByConnection.count, privacy: .public) open.")

            await serviceTask.value
            self.serviceTasksByConnection.removeValue(forKey: key)
        }
    }

    /// Waits for the client to open the inbound stream, then sets up message receiving.
    /// The server doesn't open streams; it accepts streams opened by the client.
    private func getInboundStreams(on connection: QuicConnection) async {
        do {
            // Create a `Coder` that automatically encodes and decodes the message type as JSON.
            try await connection.inboundStreams { stack in
                Coder(Message.self, using: .json) {
                    stack
                }
            } _: { stream in
                self.adoptLiveConnection(connection,
                                         stream: stream)
            }
        } catch {
            // A path the client discarded ends here by design, as does one
            // this actor ended itself. Only the live connection's failure is
            // reported, and only once.
            logger.debug("Stream not established on this path: \(error.localizedDescription, privacy: .private)")
            reportStopIfLive(connection,
                             error: error as? NWError)
        }
    }

    /// The client opened its stream on this connection, so this is the one
    /// it kept. Everything else goes.
    private func adoptLiveConnection(_ connection: QuicConnection,
                                     stream: QuicStream<Message>)
    {
        // A stream on a second connection means the client reconnected before
        // the previous connection idled out; the old one is done.
        if let previous = currentConnectionInfo,
           previous.connection !== connection {
            messageReceiveTask?.cancel()
            currentConnectionInfo = nil
            serviceTasksByConnection.removeValue(forKey: ObjectIdentifier(previous.connection))?.cancel()
        }

        // Every other path is one the client did not keep.
        let liveKey = ObjectIdentifier(connection)
        for (key, task) in serviceTasksByConnection where key != liveKey {
            task.cancel()
        }
        serviceTasksByConnection = serviceTasksByConnection.filter { $0.key == liveKey }

        didReportStop = false
        currentConnectionInfo = (connection, stream)
        logger.log("Stream opened; this is the live connection.")
        networkUpdateContinuation.yield(.connection(.ready))

        // Start receiving messages on the stream.
        messageReceiveTask = receiveMessages(on: stream,
                                            connection: connection)
    }

    /// Whether the given connection is the one carrying the live stream.
    private func isLiveConnection(_ connection: QuicConnection) -> Bool {
        guard let currentConnectionInfo else { return false }

        return currentConnectionInfo.connection === connection
    }

    /// Reports a stop to the controller if, and only if, it is the live
    /// connection stopping, and it has not been reported already.
    private func reportStopIfLive(_ connection: QuicConnection,
                                  error: NWError?)
    {
        guard isLiveConnection(connection),
              !didReportStop
        else {
            return
        }

        didReportStop = true
        networkUpdateContinuation.yield(.connection(.stopped(error)))
    }

    /// Relays messages based on the given `NetworkListener` state.
    private func handleListenerStateUpdates(_ state: NetworkListener<QUIC>.State) {
        switch state {
        case .ready:
            networkUpdateContinuation.yield(.listenerRunning)
        case .failed(let error):
            networkUpdateContinuation.yield(.listenerStopped(error))
        case .cancelled:
            networkUpdateContinuation.yield(.listenerStopped(nil))
        default:
            break
        }
    }

    /// Drops every connection this listener holds. Called by the controller
    /// whenever the network winds down.
    public func invalidate() {
        messageReceiveTask?.cancel()
        messageReceiveTask = nil
        currentConnectionInfo = nil

        for task in serviceTasksByConnection.values {
            task.cancel()
        }
        serviceTasksByConnection.removeAll()
        didReportStop = false
    }

    deinit {
        currentConnectionInfo = nil
        messageReceiveTask?.cancel()
        messageReceiveTask = nil
        receivedMessageContinuation.finish()
        networkUpdateContinuation.finish()
    }
}

// MARK: - Sending and receiving
extension Server {

    /// Sends a message over the live QUIC stream. Reports a stop if sending
    /// fails; the demo only connects to one peer.
    public func send(_ message: Message) async {
        guard let currentConnectionInfo
        else {
            logger.error("Dropped an outbound message: no live stream.")

            return
        }

        do {
            try await currentConnectionInfo.stream.send(message)
        } catch {
            logger.error("Sending failed: \(error.localizedDescription, privacy: .private)")
            reportStopIfLive(currentConnectionInfo.connection,
                             error: error as? NWError)
        }
    }

    /// Returns a task that continuously receives messages from the given stream.
    /// The protocol stack with `Coder` decodes messages automatically.
    private func receiveMessages(on stream: QuicStream<Message>,
                                 connection: QuicConnection) -> Task<Void, Never>
    {
        return Task {
            do {
                // Iterate through incoming messages from the QUIC stream and relay them using `receivedMessageContinuation`.
                for try await (message, metadata) in stream.messages {
                    self.receivedMessageContinuation.yield(message)
                    // The stream has ended; the peer is done.
                    if metadata.lastMessage {
                        self.reportStopIfLive(connection,
                                              error: nil)
                    }
                }
            } catch {
                logger.error("Error receiving messages: \(error.localizedDescription, privacy: .private)")
                self.reportStopIfLive(connection,
                                      error: error as? NWError)
            }
        }
    }
}

// MARK: - Helper methods
extension Server {
    /// Create an `NWTXTRecord` with the device ID for Bonjour discovery filtering.
    private func createTXTRecord(with id: String) -> NWTXTRecord {
        var record = NWTXTRecord()
        record[NetworkServiceConstants.deviceIdentifier] = id

        return record
    }

    /// Fetches the TLS local identity of the device on first run or if the stored device ID changes.
    private func fetchLocalIdentity(for id: String) {
        if currentDeviceID != id {
            guard let identity = TLSIdentity.getLocalIdentity(label: id)
            else {
                // If getting the local identity fails, relay the error. This updates the UI.
                networkUpdateContinuation.yield(.tlsFailed(TLSError.localIdentityDoesNotExist))
                return
            }

            localIdentity = identity
            currentDeviceID = id
        }
    }
}
