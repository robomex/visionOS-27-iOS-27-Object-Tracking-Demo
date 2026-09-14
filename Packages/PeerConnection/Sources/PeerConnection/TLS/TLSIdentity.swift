//
//  TLSIdentity.swift
//  PeerConnection
//
//  Retrieves the local identity for TLS connections, from Apple's
//  "Connecting iPadOS and visionOS apps over the local network" sample.
//

import Crypto
import Foundation
import OSLog
import Security
import SwiftASN1 // Available from Apple: https://github.com/apple/swift-certificates
import X509 // Available from Apple: https://github.com/apple/swift-certificates

public final class TLSIdentity: Sendable {
    private static let logger = Logger(subsystem: PeerConnectionLogging.subsystem,
                                       category: "TLSIdentity")

    /// Retrieves or generates a self-signed TLS identity for secure peer-to-peer connections.
    ///
    /// Security model: Self-signed certificates (not CA-issued) with trust on first use (TOFU) validation.
    /// This is appropriate for:
    /// - Local network communication where devices are physically nearby.
    /// - Two devices whose owners can confirm the pairing out of band, as in this demo.
    ///
    /// Not appropriate for:
    /// - Internet-facing services.
    /// - Connections where you can't verify the peer out-of-band.
    ///
    /// - Parameter label: Identifier used to store and retrieve certificates (matches the device ID).
    /// - Returns: Returns `sec_identity_t`, containing the certificate and the private key for making the TLS handshake.
    public static func getLocalIdentity(label: String) -> sec_identity_t? {
        logger.debug("Attempting to get identity with label: \(label, privacy: .private)")

        // Try to retrieve an existing identity from keychain.
        do {
            let existingIdentity = try retrieveIdentityFromKeychain(label: label)
            logger.debug("Successfully retrieved existing identity from keychain")
            return existingIdentity
        } catch {
            logger.debug("No existing identity found: \(String(describing: error), privacy: .private). Will generate new one.")
        }

        // If an existing identity isn't found, generate a new certificate or key pair and store it.
        do {
            logger.debug("Generating new certificate and key pair.")
            try generateNewIdentity(label: label)
            // After generating the certificate or key pair, retrieve it from the keychain.
            let newIdentity = try retrieveIdentityFromKeychain(label: label)
            logger.debug("Successfully generated and stored new identity")
            return newIdentity
        } catch {
            if let certificateError = error as? CertificateError {
                logger.error("Failed to generate identity: \(certificateError.description, privacy: .public)")
            } else {
                logger.error("Failed to generate identity: \(String(describing: error), privacy: .private)")
            }

            return nil
        }
    }

    /// A helper method used to retrieve `sec_identity_t` from the keychain.
    private static func retrieveIdentityFromKeychain(label: String) throws -> sec_identity_t? {
        // On iPadOS and visionOS, query for the identity directly.
        // The keychain automatically associates the certificate with the private key
        // when they have matching attributes (same label).
        let identityQuery: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrLabel as String: label,
            kSecReturnRef as String: true
        ]

        var identityItem: CFTypeRef?
        let identityStatus = SecItemCopyMatching(identityQuery as CFDictionary, &identityItem)
        guard identityStatus == errSecSuccess,
              let identityItem,
              CFGetTypeID(identityItem) == SecIdentityGetTypeID()
        else {
            throw CertificateError.certificateRetrievalFailed(identityStatus)
        }

        // The type check above is what makes this cast safe: SecIdentity is a
        // Core Foundation type, so `as?` cannot verify it.
        let secIdentity = unsafeDowncast(identityItem, to: SecIdentity.self)

        // Convert to `sec_identity_t` and use it as the local identity for the connection.
        return sec_identity_create(secIdentity)
    }
}

extension TLSIdentity {
    /// Generates a new identity with Swift-Certificates, then converts it to CryptoKit `SecCertificate`, and stores it.
    private static func generateNewIdentity(label: String) throws {
        // Generate the keys for the certificate.
        let (cryptoPrivateKey, cryptoPublicKey) = try generateKeyPair(label: label)

        //  Create the self-signed certificate using those keys.
        let certificate = try createSelfSignedCertificate(privateKey: cryptoPrivateKey,
                                                          publicKey: cryptoPublicKey,
                                                          with: label)

        // Store the certificate in the keychain beside the key. If that
        // fails, remove the key too: a key with no certificate is an identity
        // the keychain can never assemble, and it would block every later
        // attempt to make a new one.
        do {
            try storeCertificate(certificate: certificate,
                                 label: label)
        } catch {
            removePrivateKey(label: label)
            throw error
        }
    }

    /// Removes the private key stored under the label, for rollback.
    private static func removePrivateKey(label: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrLabel as String: label,
            kSecAttrApplicationTag as String: Data(label.utf8)
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Generate a NIST P-256 elliptic curve key pair for certificate signing.
    private static func generateKeyPair(label: String) throws -> (P256.Signing.PrivateKey, P256.Signing.PublicKey) {
        // Generate a NIST P-256 elliptic curve key (256-bit security).
        let keyAttributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,  // NIST P-256 curve
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrIsPermanent as String: false  // Store the private key in the keychain below, not here.
        ]

        // Generate the private key.
        var error: Unmanaged<CFError>?
        guard let secPrivateKey = SecKeyCreateRandomKey(keyAttributes as CFDictionary, &error) else {
            throw CertificateError.keyGenerationFailed
        }

        // Store the private key in keychain with a label-matching certificate.
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrLabel as String: label,  // This must match the certificate label.
            kSecAttrApplicationTag as String: Data(label.utf8),
            kSecValueRef as String: secPrivateKey,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw CertificateError.keychainStorageFailed(status)
        }

