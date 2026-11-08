# Local Whisper Server — Settings 設計說明

來源：Settings ▸ Service Providers ▸ Whisper Server（`localapp.local-whisper`）這一輪的產品／版面決定。  
實作主檔：`source/localapp/macos/sources/AirType/SettingsWindowController.swift`、`LocalWhisperServerManager.swift`、`AirTypeCoordinator.swift`。

## 目標

在 localapp Settings 裡管理本機 `whisper-server` process：能看狀態、手動起停、把「下次開 App 要不要自動起」與「現在有沒有在跑」分開，表單緊湊、可掃、不堆垂直空白。

## 核心語意（必守）

| 概念 | 意思 | 不是 |
|------|------|------|
| **Enabled** | 下次 App 啟動時是否自動 `start` whisper-server（launch preference） | 不是「現在正在跑」；勾／取消勾**不要**立刻 start／stop |
| **Start／Stop** | 執行期手動起停（同一顆 toggle：Stop 時標題變 Stop） | 不要做成兩顆常駐按鈕 |
| **Check** | 刷新／探測目前 runtime 狀態（含錯誤） | 不是「只檢查 path 存在」的假動作；也不要另開第二條 Status |
| **Status** | 單一來源的執行期狀態列，格式 `Status: …` | 不要同時顯示 `localServerStatus` 又加 `localTestResult` |

其他 lifecycle：

- `enabled` **預設 `false`**；新安裝不自動起 server。
- 拿掉 `launch_on_start`；不要再加第二個「開機自動起」開關。
- **Apply／Save 只寫 config**，不依 Enabled 同步 process。
- App **quit／terminate** 時必須 `stop` 掉由 manager spawn 的 whisper-server（managed process，不是常駐 daemon）。
- 狀態執行中要帶 **PID**（與 host:port 若有）；失敗時 Status 要看得到錯誤文字。

## Design concepts（版面）

這些是從 Whisper Server 頁反覆調整抽出來的 Preferences 風格，之後同類「長表單 + 執行期控制」頁應沿用。

### 1. 密度優先，少垂直堆疊

- 相關短欄位**併列同一列**，不要一人一列：
  - Host + Port（右側小標籤用 **Port**，不要寫 Host Port）
  - Max Threads + Max GPU
  - Language + Beam + Temperature
  - No Timestamps + No Language Symbol
- 列與列之間的 spacing 偏緊；標題下方不要留大塊空白。
- 整塊欄位區相對 detail 標題可以**略往下**一點，但整體**不要太高**（控制項高度、Status 最小高度、stack spacing 一起收）。

### 2. 欄位區靠左、寬度對齊

- 內容區 leading inset 偏小（靠左），不要被大 padding 推到畫面中央。
- **所有可編輯控制列共用同一個 `fieldWidth`（目前 480）**，與 Advanced Args／Vocabulary Prompt 對齊，避免長短不一。
- Browse…／Refresh／Start／Check 等 action 按鈕共用固定寬（目前 88），Start 翻成 Stop 時寬度不變。

### 3. 執行期控制放最上、狀態在正下方

- 第一列：`Enabled` + `Start|Stop` + `Check`（+ spinner）。
- 第二列：左對齊、最多兩行的 `Status: …`（等寬小字、secondary color）。
- Status **不要**擠在右側當 inline badge；也不要浮在別的欄位旁邊重複一份。

### 4. 標題區資訊，不佔一列欄位

- Config path 標示（例如 `[localapp.local-whisper]`）放在**標題旁**，不要當表單第一個欄位或獨立說明段落。

### 5. 用正確的控制型別

- Language 用 **popup／combo 固定選項**，不要自由文字（除非另有 Advanced）。
- Path 類：文字欄 + Browse… 同一列。
- Model 類：combo + Refresh 同一列；輔助說明可放在列下方一行 note。

### 6. 視覺層級

- 左欄 label 夠讀即可，不要過寬把控制項擠掉。
- Status／note 用 secondary／小字；主控制用 regular／略大即可，避免整頁「按鈕都很大」造成行高膨脹。
- 一頁一個工作：這頁就是「設定 + 起停 local whisper-server」，不要塞無關 marketing 或重複說明。

## 欄位列順序（建議）

1. Enabled / Start|Stop / Check + Status  
2. Server binary (+ Browse)  
3. Host + Port  
4. Max Threads + Max GPU  
5. Advanced Args  
6. Model Dir (+ Browse)  
7. Model Filename (+ Refresh)  
8. Language + Beam + Temperature  
9. Vocabulary Prompt  
10. No Timestamps + No Language Symbol  

（實際 key 以 `ConfigStore`／`ConfigJSON` 的 `localapp.local-whisper` 為準。）

## 反例（刻意不要）

- Enabled 與 Start／Stop 語意綁死（勾 Enabled 就立刻起、取消就立刻停）。
- Apply 時依 Enabled sync process。
- 兩個 Status 來源、或 Status 複製一份在右側。
- 每個數字欄位獨佔一列，表單變成很長一條。
- 欄位寬度參差（有的跟 Advanced Args 齊、有的明顯短一截）。
- 大 leading inset／大 title–content gap 讓內容「浮」在中央且偏高。
- quit 後留下 orphan whisper-server。

## 相關檔案

| 檔案 | 角色 |
|------|------|
| `SettingsWindowController.swift` | Whisper tab UI、Start/Stop/Check、Status |
| `LocalWhisperServerManager.swift` | Process 生命週期、readiness、PID／status 字串 |
| `AirTypeCoordinator.swift` | 擁有 manager；launch 時若 enabled 則 start；quit 時 stop |
| `ConfigStore.swift` / `ConfigJSON.swift` | `LocalWhisperServiceConfig`；無 `launch_on_start` |
| `config.example.json` | `localapp.local-whisper` 範例；`enabled` 預設 false |

## 未決／後續（這輪有提過但未當成硬需求）

- 其他 Service Provider 頁是否全面套用同一套「併列 + 480 寬 + 靠左」規則（建議：新改的頁跟進）。
- Status 文案多語系（目前英文 `Status: …` 即可）。
- Whisper Server 與 in-process ASR engine 選單的產品邊界說明（可另開文件）。
