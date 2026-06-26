export type AppSettings = {
  whisper?: {
    language?: string;
    remote_endpoint?: string;
  };
  llm?: {
    provider?: string;
    endpoint?: string;
    api_key?: string;
    model?: string;
    selected_model?: string;
    temperature?: number;
    contextLength?: number;
    system?: string;
  };
};
