# LLM Endpoints — Settings 設計說明

來源：Settings ▸ Endpoint Profiles ▸ LLM Endpoints（`webui.llm-server`）這一輪的版面決定。  
實作主檔：`source/localapp/macos/sources/AirType/SettingsWindowController.swift`、`ProfileListPanel.swift`。  
版面規則沿用 `docs/localapp-settings-whisper-server.md` 的 Preferences 密度。

## 目標

用緊湊、可掃的表單管理多個 LLM server profile（llama.cpp / OpenAI-compatible 等）：改 endpoint／model、Fetch Models、Test。Profile 只有名字；Apply／Save 時以目前選中的那份寫入 `default-llm-server-name`。不改 JSON 的主要 shape。

## 核心語意（必守）

| 概念 | 意思 | 不是 |
|------|------|------|
| **Profiles 列表** | 已存的 `[[webui.llm-server]]` entries；名字只是標籤 | 不是即時寫檔；要 Apply／Save 才進 config.json。**沒有** Active／Set Active |
| **Add／Modify／Delete** | 對記憶體中的 profile 清單操作 | Modify ≠ Apply；切列前若 dirty 會確認 |
| **目前選中的 profile** | Apply／Save 時寫成 `[webui] default-llm-server-name`／`webui.llm`（app 實際使用的那份） | 不是獨立的「設為 active」動作 |
| **selected-model** | config.json **唯一**持久化的 model 欄位 | 不要把整份 supported model 清單寫進 config |
| **models（config）** | 不再使用；讀舊檔可忽略，存檔時寫成 `[]` | 不是下拉選單的來源 |
| **Model combo** | 預設下拉**只有**該 profile 的 `selected-model` | 不是一進頁就列出遠端全部 model |
| **Fetch** | `GET {base}/v1/models`；成功則**暫時**填滿下拉並保留按下 Fetch 當下的 selected；失敗／空列表則清空下拉與選取。清單不寫入 config | 不是 Test；不要在成功後擅自改成列表第一項 |
| **Test** | `POST {base}/v1/chat/completions` 探測選中的 model | 結果用單一 Status 風格列，不要第二條結果 |

## Design concepts（版面）

### 1. 密度優先，少垂直堆疊

- 短欄位併列：
  - Name + Provider
  - Context Length + Temperature + Thinking
- Model + Fetch 同一列；Fetch note 在列下。
- System Prompt 略矮（約 64pt），不要用過高多行框撐滿視窗。

### 2. 欄位區靠左、寬度對齊

- 控制欄共用 `fieldWidth`（480）。
- Fetch／Test 共用 `actionButtonWidth`（88）；Fetch 標題用 **Fetch**（tooltip 可寫 Fetch Models）。
- Profiles 表與按鈕列總寬大致對齊 480，垂直空白略收。

### 3. 標題區資訊，不佔一列欄位

- Config path `[webui.llm-server]` 放在 detail **標題旁**，不要在表單頂部再塞 `[[…]] · active = …`。

### 4. Test 結果單一來源

- Test 按鈕 + spinner 一列；下方等寬小字結果（最多兩行、綠／紅／secondary）。
- 不要複製第二條 status，也不要右側 badge。

## 欄位列順序

1. Profiles（list + Add／Modify／Delete）  
2. Name + Provider  
3. Endpoint  
4. API Key  
5. Model + Fetch（+ note）  
6. Context Length + Temperature + Thinking  
7. System Prompt  
8. Test + result  

## 反例（刻意不要）

- 把 Fetch 到的全 model 清單寫進 config.json／`models`。
- 進頁就把遠端全清單當預設下拉（必須先 Fetch）。
- Active 欄／Set Active／✓ 標記。
- 表單內再顯示 `[[webui.llm-server]] · active = …`。
- Selected Model 360、Endpoint 480 混用。
- Context／Temperature／Thinking 各佔一長列。

## 相關檔案

| 檔案 | 角色 |
|------|------|
| `SettingsWindowController.swift` | `buildLLMTab`、Fetch／Test |
| `ProfileListPanel.swift` | 共用 profile 表 + 按鈕 |
| `ConfigStore.swift` / `ConfigJSON.swift` | `LLMServerConfig`；schema 不變 |

## 未決／後續

- ASR Endpoints／Whisper Endpoints 套用同一套密度。
- Provider 是否改成固定 popup（llama.cpp／ollama／openai）而非自由文字。
