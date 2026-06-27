const seedSegments = [
    {
        time: "00:00:00 -> 00:00:20",
        text: "如果我成為一名學生，我最想做會的是學習 AI。學習 AI 的方法不僅是一個工具，他是很好的開源體系。王仁勳叫我們學會和 AI 溝通，聽起來很遙遠對吧？就像 1915 年，有人拍著一些快要被淘汰的老馬說。"
    },
    {
        time: "00:00:20 -> 00:00:40",
        text: "放心你要學會拉車拉得更平穩哪所以別被巨頭的公開稿騙了打開華爾街 2026 年的真實劇本他們正在執行一場針對白領階級的人力安樂死今天我不想聊什麼如何提升職場競爭力"
    },
    {
        time: "00:00:40 -> 00:01:00",
        text: "我們都是靠薪水養家的普通人說實話我們的對手是不是不用睡覺也不用付勞保的算力時該競爭力真的太不現實了我們真正應該做的是看懂聰明錢的資金管線在影片的最後我會分享我是如何去防範這場危機"
    },
    {
        time: "00:01:00 -> 00:01:20",
        text: "這不是販賣焦慮是我們中產階級為了保護家人必須打贏的一場財富保衛戰我們先來看看一段很多人不知道的歷史 1915 年人類歷史上馬的數量達到了頂峰那時候的馬是社會上的核心生產力有專門的社會"
    },
    {
        time: "00:01:20 -> 00:01:40",
        text: "頂級的馬感覺至今保護他們的工會如果當時有一隻充滿焦慮的中產階級老馬看到了汽車出現的新聞他做出了最散戶思維的決定把自己的小馬送去頂級拉車學院以為只要小馬考了第一名未來就有了保障"
    },
    {
        time: "00:01:40 -> 00:02:00",
        text: "但打敗他們的從來不是另一匹學歷更高的馬打敗他們的是不需要吃草不會發脾氣不知道疲倦的內燃機一夜之間馬就從社會的核心資本降為優化成了富人農場裡的寵物或者是看膩工廠裡的"
    }
];

const segmentsEl = document.getElementById("segments");
const transcriptScrollPanel = document.getElementById("transcriptScrollPanel");
const emptyState = document.getElementById("emptyState");
const segmentCount = document.getElementById("segmentCount");
const toast = document.getElementById("toast");
const audioFile = document.getElementById("audioFile");
const languageSelect = document.getElementById("languageSelect");
const waveform = document.getElementById("waveform");
const recordButton = document.getElementById("recordButton");
const micToggle = document.getElementById("micToggle");
const currentTime = document.getElementById("currentTime");
const dropZone = document.getElementById("dropZone");
const sourceUrl = document.getElementById("sourceUrl");
const asrServerStatusPill = document.getElementById("asrServerStatusPill");
const localLlmStatusPill = document.getElementById("localLlmStatusPill");
const transcribeUrlButton = document.getElementById("transcribeUrlButton");
const progressText = document.getElementById("progressText");
const progressDetail = document.getElementById("progressDetail");
const progressBar = document.getElementById("progressBar");
const transcriptDebug = document.getElementById("transcriptDebug");
const transcriptTitle = document.getElementById("transcriptTitle");
const recordList = document.getElementById("recordList");
const historySearchInput = document.getElementById("historySearchInput");
const imeRecordList = document.getElementById("imeRecordList");
const imeSegmentsEl = document.getElementById("imeSegments");
const imeDebug = document.getElementById("imeDebug");
const recordContextMenu = document.getElementById("recordContextMenu");
const renameDialog = document.getElementById("renameDialog");
const renameForm = document.getElementById("renameForm");
const renameTitleInput = document.getElementById("renameTitleInput");
const renameCurrentTitle = document.getElementById("renameCurrentTitle");
const cancelRenameButton = document.getElementById("cancelRenameButton");
const llmApiKeyDialog = document.getElementById("llmApiKeyDialog");
const llmApiKeyForm = document.getElementById("llmApiKeyForm");
const llmApiKeyInput = document.getElementById("llmApiKeyInput");
const llmApiKeyDialogText = document.getElementById("llmApiKeyDialogText");
const cancelLlmApiKeyButton = document.getElementById("cancelLlmApiKeyButton");
const llmApiKeyStatus = document.getElementById("llmApiKeyStatus");
const fileName = document.getElementById("fileName");
const fileSource = document.getElementById("fileSource");
const fileSize = document.getElementById("fileSize");
const fileType = document.getElementById("fileType");
const mediaPlayerCard = document.getElementById("mediaPlayerCard");
const playerEmptyState = document.getElementById("playerEmptyState");
const mediaViewer = document.getElementById("mediaViewer");
const audioViewer = document.getElementById("audioViewer");
const playerStatus = document.getElementById("playerStatus");
const copyArticleButton = document.getElementById("copyArticleButton");
const transcriptPage = document.getElementById("transcriptPage");
const transcriptActionbar = document.getElementById("transcriptActionbar");
const transcriptWavebar = document.getElementById("transcriptWavebar");
const imePage = document.getElementById("imePage");
const postWeaverPage = document.getElementById("postWeaverPage");
const settingsPage = document.getElementById("settingsPage");
const settingsNav = document.getElementById("settingsNav");
const llmModelSelect = document.getElementById("settingLlmModelSelect");
const llmPrompt = document.getElementById("llmPrompt");
const llmResponse = document.getElementById("llmResponse");
const postWeaverUrl = document.getElementById("postWeaverUrl");
const postWeaverPosts = document.getElementById("postWeaverPosts");
const postWeaverOutput = document.getElementById("postWeaverOutput");
const postWeaverObsidianPreview = document.getElementById("postWeaverObsidianPreview");
const postWeaverProgress = document.getElementById("postWeaverProgress");
const transcriptObsidianPreview = document.getElementById("transcriptObsidianPreview");
const saveTranscriptToObsidianButton = document.getElementById("saveTranscriptToObsidianButton");

const defaultSettings = {
    whisper: {
        model_dir: "",
        model_filename: "",
        server_bin: "",
        remote_endpoint: "",
        language: "zh-tw",
        beam: 5,
        temperature: 0,
    },
    llm: {
        name: "default",
        provider: "llama.cpp",
        endpoint: "http://127.0.0.1:8080",
        api_key: "",
        model: "",
        models: [],
        selected_model: "",
        contextLength: 8192,
        temperature: 0.4,
        system: "Summarize and answer questions using the transcript as the source of truth."
    },
    auth: {
        enabled: false,
        username: "airtype",
        password: ""
    },
    llm_servers: [],
    default_llm_server_name: "default"
};

let segments = [];
let selectedIndex = 0;
let recorder = null;
let chunks = [];
let discardCurrentRecording = false;
let timer = null;
let seconds = 24;
let activeJobId = null;
let transcribePending = false;
let stopRequested = false;
let selectedRecordId = null;
let transcriptRecords = [];
let currentArticleText = "";
let currentTranscriptRecord = null;
let selectedImeRecordId = null;
let contextRecord = null;
let contextRecordType = "transcript";
let renameRecordTarget = null;
let dropInProgress = false;
let activeMedia = null;
let mediaObjectUrl = null;
let lastAutoScrolledIndex = -1;
let appSettings = loadSettings();
let localModels = [];
let llmSessionApiKeys = {};
let pendingLlmApiKeyDialog = null;
let wovenPosts = [];
let capturedPostUrl = "";
let capturedPostTitle = "";
let wovenAiTags = "";
const OBSIDIAN_POST_TEMPLATE = `---
title: {{DATE}} {{TITLE}}
sources:
{{sources}}
datetime: {{DATETIME}}
tags:
{{tags}}
---

---

# Title

{{TITLE}}

---

# Notes




---

# AI Tags

{{ai_tags}}

---

# AI Polished Article

{{polished_content}}

---

# Original Content

{{content}}

---

END`;
const OBSIDIAN_TRANSCRIPT_TEMPLATE = `---
title: {{DATE}} {{TITLE}}
sources:
{{sources}}
datetime: {{DATETIME}}
tags:
{{tags}}
---

---

# Title

{{TITLE}}

---

# Notes




---

# AI Tags

{{ai_tags}}

---

# AI Polished Article

{{polished_content}}

---

# Original Transcript

{{content}}
`;
function showToast(message) {
    toast.textContent = message;
    toast.classList.add("show");
    clearTimeout(showToast.timer);
    showToast.timer = setTimeout(() => toast.classList.remove("show"), 1800);
}

function llmApiKeySlot(llm = appSettings.llm || {}) {
    return `${llm.provider || ""}|${String(llm.endpoint || "").trim().replace(/\/+$/, "")}`;
}

function sessionLlmApiKey(llm = appSettings.llm || {}) {
    return llmSessionApiKeys[llmApiKeySlot(llm)] || "";
}

function configuredLlmApiKey(llm = appSettings.llm || {}) {
    return String(llm.api_key || llm["api-key"] || "").trim();
}

function isLocalEndpoint(endpoint = "") {
    try {
        const url = new URL(endpoint);
        return ["localhost", "127.0.0.1", "::1"].includes(url.hostname);
    } catch {
        return false;
    }
}

function shouldAskForLlmApiKey(llm = appSettings.llm || {}) {
    const endpoint = String(llm.endpoint || "").trim();
    if (!endpoint || configuredLlmApiKey(llm) || sessionLlmApiKey(llm)) return false;
    try {
        const url = new URL(endpoint);
        return url.protocol === "https:" && !isLocalEndpoint(endpoint);
    } catch {
        return false;
    }
}

function updateLlmApiKeyStatus() {
    if (!llmApiKeyStatus) return;
    llmApiKeyStatus.textContent = configuredLlmApiKey(appSettings.llm || {})
        ? "Saved in config"
        : (sessionLlmApiKey(appSettings.llm || {}) ? "Set for this session" : "Not saved");
}

function openLlmApiKeyDialog(llm = appSettings.llm || {}, message = "") {
    if (pendingLlmApiKeyDialog) return pendingLlmApiKeyDialog.promise;
    const endpoint = String(llm.endpoint || "").trim() || "this endpoint";
    llmApiKeyDialogText.textContent = message || `Enter the API key for ${endpoint}. It will not be saved.`;
    llmApiKeyInput.value = "";
    llmApiKeyDialog.hidden = false;
    llmApiKeyInput.focus();
    pendingLlmApiKeyDialog = {};
    pendingLlmApiKeyDialog.slot = llmApiKeySlot(llm);
    pendingLlmApiKeyDialog.promise = new Promise(resolve => {
        pendingLlmApiKeyDialog.resolve = resolve;
    });
    return pendingLlmApiKeyDialog.promise;
}

function closeLlmApiKeyDialog(value = "") {
    llmApiKeyDialog.hidden = true;
    llmApiKeyInput.value = "";
    if (pendingLlmApiKeyDialog) {
        pendingLlmApiKeyDialog.resolve(value);
        pendingLlmApiKeyDialog = null;
    }
}

async function ensureLlmApiKey(llm = appSettings.llm || {}) {
    const configured = configuredLlmApiKey(llm);
    if (configured) return configured;
    if (!shouldAskForLlmApiKey(llm)) return sessionLlmApiKey(llm);
    const apiKey = await openLlmApiKeyDialog(llm);
    if (!apiKey) {
        throw new Error("API key is required for this endpoint");
    }
    return apiKey;
}

function setCurrentArticleText(text = "") {
    currentArticleText = text || "";
    updateCopyArticleButtonState();
    renderTranscriptObsidianPreview();
}

function updateCopyArticleButtonState() {
    const hasArticle = Boolean(currentArticleText.trim());
    copyArticleButton.disabled = !hasArticle;
    copyArticleButton.title = hasArticle
        ? "Copy generated article"
        : "Article is not ready yet";
}

function renderSegments() {
    segmentsEl.innerHTML = "";
    segmentCount.textContent = `${segments.length || 0} segments`;

    if (segments.length === 0) {
        const empty = document.createElement("div");
        empty.className = "result-empty";
        empty.textContent = activeJobId
            ? "Transcription has started. Results will appear here as soon as whisper.cpp emits segments."
            : "Transcript results will appear here.";
        segmentsEl.appendChild(empty);
        renderTranscriptObsidianPreview();
        return;
    }

    segments
        .map((segment, index) => ({ segment, index }))
        .forEach(({ segment, index }) => {
            const item = document.createElement("article");
            item.className = `segment${index === selectedIndex ? " active" : ""}`;
            item.dataset.segmentIndex = String(index);
            const hasTimestamps = segment.has_timestamps !== false;
            const time = segment.time || "time unavailable";
            const duration = segment.duration_text || (hasTimestamps ? `${Math.max(0, Number(segment.end || 0) - Number(segment.start || 0)).toFixed(1)}s` : "time unavailable");
            const timeline = duration === "time unavailable" ? time : `${time} (${duration})`;
            item.innerHTML = `
                <div class="segment-meta">
                    <span class="segment-time">${escapeHtml(timeline)}</span>
                </div>
                <div class="segment-text">${escapeHtml(segment.text)}</div>
            `;
            item.addEventListener("click", () => {
                selectedIndex = index;
                lastAutoScrolledIndex = -1;
                seekToSegment(segment);
                renderSegments();
                scrollActiveSegmentIntoView("smooth");
            });
            segmentsEl.appendChild(item);
        });
    renderTranscriptObsidianPreview();
}

