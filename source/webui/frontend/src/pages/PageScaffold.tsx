import { Box, Paper, Stack, Typography } from "@mui/material";
import type { PropsWithChildren, ReactNode } from "react";

type PageScaffoldProps = PropsWithChildren<{
  title?: string;
  eyebrow?: string;
  actions?: ReactNode;
}>;

export function PageScaffold({ title, eyebrow, actions, children }: PageScaffoldProps) {
  return (
    <Stack spacing={2.5} sx={{ minHeight: "100%" }}>
      {title || eyebrow || actions ? (
        <Stack direction="row" alignItems="flex-end" justifyContent="space-between" spacing={2}>
          <Box>
            {eyebrow ? (
              <Typography
                variant="overline"
                sx={{ color: "text.secondary", fontWeight: 800, letterSpacing: 0.4 }}
              >
                {eyebrow}
              </Typography>
            ) : null}
            {title ? <Typography variant="h1">{title}</Typography> : null}
          </Box>
          {actions}
        </Stack>
      ) : null}
      {children}
    </Stack>
  );
}

export function WorkspacePanel({ children }: PropsWithChildren) {
  return (
    <Paper
      sx={{
        p: 2,
        minWidth: 0,
        minHeight: 0
      }}
    >
      {children}
    </Paper>
  );
}
