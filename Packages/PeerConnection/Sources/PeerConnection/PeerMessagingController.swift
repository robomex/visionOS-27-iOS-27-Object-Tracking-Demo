//
//  PeerMessagingController.swift
//  PeerConnection
//
//  Bridges the networking actors to MainActor UI state, from Apple's
//  "Connecting iPadOS and visionOS apps over the local network" sample, with
//  two additions this demo's zero-tap connection flow needs: an ordered
//  outbound queue, and a reconnect loop that owns discovery, so the two apps
//  find each other, and find each other again after a drop, with no taps.
//

import Network
import OSLog
import SwiftUI

/// Bridges actor-isolated networking (client or server) with `MainActor` UI
/// updates.
/// - Network operations run in an actor (thread-safe, isolated).
/// - UI state updates run on `MainActor` (synchronous UI updates).
/// - Messages broadcast to multiple views using `AsyncStream` continuations.
@MainActor @Observable
public final class PeerMessagingController<Manager: PeerMessagingManager> {
    private let logger = Logger(subsystem: PeerConnectionLogging.subsystem,
                                category: "PeerMessagingController")

    /// Network connection actor for isolated network operations, either client or server.
    let peerMessagingManager: Manager

    /// Current connection state for UI binding.
    public private(set) var connectionState: NetworkState = .stopped {
        didSet {
            guard oldValue != connectionState else { return }

            logger.log("Connection state: \(oldValue.rawValue, privacy: .public) → \(self.connectionState.rawValue, privacy: .public)")
        }
    }
    public private(set) var errorMessage: String?

    // Tasks for monitoring state.
    @ObservationIgnored private var monitorTask: Task<Void, Never>?

    /// The one reconnect loop. Non-nil for the controller's whole life once
    /// started: it browses or listens, reconnects when a connection ends, and
    /// stops only when cancelled at teardown.
    @ObservationIgnored private var networkTask: Task<Void, Never>?

    /// Outbound messages, in the order they were sent. `send(_:)` yields into
    /// this stream and one drain task forwards to the actor one message at a
    /// time, so two messages sent back to back arrive in that order. Sending
    /// each from its own task would hand the actor two independent jobs with
    /// no ordering between them, and this demo's phase protocol depends on
    /// the order.
    @ObservationIgnored private let outboundMessages: AsyncStream<Manager.Message>
    @ObservationIgnored private let outboundContinuation: AsyncStream<Manager.Message>.Continuation

    /// Broadcast incoming messages to multiple consumers (such as multiple views).
    /// Each consumer gets its own `AsyncStream` with a unique continuation.
    @ObservationIgnored private var incomingMessageContinuations: [UUID: AsyncStream<Manager.Message>.Continuation] = [:]

