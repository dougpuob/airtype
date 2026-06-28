import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { apiRequest } from "./client";

export type AuthStatus = {
  enabled: boolean;
  authenticated: boolean;
  username?: string;
  session_days?: number;
};

export function useAuthStatusQuery() {
  return useQuery({
    queryKey: ["auth-status"],
    queryFn: () => apiRequest<AuthStatus>("/api/auth/status"),
    retry: false,
    staleTime: 30_000
  });
}

export function useLoginMutation() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: (credentials: { username: string; password: string }) =>
      apiRequest<AuthStatus>("/api/auth/login", {
        method: "POST",
        body: JSON.stringify(credentials)
      }),
    onSuccess: (status) => {
      queryClient.setQueryData(["auth-status"], status);
      queryClient.invalidateQueries({ queryKey: ["settings"] });
    }
  });
}

export function useLogoutMutation() {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: () => apiRequest<AuthStatus>("/api/auth/logout", { method: "POST" }),
    onSuccess: (status) => {
      queryClient.clear();
      queryClient.setQueryData(["auth-status"], status);
    }
  });
}
