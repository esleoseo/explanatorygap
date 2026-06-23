// LiveManager.swift
// v6 — StreamResolver(프록시 서버) + AVPlayer 방식
// WKWebView / 임베드 완전 제거.

import Foundation
import Combine

// MARK: - 모델

struct LiveVideo: Equatable {
    let videoId:  String
    let title:    String
    let channel:  String
    let region:   String
    let category: String
}

enum LiveState: Equatable {
    case searching
    case blackScreen
    case playing(ResolvedStream)
    case error(String)

    static func == (lhs: LiveState, rhs: LiveState) -> Bool {
        switch (lhs, rhs) {
        case (.searching, .searching):       return true
        case (.blackScreen, .blackScreen):   return true
        case (.playing(let a), .playing(let b)): return a.videoId == b.videoId
        case (.error(let a), .error(let b)): return a == b
        default: return false
        }
    }
}

extension ResolvedStream: Equatable {
    static func == (lhs: ResolvedStream, rhs: ResolvedStream) -> Bool {
        lhs.videoId == rhs.videoId
    }
}

// MARK: - LiveManager

@MainActor
final class LiveManager: ObservableObject {

    @Published var state: LiveState = .searching
    @Published var isLoading = false

    private let youtubeService = YouTubeService()
    private let resolver       = StreamResolver()

    private var loadTask:    Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var preloadTask: Task<Void, Never>?
    private var safetyTask:  Task<Void, Never>?

    private var preloadedStream: ResolvedStream?
    private var currentVideoId:  String?

    // 연속 실패 추적 (폭주 방지)
    private var recentFailures: [Date] = []
    private let maxFailuresPerMinute   = 6

    // MARK: - 공개 액션

    func start()      { loadNext(reason: "앱 시작",     showBlack: false) }
    func skipToNext() { loadNext(reason: "사용자 스킵", showBlack: true) }
    func liveEnded()  { loadNext(reason: "라이브 종료", showBlack: true) }

    func playbackFailed() {
        let now = Date()
        recentFailures.append(now)
        recentFailures = recentFailures.filter { now.timeIntervalSince($0) < 60 }

        if recentFailures.count >= maxFailuresPerMinute {
            recentFailures.removeAll()
            cancelAll()
            state = .error("스트림을 불러올 수 없습니다.\n잠시 후 자동으로 재시도합니다.")
            NotificationService.shared.notifyError(
                message: "연속 스트림 실패 — 서버 점검 중", restarting: true)
            scheduleErrorRetry()
            return
        }
        loadNext(reason: "스트림 실패 건너뜀", showBlack: true)
    }

    // MARK: - 내부 로직

    private func loadNext(reason: String, showBlack: Bool) {
        print("[LiveManager] 탐색 시작: \(reason)")

        cancelTimersAndPreload()
        loadTask?.cancel()

        if showBlack { state = .blackScreen }
        isLoading = true

        loadTask = Task { [weak self] in
            guard let self else { return }
            await self.performLoad(reason: reason)
        }
    }

    private func performLoad(reason: String) async {
        // 1. 선탐색된 스트림이 있으면 즉시 사용
        if let cached = preloadedStream {
            preloadedStream = nil
            print("[LiveManager] 선탐색 스트림 사용: \(cached.title)")
            apply(stream: cached, reason: reason)
            schedulePreload(delay: 5)
            return
        }

        // 2. 풀에서 후보 가져오기 → 프록시 서버로 스트림 URL 해석
        guard let candidate = await youtubeService.nextCandidate() else {
            isLoading = false
            state = .error("라이브 영상을 찾지 못했습니다.")
            scheduleErrorRetry()
            return
        }

        let stream = await resolveWithRetry(videoId: candidate.videoId, maxAttempts: 3)
        guard let stream else {
            // 이 후보만 실패 → 다음 후보로
            loadNext(reason: "스트림 해석 실패 → 다음 후보", showBlack: false)
            return
        }

        apply(stream: stream, reason: reason)
        schedulePreload(delay: 5)
    }

    private func resolveWithRetry(videoId: String, maxAttempts: Int) async -> ResolvedStream? {
        for attempt in 1...maxAttempts {
            do {
                let stream = try await resolver.resolve(videoId: videoId)
                print("[Resolve] ✓ \(videoId) → \(stream.streamURL.absoluteString.prefix(60))")
                return stream
            } catch {
                print("[Resolve] ✗ 시도 \(attempt)/\(maxAttempts): \(error)")
                if attempt < maxAttempts {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                }
            }
        }
        return nil
    }

    private func apply(stream: ResolvedStream, reason: String) {
        guard !Task.isCancelled else { return }
        currentVideoId = stream.videoId
        isLoading      = false
        state          = .playing(stream)

        print("[LiveManager] 재생: \(stream.title) [\(stream.videoId)]")
        NotificationService.shared.notifyVideoChange(
            title: stream.title, channel: stream.channel, reason: reason)

        scheduleRefresh(interval: 10 * 60)
        scheduleSafetyPoll(after: 60)
    }

    // MARK: - 선탐색

    private func schedulePreload(delay: Double) {
        preloadTask?.cancel()
        preloadTask = Task { [weak self] in
            guard let self else { return }
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            catch { return }
            guard !Task.isCancelled else { return }
            await self.doPreload()
        }
    }

    private func doPreload() async {
        guard preloadedStream == nil,
              let candidate = await youtubeService.nextCandidate()
        else { return }

        let stream = await resolveWithRetry(videoId: candidate.videoId, maxAttempts: 2)
        if let stream {
            preloadedStream = stream
            print("[Preload] 선탐색 완료: \(stream.title)")
        }
    }

    // MARK: - 타이머

    private func scheduleRefresh(interval: Double) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000)) }
            catch { return }
            guard !Task.isCancelled else { return }
            self?.loadNext(reason: "10분 경과 → 자동 교체", showBlack: true)
        }
    }

    private func scheduleSafetyPoll(after delay: Double) {
        safetyTask?.cancel()
        safetyTask = Task { [weak self] in
            guard let self else { return }
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            catch { return }

            while !Task.isCancelled {
                if let vid = self.currentVideoId {
                    let stillLive = await self.youtubeService.isStillLive(videoId: vid)
                    if !stillLive {
                        print("[Safety] 라이브 종료 감지 → 다음 영상")
                        self.loadNext(reason: "라이브 종료", showBlack: true)
                        return
                    }
                }
                do { try await Task.sleep(nanoseconds: 60_000_000_000) }
                catch { return }
            }
        }
    }

    private func scheduleErrorRetry() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 30_000_000_000) }
            catch { return }
            guard !Task.isCancelled else { return }
            self?.start()
        }
    }

    private func cancelTimersAndPreload() {
        refreshTask?.cancel(); refreshTask = nil
        preloadTask?.cancel(); preloadTask = nil
        safetyTask?.cancel();  safetyTask  = nil
        preloadedStream = nil
    }

    private func cancelAll() {
        loadTask?.cancel();    loadTask    = nil
        cancelTimersAndPreload()
        currentVideoId = nil
        isLoading      = false
    }
}
