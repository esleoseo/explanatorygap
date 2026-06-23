// PlayerView.swift
// AVPlayer 기반 플레이어 — 광고 없음, UI 없음, HLS 직접 재생.

import SwiftUI
import AVKit
import AVFoundation

struct PlayerView: UIViewRepresentable {

    let streamURL: URL
    var onPlaybackEnded: (() -> Void)? = nil
    var onPlaybackFailed: (() -> Void)? = nil

    // MARK: - Coordinator

    final class Coordinator: NSObject {
        var player:    AVPlayer?
        var playerLayer: AVPlayerLayer?
        var onPlaybackEnded:  (() -> Void)?
        var onPlaybackFailed: (() -> Void)?

        private var itemObserver:   NSKeyValueObservation?
        private var statusObserver: NSKeyValueObservation?
        private var endObserver:    Any?

        func setup(url: URL, layer: AVPlayerLayer) {
            teardown()

            let item   = AVPlayerItem(url: url)
            let player = AVPlayer(playerItem: item)
            player.isMuted = false
            player.automaticallyWaitsToMinimizeStalling = true

            layer.player = player
            layer.videoGravity = .resizeAspectFill
            self.player      = player
            self.playerLayer = layer

            // 재생 상태 감시
            statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                DispatchQueue.main.async {
                    switch item.status {
                    case .readyToPlay:
                        player.play()
                        print("[PlayerView] ▶ 재생 시작: \(url.absoluteString.prefix(80))")
                    case .failed:
                        print("[PlayerView] ✗ 재생 실패: \(item.error?.localizedDescription ?? "")")
                        self?.onPlaybackFailed?()
                    default:
                        break
                    }
                }
            }

            // 재생 완료 (라이브는 거의 발생 안 하지만 안전망)
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] _ in
                print("[PlayerView] ■ 재생 종료")
                self?.onPlaybackEnded?()
            }

            // 재생 오류 (네트워크 끊김 등)
            NotificationCenter.default.addObserver(
                forName: .AVPlayerItemFailedToPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] notification in
                let err = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey]
                print("[PlayerView] ✗ 재생 중 오류: \(err ?? "unknown")")
                self?.onPlaybackFailed?()
            }

            player.play()
        }

        func teardown() {
            player?.pause()
            player?.replaceCurrentItem(with: nil)
            itemObserver   = nil
            statusObserver = nil
            if let obs = endObserver {
                NotificationCenter.default.removeObserver(obs)
                endObserver = nil
            }
            NotificationCenter.default.removeObserver(self)
            player      = nil
            playerLayer = nil
        }

        deinit { teardown() }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    // MARK: - UIViewRepresentable

    func makeUIView(context: Context) -> UIView {
        let view  = UIView(frame: .zero)
        view.backgroundColor = .black

        let layer = AVPlayerLayer()
        layer.frame        = view.bounds
        layer.videoGravity = .resizeAspectFill
        layer.backgroundColor = UIColor.black.cgColor
        view.layer.addSublayer(layer)

        context.coordinator.onPlaybackEnded  = onPlaybackEnded
        context.coordinator.onPlaybackFailed = onPlaybackFailed
        context.coordinator.setup(url: streamURL, layer: layer)

        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onPlaybackEnded  = onPlaybackEnded
        context.coordinator.onPlaybackFailed = onPlaybackFailed

        // URL 이 바뀐 경우에만 재설정
        if context.coordinator.player?.currentItem?.asset
            .isEqual(AVAsset(url: streamURL)) == false {
            if let layer = uiView.layer.sublayers?.first as? AVPlayerLayer {
                context.coordinator.setup(url: streamURL, layer: layer)
            }
        }

        // 레이어 크기 항상 동기화
        if let layer = uiView.layer.sublayers?.first as? AVPlayerLayer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.frame = uiView.bounds
            CATransaction.commit()
        }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.teardown()
    }
}
