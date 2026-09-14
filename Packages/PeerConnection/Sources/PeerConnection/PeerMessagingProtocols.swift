//
//  PeerMessagingProtocols.swift
//  PeerConnection
//
//  The connection actor interface and message requirements, from Apple's
//  "Connecting iPadOS and visionOS apps over the local network" sample.
//

import Foundation

/// Message type for peer-to-peer communication. Must be JSON-encodable and thread-safe.
public protocol PeerToPeerMessage: Codable, Sendable, Hashable {}

/// Actor interface for client-server implementing peer-to-peer messaging.
/// Actors provide thread-safe networking operations isolated from the UI.
public protocol PeerMessagingManager<Message>: Actor where Message: PeerToPeerMessage {
    associatedtype Message: PeerToPeerMessage

    /// Stream of messages received from the connected peer.
    var receivedMessages: AsyncStream<Message> { get }
    /// Stream of network life cycle events (connecting, connected, stopped, and so on).
    var networkUpdateEvents: AsyncStream<NetworkEvent> { get }

    /// Send a message to the connected peer.
    func send(_ message: Message) async
    /// Drop the current connection, if any, without stopping discovery. The
    /// client's `start(with:)` returns so the controller browses again; the
    /// server's listener keeps running under it, ready to accept the peer's
    /// reconnect.
    func invalidate()
    /// Runs the client's browse-and-connect or the server's listener. Returns
    /// when the current connection ends (the client) or the listener stops
    /// (the server); the controller calls it in a loop to reconnect. Throwing
    /// or returning both hand control back to that loop.
    func start(with id: String) async throws

    init()
}
