import AVFoundation
import Foundation

/// Fulfils FairPlay Streaming key requests for the LSM VOD catalogue.
///
/// The playlist advertises `EXT-X-KEY:METHOD=SAMPLE-AES ... URI="skd://skd"`.
/// We load LSM's FPS certificate, turn each key request into an SPC, exchange
/// it for a CKC at the license endpoint and hand the CKC back to AVFoundation.
final class FairPlayKeyLoader: NSObject, AVContentKeySessionDelegate {
    private let certificateURL: URL
    private let licenseURL: URL
    private let keySession: AVContentKeySession
    private let urlSession: URLSession

    private var cachedCertificate: Data?

    init(certificateURL: URL, licenseURL: URL) {
        self.certificateURL = certificateURL
        self.licenseURL = licenseURL
        self.keySession = AVContentKeySession(keySystem: .fairPlayStreaming)
        self.urlSession = URLSession(configuration: .ephemeral)

        super.init()
        keySession.setDelegate(self, queue: .global(qos: .userInitiated))
    }

    /// Must be called before the asset is put into a player item.
    func attach(to asset: AVURLAsset) {
        keySession.addContentKeyRecipient(asset)
    }

    // MARK: - AVContentKeySessionDelegate

    func contentKeySession(_ session: AVContentKeySession, didProvide keyRequest: AVContentKeyRequest) {
        fulfil(keyRequest)
    }

    private func fulfil(_ request: AVContentKeyRequest) {
        Task {
            do {
                let certificate = try await certificate()
                let identifier = contentIdentifier(for: request)
                let spc = try await request.makeStreamingContentKeyRequestData(
                    forApp: certificate,
                    contentIdentifier: Data(identifier.utf8),
                    options: nil
                )
                let ckc = try await license(for: spc)
                request.processContentKeyResponse(
                    AVContentKeyResponse(fairPlayStreamingKeyResponseData: ckc)
                )
            } catch {
                request.processContentKeyResponseError(error)
            }
        }
    }

    private func contentIdentifier(for request: AVContentKeyRequest) -> String {
        if let identifier = request.identifier as? String,
           identifier.lowercased().hasPrefix("skd://") {
            return identifier
        }
        return "skd://skd"
    }

    // MARK: - Network

    private func certificate() async throws -> Data {
        if let cachedCertificate {
            return cachedCertificate
        }
        var request = URLRequest(url: certificateURL)
        request.setValue("LSMTV/1.0 (tvOS)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await urlSession.data(for: request)
        try Self.validate(response)
        cachedCertificate = data
        return data
    }

    private func license(for spc: Data) async throws -> Data {
        var request = URLRequest(url: licenseURL)
        request.httpMethod = "POST"
        request.httpBody = spc
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("https://replay.lsm.lv", forHTTPHeaderField: "Origin")
        request.setValue("https://replay.lsm.lv/", forHTTPHeaderField: "Referer")
        request.setValue("LSMTV/1.0 (tvOS)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await urlSession.data(for: request)
        try Self.validate(response)
        return try Self.contentKey(from: data)
    }

    // MARK: - Response parsing

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw LSMError.http(http.statusCode)
        }
    }

    /// The license server may answer with raw CKC bytes, an XML
    /// `<ckc>base64</ckc>` document, or JSON carrying a base64 key.
    static func contentKey(from data: Data) throws -> Data {
        if let text = String(data: data, encoding: .utf8) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmed.hasPrefix("<"),
               let start = trimmed.range(of: "<ckc>"),
               let end = trimmed.range(of: "</ckc>") {
                let base64 = trimmed[start.upperBound..<end.lowerBound]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let decoded = Data(base64Encoded: base64) {
                    return decoded
                }
            }

            if trimmed.hasPrefix("{"),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                for key in ["ckc", "CkcMessage", "License"] {
                    if let value = object[key] as? String,
                       let decoded = Data(base64Encoded: value) {
                        return decoded
                    }
                }
            }
        }
        return data
    }
}
