# yt-dlp 更新指南

## 為什麼需要更新 yt-dlp？

yt-dlp 頻繁更新以支援新的網站和修復相容性問題。請先分清這兩類錯誤：

- `No supported JavaScript runtime could be found` — 缺少 Deno（或 Node.js 22+）。這不是 yt-dlp 過舊，也不是 cookies 能解的。安裝：`brew install deno`，然後重啟 AirType。
- `Remote components ... were skipped` / `n challenge solving failed` / `Only images are available` — Deno 已找到，但 EJS 解題腳本沒載入。AirType 會傳 `--remote-components ejs:github`。伺服器上也要安裝：`.venv/bin/python -m pip install -U yt-dlp-ejs`。
- `unable to download video data: HTTP Error 403` — 簽名解完後 CDN 仍拒絕。先確認 EJS 腳本有載入。若仍 403，才是 IP 被擋或該影片需要 cookies。

**YouTube Shorts 通常需要 yt-dlp 版本 2026.08 或更高版本，以及 Deno 2.3+。**

## 更新方法

### 方法 1：使用更新腳本（本地）

```bash
./scripts/update-yt-dlp.sh
```

### 方法 2：手動更新

#### 對於 virtual environment

```bash
.venv/bin/python -m pip install --upgrade yt-dlp
```

#### 對於系統 Python

```bash
python3 -m pip install --upgrade yt-dlp
```

#### 如果遇到 "Will not install to the site-packages" 錯誤

```bash
python3 -m pip install --upgrade yt-dlp --break-system-packages
```

### 方法 3：使用 Homebrew (macOS)

```bash
brew upgrade yt-dlp
```

### 方法 4：遠端伺服器更新

如果您使用遠端 WebUI（如 `https://airtype.dougpuob.uk`），請在伺服器上執行以下指令：

```bash
# 1. 連線到遠端伺服器
ssh your-server-ip

# 2. 找到 Python 環境
cd /path/to/airtype
ls -la .venv/bin/python

# 3. 更新 yt-dlp
.venv/bin/python -m pip install --upgrade yt-dlp

# 4. 驗證版本
.venv/bin/python -m yt_dlp --version

# 5. 測試 YouTube Shorts 下載
.venv/bin/python -m yt_dlp --no-playlist -f "bestaudio/best" --write-info-json -o "test.%(ext)s" "https://youtube.com/shorts/zBstQ3x3WZE"
```

## 驗證更新

更新後，測試 YouTube Shorts URL：

```bash
# 測試 1：獲取格式列表
yt-dlp --list-formats "https://youtube.com/shorts/zBstQ3x3WZE"

# 測試 2：下載音訊
yt-dlp --no-playlist -f "bestaudio/best" --write-info-json -o "test.%(ext)s" "https://youtube.com/shorts/zBstQ3x3WZE"
```

## 自動更新

AirType 現在在 WebUI 啟動時會自動檢查 yt-dlp 版本並嘗試更新。如果您想手動觸發更新，可以：

1. 重新啟動 WebUI：`./scripts/start-webui.sh`
2. 或直接執行更新腳本：`./scripts/update-yt-dlp.sh`

## 常見問題

### Q: 出現 `No supported JavaScript runtime could be found`？
A: 安裝 Deno 2.3+（`brew install deno`）後重啟 AirType。AirType 會自動尋找 `/opt/homebrew/bin/deno` 等路徑，並把 `--js-runtimes deno:/絕對路徑` 傳給 yt-dlp。`--impersonate`、cookies、更新 yt-dlp 都不能取代這個 JS runtime。

### Q: 更新後仍然有 403 錯誤？
A: 請確保：
1. Deno（或 Node.js 22+）已安裝，且 AirType 重啟後能找到它
2. 使用正確的 Python 環境（virtual environment 或系統 Python）
3. 更新指令沒有被快取（可以加 `--no-cache-dir` 參數）
4. 檢查是否有其他 yt-dlp 版本被安裝
5. 若是年齡限制或需登入的影片，再設定 `[webui.yt-dlp] cookies_from_browser`

### Q: 如何檢查目前的 yt-dlp 版本？
A: 執行 `yt-dlp --version` 或 `python3 -m yt_dlp --version`

### Q: 更新腳本失敗了怎麼辦？
A: 請手動執行更新指令，並查看錯誤訊息解決問題。

## 設定 cookies (可選)

如果更新後仍然遇到問題，可以考慮設定瀏覽器 cookies：

```toml
[webui.yt-dlp]
cookies_from_browser = "chrome"
```

這會讓 yt-dlp 使用您瀏覽器的cookies來下載內容，適用於需要登入的媒體。