async function loadTranscriptRecords() {
    try {
        const response = await fetch("/api/transcribe/records");
        if (!response.ok) return;
        const payload = await response.json();
        transcriptRecords = payload.records || [];
        renderTranscriptRecords();
    } catch {
        transcriptRecords = [];
        renderTranscriptRecords();
    }
}

async function loadImeRecords() {
    try {
        const response = await fetch("/api/transcribe/records?record_type=ime");
        if (!response.ok) return;
        const payload = await response.json();
        renderImeRecords(payload.records || []);
    } catch {
        renderImeRecords([]);
    }
}

function historyFilterText(record) {
    const segmentCount = record.result?.segment_count ?? 0;
    const timestamp = recordTimestamp(record);
    return [
        recordTitle(record, "transcript"),
        record.job_id,
        record.status,
        record.source?.name,
        record.source?.type,
        `${segmentCount} segments`,
        formatRecordTimestamp(timestamp),
        record.updated_at,
        record.created_at
    ].filter(Boolean).join(" ").toLowerCase();
}

function recordTimestamp(record) {
    return record.updated_at || record.created_at || "";
}

function formatRecordTimestamp(value) {
    if (!value) return "";
    const date = new Date(value);
    if (Number.isNaN(date.getTime())) return "";
    return date.toLocaleString("zh-TW", {
        year: "numeric",
        month: "2-digit",
        day: "2-digit",
        hour: "2-digit",
        minute: "2-digit",
        hour12: false
    });
}

function filteredTranscriptRecords() {
    const query = historySearchInput.value.trim().toLowerCase();
    if (!query) return transcriptRecords;
    return transcriptRecords.filter(record => historyFilterText(record).includes(query));
}

function renderTranscriptRecords() {
    const records = filteredTranscriptRecords();
    recordList.innerHTML = "";
    if (!transcriptRecords.length) {
        const empty = document.createElement("div");
        empty.className = "record-item";
        empty.innerHTML = `<strong>No records yet</strong><span>Completed transcripts will appear here.</span>`;
        recordList.appendChild(empty);
        return;
    }

    if (!records.length) {
        const empty = document.createElement("div");
        empty.className = "record-item";
        empty.innerHTML = `<strong>No matches</strong><span>Try another title, status, or source.</span>`;
        recordList.appendChild(empty);
        return;
    }

    records.slice(0, 12).forEach(record => {
        const item = document.createElement("button");
        item.className = `record-item${record.job_id === selectedRecordId ? " active" : ""}`;
        item.type = "button";
        const segmentCount = record.result?.segment_count ?? 0;
        const status = record.status || "unknown";
        const timestamp = formatRecordTimestamp(recordTimestamp(record));
        const metadata = [status, `${segmentCount} segments`, timestamp].filter(Boolean).join(" · ");
        item.innerHTML = `
            <span class="record-main">
                <strong>${escapeHtml(recordTitle(record, "transcript"))}</strong>
                <span>${escapeHtml(metadata)}</span>
            </span>
        `;
        item.addEventListener("click", () => loadTranscriptRecord(record.job_id));
        item.addEventListener("contextmenu", event => showRecordContextMenu(event, record, "transcript"));
        recordList.appendChild(item);
    });
}

function renderImeRecords(records) {
    imeRecordList.innerHTML = "";
    if (!records.length) {
        const empty = document.createElement("div");
        empty.className = "record-item";
        empty.innerHTML = `<strong>No IME records yet</strong><span>Speech input records will appear here.</span>`;
        imeRecordList.appendChild(empty);
        return;
    }

    records.slice(0, 24).forEach(record => {
        const item = document.createElement("button");
        item.className = `record-item${record.job_id === selectedImeRecordId ? " active" : ""}`;
        item.type = "button";
        const textLength = record.result?.text_length ?? 0;
        item.innerHTML = `
            <span class="record-main">
                <strong>${escapeHtml(recordTitle(record, "ime"))}</strong>
                <span>${escapeHtml(record.status || "unknown")} · ${textLength} chars</span>
            </span>
            <span class="record-actions" aria-label="IME record actions">
                <span class="record-action" role="button" tabindex="0" data-action="rename" title="Rename">Edit</span>
                <span class="record-action danger" role="button" tabindex="0" data-action="delete" title="Delete">Del</span>
            </span>
        `;
        item.addEventListener("click", () => loadImeRecord(record.job_id));
        item.addEventListener("contextmenu", event => showRecordContextMenu(event, record, "ime"));
        attachInlineRecordActions(item, record, "ime");
        imeRecordList.appendChild(item);
    });
}

function recordTitle(record, recordType = "transcript") {
    if (record?.title) return record.title;
    if (record?.source?.name) return record.source.name;
    if (recordType === "ime") return record?.job_id || "IME record";
    return "Untitled transcript";
}

function attachInlineRecordActions(item, record, recordType) {
    item.querySelectorAll(".record-action").forEach(actionButton => {
        actionButton.addEventListener("click", async event => {
            event.stopPropagation();
            const action = actionButton.dataset.action;
            try {
                if (action === "rename") {
                    openRenameDialog(record, recordType);
                } else if (action === "delete") {
                    await deleteRecord(record, recordType);
                }
            } catch (error) {
                showToast(error.message);
            }
        });
        actionButton.addEventListener("keydown", event => {
            if (event.key === "Enter" || event.key === " ") {
                event.preventDefault();
                actionButton.click();
            }
        });
    });
}

function renderImeRecord(record) {
    const transcript = record?.transcript || {};
    const debug = transcript.debug || record?.whisper_server_debug || null;
    const text = transcript.text || "";
    imeSegmentsEl.innerHTML = "";
    if (!text) {
        const empty = document.createElement("div");
        empty.className = "result-empty";
        empty.textContent = "IME record content will appear here.";
        imeSegmentsEl.appendChild(empty);
    } else {
        const item = document.createElement("article");
        item.className = "segment active";
        item.innerHTML = `
            <div class="segment-meta">
                <span>${escapeHtml(record.job_id || "time unavailable")}</span>
                <span>${text.length} chars</span>
                <span class="source">ime</span>
            </div>
            <div class="segment-text">${escapeHtml(text)}</div>
        `;
        imeSegmentsEl.appendChild(item);
    }

    if (!debug) {
        imeDebug.hidden = true;
        imeDebug.innerHTML = "";
        return;
    }
    const timing = debug.timing_ms || {};
    const fields = debug.request_fields || {};
    imeDebug.hidden = false;
    imeDebug.innerHTML = `
        <strong>IME debug</strong>
        <div>${Object.entries(timing).map(([key, value]) => `${escapeHtml(key)}=${escapeHtml(value)}ms`).join(" · ") || "No timing data"}</div>
        <div>${Object.entries(fields).map(([key, value]) => `${escapeHtml(key)}=${escapeHtml(value)}`).join(" · ") || "No request field data"}</div>
    `;
}

async function loadImeRecord(jobId) {
    if (!jobId) return;
    try {
        const response = await fetch(`/api/transcribe/records/${jobId}?record_type=ime`);
        if (!response.ok) {
            const error = await response.json().catch(() => ({}));
            throw new Error(error.detail || "Could not load IME record");
        }
        const payload = await response.json();
        selectedImeRecordId = payload.record.job_id;
        renderImeRecord(payload.record);
        loadImeRecords();
        showToast("IME record loaded");
    } catch (error) {
        showToast(error.message);
    }
}

function showRecordContextMenu(event, record, recordType = "transcript") {
    event.preventDefault();
    contextRecord = record;
    contextRecordType = recordType;
    recordContextMenu.hidden = false;
    recordContextMenu.style.left = `${event.clientX}px`;
    recordContextMenu.style.top = `${event.clientY}px`;
}

function hideRecordContextMenu() {
    recordContextMenu.hidden = true;
    contextRecord = null;
    contextRecordType = "transcript";
}

function shouldHideRecordContextMenu(event) {
    return !recordContextMenu.hidden &&
        event.button === 0 &&
        !recordContextMenu.contains(event.target);
}

function openRenameDialog(record, recordType = "transcript") {
    renameRecordTarget = record;
    renameRecordTarget.recordType = recordType;
    const currentTitle = recordTitle(record, recordType);
    renameCurrentTitle.textContent = `Current title: ${currentTitle}`;
    renameTitleInput.value = currentTitle;
    renameDialog.hidden = false;
    requestAnimationFrame(() => {
        renameTitleInput.focus();
        renameTitleInput.select();
    });
}

function closeRenameDialog() {
    renameDialog.hidden = true;
    renameRecordTarget = null;
    renameCurrentTitle.textContent = "";
    renameTitleInput.value = "";
}

async function submitRenameDialog() {
    if (!renameRecordTarget) return;
    const title = renameTitleInput.value.trim();
    if (!title) {
        showToast("Title cannot be empty");
        return;
    }

    const renamedRecordId = renameRecordTarget.job_id;
    const recordType = renameRecordTarget.recordType || "transcript";
    const suffix = recordType === "ime" ? "?record_type=ime" : "";
    const response = await fetch(`/api/transcribe/records/${renamedRecordId}${suffix}`, {
        method: "PATCH",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ title })
    });
    if (!response.ok) {
        const error = await response.json().catch(() => ({}));
        throw new Error(error.detail || "Could not rename transcript");
    }
    if (selectedRecordId === renamedRecordId) {
        currentTranscriptRecord = { ...(currentTranscriptRecord || {}), title };
        setTranscriptTitle(title);
        fileName.textContent = title;
    }
    if (selectedImeRecordId === renamedRecordId) {
        loadImeRecord(renamedRecordId);
    }
    closeRenameDialog();
    if (recordType === "ime") {
        await loadImeRecords();
    } else {
        await loadTranscriptRecords();
    }
    showToast("Record renamed");
}

async function deleteRecord(record, recordType = "transcript") {
    const name = recordTitle(record, recordType);
    if (!confirm(`Delete "${name}"?`)) return;
    const suffix = recordType === "ime" ? "?record_type=ime" : "";
    const response = await fetch(`/api/transcribe/records/${record.job_id}${suffix}`, { method: "DELETE" });
    if (!response.ok) {
        const error = await response.json().catch(() => ({}));
        throw new Error(error.detail || "Could not delete record");
    }
    if (recordType === "transcript" && selectedRecordId === record.job_id) {
        selectedRecordId = null;
        currentTranscriptRecord = null;
        setCurrentArticleText("");
        segments = [];
        selectedIndex = 0;
        renderTranscriptDebug(null);
        renderSegments();
        setSourceInfo("", null, "", "");
        setTranscriptTitle("");
        clearMediaPlayer();
    }
    if (recordType === "ime" && selectedImeRecordId === record.job_id) {
        selectedImeRecordId = null;
        imeSegmentsEl.innerHTML = `<div class="result-empty">IME record content will appear here.</div>`;
        imeDebug.hidden = true;
        imeDebug.innerHTML = "";
    }
    if (recordType === "ime") {
        await loadImeRecords();
    } else {
        await loadTranscriptRecords();
    }
    showToast("Record deleted");
}

async function loadTranscriptRecord(jobId) {
    if (!jobId) return;
    try {
        const response = await fetch(`/api/transcribe/records/${jobId}`);
        if (!response.ok) {
            const error = await response.json().catch(() => ({}));
            throw new Error(error.detail || "Could not load transcript record");
        }
        const payload = await response.json();
        const record = payload.record;
        selectedRecordId = record.job_id;
        currentTranscriptRecord = record;
        setCurrentArticleText(record.article?.text || "");
        const title = record.title || record.source?.name || "Transcript";
        setTranscriptTitle(title);
        const recordSource = sourceUrlFromRecord(record) || record.source?.path || "Saved record";
        setSourceInfo(title, record.source?.size ?? null, record.source?.type || "record", recordSource);
        loadRecordMedia(record);
        applyTranscriptResult(record.transcript || {});
        loadTranscriptRecords();
        showToast("Transcript loaded");
    } catch (error) {
        showToast(error.message);
    }
}

