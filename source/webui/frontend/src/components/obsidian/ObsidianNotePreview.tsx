import { Box, Paper, Stack, Table, TableBody, TableCell, TableRow, Typography } from "@mui/material";
import type { ReactNode } from "react";

type ObsidianPreviewDraft = {
  noteTitle: string;
  content: string;
  polishedContent: string;
  aiTags: string;
  sources: string[];
  tags: string[];
  datetime: string;
};

type ObsidianNotePreviewProps = {
  draft: ObsidianPreviewDraft | null;
  emptyMessage: string;
  polishedFallback: string;
  originalTitle: string;
};

const previewSectionHeadingSx = {
  color: "#C8D2FF",
  fontSize: 24,
  fontWeight: 850,
  lineHeight: 1.25,
  mb: 1.25
};

const propertyCellSx = {
  borderColor: "#343A4A",
  color: "#F1F4FA",
  fontSize: 13,
  lineHeight: 1.5,
  py: 0.75
};

export function ObsidianNotePreview({ draft, emptyMessage, polishedFallback, originalTitle }: ObsidianNotePreviewProps) {
  if (!draft) {
    return (
      <Stack alignItems="center" justifyContent="center" sx={{ minHeight: 520, color: "text.secondary" }}>
        <Typography>{emptyMessage}</Typography>
      </Stack>
    );
  }

  return (
    <Paper
      sx={{
        p: 2,
        bgcolor: "#1F2330",
        color: "#F1F4FA",
        borderColor: "#343A4A",
        minHeight: 520,
        maxHeight: 720,
        overflow: "auto"
      }}
    >
      <Stack spacing={2.25}>
        <MarkdownPreviewText text={`\n\n# ${draft.noteTitle}`} />
        <PreviewSection title="Properties">
          <PropertiesTable draft={draft} />
        </PreviewSection>
        <PreviewSection title="Notes">
          <Box sx={{ height: 48 }} />
        </PreviewSection>
        <PreviewSection title="AI Tags">
          <MarkdownPreviewText text={draft.aiTags || "AI tags are not available yet."} />
        </PreviewSection>
        <PreviewSection title="AI Polished Article">
          <MarkdownPreviewText text={draft.polishedContent || polishedFallback} />
        </PreviewSection>
        <PreviewSection title={originalTitle}>
          <MarkdownPreviewText text={draft.content} />
        </PreviewSection>
      </Stack>
    </Paper>
  );
}

function PreviewSection({ title, children }: { title: string; children: ReactNode }) {
  return (
    <Box sx={{ pt: 1.5, borderTop: 1, borderColor: "#343A4A" }}>
      <Typography component="h1" sx={previewSectionHeadingSx}>
        {title}
      </Typography>
      {children}
    </Box>
  );
}

function PropertiesTable({ draft }: { draft: ObsidianPreviewDraft }) {
  const rows = [
    ["title", draft.noteTitle],
    ["sources", draft.sources.length ? draft.sources.join("\n") : "--"],
    ["datetime", draft.datetime],
    ["tags", draft.tags.length ? draft.tags.join(", ") : "--"]
  ];

  return (
    <Table size="small" sx={{ tableLayout: "fixed", border: 1, borderColor: "#343A4A" }}>
      <TableBody>
        {rows.map(([label, value]) => (
          <TableRow key={label}>
            <TableCell
              component="th"
              scope="row"
              sx={{
                ...propertyCellSx,
                width: 112,
                color: "#C8D2FF",
                fontWeight: 850,
                bgcolor: "rgba(200, 210, 255, 0.06)"
              }}
            >
              {label}
            </TableCell>
            <TableCell sx={{ ...propertyCellSx, overflowWrap: "anywhere", whiteSpace: "pre-wrap" }}>{value}</TableCell>
          </TableRow>
        ))}
      </TableBody>
    </Table>
  );
}

function MarkdownPreviewText({ text }: { text: string }) {
  const lines = String(text || "").replace(/\r\n?/g, "\n").split("\n");

  return (
    <Box sx={{ display: "grid", gap: 0.5 }}>
      {lines.map((line, index) => {
        if (!line.trim()) return <Box key={index} sx={{ height: 8 }} />;

        const heading = /^(#{1,6})\s+(.+)$/.exec(line);
        if (heading) {
          const level = heading[1].length;
          const component = `h${Math.min(level, 6)}` as "h1";
          return (
            <Typography key={index} component={component} sx={headingSx(level)}>
              {heading[2]}
            </Typography>
          );
        }

        return (
          <Typography key={index} component="p" sx={{ m: 0, fontSize: 14, lineHeight: 1.75, whiteSpace: "pre-wrap" }}>
            {line}
          </Typography>
        );
      })}
    </Box>
  );
}

function headingSx(level: number) {
  const sizes: Record<number, number> = {
    1: 24,
    2: 20,
    3: 17,
    4: 15.5,
    5: 14.5,
    6: 14
  };

  return {
    color: level === 1 ? "#C8D2FF" : "#E2E7FF",
    fontSize: sizes[level] || 14,
    fontWeight: level <= 3 ? 850 : 780,
    lineHeight: 1.25,
    m: 0,
    mt: level === 1 ? 0.5 : 0.25
  };
}
