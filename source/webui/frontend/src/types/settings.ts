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
    thinking_steps?: Array<"polish" | "title" | "tags">;
    tags_thinking_level?: ThinkingLevel;
  };
  ime?: {
    correction_enabled?: boolean;
  };
  llm_servers?: AppSettings["llm"][];
  default_llm_server_name?: string;
  ai_routes?: AiRoute[];
  ai_steps?: AiSteps;
};

export type AiStep = "correct" | "polish" | "title" | "tags";
export type AiRouteType =
  | "openai-compat"
  | "grok-cli"
  | "grok-api"
  | "chatgpt"
  | "chatgpt-codex"
  | "claude-code"
  | "gemini";

/** Routes that run through a local CLI with its own login. */
export const CLI_ROUTE_TYPES: AiRouteType[] = ["grok-cli", "chatgpt-codex", "claude-code"];
/** Routes that call an OpenAI-compatible cloud API with an API key. */
export const API_ROUTE_TYPES: AiRouteType[] = ["grok-api", "chatgpt", "gemini"];
export type AiSteps = Partial<Record<AiStep, string>>;

/** One named way to reach a text model. openai-compat routes are the local llm-server entries. */
export type AiRoute = NonNullable<AppSettings["llm"]> & {
  name: string;
  type: AiRouteType;
  // CLI routes (grok-cli, chatgpt-codex, claude-code)
  bin?: string;
  reasoning_effort?: string;
  timeout_seconds?: number;
  correct_timeout_seconds?: number;
  typo_concurrency?: number;
};

export const AI_STEPS: AiStep[] = ["correct", "polish", "title", "tags"];

export function isCloudRoute(route?: Pick<AiRoute, "type"> | null) {
  return Boolean(route?.type) && route?.type !== "openai-compat";
}

/** Which kinds of route the AI steps use: "local", "cloud", or "mixed". */
export function aiRouteMode(settings?: AppSettings): "local" | "cloud" | "mixed" {
  const routes = settings?.ai_routes || [];
  const kinds = new Set(
    AI_STEPS.map((step) => {
      const name = settings?.ai_steps?.[step] || "";
      return isCloudRoute(routes.find((route) => route.name === name)) ? "cloud" : "local";
    })
  );
  if (kinds.size > 1) return "mixed";
  return kinds.has("cloud") ? "cloud" : "local";
}

/** Shared thinking level; each AI route maps it to its own request params. */
export type ThinkingLevel = "off" | "low" | "mid" | "high";
