//
//  CertificateTrustManager.swift
//  PeerConnection
//
//  Validates incoming TLS certificates with a trust on first use (TOFU)
//  model, from Apple's "Connecting iPadOS and visionOS apps over the local
//  network" sample.
//

import CryptoKit
import Foundation
import OSLog
import Security

/// Implements trust on first use certificate validation.
///
/// The first certificate a peer presents is trusted and its fingerprint is
/// stored; every later connection must present the same one. This protects
/// against an intermediary after the first connection, and is simple enough
/// for a demo. CA-based PKI is preferred for production.
///
/// Both devices in this demo use the same certificate subject, so each
/// device holds exactly one stored fingerprint: the other device's. If either
/// app is reinstalled it generates a new certificate, and the other device
/// rejects it until `forgetPairedDevice()` clears the stored fingerprint.
public final class CertificateTrustManager: Sendable {
    private static let logger = Logger(subsystem: PeerConnectionLogging.subsystem,
                                       category: "CertificateTrustManager")
    private static let keychainService = "com.example.ObjectTrackingUpdates.trusted-certs"

    /// Verify a given certificate. Returns true if the certificate is recognized.
    public static func verifyCertificate(metadata: sec_protocol_metadata_t,
                                         trustResult: sec_trust_t) -> Bool
    {
        logger.debug("Certificate validation callback initiated")

        // Get peer certificate from metadata.
        let trust = sec_trust_copy_ref(trustResult).takeRetainedValue()
        guard let certChain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let peerCert = certChain.first
        else {
            logger.error("Failed to extract peer certificate")

            return false
        }

        // Use peer's certificate subject as identifier.
        let peerIdentifier: String
        if let summary = SecCertificateCopySubjectSummary(peerCert) as String? {
            peerIdentifier = summary
        } else {
            peerIdentifier = "unknown-peer"
        }

        // Validate that the certificate either has been seen before or is the first use, so it's trusted.
        let isValid = validateCertificate(peerCert,
                                          for: peerIdentifier)

        if isValid {
            logger.debug("Certificate validation worked - accepting connection")
        } else {
            logger.error("Certificate validation failed")
        }

        return isValid
    }

    /// Forgets the paired device's certificate, so the next connection from
    /// it is treated as a first connection and its new certificate is
    /// trusted. Run this on both devices after reinstalling the app on
    /// either one.
    public static func forgetPairedDevice() {
        removeTrustedPeer(NetworkServiceConstants.fixedPairingID)
    }

    /// Validate certificate using trust on first use. Reject if the certificate changed since the first connection.
    /// - Parameters:
    ///   - certificate: The peer's certificate to validate.
    ///   - peerIdentifier: A unique identifier for the peer (such as the device name or an endpoint).
    /// - Returns: Returns true to trust the certificate; otherwise, false.
    private static func validateCertificate(_ certificate: SecCertificate,
                                            for peerIdentifier: String) -> Bool
    {
        logger.debug("Validating certificate for peer: \(peerIdentifier, privacy: .private)")

        // Calculate the fingerprint of the presented certificate.
        guard let presentedFingerprint = certificateFingerprint(certificate)
        else {
            logger.error("Failed to calculate certificate fingerprint")

            return false
        }

        // Check if there is a trusted fingerprint for this peer.
        if let trustedFingerprint = retrieveTrustedFingerprint(for: peerIdentifier) {
            // Known peer - verify fingerprint matches.
            if presentedFingerprint == trustedFingerprint {
                logger.debug("Certificate matches trusted fingerprint")

                return true
            } else {
                logger.error("Certificate fingerprint mismatch. Is not valid.")

                return false
            }
        } else {
            // First connection: Trust and save the fingerprint for future validation.
            logger.debug("First connection from this peer")

            if storeTrustedFingerprint(presentedFingerprint,
                                       for: peerIdentifier) {
                logger.debug("Stored fingerprint and accepting connection")

                return true
            } else {
                logger.error("Failed to store fingerprint")

                return false
            }
        }
    }

    /// Calculate a SHA-256 fingerprint of a certificate to save rather than saving the entire certificate.
    private static func certificateFingerprint(_ certificate: SecCertificate) -> String? {
        guard let certData = SecCertificateCopyData(certificate) as Data?
        else {
            return nil
        }

        let hash = SHA256.hash(data: certData)

        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    /// Store a trusted certificate fingerprint in the keychain.
    private static func storeTrustedFingerprint(_ fingerprint: String,
                                                for peerIdentifier: String) -> Bool
    {
        logger.debug("Storing trusted fingerprint for peer: \(peerIdentifier, privacy: .private)")

        let key = "trusted-\(peerIdentifier)"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key,
            kSecValueData as String: Data(fingerprint.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        // Delete the existing entry, if present.
        SecItemDelete(query as CFDictionary)

        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecSuccess {
            logger.debug("Successfully stored fingerprint")

            return true
        } else {
            logger.error("Failed to store fingerprint: \(status, privacy: .public)")

            return false
        }
    }

    /// Retrieve a trusted certificate fingerprint from the keychain.
    private static func retrieveTrustedFingerprint(for peerIdentifier: String) -> String? {
        let key = "trusted-\(peerIdentifier)"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecSuccess,
           let data = result as? Data,
           let fingerprint = String(data: data, encoding: .utf8) {
            logger.debug("Found existing trusted fingerprint for peer: \(peerIdentifier, privacy: .private)")

            return fingerprint
        } else {
            logger.debug("No existing fingerprint found for peer: \(peerIdentifier, privacy: .private)")

            return nil
        }
    }

    /// Removes a trusted peer's certificate fingerprint from the keychain.
    /// After this, the next connection from the peer is treated as a first
    /// connection and its certificate's fingerprint is saved.
    private static func removeTrustedPeer(_ peerIdentifier: String) {
        logger.debug("Removing trusted peer: \(peerIdentifier, privacy: .private)")

        let key = "trusted-\(peerIdentifier)"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key
        ]

        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound {
            logger.debug("Successfully removed trusted peer")
        } else {
            logger.error("Failed to remove trusted peer: \(status, privacy: .public)")
        }
    }
}