function setProgress(percent, message, busy = false, indeterminate = false) {
    const normalized = Math.max(0, Math.min(100, Number(percent) || 0));
    if (progressBar) {
        progressBar.classList.toggle("indeterminate", indeterminate);
        if (!indeterminate) {
            progressBar.style.width = `${normalized}%`;
        } else {
            progressBar.style.width = "";
        }
    }
    progressText.textContent = message ? `${normalized}% - ${message}` : "Ready";
    progressDetail.textContent = message
        ? (busy ? "Working on the current transcription." : "Status updated.")
        : "Paste a URL or choose a file to begin.";
    dropZone.classList.toggle("busy", busy);
    updateTranscribeButtonState();
}

function updateTranscribeButtonState() {
    const canStop = Boolean(activeJobId) || transcribePending;
    transcribeUrlButton.textContent = canStop ? "Stop" : "Transcribe";
    transcribeUrlButton.classList.toggle("danger", canStop);
    transcribeUrlButton.classList.toggle("primary", !canStop);
}

function loadSettings() {
    try {
        const stored = JSON.parse(localStorage.getItem("airtype.settings") || "{}");
        return normalizeSettings({ ...defaultSettings, ...stored });
    } catch {
        return { ...defaultSettings };
    }
}

async function loadServerSettings(options = {}) {
    try {
        const url = options.force ? `/api/settings?ts=${Date.now()}` : "/api/settings";
        const response = await fetch(url, {
            cache: "no-store",
            headers: { "Cache-Control": "no-cache" }
        });
        if (!response.ok) return;
        const payload = await response.json();
        saveSettings(payload.settings || {}, { persist: false, markWhisperClean: true });
        loadWhisperServerStatus();
    } catch {
        // Keep browser-local defaults when ~/.airtype/config.toml is unavailable.
    }
}

async function persistSettingsToServer(settings) {
    try {
        const response = await fetch("/api/settings", {
            method: "PUT",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ settings })
        });
        if (!response.ok) {
            throw new Error("Could not save settings");
        }
        return true;
    } catch {
        showToast("Settings saved locally only");
        return false;
    }
}

function normalizeSettings(settings) {
    const whisper = { ...defaultSettings.whisper, ...(settings.whisper || {}) };
    const auth = { ...defaultSettings.auth, ...(settings.auth || {}) };
    auth.enabled = Boolean(auth.enabled);
    auth.username = auth.username || "airtype";
    auth.password = auth.password || "";
    let llm = normalizeLlmServer({ ...defaultSettings.llm, ...(settings.llm || {}) });
    let llmServers = Array.isArray(settings.llm_servers)
        ? settings.llm_servers.map(server => normalizeLlmServer(server)).filter(server => server.name)
        : [];
    if (!llmServers.length && llm.name) {
        llmServers = [llm];
    }
    const defaultName = settings.default_llm_server_name || llm.name || llmServers[0]?.name || "default";
    const selectedServer = llmServers.find(server => server.name === defaultName)
        || llmServers.find(server => server.name === llm.name)
        || llmServers[0];
    if (selectedServer) {
        llm = { ...selectedServer };
    }
    
    return {
        whisper,
        auth,
        llm,
        llm_servers: llmServers,
        default_llm_server_name: llm.name || defaultName
    };
}

function normalizeLlmServer(server) {
    const llm = { ...defaultSettings.llm, ...(server || {}) };
    llm.name = llm.name || "default";
    llm.provider = llm.provider || "llama.cpp";
    llm.api_key = llm.api_key || llm["api-key"] || "";
    llm.models = Array.isArray(llm.models) ? llm.models.filter(Boolean) : [];
    llm.selected_model = llm.selected_model || llm["selected-model"] || llm.default_model || llm.model || "";
    llm.model = llm.selected_model || llm.model || "";
    return llm;
}

function currentLlmServersWithSelected(selectedLlm = appSettings.llm || {}) {
    const selected = normalizeLlmServer(selectedLlm);
    const servers = Array.isArray(appSettings.llm_servers)
        ? appSettings.llm_servers.map(server => normalizeLlmServer(server)).filter(server => server.name)
        : [];
    const index = servers.findIndex(server => server.name === selected.name);
    if (index >= 0) {
        servers[index] = selected;
    } else {
        servers.push(selected);
    }
    return servers;
}

function uniqueLlmServerName(baseName) {
    const existing = new Set((appSettings.llm_servers || []).map(server => server.name));
    let name = baseName || "local";
    let suffix = 2;
    while (existing.has(name)) {
        name = `${baseName || "local"}-${suffix}`;
        suffix += 1;
    }
    return name;
}

function addLlmServer() {
    const rawName = prompt("New LLM server name", "local");
    if (rawName === null) return;
    const name = uniqueLlmServerName(rawName.trim() || "local");
    const current = readSettingsFromForm();
    const nextServer = normalizeLlmServer({
        name,
        provider: "llama.cpp",
        endpoint: "http://127.0.0.1:8080",
        api_key: "",
        model: "",
        selected_model: "",
        contextLength: 8192,
        temperature: 0.4,
        system: "",
        models: []
    });
    saveSettings({
        ...current,
        llm: nextServer,
        llm_servers: [...current.llm_servers, nextServer],
        default_llm_server_name: name
    }, { persist: false });
    localModels = [];
    showToast(`Added ${name}`);
}

function deleteLlmServer() {
    const current = readSettingsFromForm();
    const selectedName = current.default_llm_server_name;
    const servers = current.llm_servers.filter(server => server.name !== selectedName);
    if (!selectedName || current.llm_servers.length <= 1) {
        showToast("Keep at least one LLM server");
        return;
    }
    if (!confirm(`Delete LLM server "${selectedName}"?`)) return;
    const nextServer = servers[0] || normalizeLlmServer(defaultSettings.llm);
    saveSettings({
        ...current,
        llm: nextServer,
        llm_servers: servers.length ? servers : [nextServer],
        default_llm_server_name: nextServer.name
    }, { persist: false });
    localModels = [];
    showToast(`Deleted ${selectedName}`);
}

async function saveSettingsFromForm() {
    const settings = readSettingsFromForm();
    const saved = await persistSettingsToServer(settings);
    saveSettings(settings, { persist: false, markWhisperClean: true });
    showToast(saved ? "Settings saved" : "Settings saved locally only");
}

function markWhisperSettingsClean() {
    updateSaveSettingsButtonState();
}

function updateSaveSettingsButtonState() {
    const currentSettings = readSettingsFromForm();
    const hasChanges = JSON.stringify(currentSettings) !== JSON.stringify(appSettings);
    const saveButton = document.getElementById("saveSettingsButton");
    if (saveButton) {
        saveButton.disabled = !hasChanges;
    }
}

function saveSettings(settings, options = {}) {
    const shouldPersist = options.persist !== false;
    appSettings = normalizeSettings(settings);
    localStorage.setItem("airtype.settings", JSON.stringify(appSettings));
    applySettingsToForm();
    if (options.markWhisperClean) {
        markWhisperSettingsClean();
    }
    updateSaveSettingsButtonState();
    if (shouldPersist) {
        return persistSettingsToServer(appSettings);
    }
    return Promise.resolve();
}

function applySettingsToForm() {
    const whisper = appSettings.whisper || {};
    const llm = appSettings.llm || {};
    
    document.getElementById("settingWhisperModelDir").value = whisper.model_dir || "";
    document.getElementById("settingWhisperModelFilename").value = whisper.model_filename || "";
    document.getElementById("settingWhisperServerBin").value = whisper.server_bin || "";
    document.getElementById("settingWhisperLanguage").value = whisper.language || "zh-tw";
    const auth = appSettings.auth || {};
    document.getElementById("settingAuthEnabled").checked = Boolean(auth.enabled);
    document.getElementById("settingAuthUsername").value = auth.username || "airtype";
    document.getElementById("settingAuthPassword").value = auth.password || "";
    const llmNameSelect = document.getElementById("settingLlmName");
    const llmServers = Array.isArray(appSettings.llm_servers) && appSettings.llm_servers.length
        ? appSettings.llm_servers
        : [llm];
    llmNameSelect.innerHTML = llmServers
        .map(server => `<option value="${escapeHtml(server.name || "default")}">${escapeHtml(server.name || "default")}</option>`)
        .join("");
    llmNameSelect.value = llm.name || appSettings.default_llm_server_name || "default";
    const providerSelect = document.getElementById("settingLlmProvider");
    providerSelect.value = llm.provider || "llama.cpp";
    if (providerSelect.value !== (llm.provider || "llama.cpp")) {
        providerSelect.value = "openai";
    }
    document.getElementById("settingLlmEndpoint").value = llm.endpoint || "http://127.0.0.1:8080";
    document.getElementById("settingLlmApiKey").value = llm.api_key || "";
    if (Array.isArray(llm.models) && llm.models.length) {
        llmModelSelect.innerHTML = llm.models
            .map(modelName => `<option value="${escapeHtml(modelName)}">${escapeHtml(modelName)}</option>`)
            .join("");
    } else {
        llmModelSelect.innerHTML = `<option value="">Fetch model list to choose</option>`;
    }
    if ([...llmModelSelect.options].some(option => option.value === llm.model)) {
        llmModelSelect.value = llm.model;
    }
    document.getElementById("settingLlmContext").value = llm.contextLength || 8192;
    document.getElementById("settingLlmTemperature").value = llm.temperature || 0.4;
    document.getElementById("settingLlmSystem").value = llm.system || "";
    languageSelect.value = whisper.language || "zh-tw";
    const deleteServerButton = document.getElementById("deleteLlmServerButton");
    if (deleteServerButton) {
        deleteServerButton.disabled = llmServers.length <= 1;
    }
    updateLlmApiKeyStatus();
    updateContextLengthHint();
    updateSaveSettingsButtonState();
}

function readSettingsFromForm() {
    const existingLlm = appSettings.llm || {};
    const selectedModel = llmModelSelect.value || "";
    const selectedName = document.getElementById("settingLlmName").value || existingLlm.name || "default";
    const selectedLlm = {
        ...existingLlm,
        name: selectedName,
        provider: document.getElementById("settingLlmProvider").value || existingLlm.provider || "llama.cpp",
        endpoint: document.getElementById("settingLlmEndpoint").value.trim(),
        api_key: document.getElementById("settingLlmApiKey").value.trim(),
        model: selectedModel,
        selected_model: selectedModel,
        contextLength: Number(document.getElementById("settingLlmContext").value) || 8192,
        temperature: Number(document.getElementById("settingLlmTemperature").value) || 0.4,
        system: document.getElementById("settingLlmSystem").value
    };
    return {
        auth: {
            enabled: document.getElementById("settingAuthEnabled").checked,
            username: document.getElementById("settingAuthUsername").value.trim() || "airtype",
            password: document.getElementById("settingAuthPassword").value
        },
        whisper: {
            model_dir: document.getElementById("settingWhisperModelDir").value.trim(),
            model_filename: document.getElementById("settingWhisperModelFilename").value.trim(),
            server_bin: document.getElementById("settingWhisperServerBin").value.trim(),
            remote_endpoint: "",
            language: document.getElementById("settingWhisperLanguage").value
        },
        llm: selectedLlm,
        llm_servers: currentLlmServersWithSelected(selectedLlm),
        default_llm_server_name: selectedName
    };
}

function setWhisperServerStatus(message, state = "") {
    const status = document.getElementById("whisperServerStatus");
    status.textContent = message;
    status.classList.toggle("ok", state === "ok");
    status.classList.toggle("error", state === "error");
}

function setActiveWhisperServer(payload = {}) {
    const endpointInput = document.getElementById("activeWhisperEndpoint");
    const modelInput = document.getElementById("activeWhisperModel");
    const running = Boolean(payload.running || payload.endpoint);
    endpointInput.value = running ? (payload.endpoint || "External endpoint configured") : "Not running";
    modelInput.value = payload.model || payload.model_path || (payload.mode === "remote" ? "External server" : "Not loaded");
}

function setStatusPillState(pill, state) {
    pill.classList.toggle("online", state === "online");
    pill.classList.toggle("offline", state === "offline");
    pill.classList.toggle("checking", state === "checking");
}

async function loadWhisperServerStatus() {
    try {
        const response = await fetch("/api/whisper-server/status", { cache: "no-store" });
        if (!response.ok) {
            setStatusPillState(asrServerStatusPill, "offline");
            return;
        }
        const payload = await response.json();
        setActiveWhisperServer(payload);
        if (payload.running === true) {
            setStatusPillState(asrServerStatusPill, "online");
        } else if (payload.running === false) {
            setStatusPillState(asrServerStatusPill, "offline");
        }
    } catch {
        setActiveWhisperServer();
        setStatusPillState(asrServerStatusPill, "offline");
    }
}

