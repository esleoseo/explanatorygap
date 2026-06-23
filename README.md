# RandomLiveTV — yt-dlp 프록시 서버

YouTube 광고 없이 HLS 스트림을 iOS AVPlayer로 재생하기 위한 백엔드.

## 구조

```
[iOS 앱] → GET /stream?id=VIDEO_ID → [Railway 서버: yt-dlp] → HLS URL 반환 → AVPlayer 재생
```

## Railway 배포 (5분)

### 1. 이 폴더를 GitHub 레포로 올리기

```bash
cd yt-proxy/
git init
git add .
git commit -m "init"
# GitHub 에서 새 레포 생성 후:
git remote add origin https://github.com/YOUR_NAME/yt-proxy.git
git push -u origin main
```

### 2. Railway 에서 배포

1. [railway.app](https://railway.app) 접속 → GitHub 로그인
2. **New Project → Deploy from GitHub repo** → 위 레포 선택
3. 자동 빌드 시작 (약 2~3분)
4. **Settings → Networking → Generate Domain** 클릭
   - 예: `yt-proxy-production.up.railway.app`

### 3. 환경변수 설정 (선택 — 보안)

Railway 대시보드 → Variables:

| 키 | 값 | 설명 |
|---|---|---|
| `API_SECRET` | 임의의 문자열 | iOS 앱에서 같은 값 입력 |

비워두면 누구나 접근 가능 (테스트용으로는 괜찮음).

### 4. iOS 앱에서 URL 입력

`StreamResolver.swift` 에서:

```swift
private let baseURL   = "https://yt-proxy-production.up.railway.app"
private let apiSecret = "설정한_시크릿_값"   // 없으면 ""
```

## API

### GET /stream?id=VIDEO_ID

**응답 (200)**
```json
{
  "video_id":   "dQw4w9WgXcQ",
  "stream_url": "https://manifest.googlevideo.com/...m3u8",
  "is_hls":     true,
  "is_live":    true,
  "title":      "영상 제목",
  "channel":    "채널명"
}
```

**오류 응답**
- `400` — video_id 가 잘못됨
- `401` — API_SECRET 불일치
- `404` — 스트림을 찾지 못함 (비공개/삭제/지역 제한)

### GET /health

서버 상태 확인. `{"status": "ok"}` 반환.

## iOS 파일 교체 목록

기존 Xcode 프로젝트에서 아래 파일을 교체/추가:

| 파일 | 변경 내용 |
|---|---|
| `StreamResolver.swift` | 신규 추가 |
| `PlayerView.swift` | 신규 추가 (AVPlayer 기반) |
| `LiveManager.swift` | StreamResolver 연동, ResolvedStream 상태 |
| `ContentView.swift` | PlayerView(streamURL:) 사용 |
| `PlayerWebView.swift` | **삭제** (더 이상 불필요) |

`YouTubeService.swift` 는 기존 것 그대로 사용.

## 비용

Railway 무료 플랜: 월 $5 크레딧.
yt-dlp 호출당 약 1~2초, 메모리 50MB 이하.
하루 수백 회 호출 기준 무료 플랜 안에서 충분히 운용 가능.
