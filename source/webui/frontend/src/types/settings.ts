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
  };
  ytdlp?: {
    cookies?: string;
    cookies_from_browser?: string;
  };
  auth?: {
    enabled?: boolean;
    username?: string;
    password?: string;
  };
  llm_servers?: AppSettings["llm"][];
  default_llm_server_name?: string;
};