async function loadLocalLlmStatus() {
    const llm = appSettings.llm || {};
    if (!llm.provider || !llm.endpoint) {
        setStatusPillState(localLlmStatusPill, "offline");
        return;
    }
    try {
        const apiKey = configuredLlmApiKey(llm) || sessionLlmApiKey(llm);
        const response = await fetch("/api/local-llm/health", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            cache: "no-store",
            body: JSON.stringify({
                provider: llm.provider,
                endpoint: llm.endpoint,
                api_key: apiKey || null
            })
        });
        if (!response.ok) {
            setStatusPillState(localLlmStatusPill, "offline");
            return;
        }
        const payload = await response.json().catch(() => ({}));
        if (payload.ok === true) {
            setStatusPillState(localLlmStatusPill, "online");
        } else {
            setStatusPillState(localLlmStatusPill, "offline");
        }
    } catch {
        setStatusPillState(localLlmStatusPill, "offline");
    }
}

function pollServiceHealth() {
    loadWhisperServerStatus();
    loadLocalLlmStatus();
}

async function testWhisperServer() {
    const button = document.getElementById("testWhisperServerButton");
    const settings = readSettingsFromForm();
    button.disabled = true;
    setWhisperServerStatus("Testing...", "");
    saveSettings(settings, { persist: false });
    try {
        const response = await fetch("/api/whisper-server/test", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ settings })
        });
        const payload = await response.json().catch(() => ({}));
        if (!response.ok || payload.ok === false) {
            throw new Error(payload.detail || "whisper-server test failed");
        }
        const saved = await persistSettingsToServer(settings);
        saveSettings(payload.settings || settings, { persist: false, markWhisperClean: true });
        setActiveWhisperServer(payload);
        setWhisperServerStatus(payload.message || "whisper-server is ready.", "ok");
        showToast(saved ? "whisper-server is ready; settings saved" : "whisper-server is ready");
    } catch (error) {
        setWhisperServerStatus(error.message || "whisper-server test failed", "error");
        showToast(error.message || "whisper-server test failed");
    } finally {
        button.disabled = false;
    }
}

async function restartWhisperServer() {
    const button = document.getElementById("restartWhisperServerButton");
    const settings = readSettingsFromForm();
    button.disabled = true;
    setWhisperServerStatus("Restarting whisper-server...", "");
    try {
        let response = await fetch("/api/whisper-server/restart", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ settings })
        });
        let payload = await response.json().catch(() => ({}));
        if (response.status === 405) {
            response = await fetch("/api/whisper-server/test", {
                method: "POST",
                headers: { "Content-Type": "application/json" },
                body: JSON.stringify({ settings })
            });
            payload = await response.json().catch(() => ({}));
        }
        if (!response.ok || payload.ok === false) {
            throw new Error(payload.detail || "Could not restart whisper-server");
        }
        const saved = await persistSettingsToServer(payload.settings || settings);
        saveSettings(payload.settings || settings, { persist: false, markWhisperClean: true });
        setActiveWhisperServer(payload);
        setWhisperServerStatus(payload.message || "whisper-server restarted.", "ok");
        showToast(saved ? "whisper-server restarted; settings saved" : "whisper-server restarted");
    } catch (error) {
        setWhisperServerStatus(error.message || "Could not restart whisper-server", "error");
        showToast(error.message || "Could not restart whisper-server");
    } finally {
        button.disabled = false;
    }
}

function splitModelPath(modelPath) {
    const trimmed = String(modelPath || "").trim();
    if (!trimmed) {
        return { modelDir: "", modelFilename: "" };
    }
    const separatorIndex = Math.max(trimmed.lastIndexOf("/"), trimmed.lastIndexOf("\\"));
    if (separatorIndex < 0) {
        return { modelDir: "", modelFilename: trimmed };
    }
    return {
        modelDir: trimmed.slice(0, separatorIndex),
        modelFilename: trimmed.slice(separatorIndex + 1)
    };
}

function formatTokens(value) {
    return Number(value).toLocaleString("en-US");
}

function escapeHtml(value) {
    return String(value)
        .replaceAll("&", "&amp;")
        .replaceAll("<", "&lt;")
        .replaceAll(">", "&gt;")
        .replaceAll("\"", "&quot;")
        .replaceAll("'", "&#39;");
}

function describeModel(model) {
    if (model.context_length) {
        return `${model.name} (${formatTokens(model.context_length)} ctx)`;
    }
    if (model.configured_context_length) {
        return `${model.name} (${formatTokens(model.configured_context_length)} configured ctx)`;
    }
    return model.name;
}

function modelContextLength(model) {
    return model?.context_length || model?.configured_context_length || null;
}

function selectedLocalModel() {
    const llm = appSettings.llm || {};
    const selectedModel = llmModelSelect.value || llm.model;
    return localModels.find(item => item.name === selectedModel);
}

function applySelectedModelMetadata() {
    const model = selectedLocalModel();
    const contextLength = modelContextLength(model);
    if (contextLength) {
        document.getElementById("settingLlmContext").value = contextLength;
    }
    updateContextLengthHint();
}

function updateContextLengthHint() {
    const hint = document.getElementById("settingLlmContextHint");
    const input = document.getElementById("settingLlmContext");
    const llm = appSettings.llm || {};
    const model = selectedLocalModel();

    input.removeAttribute("max");
    if (model?.context_length) {
        input.max = model.context_length;
        hint.textContent = `${model.context_source || "Model metadata"} reports ${formatTokens(model.context_length)} tokens.`;
    } else if (model?.configured_context_length) {
        hint.textContent = `Modelfile config reports num_ctx ${formatTokens(model.configured_context_length)}. You can override it for this request.`;
    } else {
        hint.textContent = "Fetch model list to read context length from llama.cpp /props or Ollama model metadata when available.";
    }
}

async function loadLocalModels() {
    saveSettings(readSettingsFromForm(), { persist: false });
    llmModelSelect.innerHTML = `<option value="">Loading models...</option>`;
    try {
        const llm = appSettings.llm || {};
        const apiKey = await ensureLlmApiKey(llm);
        const response = await fetch("/api/local-llm/models", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({
                provider: llm.provider,
                endpoint: llm.endpoint,
                api_key: apiKey
            })
        });
        if (!response.ok) {
            const error = await response.json().catch(() => ({}));
            throw new Error(error.detail || "Could not fetch model list");
        }
        const payload = await response.json();
        const models = payload.models || [];
        localModels = models;
        appSettings.llm = {
            ...(appSettings.llm || {}),
            models: models.map(model => model.name).filter(Boolean)
        };
        llmModelSelect.innerHTML = models.length
            ? models.map(model => `<option value="${escapeHtml(model.name)}">${escapeHtml(describeModel(model))}</option>`).join("")
            : `<option value="">No local models found</option>`;
        if (models.length) {
            const llm = appSettings.llm || {};
            const storedModel = models.find(model => model.name === llm.model);
            llmModelSelect.value = storedModel ? storedModel.name : models[0].name;
            applySelectedModelMetadata();
        }
        const saved = await persistSettingsToServer(readSettingsFromForm());
        saveSettings(readSettingsFromForm(), { persist: false });
        updateContextLengthHint();
        showToast(`Loaded ${models.length} model${models.length === 1 ? "" : "s"}${saved ? "; settings saved" : ""}`);
    } catch (error) {
        localModels = [];
        llmModelSelect.innerHTML = `<option value="">${escapeHtml(error.message || "Fetch model list failed")}</option>`;
        updateContextLengthHint();
        showToast(error.message);
    }
}

async function sendLocalPrompt() {
    const settings = readSettingsFromForm();
    saveSettings(settings, { persist: false });
    const prompt = llmPrompt.value.trim();
    if (!prompt) {
        showToast("Enter a prompt first");
        return;
    }
    llmResponse.textContent = "Thinking...";
    try {
        const llm = appSettings.llm || {};
        const apiKey = await ensureLlmApiKey(llm);
        const response = await fetch("/api/local-llm/chat", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({
                provider: llm.provider,
                endpoint: llm.endpoint,
                model: llm.model,
                prompt,
                system: llm.system,
                temperature: llm.temperature,
                context_length: llm.contextLength,
                api_key: apiKey
            })
        });
        if (!response.ok) {
            const error = await response.json().catch(() => ({}));
            throw new Error(error.detail || "Local LLM request failed");
        }
        const payload = await response.json();
        llmResponse.textContent = payload.response || "(Empty response)";
        const saved = await persistSettingsToServer(settings);
        showToast(saved ? "Local LLM responded; settings saved" : "Local LLM responded");
    } catch (error) {
        llmResponse.textContent = error.message;
        showToast(error.message);
    }
}

function activeWhisperEndpoint() {
    return "";
}

function renderWovenPosts() {
    if (!wovenPosts.length) {
        postWeaverPosts.innerHTML = '<div class="weaver-empty">No post captured yet. Add a public post URL, then select Capture.</div>';
        return;
    }
    postWeaverPosts.innerHTML = wovenPosts.map((post, index) => `
        <article class="weaver-post">
            <header><span>Post ${index + 1}${post.url ? ` · ${escapeHtml(postHost(post.url))}` : ""}</span></header>
            <p>${escapeHtml(post.text)}</p>
        </article>
    `).join("");
}

function postHost(url) {
    try {
        return new URL(url).hostname || "source";
    } catch {
        return "source";
    }
}

function combinedPostsText() {
    return uniquePostBlocks(wovenPosts.map(post => post.text.trim()).filter(Boolean).join("\n\n"));
}

function uniquePostBlocks(text = "") {
    const seen = new Set();
    return String(text)
        .split(/\n\s*\n/)
        .map(block => block.trim())
        .filter(block => {
            if (!block) return false;
            const key = block.replace(/[\s\u200B-\u200D\uFEFF]+/g, " ").trim();
            if (seen.has(key)) return false;
            seen.add(key);
            return true;
        })
        .join("\n\n");
}

function titleFromPostText(text = "") {
    const firstBlock = String(text)
        .split(/\n\s*\n/)
        .map(block => block.trim())
        .find(Boolean) || "";
    return firstBlock.replace(/\s+/g, " ").trim();
}

const ARTICLE_TITLE_MAX_LENGTH = 30;

function fallbackArticleTitle(text = "") {
    const characters = Array.from(String(text).replace(/\s+/g, " ").trim());
    if (!characters.length) return "TITLE";
    return sanitizeObsidianTitle(characters.slice(0, ARTICLE_TITLE_MAX_LENGTH).join("")) || "TITLE";
}

