"""
RandomLiveTV — yt-dlp 스트림 프록시 서버
- GET /stream?id=VIDEO_ID  → HLS/직접 스트림 URL 반환
- GET /health              → 서버 상태 확인
"""

import os
import json
import subprocess
import tempfile
from flask import Flask, jsonify, request, abort

app = Flask(__name__)

# 선택적 API 키 인증 (비워두면 인증 없음)
API_SECRET = os.environ.get("API_SECRET", "")

# yt-dlp 경로 (Railway 환경에서는 PATH에 있음)
YTDLP = os.environ.get("YTDLP_PATH", "yt-dlp")


def check_auth():
    """API_SECRET 이 설정된 경우 요청 헤더 검증."""
    if not API_SECRET:
        return True
    token = request.headers.get("X-API-Secret", "")
    return token == API_SECRET


def resolve_stream(video_id: str) -> dict:
    """
    yt-dlp 로 video_id 의 스트림 URL 추출.
    HLS manifest → 없으면 best mp4/webm direct URL 반환.
    """
    url = f"https://www.youtube.com/watch?v={video_id}"

    # 1순위: HLS manifest (라이브 스트림에 최적)
    cmd_hls = [
        YTDLP,
        "--no-warnings",
        "--quiet",
        "-f", "91/92/93/94/95/96/best",   # HLS 포맷 ID (라이브 전용)
        "--get-url",
        "--no-playlist",
        url,
    ]

    # 2순위: best 포맷 (HLS 없을 때 fallback)
    cmd_best = [
        YTDLP,
        "--no-warnings",
        "--quiet",
        "-f", "bestvideo[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]/best",
        "--get-url",
        "--no-playlist",
        url,
    ]

    # 메타데이터 (제목·채널)
    cmd_meta = [
        YTDLP,
        "--no-warnings",
        "--quiet",
        "--print", "%(title)s\n%(uploader)s\n%(is_live)s",
        "--no-playlist",
        url,
    ]

    stream_url = None
    is_hls = False

    # HLS 시도
    try:
        result = subprocess.run(
            cmd_hls, capture_output=True, text=True, timeout=20
        )
        line = result.stdout.strip().splitlines()[0] if result.stdout.strip() else ""
        if line.startswith("http") and ".m3u8" in line:
            stream_url = line
            is_hls = True
    except Exception:
        pass

    # HLS 실패 시 best 시도
    if not stream_url:
        try:
            result = subprocess.run(
                cmd_best, capture_output=True, text=True, timeout=20
            )
            lines = [l for l in result.stdout.strip().splitlines() if l.startswith("http")]
            if lines:
                stream_url = lines[0]
        except Exception:
            pass

    if not stream_url:
        return {"error": "stream_not_found"}

    # 메타데이터 추출
    title, channel, live_flag = "알 수 없음", "알 수 없음", "False"
    try:
        meta = subprocess.run(
            cmd_meta, capture_output=True, text=True, timeout=15
        )
        parts = meta.stdout.strip().splitlines()
        if len(parts) >= 1: title    = parts[0]
        if len(parts) >= 2: channel  = parts[1]
        if len(parts) >= 3: live_flag = parts[2]
    except Exception:
        pass

    return {
        "video_id":   video_id,
        "stream_url": stream_url,
        "is_hls":     is_hls,
        "is_live":    live_flag.lower() == "true",
        "title":      title,
        "channel":    channel,
    }


# ──────────────────────────────────────────────
# 엔드포인트
# ──────────────────────────────────────────────

@app.route("/health")
def health():
    """Railway 헬스체크용."""
    return jsonify({"status": "ok"})


@app.route("/stream")
def stream():
    """
    GET /stream?id=VIDEO_ID
    Header: X-API-Secret: <secret>  (API_SECRET 설정 시)

    응답:
    {
      "video_id":   "...",
      "stream_url": "https://...",
      "is_hls":     true,
      "is_live":    true,
      "title":      "...",
      "channel":    "..."
    }
    """
    if not check_auth():
        abort(401)

    video_id = request.args.get("id", "").strip()
    if not video_id or len(video_id) != 11:
        return jsonify({"error": "invalid_video_id"}), 400

    result = resolve_stream(video_id)

    if "error" in result:
        return jsonify(result), 404

    return jsonify(result)


if __name__ == "__main__":
    port = int(os.environ.get("PORT", 8080))
    app.run(host="0.0.0.0", port=port)