        // Extract public key data.
        guard let secPublicKey = SecKeyCopyPublicKey(secPrivateKey),
              let publicKeyData = SecKeyCopyExternalRepresentation(secPublicKey, nil) as Data? else {
            throw CertificateError.publicKeyExtractionFailed
        }

        // Get the external representation of the key to convert to cryptography keys.
        guard let privateKeyData = SecKeyCopyExternalRepresentation(secPrivateKey, nil) as Data? else {
            throw CertificateError.publicKeyExtractionFailed
        }

        // Create CryptoKit keys from the data.
        let cryptoPrivateKey: P256.Signing.PrivateKey
        let cryptoPublicKey: P256.Signing.PublicKey

        do {
            // Try an x963 representation first; a private key might be in a different format.
            cryptoPublicKey = try P256.Signing.PublicKey(x963Representation: publicKeyData)

            // For a private key, try raw representation (32 bytes).
            if privateKeyData.count == 32 {
                cryptoPrivateKey = try P256.Signing.PrivateKey(rawRepresentation: privateKeyData)
            } else {
                // If not 32 bytes, try x963 or Distinguished Encoding Rules (DER).
                cryptoPrivateKey = try P256.Signing.PrivateKey(x963Representation: privateKeyData)
            }
        } catch {
            logger.error("Failed to create CryptoKit keys: \(String(describing: error), privacy: .private)")
            throw error
        }

        return (cryptoPrivateKey, cryptoPublicKey)
    }

    /// Creates a self-signed certificate using Swift-Certificates.
    private static func createSelfSignedCertificate(privateKey: P256.Signing.PrivateKey,
                                                    publicKey: P256.Signing.PublicKey,
                                                    validityDays: Int = 365,
                                                    with label: String) throws -> Certificate
    {
        // Subject name for the certificate (minimal for local use).
        let subjectName = try DistinguishedName {
            CommonName(label)  // Device ID becomes the certificate subject.
        }

        // Certificate extensions define the certificate's use.
        let extensions = try Certificate.Extensions {
            Critical(
                BasicConstraints.notCertificateAuthority  // This certificate can't sign other certificates.
            )
            Critical(
                KeyUsage(
                    digitalSignature: true, // Can sign data (TLS handshake).
                    keyEncipherment: true, // Can encrypt keys.
                    keyAgreement: true // Can perform key exchange.
                )
            )
            // Allow both server and client authorization (peer-to-peer needs both roles).
            try ExtendedKeyUsage([.serverAuth, .clientAuth])

            // Subject Alternative Name for local Bonjour discovery.
            SubjectAlternativeNames([.dnsName("\(NetworkServiceConstants.listenerName).\(NetworkServiceConstants.serviceType).local")])
        }

        // Create the certificate.
        var serialBytes = [UInt8](repeating: 0, count: 16)
        let randomStatus = SecRandomCopyBytes(kSecRandomDefault, serialBytes.count, &serialBytes)
        guard randomStatus == errSecSuccess
        else {
            throw CertificateError.serialNumberGenerationFailed(randomStatus)
        }
        let serialNumber = Certificate.SerialNumber(bytes: ArraySlice(serialBytes))

        let notBefore = Date()
        let notAfter = notBefore.addingTimeInterval(TimeInterval(validityDays) * 24 * 60 * 60)

        let certificate = try Certificate(
            version: .v3,
            serialNumber: serialNumber,
            publicKey: Certificate.PublicKey(publicKey),
            notValidBefore: notBefore,
            notValidAfter: notAfter,
            issuer: subjectName,
            subject: subjectName,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: extensions,
            issuerPrivateKey: Certificate.PrivateKey(privateKey)
        )

        return certificate
    }

    /// Store the certificate in keychain.
    private static func storeCertificate(certificate: Certificate,
                                         label: String) throws
    {
        // Convert the Swift-Certificates certificate to SecCertificate.
        var serializer = DER.Serializer()
        try serializer.serialize(certificate)
        let derEncodedCertificate = serializer.serializedBytes

        // Create the `SecCertificate` from DER-encoded certificate data.
        guard let secCertificate = SecCertificateCreateWithData(nil, Data(derEncodedCertificate) as CFData) else {
            throw CertificateError.secCertificateCreationFailed
        }

        // Store the certificate in keychain with the same label as the private key.
        // On iPadOS and visionOS, the identity is automatically created when both the certificate and private key exist with matching labels.
        let certAddQuery: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: secCertificate,
            kSecAttrLabel as String: label,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let certStatus = SecItemAdd(certAddQuery as CFDictionary, nil)
        guard certStatus == errSecSuccess else {
            throw CertificateError.certificateStorageFailed(certStatus)
        }
    }
}

extension TLSIdentity {

    enum CertificateError: Error {
        case keyGenerationFailed
        case keychainStorageFailed(OSStatus)
        case publicKeyExtractionFailed
        case certificateStorageFailed(OSStatus)
        case secCertificateCreationFailed
        case serialNumberGenerationFailed(OSStatus)
        case certificateRetrievalFailed(OSStatus)

        var description: String {
            switch self {
            case .keyGenerationFailed:
                return "Failed to generate key pair."
            case .keychainStorageFailed(let status):
                return "Failed to store key in keychain with status: \(status)."
            case .publicKeyExtractionFailed:
                return "Failed to extract public key from generated key pair."
            case .certificateStorageFailed(let status):
                return "Failed to store certificate in keychain with status: \(status)."
            case .secCertificateCreationFailed:
                return "Failed to create SecCertificateRef from certificate data."
            case .serialNumberGenerationFailed(let status):
                return "Failed to generate a random certificate serial number with status: \(status)."
            case .certificateRetrievalFailed(let status):
                return "Failed to retrieve certificate from keychain with status: \(status)."
            }
        }
    }
}
