// StreamResolver.swift
// 프록시 서버에서 HLS URL 을 받아오는 단일 책임 모듈.

import Foundation

struct ResolvedStream {
    let videoId:   String
    let streamURL: URL
    let isHLS:     Bool
    let title:     String
    let channel:   String
}

enum ResolveError: Error {
    case invalidVideoId
    case serverError(Int)
    case streamNotFound
    case networkError(Error)
    case decodingError
}

actor StreamResolver {

    // ── 설정 ────────────────────────────────────────────────
    // Railway 배포 후 발급된 URL 로 교체하세요.
    // 예: "https://randomlivetv-proxy-production.up.railway.app"
    private let baseURL   = "https://YOUR_RAILWAY_URL_HERE"
    // Railway 환경변수 API_SECRET 에 설정한 값과 동일하게 입력.
    // 인증 없이 배포했으면 빈 문자열("") 로 두세요.
    private let apiSecret = "YOUR_API_SECRET_HERE"

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest  = 25
        cfg.timeoutIntervalForResource = 30
        return URLSession(configuration: cfg)
    }()

    // ── 공개 API ────────────────────────────────────────────

    /// video_id → ResolvedStream (HLS URL + 메타데이터)
    func resolve(videoId: String) async throws -> ResolvedStream {
        guard videoId.count == 11 else { throw ResolveError.invalidVideoId }

        var components = URLComponents(string: "\(baseURL)/stream")!
        components.queryItems = [.init(name: "id", value: videoId)]
        guard let url = components.url else { throw ResolveError.invalidVideoId }

        var request = URLRequest(url: url)
        if !apiSecret.isEmpty {
            request.setValue(apiSecret, forHTTPHeaderField: "X-API-Secret")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ResolveError.networkError(error)
        }

        if let http = response as? HTTPURLResponse {
            guard (200..<300).contains(http.statusCode) else {
                throw ResolveError.serverError(http.statusCode)
            }
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw ResolveError.decodingError }

        if let _ = json["error"] { throw ResolveError.streamNotFound }

        guard
            let urlString = json["stream_url"] as? String,
            let streamURL = URL(string: urlString)
        else { throw ResolveError.streamNotFound }

        return ResolvedStream(
            videoId:   videoId,
            streamURL: streamURL,
            isHLS:     json["is_hls"]  as? Bool   ?? false,
            title:     json["title"]   as? String ?? "알 수 없음",
            channel:   json["channel"] as? String ?? "알 수 없음"
        )
    }
}