function sanitizeObsidianTitle(text = "") {
    return String(text)
        .replace(/[\\/:*?"<>|;；：\u0000-\u001F]/g, " ")
        .replace(/\s+/g, " ")
        .trim();
}

function normalizeGeneratedTitle(text = "") {
    const firstLine = String(text).split(/\r?\n/).find(line => line.trim()) || "";
    const normalized = firstLine
        .replace(/^\s*(?:標題|title)\s*[:：]\s*/i, "")
        .replace(/^#+\s*/, "")
        .replace(/[「」『』"“”]/g, "")
        .trim();
    return sanitizeObsidianTitle(Array.from(normalized).slice(0, ARTICLE_TITLE_MAX_LENGTH).join(""));
}

function setWeaverProgress(step = "", status = "idle") {
    const steps = ["capture", "polish", "title", "obsidian"];
    const activeIndex = steps.indexOf(step);
    postWeaverProgress.querySelectorAll("[data-weaver-step]").forEach((item, index) => {
        item.classList.remove("active", "complete", "error");
        if (status === "complete" || (activeIndex > index && status !== "error")) {
            item.classList.add("complete");
        } else if (index === activeIndex) {
            item.classList.add(status === "error" ? "error" : "active");
        }
    });
}

async function captureWovenPost() {
    const url = postWeaverUrl.value.trim();
    if (!url) {
        showToast("Paste a public post URL first");
        postWeaverUrl.focus();
        return;
    }
    const button = document.getElementById("capturePostButton");
    const saveButton = document.getElementById("savePostsToObsidianButton");
    button.disabled = true;
    button.textContent = "Capturing...";
    saveButton.disabled = true;
    capturedPostTitle = "";
    let currentWeaverStep = "capture";
    setWeaverProgress(currentWeaverStep);
    renderObsidianPreview();
    try {
        const isThreadsUrl = /https?:\/\/(?:www\.)?threads\.(?:com|net)\//i.test(url);
        const response = await fetch(isThreadsUrl ? "/api/post-weaver/threads-chain" : "/api/post-weaver/import", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({ url })
        });
        const payload = await response.json().catch(() => ({}));
        if (!response.ok) throw new Error(payload.detail || "Could not import this post");
        if (isThreadsUrl) {
            const incomingPosts = Array.isArray(payload.posts) ? payload.posts : [];
            if (!incomingPosts.length) throw new Error("No public continuation posts were found");
            wovenPosts = incomingPosts
                .filter(post => post?.text)
                .map(post => ({ text: post.text, url: post.url || url, mediaUrls: Array.isArray(post.media_urls) ? post.media_urls : [] }));
            capturedPostTitle = titleFromPostText(wovenPosts[0]?.text);
            renderWovenPosts();
            showToast(`Captured ${wovenPosts.length} post${wovenPosts.length === 1 ? "" : "s"} from @${payload.author || "author"}`);
        } else {
            const text = String(payload.text || "").trim();
            if (!text) throw new Error("This site did not expose public post text");
            wovenPosts = [{ text, url, mediaUrls: Array.isArray(payload.media_urls) ? payload.media_urls : [] }];
            capturedPostTitle = String(payload.title || "").trim() || titleFromPostText(text);
            renderWovenPosts();
            showToast("Post captured");
        }
        capturedPostUrl = url;
        wovenAiTags = "";
        postWeaverOutput.value = "";
        document.getElementById("weaverPolishSection").open = true;
        currentWeaverStep = "polish";
        setWeaverProgress(currentWeaverStep);
        const polishedContent = await polishWovenPosts();
        currentWeaverStep = "title";
        setWeaverProgress(currentWeaverStep);
        capturedPostTitle = await generateWovenPostTitle(polishedContent || combinedPostsText());
        wovenAiTags = await generateWovenPostAiTags(polishedContent || combinedPostsText(), capturedPostTitle);
        currentWeaverStep = "obsidian";
        setWeaverProgress(currentWeaverStep);
        renderObsidianPreview();
        saveButton.disabled = false;
        document.getElementById("weaverCopySection").open = true;
        setWeaverProgress("obsidian", "complete");
    } catch (error) {
        setWeaverProgress(currentWeaverStep, "error");
        showToast(error.message || "Could not capture this post");
    } finally {
        button.disabled = false;
        button.textContent = "Capture";
    }
}

async function polishWovenPosts() {
    const source = uniquePostBlocks(combinedPostsText());
    if (!source) {
        return false;
    }
    try {
        const llm = appSettings.llm || {};
        const apiKey = await ensureLlmApiKey(llm);
        const response = await fetch("/api/local-llm/chat", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({
                provider: llm.provider,
                endpoint: llm.endpoint,
                model: llm.model,
                api_key: apiKey,
                temperature: llm.temperature,
                context_length: llm.contextLength,
                system: "你是嚴謹、克制的繁體中文編輯。忠實保留原文的觀點、時間線與事實，不得加入新資訊、評論、推測、俏皮語氣、誇張修辭或宣傳式文字。",
                prompt: `請將以下社群貼文整理成一篇通順、簡潔、語氣中性的繁體中文文章。\n\n要求：\n1. 移除重複段落、重複敘述、社群介面文字與 hashtag 雜訊；同一事實只保留一次。\n2. 只做必要的語句銜接與錯字修正，不要改寫成花俏、幽默或煽動性的文風。\n3. 保留原本段落與事實順序；不新增標題、標籤、摘要或任何說明。\n4. 只輸出完成後的文章正文。\n\n原始貼文：\n${source}`
            })
        });
        const payload = await response.json().catch(() => ({}));
        if (!response.ok) throw new Error(payload.detail || "AI polishing failed");
        postWeaverOutput.value = payload.response || source;
        showToast("AI polished preview updated");
        return postWeaverOutput.value;
    } catch (error) {
        postWeaverOutput.value = "";
        showToast(error.message || "AI polishing failed");
        return "";
    }
}

async function generateWovenPostTitle(publishedContent) {
    const fallback = fallbackArticleTitle(publishedContent);
    if (!publishedContent.trim()) return fallback;
    try {
        const llm = appSettings.llm || {};
        const apiKey = await ensureLlmApiKey(llm);
        const response = await fetch("/api/local-llm/chat", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({
                provider: llm.provider,
                endpoint: llm.endpoint,
                model: llm.model,
                api_key: apiKey,
                temperature: llm.temperature,
                context_length: llm.contextLength,
                system: "",
                prompt: `找出重點給我30個字左右的標題，不該有冒號，不要給選擇直接回應。\n\n${publishedContent}`
            })
        });
        const payload = await response.json().catch(() => ({}));
        if (!response.ok) throw new Error(payload.detail || "AI title generation failed");
        const title = normalizeGeneratedTitle(payload.response);
        if (!title) throw new Error("AI title generation returned an empty title");
        showToast("AI title generated");
        return title;
    } catch (error) {
        showToast("AI title unavailable; using the article opening");
        return fallback;
    }
}

async function generateWovenPostAiTags(content, title) {
    const source = String(content || "").trim();
    if (!source) return "";
    try {
        const llm = appSettings.llm || {};
        const apiKey = await ensureLlmApiKey(llm);
        const response = await fetch("/api/local-llm/chat", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({
                provider: llm.provider,
                endpoint: llm.endpoint,
                model: llm.model,
                api_key: apiKey,
                temperature: llm.temperature,
                context_length: llm.contextLength,
                system: "你是擅長資訊整理的繁體中文知識管理助手。只輸出可直接貼進 Obsidian 的 hashtag 清單。",
                prompt: buildAiTagsPrompt(source, title)
            })
        });
        const payload = await response.json().catch(() => ({}));
        if (!response.ok) throw new Error(payload.detail || "AI tags generation failed");
        const tags = normalizeAiTags(payload.response);
        if (tags) showToast("AI tags generated");
        return tags;
    } catch (error) {
        showToast(error.message || "AI tags unavailable");
        return "";
    }
}

function localObsidianDateParts(date = new Date()) {
    const pad = value => String(value).padStart(2, "0");
    const day = `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`;
    return {
        date: day,
        datetime: `${day} ${pad(date.getHours())}:${pad(date.getMinutes())}`
    };
}

function defaultObsidianNoteTitle() {
    const date = localObsidianDateParts().date;
    const title = sanitizeObsidianTitle(capturedPostTitle || fallbackArticleTitle(combinedPostsText()));
    return `${date} ${title}`;
}

function sourceUrls() {
    // A Threads continuation is made of distinct posts. Keep every
    // canonical post URL, not only the URL initially pasted by the
    // user, before adding that post's attached image/video URLs.
    const candidates = [
        capturedPostUrl,
        ...wovenPosts.flatMap(post => [
            post.url,
            ...urlsInPostText(post.text),
            ...(Array.isArray(post.mediaUrls) ? post.mediaUrls : [])
        ])
    ];
    const seen = new Set();
    return candidates.filter(value => {
        const url = String(value || "").trim();
        if (!url || seen.has(url)) return false;
        seen.add(url);
        return true;
    });
}

function urlsInPostText(text = "") {
    return (String(text).match(/https?:\/\/\S+/gi) || [])
        .map(url => url.replace(/[\])}>，。！？；：、】【、.,;:!?]+$/g, ""))
        .filter(Boolean);
}

function legacyYamlSourceList(urls) {
    return urls.map(url => `  - "${url.replace(/\\\\/g, "\\\\\\\\").replace(/"/g, '\\\\"')}"`).join("\n");
}

function yamlSourceList(urls) {
    return urls.map(url => {
        const escaped = String(url).split("\\").join("\\\\").split('"').join('\\"');
        return '  - "' + escaped + '"';
    }).join("\n");
}

function sourceDomainTags(urls) {
    const tags = new Set();
    urls.forEach(value => {
        try {
            const url = new URL(String(value || "").trim());
            if (!/^https?:$/.test(url.protocol) || !url.hostname) return;
            const hostname = url.hostname.toLowerCase().replace(/^www\./, "");
            const serviceName = hostname.split(".")[0];
            if (serviceName) tags.add(serviceName);
        } catch {
            // Local files and non-URL sources do not need a domain tag.
        }
    });
    return [...tags];
}

function yamlTagList(tags) {
    return tags.map(tag => `  - ${tag}`).join("\n");
}

function renderObsidianTags(tags) {
    return tags.map(tag => `<i class="obsidian-tag">${escapeHtml(tag)}</i>`).join("");
}

function buildAiTagsPrompt(content, title) {
    return `請根據以下文章產生 5 到 8 組 Obsidian hashtag。

要求：
1. 每一組包含一個繁體中文 hashtag 與一個對應英文 hashtag。
2. 英文若有常見縮寫，請優先使用縮寫，例如 AI、LLM、API、GPU、CPU、SaaS。
3. hashtag 不要有空格、標點或解釋文字。
4. 每行只輸出一組，格式固定為：#中文標籤 #EnglishTag
5. 不要輸出編號、前言、結語、Markdown code block。

標題：${title || "未命名"}

文章：
${content}`;
}

function normalizeAiTags(text = "") {
    return String(text)
        .replace(/```[\s\S]*?```/g, block => block.replace(/```[a-zA-Z]*\n?/g, "").replace(/```/g, ""))
        .split(/\r?\n/)
        .map(line => line.replace(/^\s*(?:[-*]|\d+[.)])\s*/, "").trim())
        .filter(Boolean)
        .filter(line => line.includes("#"))
        .slice(0, 8)
        .join("\n");
}

function renderObsidianPropertiesTable(rows) {
    return `
        <table class="obsidian-properties-table">
            <tbody>
                ${rows.map(([label, value]) => `
                    <tr>
                        <th scope="row">${escapeHtml(label)}</th>
                        <td>${value}</td>
                    </tr>
                `).join("")}
            </tbody>
        </table>
    `;
}

