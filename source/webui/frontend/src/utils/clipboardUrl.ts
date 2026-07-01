const TRAILING_URL_PUNCTUATION = /[),.;!?。，、；：！？）】》」』]+$/u;

export function extractFirstClipboardUrl(text: string): string | null {
  const match = text.match(/https?:\/\/[^\s<>"'`]+/iu);
  if (!match) return null;

  const url = match[0].replace(TRAILING_URL_PUNCTUATION, "");
  return url || null;
}

export async function readFirstClipboardUrl(): Promise<string> {
  if (!navigator.clipboard?.readText) {
    throw new Error("Clipboard access is not available in this browser");
  }

  const text = await navigator.clipboard.readText();
  const url = extractFirstClipboardUrl(text);
  if (!url) {
    throw new Error("No URL was found in the clipboard");
  }

  return url;
}
