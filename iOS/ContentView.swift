// ContentView.swift
// AVPlayer(PlayerView) 기반 — WKWebView 완전 제거.

import SwiftUI

struct ContentView: View {

    @StateObject private var manager = LiveManager()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch manager.state {

            // MARK: 탐색·전환 중 — 완전 검정
            case .searching, .blackScreen:
                Color.black
                    .ignoresSafeArea()
                    .transition(.opacity)

            // MARK: 재생 중 — AVPlayer, 버튼 없음
            case .playing(let stream):
                PlayerView(
                    streamURL: stream.streamURL,
                    onPlaybackEnded:  { manager.liveEnded()      },
                    onPlaybackFailed: { manager.playbackFailed() }
                )
                .ignoresSafeArea()
                .transition(.opacity)

            // MARK: 오류
            case .error(let msg):
                errorView(message: msg)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: manager.state)
        .statusBarHidden(true)
        .hidePersistentOverlaysIfAvailable()
        .onAppear { manager.start() }
        // iOS 15 호환 단일 파라미터 onChange
        .onChange(of: scenePhase) { phase in
            if phase == .active, case .error = manager.state {
                manager.start()
            }
        }
    }

    // MARK: - 오류 화면

    private func errorView(message: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 48))
                .foregroundStyle(Color(white: 0.4))

            Text(message)
                .font(.system(size: 15))
                .foregroundStyle(Color(white: 0.45))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }
}

// MARK: - iOS 15 호환 헬퍼

private extension View {
    @ViewBuilder
    func hidePersistentOverlaysIfAvailable() -> some View {
        if #available(iOS 16.0, *) {
            self.persistentSystemOverlays(.hidden)
        } else {
            self
        }
    }
}