function renderObsidianMarkdownPreview(text) {
    return String(text || "").replace(/\r\n?/g, "\n").split("\n").map(line => {
        if (!line.trim()) return `<div class="obsidian-preview-spacer"></div>`;
        const heading = /^(#{1,6})\s+(.+)$/.exec(line);
        if (heading) {
            const level = Math.min(heading[1].length, 6);
            return `<h${level}>${escapeHtml(heading[2])}</h${level}>`;
        }
        return `<p>${escapeHtml(line)}</p>`;
    }).join("");
}

function buildObsidianNote() {
    const content = combinedPostsText();
    if (!content) return null;
    const dateParts = localObsidianDateParts();
    const originalUrl = capturedPostUrl;
    const sources = sourceUrls();
    const polishedContent = postWeaverOutput.value.trim();
    const tags = [dateParts.date, "airtype", ...sourceDomainTags(sources)];
    const articleTitle = sanitizeObsidianTitle(
        capturedPostTitle || fallbackArticleTitle(polishedContent || content)
    ) || "TITLE";
    const values = {
        original_url: originalUrl,
        sources: yamlSourceList(sources),
        DATETIME: dateParts.datetime,
        DATE: dateParts.date,
        tags: yamlTagList(tags),
        TITLE: articleTitle,
        ai_tags: wovenAiTags,
        polished_content: polishedContent,
        content
    };
    const note = OBSIDIAN_POST_TEMPLATE.replace(/{{(sources|DATETIME|DATE|TITLE|tags|ai_tags|polished_content|content)}}/g, (_, key) => values[key]);
    return {
        articleTitle,
        content,
        dateParts,
        note,
        noteTitle: defaultObsidianNoteTitle(),
        originalUrl,
        sources,
        tags,
        aiTags: wovenAiTags,
        polishedContent
    };
}

function renderObsidianPreview() {
    const draft = buildObsidianNote();
    if (!draft) {
        postWeaverObsidianPreview.className = "obsidian-note-preview empty";
        postWeaverObsidianPreview.textContent = "Capture a public post to preview the note.";
        return;
    }
    const source = draft.sources.length ? draft.sources.join("\n") : "—";
    const polished = draft.polishedContent || "AI publishing was unavailable for this capture.";
    postWeaverObsidianPreview.className = "obsidian-note-preview";
    postWeaverObsidianPreview.innerHTML = `
        ${renderObsidianMarkdownPreview(`\n\n# ${draft.noteTitle}`)}
        <section class="obsidian-properties" aria-label="Obsidian properties">
            <h1>Properties</h1>
            ${renderObsidianPropertiesTable([
                ["title", escapeHtml(`${draft.dateParts.date} ${draft.articleTitle}`)],
                ["sources", escapeHtml(source)],
                ["datetime", escapeHtml(draft.dateParts.datetime)],
                ["tags", renderObsidianTags(draft.tags)]
            ])}
        </section>
        <section class="obsidian-preview-section"><h1>Title</h1><div class="obsidian-preview-content">${renderObsidianMarkdownPreview(draft.articleTitle)}</div></section>
        <section class="obsidian-preview-section"><h1>Notes</h1><div class="obsidian-preview-content">${renderObsidianMarkdownPreview("\n\n\n")}</div></section>
        <section class="obsidian-preview-section"><h1>AI Tags</h1><div class="obsidian-preview-content">${renderObsidianMarkdownPreview(draft.aiTags || "AI tags are not available yet.")}</div></section>
        <section class="obsidian-preview-section"><h1>AI Polished Article</h1><div class="obsidian-preview-content">${renderObsidianMarkdownPreview(polished)}</div></section>
        <section class="obsidian-preview-section"><h1>Original Content</h1><div class="obsidian-preview-content">${renderObsidianMarkdownPreview(draft.content)}</div></section>
    `;
}

function saveWovenPostsToObsidian() {
    const draft = buildObsidianNote();
    if (!draft) {
        showToast("Capture a post before saving");
        return;
    }
    const query = [
        ["name", draft.noteTitle],
        ["content", draft.note]
    ].map(([key, value]) => `${key}=${encodeURIComponent(value)}`).join("&");

    window.location.href = `obsidian://new?${query}`;
    showToast("Opening Obsidian to create the note");
}

function transcriptObsidianSources() {
    const source = sourceUrlFromRecord(currentTranscriptRecord) || sourceUrl.value.trim();
    return source ? [source] : [];
}

function buildTranscriptObsidianNote() {
    const content = transcriptObsidianOriginalText();
    if (!content || !currentTranscriptRecord) return null;
    const dateParts = localObsidianDateParts();
    const title = sanitizeObsidianTitle(
        currentTranscriptRecord?.title || currentTranscriptRecord?.source?.name || transcriptTitle.textContent || fileName.textContent
    ) || "Untitled transcript";
    const sources = transcriptObsidianSources();
    const tags = [dateParts.date, "airtype", "speech-to-text", ...sourceDomainTags(sources)];
    const values = {
        sources: yamlSourceList(sources),
        DATETIME: dateParts.datetime,
        DATE: dateParts.date,
        tags: yamlTagList(tags),
        TITLE: title,
        ai_tags: "",
        polished_content: currentArticleText.trim(),
        content
    };
    const note = OBSIDIAN_TRANSCRIPT_TEMPLATE.replace(/{{(sources|DATETIME|DATE|TITLE|tags|ai_tags|polished_content|content)}}/g, (_, key) => values[key]);
    return {
        title,
        content,
        dateParts,
        note,
        noteTitle: `${dateParts.date} ${title}`,
        polishedContent: currentArticleText.trim(),
        sources,
        tags
    };
}

function renderTranscriptObsidianPreview() {
    const draft = buildTranscriptObsidianNote();
    saveTranscriptToObsidianButton.disabled = !draft;
    if (!draft) {
        transcriptObsidianPreview.className = "obsidian-note-preview empty";
        transcriptObsidianPreview.textContent = "Complete or select a transcript to preview the note.";
        return;
    }
    const source = draft.sources.length ? draft.sources.join("\n") : "—";
    const polished = draft.polishedContent || "AI article is not available for this transcript.";
    transcriptObsidianPreview.className = "obsidian-note-preview";
    transcriptObsidianPreview.innerHTML = `
        ${renderObsidianMarkdownPreview(`\n\n# ${draft.noteTitle}`)}
        <section class="obsidian-properties" aria-label="Obsidian properties">
            <h1>Properties</h1>
            ${renderObsidianPropertiesTable([
                ["title", escapeHtml(draft.noteTitle)],
                ["sources", escapeHtml(source)],
                ["datetime", escapeHtml(draft.dateParts.datetime)],
                ["tags", renderObsidianTags(draft.tags)]
            ])}
        </section>
        <section class="obsidian-preview-section"><h1>Title</h1><div class="obsidian-preview-content">${renderObsidianMarkdownPreview(draft.title)}</div></section>
        <section class="obsidian-preview-section"><h1>Notes</h1><div class="obsidian-preview-content">${renderObsidianMarkdownPreview("\n\n\n")}</div></section>
        <section class="obsidian-preview-section"><h1>AI Tags</h1><div class="obsidian-preview-content">${renderObsidianMarkdownPreview("AI tags are not available yet.")}</div></section>
        <section class="obsidian-preview-section"><h1>AI Polished Article</h1><div class="obsidian-preview-content">${renderObsidianMarkdownPreview(polished)}</div></section>
        <section class="obsidian-preview-section"><h1>Original Transcript</h1><div class="obsidian-preview-content">${renderObsidianMarkdownPreview(draft.content)}</div></section>
    `;
}

function saveTranscriptToObsidian() {
    const draft = buildTranscriptObsidianNote();
    if (!draft) {
        showToast("Complete or select a transcript before saving");
        return;
    }
    const query = [
        ["name", draft.noteTitle],
        ["content", draft.note]
    ].map(([key, value]) => `${key}=${encodeURIComponent(value)}`).join("&");
    window.location.href = `obsidian://new?${query}`;
    showToast("Opening Obsidian to create the note");
}

function appendWhisperSettings(form) {
    const endpoint = activeWhisperEndpoint();
    form.append("whisper_endpoint", endpoint);
    const whisper = appSettings.whisper || {};
    if (whisper.language) {
        form.append("language", whisper.language);
    }
}

function showPage(page) {
    const isSettings = page === "settings";
    const isIme = page === "ime";
    const isPostWeaver = page === "post-weaver";
    transcriptPage.classList.toggle("view-hidden", isSettings || isIme || isPostWeaver);
    transcriptActionbar.classList.toggle("view-hidden", isSettings || isIme || isPostWeaver);
    transcriptWavebar.classList.toggle("view-hidden", isSettings || isIme || isPostWeaver);
    imePage.classList.toggle("view-hidden", !isIme);
    postWeaverPage.classList.toggle("view-hidden", !isPostWeaver);
    settingsPage.classList.toggle("view-hidden", !isSettings);
    settingsNav.classList.toggle("active", isSettings);
    document.querySelectorAll(".nav-item[data-panel]").forEach(node => {
        node.classList.toggle("active", !isSettings && node.dataset.panel === page);
    });
    if (isIme) {
        loadImeRecords();
    }
    if (isPostWeaver) {
        renderWovenPosts();
    }
    if (isSettings) {
        loadServerSettings({ force: true });
    }
}

function setSourceInfo(name, size, type, source) {
    fileName.textContent = name || "No title selected";
    if (arguments.length >= 4) {
        fileSource.textContent = source || "--";
    }
    fileSize.textContent = typeof size === "number" ? formatBytes(size) : "--";
    fileType.textContent = type || "--";
}

function sourceUrlFromRecord(record) {
    const metadata = record?.source?.metadata || {};
    return record?.source?.url ||
        record?.request?.url ||
        metadata.webpage_url ||
        metadata.url ||
        metadata.original_url ||
        metadata.resolved_url ||
        "";
}

function formatJobStage(status, message) {
    const normalized = (status || "").toLowerCase();
    if (/waiting/i.test(message || "")) return "Waiting";
    if (normalized === "downloading") return "Downloading";
    if (normalized === "running" && /article/i.test(message || "")) return "WriteArticle";
    if (normalized === "running") return "Transcribing";
    if (normalized === "queued") return "Queued";
    if (normalized === "completed") return "Completed";
    if (normalized === "failed") return "Failed";
    if (normalized === "cancelled") return "Stopped";
    return status || "--";
}

function formatDownloadStatus(details, sourceSize) {
    const downloaded = typeof details.downloaded_bytes === "number" ? details.downloaded_bytes : null;
    const total = typeof details.total_bytes === "number" ? details.total_bytes : sourceSize;
    if (downloaded !== null && typeof total === "number" && total > 0) {
        return `${formatBytes(downloaded)} / ${formatBytes(total)}`;
    }
    if (downloaded !== null) return formatBytes(downloaded);
    if (typeof total === "number" && total > 0) return formatBytes(total);
    return "--";
}

function formatCount(value) {
    return Number(value).toLocaleString("en-US");
}

function formatSegmentPosition(details, partialSegments) {
    const lastSegment = partialSegments.length ? partialSegments[partialSegments.length - 1] : null;
    const end = typeof details.last_segment_end === "number"
        ? details.last_segment_end
        : lastSegment?.end;
    if (typeof end === "number") {
        const duration = typeof details.duration === "number" ? details.duration : null;
        return duration && duration > 0
            ? `${formatSeconds(end)} / ${formatSeconds(duration)}`
            : formatSeconds(end);
    }
    return "--";
}

function formatJobProgressMessage(job) {
    const details = job.details || {};
    const partialSegments = Array.isArray(job.partial_segments) ? job.partial_segments : [];
    const segmentCount = typeof details.segment_count === "number"
        ? details.segment_count
        : partialSegments.length;
    const parts = [formatJobStage(job.status, job.message)];
    if (/requesting/i.test(job.message || "")) {
        const chars = typeof details.article_request_chars === "number" ? details.article_request_chars : null;
        parts.push(chars !== null ? `Requesting (${formatCount(chars)} chars)` : "Requesting");
    } else if (/waiting/i.test(job.message || "")) {
        parts.push("Waiting");
    }
    if (job.status === "downloading") {
        const downloaded = formatDownloadStatus(details, job.source_size);
        if (downloaded !== "--") parts.push(downloaded);
    }
    if (segmentCount) parts.push(`${segmentCount} segments`);
    const position = formatSegmentPosition(details, partialSegments);
    if (position !== "--") parts.push(position);
    return parts.filter(Boolean).join(" · ");
}

function setTranscriptTitle(title) {
    if (!transcriptTitle) return;
    transcriptTitle.textContent = title || "Transcript";
    renderTranscriptObsidianPreview();
}

function setPlayerStatus(message) {
    playerStatus.textContent = message;
}

function clearMediaPlayer() {
    if (activeMedia) activeMedia.pause();
    [mediaViewer, audioViewer].forEach(element => {
        element.hidden = true;
        element.removeAttribute("src");
        element.load();
    });
    if (mediaObjectUrl) URL.revokeObjectURL(mediaObjectUrl);
    mediaObjectUrl = null;
    activeMedia = null;
    playerEmptyState.hidden = false;
    setPlayerStatus("No media loaded");
}

function chooseMediaElement(type) {
    const mediaType = (type || "").toLowerCase();
    return mediaType.startsWith("video/") ? mediaViewer : audioViewer;
}

function setMediaSource(src, type, label = "Media ready", options = {}) {
    if (activeMedia) activeMedia.pause();
    [mediaViewer, audioViewer].forEach(element => {
        element.hidden = true;
        element.removeAttribute("src");
        element.load();
    });
    activeMedia = options.audioOnly ? audioViewer : chooseMediaElement(type);
    activeMedia.src = src;
    activeMedia.hidden = false;
    playerEmptyState.hidden = true;
    setPlayerStatus(label);
    if (activeMedia === audioViewer) {
        activeMedia.addEventListener("error", () => {
            if (!options.audioOnly || activeMedia !== audioViewer) return;
            setMediaSource(src, type, "Video ready");
        }, { once: true });
    }
    activeMedia.addEventListener("loadedmetadata", updatePlayerTimeline, { once: true });
    if (activeMedia === mediaViewer) {
        activeMedia.addEventListener("loadedmetadata", () => {
            if (mediaViewer.videoWidth || mediaViewer.videoHeight) return;
            const currentTime = mediaViewer.currentTime || 0;
            mediaViewer.hidden = true;
            mediaViewer.pause();
            mediaViewer.removeAttribute("src");
            mediaViewer.load();
            audioViewer.src = src;
            audioViewer.hidden = false;
            activeMedia = audioViewer;
            setPlayerStatus("Audio ready");
            if (currentTime) audioViewer.currentTime = currentTime;
            updatePlayerTimeline();
        }, { once: true });
    }
}

function setLocalMediaSource(blob, filename) {
    if (mediaObjectUrl) URL.revokeObjectURL(mediaObjectUrl);
    mediaObjectUrl = URL.createObjectURL(blob);
    setMediaSource(mediaObjectUrl, blob.type || filename, "Local media ready");
}

function loadRecordMedia(record) {
    const sourceType = record?.source?.type || "";
    if (!record?.job_id || record.record_type === "ime") {
        clearMediaPlayer();
        return;
    }
    setMediaSource(
        `/api/transcribe/records/${encodeURIComponent(record.job_id)}/media`,
        sourceType,
        "Audio ready",
        { audioOnly: true }
    );
}

function updatePlayerTimeline() {
    const media = activeMedia;
    if (!media) return;
    highlightSegmentForTime(media.currentTime || 0);
}

function seekToSegment(segment) {
    if (!activeMedia || !segment?.has_timestamps) return;
    const start = Number(segment.start);
    if (!Number.isFinite(start)) return;
    activeMedia.currentTime = Math.max(0, start);
    updatePlayerTimeline();
}

function highlightSegmentForTime(time) {
    if (!segments.length) return;
    const nextIndex = segments.findIndex(segment => {
        if (!segment.has_timestamps) return false;
        const start = Number(segment.start);
        const end = Number(segment.end);
        return Number.isFinite(start) && Number.isFinite(end) && time >= start && time < Math.max(end, start + 0.25);
    });
    if (nextIndex !== -1 && nextIndex !== selectedIndex) {
        selectedIndex = nextIndex;
        renderSegments();
        scrollActiveSegmentIntoView("smooth");
    }
}

function scrollActiveSegmentIntoView(behavior = "auto") {
    if (selectedIndex === lastAutoScrolledIndex) return;
    const activeRow = segmentsEl.querySelector(`[data-segment-index="${selectedIndex}"]`);
    if (!activeRow) return;
    lastAutoScrolledIndex = selectedIndex;
    const containerRect = transcriptScrollPanel.getBoundingClientRect();
    const rowRect = activeRow.getBoundingClientRect();
    const targetTop = transcriptScrollPanel.scrollTop +
        (rowRect.top - containerRect.top) -
        ((transcriptScrollPanel.clientHeight - activeRow.offsetHeight) / 2);
    transcriptScrollPanel.scrollTo({
        top: Math.max(0, targetTop),
        behavior
    });
}

function handleTranscriptPanelWheel(event) {
    if (!transcriptScrollPanel) return;
    const canScroll = transcriptScrollPanel.scrollHeight > transcriptScrollPanel.clientHeight;
    if (!canScroll) return;
    event.preventDefault();
    transcriptScrollPanel.scrollTop += event.deltaY;
}

function handleRecordListWheel(event) {
    if (!recordList) return;
    const canScroll = recordList.scrollHeight > recordList.clientHeight;
    if (!canScroll) return;
    event.preventDefault();
    recordList.scrollTop += event.deltaY;
}

function formatBytes(bytes) {
    if (!bytes) return "0 B";
    const units = ["B", "KB", "MB", "GB"];
    let value = bytes;
    let unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
        value /= 1024;
        unit += 1;
    }
    return `${value.toFixed(value >= 10 || unit === 0 ? 0 : 1)} ${units[unit]}`;
}

