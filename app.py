"""
RandomLiveTV — yt-dlp stream resolver server
- GET /stream?id=VIDEO_ID  → direct stream/HLS URL 반환
- GET /health              → 서버 상태 확인

주의: 이 서버는 media bytes 를 프록시하지 않는다. yt-dlp 가 얻은 URL 을 iOS 에 발급하고,
iOS 는 만료/실패 시 같은 videoId 로 새 URL 을 다시 요청한다.
"""

import os
import json
import subprocess
from flask import Flask, jsonify, request, abort

app = Flask(__name__)

API_SECRET = os.environ.get("API_SECRET", "")
YTDLP = os.environ.get("YTDLP_PATH", "yt-dlp")


def check_auth():
    if not API_SECRET:
        return True
    return request.headers.get("X-API-Secret", "") == API_SECRET


def run_ytdlp_json(video_id: str):
    url = f"https://www.youtube.com/watch?v={video_id}"
    cmd = [
        YTDLP,
        "--no-warnings",
        "--dump-single-json",
        "--no-playlist",
        "--extractor-args", "youtube:player_client=ios,android,web",
        url,
    ]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=35)
    except subprocess.TimeoutExpired as exc:
        return None, {
            "error": "yt_dlp_timeout",
            "detail": str(exc),
            "cmd": " ".join(cmd),
        }
    except Exception as exc:
        return None, {
            "error": "yt_dlp_exec_failed",
            "detail": str(exc),
            "cmd": " ".join(cmd),
        }

    if result.returncode != 0:
        return None, {
            "error": "yt_dlp_failed",
            "returncode": result.returncode,
            "stderr": result.stderr[-4000:],
            "stdout": result.stdout[-1000:],
            "cmd": " ".join(cmd),
        }

    try:
        return json.loads(result.stdout), None
    except Exception as exc:
        return None, {
            "error": "yt_dlp_json_decode_failed",
            "detail": str(exc),
            "stdout": result.stdout[:1000],
        }


def score_format(fmt: dict) -> int:
    """높을수록 iOS AVPlayer 에 넘기기 좋은 후보."""
    url = fmt.get("url") or ""
    protocol = fmt.get("protocol") or ""
    ext = fmt.get("ext") or ""
    format_id = str(fmt.get("format_id") or "")
    vcodec = fmt.get("vcodec") or "none"
    acodec = fmt.get("acodec") or "none"
    height = fmt.get("height") or 0

    if not url.startswith("http"):
        return -1

    score = 0

    # 라이브는 m3u8 이 가장 현실적이다.
    if "m3u8" in protocol or ".m3u8" in url or ext == "mp4" and format_id in {"91", "92", "93", "94", "95", "96", "300", "301"}:
        score += 1000
    if ".m3u8" in url:
        score += 300
    if "m3u8_native" in protocol:
        score += 200

    # audio+video 통합 포맷 우선. video-only/audio-only 는 AVPlayer 단일 URL 재생에 부적합할 수 있다.
    if vcodec != "none" and acodec != "none":
        score += 500
    elif vcodec != "none":
        score += 100
    elif acodec != "none":
        score -= 100

    # 너무 고해상도보다 안정적인 720p/480p 라이브 우선.
    if 360 <= height <= 720:
        score += 80
    elif height > 720:
        score += 40

    return score


def pick_stream(info: dict):
    formats = info.get("formats") or []
    candidates = []
    for fmt in formats:
        score = score_format(fmt)
        if score > 0:
            candidates.append((score, fmt))

    candidates.sort(key=lambda pair: pair[0], reverse=True)
    if candidates:
        fmt = candidates[0][1]
        return {
            "url": fmt.get("url"),
            "is_hls": "m3u8" in (fmt.get("protocol") or "") or ".m3u8" in (fmt.get("url") or ""),
            "format_id": fmt.get("format_id"),
            "format_note": fmt.get("format_note"),
            "protocol": fmt.get("protocol"),
            "height": fmt.get("height"),
            "vcodec": fmt.get("vcodec"),
            "acodec": fmt.get("acodec"),
        }

    # yt-dlp 가 top-level url 을 제공하는 경우 fallback.
    top_url = info.get("url")
    if isinstance(top_url, str) and top_url.startswith("http"):
        return {
            "url": top_url,
            "is_hls": ".m3u8" in top_url,
            "format_id": info.get("format_id"),
            "format_note": info.get("format"),
            "protocol": info.get("protocol"),
            "height": info.get("height"),
            "vcodec": info.get("vcodec"),
            "acodec": info.get("acodec"),
        }

    return None


def resolve_stream(video_id: str) -> dict:
    info, error = run_ytdlp_json(video_id)
    if error:
        return error

    stream = pick_stream(info)
    if not stream or not stream.get("url"):
        formats = info.get("formats") or []
        sample = [
            {
                "format_id": f.get("format_id"),
                "ext": f.get("ext"),
                "protocol": f.get("protocol"),
                "height": f.get("height"),
                "vcodec": f.get("vcodec"),
                "acodec": f.get("acodec"),
                "has_url": bool(f.get("url")),
            }
            for f in formats[:20]
        ]
        return {
            "error": "stream_not_found",
            "reason": "no playable http/m3u8 format selected",
            "format_count": len(formats),
            "formats_sample": sample,
        }

    return {
        "video_id": video_id,
        "stream_url": stream["url"],
        "is_hls": stream["is_hls"],
        "is_live": bool(info.get("is_live")),
        "title": info.get("title") or "알 수 없음",
        "channel": info.get("uploader") or info.get("channel") or "알 수 없음",
        "format_id": stream.get("format_id"),
        "format_note": stream.get("format_note"),
        "protocol": stream.get("protocol"),
        "height": stream.get("height"),
        "vcodec": stream.get("vcodec"),
        "acodec": stream.get("acodec"),
    }


@app.route("/health")
def health():
    return jsonify({"status": "ok"})


@app.route("/stream")
def stream():
    if not check_auth():
        abort(401)

    video_id = request.args.get("id", "").strip()
    if not video_id or len(video_id) != 11:
        return jsonify({"error": "invalid_video_id"}), 400

    result = resolve_stream(video_id)
    if "error" in result:
        code = 504 if result["error"] == "yt_dlp_timeout" else 404
        return jsonify(result), code
    return jsonify(result)


if __name__ == "__main__":
    port = int(os.environ.get("PORT", 8080))
    app.run(host="0.0.0.0", port=port)
