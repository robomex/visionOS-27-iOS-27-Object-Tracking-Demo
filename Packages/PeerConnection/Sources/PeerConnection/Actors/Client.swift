//
//  Client.swift
//  PeerConnection
//
//  The browser side of the connection, from Apple's "Connecting iPadOS and
//  visionOS apps over the local network" sample. In this demo the Apple
//  Vision Pro is the client and the iPhone is the server.
//

import Network
import OSLog

/// The client discovers the server with Bonjour and connects to it.
/// Actor isolation ensures thread-safe network operations without data races.
public actor Client<Message: PeerToPeerMessage>: PeerMessagingManager {
    private let logger = Logger(subsystem: PeerConnectionLogging.subsystem,
                                category: "Client")

    /// TLS identity for this device, cached and reused across connections.
    private var localIdentity: sec_identity_t?
    /// Current device ID, used to detect when to regenerate the identity.
    private var currentDeviceID: String?

    /// The current connection, and stream if any.
    /// The demo is exactly one iPhone and one Apple Vision Pro, so one peer.
    private var currentConnectionInfo: (connection: QuicConnection, stream: QuicStream<Message>)? = nil

    /// The task that receives messages from the connected peer.
    private var messageReceiveTask: Task<Void, Never>? = nil

    // Received messages.
    public let receivedMessages: AsyncStream<Message>
    private let receivedMessageContinuation: AsyncStream<Message>.Continuation

    // General state update events for the `NetworkBrowser` and `NetworkConnection`.
    public let networkUpdateEvents: AsyncStream<NetworkEvent>
    private let networkUpdateContinuation: AsyncStream<NetworkEvent>.Continuation

    public init() {
        // Create more than one asynchronous stream for pushing events and messages to the controller.
        // Continuations let the actor relay values, and streams let the controller consume them.
        (self.networkUpdateEvents, self.networkUpdateContinuation) = AsyncStream.makeStream(of: NetworkEvent.self)
        (self.receivedMessages, self.receivedMessageContinuation) = AsyncStream.makeStream(of: Message.self)
    }

    /// Discovers listeners using Bonjour, filters by device ID, and connects to a matching endpoint.
    /// - Parameter id: The pairing ID, which must match on both devices.
    public func start(with id: String) async throws {
        // Get the TLS local identity before running the `NetworkBrowser`.
        // Checking here, not after discovery, means a device that cannot
        // make an identity reports it immediately instead of browsing
        // forever.
        fetchLocalIdentity(for: id)

        guard localIdentity != nil
        else {
            networkUpdateContinuation.yield(.tlsFailed(TLSError.localIdentityDoesNotExist))
            return
        }

        // Create the `NetworkBrowser` using Bonjour and QUIC.
        let endpoint = try await NetworkBrowser(
            for: .bonjour(
                NetworkServiceConstants.serviceType,
                includeTxtRecord: true),
            using: .quic(alpn: [NetworkServiceConstants.alpn]))
            .onStateUpdate { _, state in
                self.handleBrowserStateUpdates(state)
            }
            .run { endpoints in
                // Filter discovered endpoints by text records matching the ID.
                // This ensures the browser only connects to the intended device.
                for endpoint in endpoints {
                    let textRecord = endpoint.txtRecord
                    // If the incoming endpoint has the same identifier as the device ID, return that endpoint.
                    if textRecord[NetworkServiceConstants.deviceIdentifier] == id {
                        return .finish(endpoint)
                    } else {
                        self.logger.debug("Found an endpoint without the expected identifier: \(String(describing: endpoint), privacy: .private)")
                    }
                }
                // Continue browsing.
                return .continue
            }

        // Create and set up the connection.
        await createConnection(to: endpoint)

        // Block until this connection ends: its stream closes, it errors, or
        // `invalidate()` cancels the receive task on a disconnect. Returning
        // hands control back to the controller's reconnect loop, which browses
        // again. The cancellation handler covers teardown - the controller
        // cancels the loop task, and this makes the receive task, which was
        // spawned on the actor and wouldn't otherwise see that cancellation,
        // stop too.
        await withTaskCancellationHandler {
            await messageReceiveTask?.value
        } onCancel: {
            Task { await self.invalidate() }
        }
    }

    /// Creates a QUIC connection with mutual TLS authentication using self-signed certificates.
    /// Both devices verify each other's certificates using a trust on first use (TOFU) model.
    private func createConnection(to endpoint: Bonjour.Endpoint) async {
        // Use cached local identity.
        guard let localIdentity
        else {
            // Stop if the local identity doesn't exist.
            networkUpdateContinuation.yield(.tlsFailed(TLSError.localIdentityDoesNotExist))
            return
        }

        // Relay connecting to update the UI.
        networkUpdateContinuation.yield(.connecting)

        // Create the connection to the endpoint, using the local identity to configure TLS.
        let connection = NetworkConnection(
            to: endpoint,
            using: .parameters {
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
        ).start()

        // Observe the state update of the connection to know when it cancels or fails.
        connection.onStateUpdate { connection, state in
            switch state {
            case .cancelled:
                self.networkUpdateContinuation.yield(.connection(.stopped(nil)))
            case .failed(let error):
                self.networkUpdateContinuation.yield(.connection(.stopped(error)))
            default: break
            }
        }

        // Open a stream with the new connection.
        await openStream(on: connection)
    }

    /// Opens a bidirectional stream on the connection.
    private func openStream(on connection: QuicConnection) async {
        do {
            // Configure the stream to automatically encode and decode the message type as JSON.
            let stream = try await connection.openStream { stack in
                Coder(Message.self, using: .json) {
                    stack
                }
            }
            // Set as the current connection and stream.
            self.currentConnectionInfo = (connection, stream)
            self.networkUpdateContinuation.yield(.connection(.ready))

            // Start receiving messages on the stream.
            self.messageReceiveTask = self.receiveMessages(on: stream)
        } catch {
            // Because the demo only connects to one peer, stop the connection when the stream fails.
            logger.error("Could not open a stream: \(error.localizedDescription, privacy: .private)")
            networkUpdateContinuation.yield(.connection(.stopped(error as? NWError)))
        }
    }

    /// Relays messages based on the given `NetworkBrowser` state.
    private func handleBrowserStateUpdates(_ state: NetworkBrowser<Bonjour>.State) {
        switch state {
        case .ready:
            networkUpdateContinuation.yield(.browserRunning)
        case .failed(let error):
            networkUpdateContinuation.yield(.browserStopped(error))
        case .cancelled:
            networkUpdateContinuation.yield(.browserStopped(nil))
        default: break
        }
    }

    /// Invalidate the current connection if it fails or someone cancels it.
    public func invalidate() {
        messageReceiveTask?.cancel()
        messageReceiveTask = nil
        currentConnectionInfo = nil
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
extension Client {
    /// Sends a message on the current QUIC stream.
    /// Stops the connection if message sending throws; the demo only connects to one peer.
    public func send(_ message: Message) async {
        guard let stream = currentConnectionInfo?.stream
        else {
            logger.error("Dropped an outbound message: no live stream.")

            return
        }

        do {
            try await stream.send(message)
        } catch {
            logger.error("Sending failed: \(error.localizedDescription, privacy: .private)")
            networkUpdateContinuation.yield(.connection(.stopped(error as? NWError)))
        }
    }

    /// Returns a task that continuously receives messages from the given stream.
    /// The protocol stack with `Coder` decodes messages automatically.
    private func receiveMessages(on stream: QuicStream<Message>) -> Task<Void, Never> {
        return Task {
            do {
                // Iterate through incoming messages from the QUIC stream and relay them using `receivedMessageContinuation`.
                for try await (message, metadata) in stream.messages {
                    self.receivedMessageContinuation.yield(message)

                    if metadata.lastMessage {
                        // The stream has ended; stop the connection as the demo only connects to one peer at a time.
                        self.networkUpdateContinuation.yield(.connection(.stopped(nil)))
                    }
                }
            } catch {
                logger.error("Message receiving error: \(error.localizedDescription, privacy: .private)")
                networkUpdateContinuation.yield(.connection(.stopped(error as? NWError)))
            }
        }
    }
}

// MARK: - Helper methods
extension Client {
    /// Fetches the TLS local identity of the device on first run or if the stored device ID changes.
    private func fetchLocalIdentity(for id: String) {
        if currentDeviceID != id {
            guard let identity = TLSIdentity.getLocalIdentity(label: id)
            else {
                // If getting the local identity fails, relay the error.
                networkUpdateContinuation.yield(.tlsFailed(TLSError.localIdentityDoesNotExist))
                return
            }

            localIdentity = identity
            currentDeviceID = id
        }
    }
}
