# Media 執行路徑

入口是 `POST /api/clip-requests` 的 `known_sources.route_for_url`（`source/webui/app/main.py`、`source/webui/app/known_sources.py`）。另外兩條不經過這個分流：本機上傳的語音，以及 IME 短錄音。

```mermaid
flowchart TD
  url[Clip URL]
  route{route_for_url}
  url --> route

  route -->|threads.com threads.net| post[Capture Post]
  route -->|YouTube Bilibili Instagram TikTok Apple Podcasts Shorts 或媒體檔| voice[V-to-Text]
  route -->|其餘網頁| article[Web Article]

  post --> threads{Threads?}
  threads -->|是| chain[抓整串貼文]
  threads -->|否| og[讀 Open Graph 預覽]
  chain --> photos[照片上傳 Immich]
  og --> photos
  photos --> polish[LLM 潤稿 標題 標籤]
  polish --> notePost["Obsidian: Original Content"]

  article --> traf[Trafilatura 抽 Markdown]
  traf --> photos

  voice --> apple{Apple Podcasts?}
  apple -->|是| notes[讀節目簡介與音檔網址]
  apple -->|否| title[讀媒體標題]
  notes --> download[下載音檔]
  title --> download
  upload[本機音檔上傳] --> whisper
  download --> whisper[Whisper 逐字稿]
  whisper --> typo[LLM 分批改錯字]
  typo --> spoken[改過的逐字稿]
  notes --> preface[節目簡介放在逐字稿上面]
  spoken --> preface
  spoken --> articleLlm[LLM 潤成文章與標籤]
  preface --> noteVoice["Obsidian: Original Transcript"]
  articleLlm --> noteVoice

  ime[IME 短錄音] --> raw[只回傳 ASR 原文]
```

三條筆記路徑的差別：

- **Web Article**：Trafilatura 抽出正文與圖片，圖片進 Immich。原文進 Original Content，再潤稿、下標題、貼標籤。
- **Capture Post**：Threads 走整串貼文；其他貼文網址只讀 Open Graph。圖片同樣進 Immich，筆記區塊與文章相同。Instagram、TikTok 不走這裡，它們被歸到 V-to-Text。
- **V-to-Text**：下載後做 Whisper。錯字修正只改辨識片段，節目簡介不送進這一步。Apple Podcasts 的簡介排在 Original Transcript 上方。潤稿用的是改過的逐字稿。本機上傳走同一條 Whisper 之後的路徑，只是沒有下載與節目簡介。
- **IME**：`/api/transcribe/ime` 停在原始辨識文字，不改錯字，也不寫 Obsidian 筆記。