function renderWaveform() {
    waveform.innerHTML = "";
    const count = Math.max(120, Math.floor(waveform.clientWidth / 5));
    for (let i = 0; i < count; i += 1) {
        const bar = document.createElement("span");
        const height = 8 + Math.abs(Math.sin(i * 0.67) * 22) + (i % 7) * 2;
        bar.className = `bar${i < 4 ? " live" : ""}`;
        bar.style.height = `${Math.min(30, height)}px`;
        waveform.appendChild(bar);
    }
}

function selectedText() {
    if (segments[selectedIndex]) return segments[selectedIndex].text;
    return segments.map(segment => segment.text).join("\n");
}

function transcriptPlainText() {
    return segments
        .map(segment => (segment.text || "").trim())
        .filter(Boolean)
        .join("\n");
}

function transcriptObsidianOriginalText() {
    return segments
        .map(segment => (segment.text || "").trim().replace(/\r\n?/g, "\n"))
        .filter(Boolean)
        .map(text => `${text}\n`)
        .join("");
}

function copyTranscriptPlainText() {
    const text = transcriptPlainText();
    if (!text) {
        showToast("No transcript text to copy");
        return;
    }
    copyText(text);
}

async function copyArticleText() {
    if (!currentArticleText.trim()) {
        updateCopyArticleButtonState();
        showToast("Article is not ready yet");
        return;
    }
    await copyText(currentArticleText, "Article copied to clipboard");
}

async function copyText(text, message = "Copied to clipboard") {
    try {
        await navigator.clipboard.writeText(text);
        showToast(message);
    } catch {
        showToast("Copy unavailable in this browser");
    }
}

function exportTranscript() {
    const body = segments.map(segment => `[${segment.time}] ${segment.text}`).join("\n\n");
    const blob = new Blob([body], { type: "text/plain;charset=utf-8" });
    const url = URL.createObjectURL(blob);
    const anchor = document.createElement("a");
    anchor.href = url;
    anchor.download = "airtype-transcript.txt";
    anchor.click();
    URL.revokeObjectURL(url);
    showToast("Transcript exported");
}

function redoSegmentation() {
    segments = segments.flatMap(segment => {
        if (segment.text.length < 72) return [segment];
        const mid = Math.floor(segment.text.length / 2);
        return [
            { time: segment.time, text: segment.text.slice(0, mid) },
            { time: segment.time, text: segment.text.slice(mid) }
        ];
    });
    selectedIndex = Math.min(selectedIndex, segments.length - 1);
    renderSegments();
    showToast("Segments regenerated");
}

function fileSourceLabel(file, fallback) {
    return file?.webkitRelativePath || fallback;
}

async function transcribeBlob(blob, filename = "recording.webm", sourceLabel = "Selected from device") {
    selectedRecordId = null;
    currentTranscriptRecord = null;
    setCurrentArticleText("");
    setTranscriptTitle(filename);
    setSourceInfo(filename, blob.size, blob.type || "media", sourceLabel);
    setLocalMediaSource(blob, filename);
    const form = new FormData();
    form.append("file", blob, filename);
    appendWhisperSettings(form);

    setProgress(2, `Uploading ${filename}...`, true, true);
    showToast("Upload started");
    const job = await uploadJob(form);
    selectedRecordId = job.job_id;
    loadTranscriptRecords();
    await watchJob(job.job_id);
}

async function transcribeUrl() {
    const url = sourceUrl.value.trim();
    if (!url) {
        showToast("Paste a file URL first");
        return;
    }

    selectedRecordId = null;
    currentTranscriptRecord = null;
    setCurrentArticleText("");
    const urlTitle = url.split("/").pop() || url;
    setTranscriptTitle(urlTitle);
    setSourceInfo(urlTitle, null, "remote url", url);
    setProgress(2, "Starting URL job...", true, true);
    showToast("URL job started");
    const endpoint = activeWhisperEndpoint();
    const whisper = appSettings.whisper || {};
    const response = await fetch("/api/transcribe/url/jobs", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
            url,
            whisper_endpoint: endpoint,
            language: whisper.language || null
        })
    });

    if (!response.ok) {
        const error = await response.json().catch(() => ({}));
        throw new Error(error.detail || "URL transcription failed");
    }

    const job = await response.json();
    selectedRecordId = job.job_id;
    loadTranscriptRecords();
    if (stopRequested) {
        activeJobId = job.job_id;
        await cancelActiveJob();
        return;
    }
    await watchJob(job.job_id);
}

function uploadJob(form) {
    return new Promise((resolve, reject) => {
        const request = new XMLHttpRequest();
        request.open("POST", "/api/transcribe/jobs");
        request.upload.onprogress = event => {
            if (!event.lengthComputable) return;
            const percent = Math.round((event.loaded / event.total) * 12);
            setProgress(Math.max(2, percent), `Uploading ${Math.round((event.loaded / event.total) * 100)}%...`, true);
        };
        request.onload = () => {
            if (request.status >= 200 && request.status < 300) {
                resolve(JSON.parse(request.responseText));
            } else {
                const error = JSON.parse(request.responseText || "{}");
                reject(new Error(error.detail || "Upload failed"));
            }
        };
        request.onerror = () => reject(new Error("Upload failed"));
        request.send(form);
    });
}

async function watchJob(jobId) {
    activeJobId = jobId;
    updateTranscribeButtonState();
    let displayedJobTitle = "";
    let displayedJobSourceInfo = "";
    while (activeJobId === jobId) {
        const response = await fetch(`/api/transcribe/jobs/${jobId}`);
        if (!response.ok) {
            const error = await response.json().catch(() => ({}));
            throw new Error(error.detail || "Could not read transcription job");
        }

        const job = await response.json();
        const jobTitle = job.title || job.source_metadata?.title || job.source_metadata?.fulltitle || "";
        const jobSourceInfo = `${jobTitle}|${job.source_size ?? ""}|${job.source_type || ""}`;
        if (jobTitle && jobSourceInfo !== displayedJobSourceInfo) {
            if (jobTitle !== displayedJobTitle) {
                displayedJobTitle = jobTitle;
                setTranscriptTitle(jobTitle);
                loadTranscriptRecords();
            }
            displayedJobSourceInfo = jobSourceInfo;
            const jobSource = job.source_url || job.source_metadata?.webpage_url || job.source_metadata?.url || "";
            if (jobSource) {
                setSourceInfo(jobTitle, job.source_size, job.source_type || "remote url", jobSource);
            } else {
                setSourceInfo(jobTitle, job.source_size, job.source_type || "remote url");
            }
        }
        if (Array.isArray(job.partial_segments) && job.partial_segments.length) {
            updatePartialSegments(job.partial_segments);
        }
        const rawMessage = job.message || job.status;
        const message = formatJobProgressMessage(job) || rawMessage;
        const progress = job.progress || 0;
        const waiting =
            job.status === "queued" ||
            job.status === "downloading" ||
            rawMessage.includes("Waiting for transcription worker") ||
            /requesting|article/i.test(rawMessage);
        setProgress(
            progress,
            message,
            job.status !== "completed" && job.status !== "failed",
            waiting
        );

        if (job.status === "completed") {
            applyTranscriptResult(job.result || {});
            await loadTranscriptRecord(jobId);
            loadTranscriptRecords();
            activeJobId = null;
            setProgress(100, "Transcript ready", false);
            showToast("Transcript updated");
            return;
        }

        if (job.status === "failed") {
            activeJobId = null;
            updateTranscribeButtonState();
            loadTranscriptRecords();
            throw new Error(job.error || "Transcription failed");
        }

        if (job.status === "cancelled") {
            activeJobId = null;
            setProgress(100, "Stopped by user", false);
            loadTranscriptRecords();
            showToast("Transcription stopped");
            return;
        }

        await new Promise(resolve => setTimeout(resolve, 1000));
    }
}

function applyTranscriptResult(result) {
    renderTranscriptDebug(result.debug);
    segments = Array.isArray(result.segments) && result.segments.length
        ? result.segments.map(normalizeSegment)
        : [{
            time: "time unavailable",
            duration_text: "time unavailable",
            has_timestamps: false,
            text: result.text || "(No text returned)",
            text_length: (result.text || "(No text returned)").length
        }];
    selectedIndex = 0;
    lastAutoScrolledIndex = -1;
    renderSegments();
}

function renderTranscriptDebug(debug) {
    if (!debug) {
        transcriptDebug.hidden = true;
        transcriptDebug.innerHTML = "";
        return;
    }

    const fields = debug.request_fields || {};
    const keys = Array.isArray(debug.payload_keys) ? debug.payload_keys.join(", ") : "";
    transcriptDebug.hidden = false;
    transcriptDebug.classList.remove("expanded");
    transcriptDebug.innerHTML = `
        <button class="debug-panel-header" type="button" aria-expanded="false">
            <span class="debug-panel-title">Whisper server debug</span>
            <span class="debug-panel-icon" aria-hidden="true"></span>
        </button>
        <div class="debug-panel-body">
            <div>URL: ${escapeHtml(debug.url || "")}</div>
            <div>Request: ${escapeHtml(Object.entries(fields).map(([key, value]) => `${key}=${value}`).join(", "))}</div>
            <div>Payload keys: ${escapeHtml(keys || "(none)")}</div>
            <div>transcription: ${debug.has_transcription ? "yes" : "no"} · segments: ${debug.has_segments ? "yes" : "no"}</div>
            <div>Raw segments: ${debug.raw_segment_count ?? 0} · Final segments: ${debug.final_segment_count ?? 0} · Text length: ${debug.text_length ?? "unknown"}</div>
            ${debug.fallback ? `<div>Fallback: ${escapeHtml(debug.fallback)}</div>` : ""}
        </div>
    `;
    const toggleButton = transcriptDebug.querySelector(".debug-panel-header");
    toggleButton.addEventListener("click", () => {
        const expanded = transcriptDebug.classList.toggle("expanded");
        toggleButton.setAttribute("aria-expanded", String(expanded));
    });
}

