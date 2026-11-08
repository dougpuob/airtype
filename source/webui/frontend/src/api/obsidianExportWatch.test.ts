import assert from "node:assert/strict";
import { test } from "node:test";
import {
  obsidianExportWatchActive,
  obsidianSaveStatusText,
  settleObsidianExportWatch,
  startObsidianExportWatch
} from "./obsidianExportWatch.ts";

test("watch stays active until the exported ids leave the pending queue", () => {
  const started = startObsidianExportWatch(null, ["a", "b"], 1_000, 60_000);
  assert.equal(obsidianExportWatchActive(started, 1_000), true);
  const stillThere = settleObsidianExportWatch(started, ["b", "new-note"], 2_000);
  assert.equal(stillThere, started);
  const done = settleObsidianExportWatch(started, ["new-note"], 3_000);
  assert.equal(done, null);
  assert.equal(obsidianExportWatchActive(done, 3_000), false);
});

test("a new pending note does not keep a finished export watch alive", () => {
  const started = startObsidianExportWatch(null, ["exported"], 0, 60_000);
  assert.equal(settleObsidianExportWatch(started, ["concurrent"], 10), null);
});

test("the deadline stops the watch while exported notes are still pending", () => {
  const started = startObsidianExportWatch(null, ["a"], 0, 1_000);
  assert.equal(obsidianExportWatchActive(started, 999), true);
  assert.equal(obsidianExportWatchActive(started, 1_000), false);
  assert.equal(settleObsidianExportWatch(started, ["a"], 1_000), null);
});

test("a second handoff unions ids and extends the deadline", () => {
  const first = startObsidianExportWatch(null, ["a"], 0, 1_000);
  const second = startObsidianExportWatch(first, ["b", "a"], 500, 1_000);
  assert.deepEqual(second.ids, ["a", "b"]);
  assert.equal(second.untilMs, 1_500);
});

test("save status follows the pending queue", () => {
  const watch = startObsidianExportWatch(null, ["a", "b"], 0, 1_000);
  assert.equal(obsidianSaveStatusText(null, ["a"], 10), null);
  assert.deepEqual(obsidianSaveStatusText(watch, ["b"], 10), {
    tone: "info",
    text: "Waiting for AirType · 1 note still unsaved"
  });
  assert.deepEqual(obsidianSaveStatusText(watch, ["a", "b"], 10), {
    tone: "info",
    text: "Waiting for AirType · 2 notes still unsaved"
  });
  assert.deepEqual(obsidianSaveStatusText(watch, ["other"], 10), {
    tone: "success",
    text: "Saved to Obsidian"
  });
  assert.equal(obsidianSaveStatusText(watch, ["a"], 1_000)?.tone, "error");
  assert.deepEqual(obsidianSaveStatusText(startObsidianExportWatch(null, [], 0, 1_000), [], 10), {
    tone: "info",
    text: "Waiting for AirType"
  });
});
