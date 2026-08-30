# yt-dlp 更新指南

## 為什麼需要更新 yt-dlp？

yt-dlp 頻繁更新以支援新的網站和修復相容性問題。如果您遇到以下錯誤，通常表示 yt-dlp 版本過舊：

- `HTTP Error 403: Forbidden` - 無法下載 YouTube Shorts 或其他媒體
- `No supported JavaScript runtime could be found` - 缺少 JavaScript 執行環境
- 某些格式無法下載

**YouTube Shorts 通常需要 yt-dlp 版本 2026.08 或更高版本。**

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

### Q: 更新後仍然有 403 錯誤？
A: 請確保：
1. 使用正確的 Python 環境（virtual environment 或系統 Python）
2. 更新指令沒有被快取（可以加 `--no-cache-dir` 參數）
3. 檢查是否有其他 yt-dlp 版本被安裝

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