function normalizeSegment(segment, index) {
    const hasTimestamps = segment.has_timestamps !== false && segment.start !== null && segment.end !== null;
    const text = segment.text || "";
    return {
        ...segment,
        id: segment.id ?? index,
        time: segment.time || (hasTimestamps ? `${formatSeconds(segment.start || 0)} -> ${formatSeconds(segment.end || 0)}` : "time unavailable"),
        duration_text: segment.duration_text || (hasTimestamps ? `${Math.max(0, Number(segment.end || 0) - Number(segment.start || 0)).toFixed(1)}s` : "time unavailable"),
        has_timestamps: hasTimestamps,
        text,
        text_length: typeof segment.text_length === "number" ? segment.text_length : text.length
    };
}

function updatePartialSegments(partialSegments) {
    const nextSegments = partialSegments.map(normalizeSegment);
    if (nextSegments.length !== segments.length) {
        segments = nextSegments;
        selectedIndex = Math.max(0, Math.min(selectedIndex, segments.length - 1));
        lastAutoScrolledIndex = -1;
        renderSegments();
    }
}

function formatSeconds(value) {
    const total = Math.max(0, Math.floor(Number(value) || 0));
    const hours = String(Math.floor(total / 3600)).padStart(2, "0");
    const minutes = String(Math.floor((total % 3600) / 60)).padStart(2, "0");
    const seconds = String(total % 60).padStart(2, "0");
    return `${hours}:${minutes}:${seconds}`;
}

async function toggleRecording() {
    if (recorder && recorder.state === "recording") {
        recorder.stop();
        clearInterval(timer);
        recordButton.classList.remove("recording");
        return;
    }

    try {
        const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
        chunks = [];
        recorder = new MediaRecorder(stream);
        recorder.ondataavailable = event => {
            if (event.data.size > 0) chunks.push(event.data);
        };
        recorder.onstop = async () => {
            stream.getTracks().forEach(track => track.stop());
            micToggle.checked = false;
            if (discardCurrentRecording) {
                discardCurrentRecording = false;
                chunks = [];
                currentTime.textContent = "00:00";
                return;
            }
            try {
                await transcribeBlob(new Blob(chunks, { type: "audio/webm" }), "recording.webm", "Recorded audio");
            } catch (error) {
                showToast(error.message);
            }
        };
        recorder.start();
        micToggle.checked = true;
        seconds = 0;
        timer = setInterval(() => {
            seconds += 1;
            const mm = String(Math.floor(seconds / 60)).padStart(2, "0");
            const ss = String(seconds % 60).padStart(2, "0");
            currentTime.textContent = `${mm}:${ss}`;
        }, 1000);
        showToast("Recording started");
    } catch {
        showToast("Microphone permission denied");
    }
}

function cancelRecording() {
    if (!recorder || recorder.state !== "recording") return false;
    discardCurrentRecording = true;
    recorder.stop();
    clearInterval(timer);
    recordButton.classList.remove("recording");
    micToggle.checked = false;
    showToast("Recording discarded");
    return true;
}

audioFile.addEventListener("change", async () => {
    const file = audioFile.files[0];
    if (!file) return;
    try {
        await transcribeBlob(file, file.name, fileSourceLabel(file, "Selected from device"));
    } catch (error) {
        showToast(error.message);
        setProgress(0, error.message, false);
    } finally {
        audioFile.value = "";
    }
});

function handleDragOver(event) {
    event.preventDefault();
    event.stopPropagation();
    dropZone.classList.add("dragging");
}

function handleDragLeave(event) {
    event.stopPropagation();
    dropZone.classList.remove("dragging");
}

async function handleDrop(event) {
    event.preventDefault();
    event.stopPropagation();
    dropZone.classList.remove("dragging");
    if (dropInProgress) return;
    const file = event.dataTransfer.files[0];
    if (!file) return;
    dropInProgress = true;
    try {
        await transcribeBlob(file, file.name, fileSourceLabel(file, "Dropped from device"));
    } catch (error) {
        showToast(error.message);
        setProgress(0, error.message, false);
    } finally {
        dropInProgress = false;
    }
}

dropZone.addEventListener("dragover", handleDragOver);
dropZone.addEventListener("dragleave", handleDragLeave);
dropZone.addEventListener("drop", handleDrop);
transcriptPage.addEventListener("dragover", handleDragOver);
transcriptPage.addEventListener("drop", handleDrop);

document.getElementById("copyButton").addEventListener("click", () => copyText(selectedText()));
document.getElementById("copyTranscriptTextButton").addEventListener("click", copyTranscriptPlainText);
copyArticleButton.addEventListener("click", copyArticleText);
document.getElementById("cutButton").addEventListener("click", () => {
    if (segments.length === 0) return;
    const removed = segments.splice(selectedIndex, 1);
    selectedIndex = Math.max(0, Math.min(selectedIndex, segments.length - 1));
    renderSegments();
    showToast(`Cut ${removed.length} segment`);
});
document.getElementById("exportButton").addEventListener("click", exportTranscript);
document.getElementById("redoButton").addEventListener("click", redoSegmentation);
document.getElementById("playButton").addEventListener("click", () => showToast("Playback preview"));
[mediaViewer, audioViewer].forEach(element => {
    element.addEventListener("timeupdate", updatePlayerTimeline);
    element.addEventListener("durationchange", updatePlayerTimeline);
    element.addEventListener("loadedmetadata", updatePlayerTimeline);
    element.addEventListener("play", () => setPlayerStatus(element === mediaViewer ? "Video playing" : "Audio playing"));
    element.addEventListener("pause", () => setPlayerStatus(element.currentTime > 0 ? "Paused" : "Media ready"));
});
transcriptScrollPanel.addEventListener("wheel", handleTranscriptPanelWheel, { passive: false });
recordList.addEventListener("wheel", handleRecordListWheel, { passive: false });
historySearchInput.addEventListener("input", renderTranscriptRecords);
async function cancelActiveJob() {
    stopRequested = true;
    if (!activeJobId) {
        setProgress(0, "Stop requested...", true, true);
        return;
    }
    const jobId = activeJobId;
    setProgress(100, "Stopping...", true, true);
    try {
        await fetch(`/api/transcribe/jobs/${jobId}/cancel`, { method: "POST" });
    } catch {
        showToast("Could not stop job");
    } finally {
        activeJobId = null;
        transcribePending = false;
        stopRequested = false;
        setProgress(100, "Stopped by user", false);
    }
}

transcribeUrlButton.addEventListener("click", async () => {
    try {
        if (activeJobId || transcribePending) {
            await cancelActiveJob();
            return;
        }
        transcribePending = true;
        stopRequested = false;
        updateTranscribeButtonState();
        await transcribeUrl();
    } catch (error) {
        showToast(error.message);
        setProgress(0, error.message, false);
    } finally {
        if (!activeJobId) {
            transcribePending = false;
            stopRequested = false;
            updateTranscribeButtonState();
        }
    }
});
document.querySelectorAll("#settingsPage input:not([readonly]), #settingsPage select, #settingsPage textarea").forEach(control => {
    control.addEventListener("input", updateSaveSettingsButtonState);
    control.addEventListener("change", updateSaveSettingsButtonState);
});
document.getElementById("resetSettingsButton").addEventListener("click", () => {
    saveSettings(defaultSettings, { persist: false, markWhisperClean: true });
    updateSaveSettingsButtonState();
    showToast("Settings reset locally");
});
document.getElementById("saveSettingsButton").addEventListener("click", saveSettingsFromForm);
document.getElementById("addLlmServerButton").addEventListener("click", addLlmServer);
document.getElementById("deleteLlmServerButton").addEventListener("click", deleteLlmServer);
const setLlmApiKeyButton = document.getElementById("setLlmApiKeyButton");
if (setLlmApiKeyButton) {
    setLlmApiKeyButton.addEventListener("click", async () => {
        saveSettings(readSettingsFromForm(), { persist: false });
        const apiKey = await openLlmApiKeyDialog(appSettings.llm || {}, "Enter an API key for this LLM endpoint.");
        if (apiKey) {
            document.getElementById("settingLlmApiKey").value = apiKey;
            await saveSettingsFromForm();
        }
    });
}
document.getElementById("loadLlmModelsButton").addEventListener("click", loadLocalModels);
document.getElementById("sendLlmPromptButton").addEventListener("click", sendLocalPrompt);
document.getElementById("testWhisperServerButton").addEventListener("click", testWhisperServer);
document.getElementById("restartWhisperServerButton").addEventListener("click", restartWhisperServer);
llmModelSelect.addEventListener("change", () => {
    if (llmModelSelect.value) {
        applySelectedModelMetadata();
        saveSettings(readSettingsFromForm(), { persist: false });
        persistSettingsToServer(readSettingsFromForm());
    }
});
document.getElementById("settingLlmName").addEventListener("change", event => {
    const selectedName = event.target.value;
    const selectedServer = (appSettings.llm_servers || []).find(server => server.name === selectedName);
    if (!selectedServer) return;
    localModels = [];
    saveSettings({
        ...appSettings,
        llm: selectedServer,
        default_llm_server_name: selectedName
    }, { persist: false });
    persistSettingsToServer(readSettingsFromForm());
    updateContextLengthHint();
});
recordContextMenu.addEventListener("click", async event => {
    const action = event.target?.dataset?.action;
    const record = contextRecord;
    const recordType = contextRecordType;
    hideRecordContextMenu();
    if (!action || !record) return;
    try {
        if (action === "rename") {
            openRenameDialog(record, recordType);
        } else if (action === "delete") {
            await deleteRecord(record, recordType);
        }
    } catch (error) {
        showToast(error.message);
    }
});
document.addEventListener("pointerdown", event => {
    if (shouldHideRecordContextMenu(event)) {
        hideRecordContextMenu();
    }
});
document.addEventListener("keydown", event => {
    if (event.key === "Escape") {
        if (cancelRecording()) {
            event.preventDefault();
            return;
        }
        hideRecordContextMenu();
        closeRenameDialog();
        closeLlmApiKeyDialog("");
    }
});
document.addEventListener("scroll", hideRecordContextMenu, true);
renameForm.addEventListener("submit", async event => {
    event.preventDefault();
    try {
        await submitRenameDialog();
    } catch (error) {
        showToast(error.message);
    }
});
cancelRenameButton.addEventListener("click", closeRenameDialog);
renameDialog.addEventListener("pointerdown", event => {
    if (event.target === renameDialog) {
        closeRenameDialog();
    }
});
llmApiKeyForm.addEventListener("submit", event => {
    event.preventDefault();
    const apiKey = llmApiKeyInput.value.trim();
    if (!apiKey) {
        showToast("API key cannot be empty");
        return;
    }
    const slot = pendingLlmApiKeyDialog?.slot || llmApiKeySlot(appSettings.llm || {});
    llmSessionApiKeys = { ...llmSessionApiKeys, [slot]: apiKey };
    const configInput = document.getElementById("settingLlmApiKey");
    if (configInput) {
        configInput.value = apiKey;
    }
    updateLlmApiKeyStatus();
    closeLlmApiKeyDialog(apiKey);
    showToast("API key ready");
});
cancelLlmApiKeyButton.addEventListener("click", () => closeLlmApiKeyDialog(""));
llmApiKeyDialog.addEventListener("pointerdown", event => {
    if (event.target === llmApiKeyDialog) {
        closeLlmApiKeyDialog("");
    }
});
settingsNav.addEventListener("click", () => {
    applySettingsToForm();
    showPage("settings");
});
recordButton.addEventListener("click", toggleRecording);

document.querySelectorAll(".nav-item[data-panel]").forEach(item => {
    item.addEventListener("click", () => {
        showPage(item.dataset.panel);
        showToast(`${item.dataset.panel} selected`);
    });
});
document.getElementById("capturePostButton").addEventListener("click", captureWovenPost);
document.getElementById("savePostsToObsidianButton").addEventListener("click", event => {
    event.preventDefault();
    event.stopPropagation();
    saveWovenPostsToObsidian();
});
saveTranscriptToObsidianButton.addEventListener("click", event => {
    event.preventDefault();
    event.stopPropagation();
    saveTranscriptToObsidian();
});

async function initializeApp() {
    await loadServerSettings({ force: true });
    applySettingsToForm();
    if (new URLSearchParams(window.location.search).get("demo") === "1") {
        segments = [...seedSegments];
        selectedIndex = 1;
    }
    showPage("transcript");
    renderSegments();
    renderObsidianPreview();
    renderTranscriptObsidianPreview();
    loadTranscriptRecords();
    pollServiceHealth();
    setInterval(pollServiceHealth, 5000);
    renderWaveform();
    window.addEventListener("resize", renderWaveform);
}

initializeApp();
