import { apiRequest } from "./client";

export type ThreadsLoginStatus = {
  running: boolean;
  url: string;
  storage_state_exists: boolean;
  cookie_count: number;
};

export type ThreadsLoginScreenshot = ThreadsLoginStatus & {
  image: string;
  width: number;
  height: number;
};

export function getThreadsLoginStatus() {
  return apiRequest<ThreadsLoginStatus>("/api/threads-login/status");
}

export function startThreadsLogin() {
  return apiRequest<ThreadsLoginStatus>("/api/threads-login/start", { method: "POST" });
}

export function getThreadsLoginScreenshot() {
  return apiRequest<ThreadsLoginScreenshot>("/api/threads-login/screenshot");
}

export function clickThreadsLogin(x: number, y: number) {
  return apiRequest<ThreadsLoginStatus>("/api/threads-login/click", {
    method: "POST",
    body: JSON.stringify({ x, y })
  });
}

export function typeThreadsLogin(text: string) {
  return apiRequest<ThreadsLoginStatus>("/api/threads-login/type", {
    method: "POST",
    body: JSON.stringify({ text })
  });
}

export function pressThreadsLoginKey(key: string) {
  return apiRequest<ThreadsLoginStatus>("/api/threads-login/key", {
    method: "POST",
    body: JSON.stringify({ key })
  });
}

export function saveThreadsLogin() {
  return apiRequest<ThreadsLoginStatus>("/api/threads-login/save", { method: "POST" });
}

export function stopThreadsLogin() {
  return apiRequest<ThreadsLoginStatus>("/api/threads-login/stop", { method: "POST" });
}
