#!/usr/bin/env bash
set -euo pipefail

echo "yt-dlp 更新腳本"
echo

# 查找 Python 環境
VENV_DIR="${VENV_DIR:-.venv}"

if [[ -x "$VENV_DIR/bin/python" ]]; then
    PYTHON_BIN="$VENV_DIR/bin/python"
    echo "使用 virtual environment: $VENV_DIR"
elif command -v python3 >/dev/null 2>&1; then
    PYTHON_BIN="python3"
    echo "使用系統 Python: $(python3 --version)"
else
    echo "錯誤：找不到 Python"
    exit 1
fi

# 獲取當前版本
CURRENT_VERSION=$("$PYTHON_BIN" -m yt_dlp --version 2>/dev/null || echo "unknown")
echo "目前版本: $CURRENT_VERSION"

# 獲取最新版本
echo "正在檢查最新版本..."
LATEST_VERSION=$("$PYTHON_BIN" -c "
import urllib.request
import json
try:
    url = 'https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest'
    request = urllib.request.Request(url, headers={'User-Agent': 'AirType', 'Accept': 'application/vnd.github.v3+json'})
    with urllib.request.urlopen(request, timeout=10) as response:
        data = json.loads(response.read().decode('utf-8'))
        tag_name = data.get('tag_name', '')
        if tag_name.startswith('v'):
            tag_name = tag_name[1:]
        print(tag_name)
except Exception as e:
    print(f'error: {e}')
")

if [[ "$LATEST_VERSION" == error:* ]]; then
    echo "無法從 GitHub 獲取最新版本，使用 pip 檢查..."
    LATEST_VERSION=""
fi

echo "最新版本: $LATEST_VERSION"
echo

# 比較版本
if [[ -n "$LATEST_VERSION" && "$LATEST_VERSION" != "unknown" ]]; then
    # 使用 Python 比較版本
    IS_OUTDATED=$("$PYTHON_BIN" -c "
def parse_version(v):
    parts = v.split('.')
    result = []
    for part in parts:
        try:
            result.append(int(part))
        except ValueError:
            result.append(part)
    return tuple(result)

def is_older(current, latest):
    current_parts = parse_version(current)
    latest_parts = parse_version(latest)
    for c, l in zip(current_parts, latest_parts):
        if isinstance(c, int) and isinstance(l, int):
            if c < l:
                return True
            elif c > l:
                return False
        else:
            if str(c) < str(l):
                return True
            elif str(c) > str(l):
                return False
    return len(current_parts) < len(latest_parts)

current = '$CURRENT_VERSION'
latest = '$LATEST_VERSION'
print('true' if is_older(current, latest) else 'false')
")

    if [[ "$IS_OUTDATED" == "false" ]]; then
        echo "yt-dlp 已經是最新版本！"
        exit 0
    else
        echo "yt-dlp 需要更新！"
    fi
else
    echo "無法確定是否需要更新，繼續嘗試更新..."
fi

echo "正在更新 yt-dlp..."
echo

# 嘗試使用 pip 更新
if "$PYTHON_BIN" -m pip install --upgrade yt-dlp yt-dlp-ejs 2>/dev/null; then
    echo "yt-dlp 更新成功！"
    echo "當前版本："
    "$PYTHON_BIN" -m yt_dlp --version
    exit 0
else
    echo "錯誤：無法更新 yt-dlp"
    echo "請嘗試手動更新："
    echo "  $PYTHON_BIN -m pip install --upgrade yt-dlp"
    echo "或添加 --break-system-packages 參數："
    echo "  $PYTHON_BIN -m pip install --upgrade yt-dlp --break-system-packages"
    exit 1
fi