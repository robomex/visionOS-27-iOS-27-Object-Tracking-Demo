//
//  ConnectionTypes.swift
//  PeerConnection
//
//  Connection type definitions and type aliases, from Apple's "Connecting
//  iPadOS and visionOS apps over the local network" sample, with this demo's
//  service constants.
//

import Foundation
import Network

// Type aliases for connections.
public typealias QuicConnection = NetworkConnection<QUIC>

public typealias QuicStream<Message: PeerToPeerMessage> = QUIC.Stream<Coder<Message, Message, NetworkJSONCoder>>

/// Events that occur during client-server life cycle and connection state changes.
public enum NetworkEvent: Sendable {
    case browserRunning
    case connecting
    case browserStopped(NWError?)

    case listenerRunning
    case listenerStopped(NWError?)
    case tlsFailed(TLSError?)
    case connection(ConnectionEvent)

    public enum ConnectionEvent: Sendable {
        case ready
        case stopped(NWError?)
    }
}

/// UI-friendly connection states mapped from `NetworkEvent`. `stopped` is
/// also the initial state: nothing is running until `start(with:)`.
public enum NetworkState: String, Sendable {
    case stopped
    case tlsFailed
    case connected
    case connecting
    case waitingForConnection
}

/// Constants for Bonjour service discovery and QUIC connection.
public enum NetworkServiceConstants {
    /// Application-Layer Protocol Negotiation (ALPN). Must match on both devices.
    public static let alpn = "otu-demo"

    /// Bonjour service type: the ALPN + `._udp` (transport protocol).
    /// Must match the `NSBonjourServices` entry in the app's Info.plist.
    public static let serviceType = "_otu-demo._udp"

    /// A human-readable name, shown in network browser results.
    public static let listenerName = "otu-listener"

    /// TXT record key for filtering endpoints by matching the device ID.
    public static let deviceIdentifier = "device-identifier"

    /// The one pairing ID both devices use. Apple's sample has people type
    /// matching IDs because many pairs might share a network; this demo is
    /// exactly one iPhone and one Apple Vision Pro on a Bonjour service type
    /// that is already unique to it, so typing a code would be pure
    /// friction. The ID doubles as each device's TLS identity label and as
    /// the trust-on-first-use key for the peer's certificate.
    public static let fixedPairingID = "otu-demo"

    /// Drop the QUIC connection after this long with no traffic. A backstop
    /// only: the app's heartbeat sends every couple of seconds, so a live
    /// connection never idles out, and a peer that goes silent is caught by
    /// the app's own liveness check long before this. Five minutes, as
    /// Apple's sample ships it.
    public static let idleTimeoutInterval: Int = 300_000

    /// How long the controller waits after a connection ends before looking
    /// for the peer again. Long enough that a persistent failure doesn't
    /// spin, short enough that a reconnect still feels automatic.
    public static let reconnectDelay = Duration.seconds(1)
}

/// One subsystem for every log line the package emits, so `log stream
/// --subsystem` on a device needs one filter.
enum PeerConnectionLogging {
    static let subsystem = "com.example.ObjectTrackingUpdates.PeerConnection"
}

/// Errors for the TLS handshake.
public enum TLSError: Error {
    /// Couldn't verify a peer's certificate.
    case certificateVerificationFailed
    /// Couldn't create or find a local identity.
    case localIdentityDoesNotExist
}
