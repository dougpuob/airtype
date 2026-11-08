import assert from "node:assert/strict";
import { test } from "node:test";
import {
  obsidianExportWatchActive,
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
