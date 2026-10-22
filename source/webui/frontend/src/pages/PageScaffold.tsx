import { Box, Paper, Stack, Typography } from "@mui/material";
import type { PropsWithChildren, ReactNode } from "react";

type PageScaffoldProps = PropsWithChildren<{
  title?: string;
  eyebrow?: string;
  actions?: ReactNode;
  fill?: boolean;
}>;

export function PageScaffold({ title, eyebrow, actions, children, fill }: PageScaffoldProps) {
  return (
    <Stack
      spacing={2.5}
      sx={{
        minHeight: "100%",
        flexShrink: fill ? 1 : 0,
        ...(fill
          ? {
              flex: 1,
              height: "100%",
              minHeight: 0
            }
          : {})
      }}
    >
      {title || eyebrow || actions ? (
        <Stack direction="row" alignItems="flex-end" justifyContent="space-between" spacing={2}>
          <Box>
            {eyebrow ? (
              <Typography
                variant="overline"
                sx={{ color: "text.secondary", fontWeight: 700, letterSpacing: 0.4 }}
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

export function WorkspacePanel({ children, fill }: PropsWithChildren<{ fill?: boolean }>) {
  return (
    <Paper
      sx={{
        p: 2,
        minWidth: 0,
        minHeight: 0,
        ...(fill
          ? {
              flex: 1,
              display: "flex",
              flexDirection: "column",
              overflow: "hidden"
            }
          : {})
      }}
    >
      {children}
    </Paper>
  );
}
