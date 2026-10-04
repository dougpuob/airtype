export type AppSettings = {
  whisper?: {
    language?: string;
    remote_endpoint?: string;
    model_dir?: string;
    model_filename?: string;
    server_bin?: string;
    server_args?: string;
    beam?: number;
    temperature?: number;
  };
  llm?: {
    name?: string;
    provider?: string;
    endpoint?: string;
    api_key?: string;
    model?: string;
    models?: string[];
    selected_model?: string;
    temperature?: number;
    contextLength?: number;
    system?: string;
    disable_thinking?: boolean;
  };
  ytdlp?: {
    cookies?: string;
    cookies_from_browser?: string;
  };
  web_to_markdown?: {
    api_key?: string;
    timeout_seconds?: number;
    download_max_mb?: number;
  };
  immich?: {
    server_url?: string;
    api_key?: string;
    create_album?: boolean;
  };
  auth?: {
    enabled?: boolean;
    username?: string;
    password?: string;
    password_configured?: boolean;
    session_days?: number;
  };
  obsidian?: {
    vault_name?: string;
    default_folder?: string;
  };
  capture_post?: {
    ai_title_enabled?: boolean;
    title_system_prompt?: string;
  };
  ime?: {
    correction_enabled?: boolean;
  };
  llm_servers?: AppSettings["llm"][];
  default_llm_server_name?: string;
};