    /// Creates a new message stream for each consumer that needs to receive messages.
    public var incomingMessages: AsyncStream<Manager.Message> {
        AsyncStream { continuation in
            let id = UUID()
            self.incomingMessageContinuations[id] = continuation

            // Clean up when the consumer stops listening.
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.incomingMessageContinuations.removeValue(forKey: id)
                }
            }
        }
    }

    public init() {
        // Either the client or server.
        self.peerMessagingManager = Manager()
        // Unbounded: the rate is low and every message matters.
        (self.outboundMessages, self.outboundContinuation) = AsyncStream.makeStream(of: Manager.Message.self,
                                                                                     bufferingPolicy: .unbounded)

        // Monitor state events, incoming messages, and the outbound queue
        // concurrently. Weak captures let the controller deinitialize, at
        // which point the streams finish and the group ends.
        self.monitorTask = Task { @MainActor [weak self] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask { [weak self] in await self?.monitorStateEvents() }
                group.addTask { [weak self] in await self?.broadcastMessages() }
                group.addTask { [weak self] in await self?.drainOutboundMessages() }
            }
        }
    }

    /// Starts the one reconnect loop. Called once, at launch; a second call is
    /// a no-op while the loop runs. The loop owns reconnection: nothing else
    /// restarts the connection.
    public func start(with id: String) {
        guard networkTask == nil else { return }

        errorMessage = nil

        networkTask = Task { [weak self] in
            // The manager's `start` browses-and-connects (client) or listens
            // (server). It returns when the client's connection ends, or when
            // the server's listener stops; either way, loop and try again.
            // The loop runs until this task is cancelled at teardown.
            while !Task.isCancelled {
                guard let self else { break }

                do {
                    try await self.peerMessagingManager.start(with: id)
                } catch {
                    self.logger.error("A connection attempt ended with an error: \(error.localizedDescription, privacy: .private)")
                }

                await self.peerMessagingManager.invalidate()

                guard !Task.isCancelled else { break }

                // Pause before looking again so a persistent failure doesn't
                // spin the loop.
                try? await Task.sleep(for: NetworkServiceConstants.reconnectDelay)
            }
        }
    }

    /// Queues a message for the connected peer. Returns immediately; the
    /// drain task sends in order.
    public func send(_ message: Manager.Message) {
        outboundContinuation.yield(message)
    }

    /// Drops the current connection so the loop forms a fresh one. Discovery
    /// keeps running throughout: the client browses again, the server's
    /// listener stays up. Used by Forget Paired Device and by the app's
    /// dead-peer liveness check.
    public func disconnect() {
        Task { await peerMessagingManager.invalidate() }
        connectionState = .waitingForConnection
        errorMessage = nil
    }

    /// Stops the reconnect loop entirely and drops the current connection.
    /// Used when the app goes to the background: nothing should browse or
    /// listen while suspended, and the peer gets a clean drop rather than a
    /// zombie connection it has to time out. `start(with:)` begins a fresh
    /// loop when the app returns.
    public func stop() {
        networkTask?.cancel()
        networkTask = nil
        Task { await peerMessagingManager.invalidate() }
        connectionState = .stopped
        errorMessage = nil
    }

    isolated deinit {
        monitorTask?.cancel()
        monitorTask = nil
        networkTask?.cancel()
        networkTask = nil
        outboundContinuation.finish()
        incomingMessageContinuations.removeAll()
    }
}

// MARK: - Private monitoring methods
extension PeerMessagingController {
    /// Monitors state events from the manager and updates connection state.
    private func monitorStateEvents() async {
        for await event in await peerMessagingManager.networkUpdateEvents {
            handleStateEvent(event)
        }
    }

    /// Broadcasts messages to all subscribed consumers.
    private func broadcastMessages() async {
        for await command in await peerMessagingManager.receivedMessages {
            // Relay the message to all active consumers.
            for continuation in incomingMessageContinuations.values {
                continuation.yield(command)
            }
        }
    }

    /// Forwards queued outbound messages to the actor, one at a time.
    private func drainOutboundMessages() async {
        for await message in outboundMessages {
            await peerMessagingManager.send(message)
        }
    }

    /// Handles state events from the manager.
    private func handleStateEvent(_ event: NetworkEvent) {
        switch event {
        case .browserRunning, .listenerRunning:
            connectionState = .waitingForConnection
        case .connecting:
            connectionState = .connecting
        case .browserStopped(let error):
            // The browser stops on its own once it hands back an endpoint;
            // only a failure is worth noting. The loop retries either way.
            if let error {
                logger.error("The browser failed: \(error.localizedDescription, privacy: .private)")
            }
        case .listenerStopped(let error):
            // The listener stops only if it fails or is torn down; the loop
            // brings it back.
            if let error {
                logger.error("The listener failed: \(error.localizedDescription, privacy: .private)")
            }
        case .tlsFailed(let error):
            // The peer's certificate didn't match, usually because its app was
            // reinstalled. Surface it so a person knows to tap Forget; the
            // loop keeps trying, so the moment they do, it reconnects.
            logger.error("TLS handshake failed: \(String(describing: error), privacy: .public)")
            connectionState = .tlsFailed
            errorMessage = "The other device's certificate changed, usually because its app was reinstalled. Tap Forget Paired Device, then wait for it to reconnect."
        case .connection(.ready):
            connectionState = .connected
            errorMessage = nil
        case .connection(.stopped(let error)):
            if let error {
                logger.error("The connection stopped: \(error.localizedDescription, privacy: .private)")
            }
            // Drop the dead connection but keep discovering: the client
            // browses again, the server's listener is still up.
            Task { await peerMessagingManager.invalidate() }
            connectionState = .waitingForConnection
        }
    }
}
