import { test } from "node:test";
import assert from "node:assert/strict";
import {
  parseConflicts,
  assembleConflict,
  buildPartialHunk,
  selectableLines,
  layoutGraph,
  rangeBetween,
  splitPatchText,
  pairHunkLines,
  intraLineDiff,
  aiEndpoint,
  nextChangeTarget,
  isPushRejected,
  isAuthFailure,
  pathTree,
} from "../src/git-text.js";

/* ---------- conflict parsing ---------- */

const CONFLICTED = [
  "top",
  "<<<<<<< HEAD",
  "mine",
  "||||||| base",
  "orig",
  "=======",
  "yours",
  ">>>>>>> other",
  "bottom",
].join("\n");

test("parseConflicts splits context, ours, base and theirs", () => {
  const { blocks, hasConflict } = parseConflicts(CONFLICTED);
  assert.equal(hasConflict, true);
  assert.deepEqual(
    blocks.map((b) => b.type),
    ["ctx", "conflict", "ctx"],
  );
  const c = blocks[1];
  assert.deepEqual(c.ours, ["mine"]);
  assert.deepEqual(c.base, ["orig"]);
  assert.deepEqual(c.theirs, ["yours"]);
  // No marker line may survive into the parsed sides.
  assert.equal(CONFLICTED.includes("<<<<<<<"), true);
  assert.equal(JSON.stringify(blocks).includes("<<<<<<<"), false);
});

test("parseConflicts leaves a clean file untouched", () => {
  const { blocks, hasConflict } = parseConflicts("a\nb\n");
  assert.equal(hasConflict, false);
  assert.equal(assembleConflict(blocks), "a\nb\n");
});

test("assembleConflict honours each block's resolution", () => {
  const pick = (res) => {
    const { blocks } = parseConflicts(CONFLICTED);
    blocks[1].resolution = res;
    return assembleConflict(blocks);
  };
  assert.equal(pick("ours"), "top\nmine\nbottom");
  assert.equal(pick("theirs"), "top\nyours\nbottom");
  assert.equal(pick("both"), "top\nmine\nyours\nbottom");
  assert.equal(pick(null), "top\nmine\nbottom", "unresolved defaults to ours");
  assert.equal(pick("none"), "top\nbottom", "both sides rejected drops the block");
});

test("assembleConflict prefers hand-edited block text", () => {
  const { blocks } = parseConflicts(CONFLICTED);
  blocks[1].resolution = "ours";
  blocks[1].edited = "merged by hand\nsecond line";
  assert.equal(assembleConflict(blocks), "top\nmerged by hand\nsecond line\nbottom");
  blocks[0].edited = "TOP";
  assert.equal(assembleConflict(blocks), "TOP\nmerged by hand\nsecond line\nbottom");
});

/* ---------- line-level staging ---------- */

const HUNK = ["@@ -1,3 +1,4 @@ fn main", " a", "-b", "+B", "+c", " d", ""].join("\n");

test("selectableLines finds only the +/- lines", () => {
  assert.deepEqual(selectableLines(HUNK), [1, 2, 3]);
});

test("buildPartialHunk staging one addition drops the other and neutralises the deletion", () => {
  const patch = buildPartialHunk(HUNK, new Set([2]));
  assert.equal(
    patch,
    ["@@ -1,3 +1,4 @@ fn main", " a", " b", "+B", " d", ""].join("\n"),
  );
});

test("buildPartialHunk staging one deletion drops both additions", () => {
  const patch = buildPartialHunk(HUNK, new Set([1]));
  assert.equal(patch, ["@@ -1,3 +1,2 @@ fn main", " a", "-b", " d", ""].join("\n"));
});

test("buildPartialHunk line counts always match the body it emits", () => {
  for (const sel of [[1], [2], [3], [1, 2], [2, 3], [1, 2, 3]]) {
    const patch = buildPartialHunk(HUNK, new Set(sel));
    const [header, ...body] = patch.replace(/\n$/, "").split("\n");
    const m = /^@@ -\d+,(\d+) \+\d+,(\d+) @@/.exec(header);
    const oldSide = body.filter((l) => l.startsWith(" ") || l.startsWith("-")).length;
    const newSide = body.filter((l) => l.startsWith(" ") || l.startsWith("+")).length;
    assert.equal(Number(m[1]), oldSide, `old count for ${sel}`);
    assert.equal(Number(m[2]), newSide, `new count for ${sel}`);
  }
});

test("buildPartialHunk selecting everything reproduces the original hunk", () => {
  assert.equal(buildPartialHunk(HUNK, new Set([1, 2, 3])), HUNK);
});

test("buildPartialHunk returns null when nothing is selected", () => {
  assert.equal(buildPartialHunk(HUNK, new Set()), null);
  assert.equal(buildPartialHunk("not a hunk", new Set([0])), null);
});

test("buildPartialHunk keeps the no-newline marker with its line", () => {
  // Marker after the old last line: that line is emitted either as "-a" (when
  // selected) or as context " a" (when not), so the marker travels with it.
  const oldSide = ["@@ -1 +1 @@", "-a", "\\ No newline at end of file", "+b", ""].join("\n");
  assert.match(buildPartialHunk(oldSide, new Set([0])), /^-a\n\\ No newline/m);
  assert.match(buildPartialHunk(oldSide, new Set([2])), /^ a\n\\ No newline/m);

  // Marker after an added line: dropping that addition must drop the marker,
  // or the patch claims a no-newline state for whatever line precedes it.
  const newSide = ["@@ -1 +1 @@", "-a", "+b", "\\ No newline at end of file", ""].join("\n");
  assert.match(buildPartialHunk(newSide, new Set([1])), /\\ No newline/);
  assert.doesNotMatch(buildPartialHunk(newSide, new Set([0])), /\\ No newline/);
});

/* ---------- graph layout ---------- */

test("layoutGraph keeps a linear history in one lane", () => {
  const { rows, width } = layoutGraph([
    { id: "c", parents: ["b"] },
    { id: "b", parents: ["a"] },
    { id: "a", parents: [] },
  ]);
  assert.equal(width, 1);
  assert.deepEqual(
    rows.map((r) => r.myCol),
    [0, 0, 0],
  );
});

test("layoutGraph gives a merge two parent lanes and reuses them", () => {
  const { rows, width } = layoutGraph([
    { id: "m", parents: ["a", "b"] },
    { id: "a", parents: ["base"] },
    { id: "b", parents: ["base"] },
    { id: "base", parents: [] },
  ]);
  assert.equal(width, 2);
  assert.equal(rows[0].parentCols.length, 2, "merge fans out to both parents");
  assert.equal(rows[1].myCol, 0);
  assert.equal(rows[2].myCol, 1);
  // The lanes collapse back once both sides reach the shared ancestor.
  assert.equal(rows[3].myCol, 0);
  assert.equal(rows[3].outgoing.length, 0);
});

test("layoutGraph tolerates parents outside the loaded page", () => {
  const { rows } = layoutGraph([{ id: "x", parents: ["missing"] }]);
  assert.equal(rows[0].myCol, 0);
  assert.deepEqual(rows[0].outgoing, ["missing"]);
});

/* ---------- shift-range selection ---------- */

test("rangeBetween selects only pickable lines inside the range", () => {
  // hunk body: 0=ctx 1=+ 2=+ 3=ctx 4=- 5=+ 6=ctx
  const pickable = [1, 2, 4, 5];
  assert.deepEqual([...rangeBetween(pickable, 1, 5)], [1, 2, 4, 5]);
  // Context lines inside the span must not be swept in.
  assert.deepEqual([...rangeBetween(pickable, 2, 4)], [2, 4]);
  // Direction must not matter — dragging upward is the same range.
  assert.deepEqual([...rangeBetween(pickable, 5, 1)], [1, 2, 4, 5]);
  // A range with a single endpoint is just that line.
  assert.deepEqual([...rangeBetween(pickable, 4, 4)], [4]);
  // Endpoints that aren't pickable still bound the range correctly.
  assert.deepEqual([...rangeBetween(pickable, 0, 3)], [1, 2]);
});

/* ---------- base must never leak into a resolved file ---------- */

const DIFF3 = [
  "one",
  "<<<<<<< ours",
  "ours",
  "||||||| base",
  "ANCESTOR",
  "=======",
  "theirs",
  ">>>>>>> theirs",
  "three",
].join("\n");

test("assembleConflict never writes the common ancestor into the result", () => {
  const { blocks } = parseConflicts(DIFF3);
  assert.deepEqual(blocks[1].base, ["ANCESTOR"], "base is parsed for display");
  for (const res of ["ours", "theirs", "both", null]) {
    blocks[1].resolution = res;
    const out = assembleConflict(blocks);
    assert.doesNotMatch(out, /ANCESTOR/, `base leaked with resolution=${res}`);
    assert.doesNotMatch(out, /\|\|\|\|\|\|\|/, `marker leaked with resolution=${res}`);
  }
});

/* ---------- side-by-side diff ---------- */

test("splitPatchText separates the file header from each hunk", () => {
  const patch =
    "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1,2 +1,2 @@\n a\n-b\n+B\n@@ -9,1 +9,1 @@\n-x\n+y\n";
  const { header, hunks } = splitPatchText(patch);
  assert.match(header, /^diff --git/);
  assert.equal(hunks.length, 2);
  assert.equal(header + hunks.join(""), patch, "must round-trip byte for byte");
});

test("pairHunkLines aligns deletions against additions and numbers both sides", () => {
  const hunk = ["@@ -10,3 +20,3 @@", " keep", "-old", "+new", " tail", ""].join("\n");
  const { rows } = pairHunkLines(hunk);
  assert.deepEqual(
    rows.map((r) => [r.type, r.left?.no, r.left?.text, r.right?.no, r.right?.text]),
    [
      ["ctx", 10, "keep", 20, "keep"],
      ["mod", 11, "old", 21, "new"],
      ["ctx", 12, "tail", 22, "tail"],
    ],
  );
});

test("pairHunkLines leaves the opposite cell empty for unbalanced runs", () => {
  const hunk = ["@@ -1,3 +1,2 @@", "-a", "-b", "+A", " c", ""].join("\n");
  const { rows } = pairHunkLines(hunk);
  assert.deepEqual(rows.map((r) => r.type), ["mod", "del", "ctx"]);
  assert.equal(rows[1].right, null, "second deletion has no counterpart");
  // Numbering must not advance on the side that has no line.
  assert.deepEqual(rows.map((r) => [r.left?.no ?? null, r.right?.no ?? null]),
    [[1, 1], [2, null], [3, 2]]);
});

test("pairHunkLines carries the body indices that staging needs", () => {
  const hunk = ["@@ -1,2 +1,2 @@", " x", "-a", "+A", ""].join("\n");
  const { rows } = pairHunkLines(hunk);
  assert.deepEqual(rows[0].picks, [], "context is not stageable");
  // Picking a modified row must stage both halves of the change.
  assert.deepEqual(rows[1].picks, [1, 2]);
  assert.equal(buildPartialHunk(hunk, new Set(rows[1].picks)), hunk);
});

test("pairHunkLines never loops on malformed body lines", () => {
  const hunk = ["@@ -1,1 +1,1 @@", "???unexpected", "-a", "+b", ""].join("\n");
  const { rows } = pairHunkLines(hunk);
  assert.ok(rows.length >= 1, "returns instead of hanging");
  assert.equal(pairHunkLines("no header here"), null);
});

test("intraLineDiff highlights only the changed middle", () => {
  const a = "【UniFly萤火虫】令牌变更通知 · {令牌名称}";
  const b = "【UniFly萤火虫】令牌变更通11知 · {令牌名称}";
  const d = intraLineDiff(a, b);
  assert.equal(d.left.mid, "", "nothing was removed");
  assert.equal(d.right.mid, "11", "only the inserted text is highlighted");
  assert.equal(d.left.prefix, d.right.prefix);
  assert.equal(d.left.suffix, d.right.suffix);
  // Reassembling each side must give back the original line.
  assert.equal(d.left.prefix + d.left.mid + d.left.suffix, a);
  assert.equal(d.right.prefix + d.right.mid + d.right.suffix, b);
});

test("intraLineDiff returns null for identical lines and handles no overlap", () => {
  assert.equal(intraLineDiff("same", "same"), null);
  const d = intraLineDiff("abc", "xyz");
  assert.equal(d.left.mid, "abc");
  assert.equal(d.right.mid, "xyz");
});

test("intraLineDiff splits on code points, not UTF-16 units", () => {
  // 😀 U+1F600 and 😁 U+1F601 share a high surrogate and differ only in the
  // low one, so a UTF-16-unit scan stops *inside* the pair and leaves a lone
  // surrogate in the prefix. This is the input that tells the two apart.
  const d = intraLineDiff("a😀b", "a😁b");
  assert.equal(d.left.mid, "😀");
  assert.equal(d.right.mid, "😁");
  assert.equal(d.left.prefix, "a");
  assert.equal(d.left.suffix, "b");
  // Every piece must be valid UTF-16 on its own — a charAt scan would hand back
  // a half-emoji here. (A complete pair legitimately ends in a low surrogate,
  // so "well-formed" is the predicate, not "no trailing surrogate".)
  for (const part of [d.left, d.right]) {
    for (const piece of [part.prefix, part.mid, part.suffix]) {
      assert.ok(piece.isWellFormed(), `broken UTF-16 in ${JSON.stringify(piece)}`);
    }
  }

});

/* ---------- AI endpoint ---------- */

test("aiEndpoint appends the chat path to a base url, once", () => {
  assert.equal(aiEndpoint("https://api.openai.com/v1"), "https://api.openai.com/v1/chat/completions");
  assert.equal(aiEndpoint("https://api.openai.com/v1/"), "https://api.openai.com/v1/chat/completions");
  assert.equal(
    aiEndpoint(" https://api.openai.com/v1/chat/completions "),
    "https://api.openai.com/v1/chat/completions",
  );
});

/* ---------- prev / next change navigation ---------- */

const step = (o) => nextChangeTarget({ blockCount: 3, navCount: 2, ...o });

test("nextChangeTarget enters an unvisited file from the near end", () => {
  assert.deepEqual(step({ blockIndex: -1, navIndex: 0, dir: 1 }), { kind: "block", index: 0 });
  assert.deepEqual(step({ blockIndex: -1, navIndex: 0, dir: -1 }), { kind: "block", index: 2 });
});

test("nextChangeTarget walks blocks inside the current file", () => {
  assert.deepEqual(step({ blockIndex: 0, navIndex: 0, dir: 1 }), { kind: "block", index: 1 });
  assert.deepEqual(step({ blockIndex: 2, navIndex: 0, dir: -1 }), { kind: "block", index: 1 });
});

test("nextChangeTarget crosses into the adjacent file at either end", () => {
  // Last block of file 0, going forward -> file 1.
  assert.deepEqual(step({ blockIndex: 2, navIndex: 0, dir: 1 }), { kind: "file", index: 1 });
  // First block of file 1, going back -> file 0.
  assert.deepEqual(step({ blockIndex: 0, navIndex: 1, dir: -1 }), { kind: "file", index: 0 });
});

test("nextChangeTarget stops at the very first and very last change", () => {
  assert.deepEqual(step({ blockIndex: 2, navIndex: 1, dir: 1 }), { kind: "none" });
  assert.deepEqual(step({ blockIndex: 0, navIndex: 0, dir: -1 }), { kind: "none" });
});

test("nextChangeTarget skips straight to a file when the diff has no blocks", () => {
  // A binary file or pure rename renders nothing to step through.
  const none = { blockIndex: -1, blockCount: 0, navCount: 3 };
  assert.deepEqual(nextChangeTarget({ ...none, navIndex: 1, dir: 1 }), { kind: "file", index: 2 });
  assert.deepEqual(nextChangeTarget({ ...none, navIndex: 1, dir: -1 }), { kind: "file", index: 0 });
  // ...and reports nowhere-to-go rather than looping when it's the only file.
  assert.deepEqual(
    nextChangeTarget({ blockIndex: -1, blockCount: 0, navIndex: 0, navCount: 1, dir: 1 }),
    { kind: "none" },
  );
});

test("nextChangeTarget handles a single-block file without dead ends", () => {
  const one = { blockCount: 1, navCount: 1 };
  assert.deepEqual(nextChangeTarget({ ...one, blockIndex: -1, navIndex: 0, dir: 1 }), { kind: "block", index: 0 });
  assert.deepEqual(nextChangeTarget({ ...one, blockIndex: 0, navIndex: 0, dir: 1 }), { kind: "none" });
});

/* ---------- push rejection ---------- */

test("isPushRejected: 远端领先时应识别为可通过更新解决", () => {
  // Verbatim stderr from `git push` against a remote that moved ahead.
  const behind = [
    "To https://git-codecommit.us-west-2.amazonaws.com/v1/repos/aihttpproxy",
    " ! [rejected]        master -> master (fetch first)",
    "error: failed to push some refs to 'https://git-codecommit.us-west-2.amazonaws.com/v1/repos/aihttpproxy'",
  ].join("\n");
  assert.equal(isPushRejected(behind), true);

  const diverged = " ! [rejected]        main -> main (non-fast-forward)";
  assert.equal(isPushRejected(diverged), true);
});

test("isAuthFailure: 识别 git 报凭证问题的几种说法", () => {
  // 关掉交互提示后 cgit 拿到的原话
  assert.equal(
    isAuthFailure("fatal: could not read Username for 'https://example.com': terminal prompts disabled"),
    true,
  );
  assert.equal(isAuthFailure("fatal: could not read Password for 'https://u@example.com'"), true);
  assert.equal(isAuthFailure("fatal: Authentication failed for 'https://example.com/repo'"), true);
  assert.equal(isAuthFailure("git@example.com: Permission denied (publickey)."), true);
});

test("isAuthFailure: 其他失败不应被当成凭证问题", () => {
  assert.equal(isAuthFailure("! [rejected] main -> main (fetch first)"), false);
  assert.equal(isAuthFailure("remote: error: GH006: Protected branch update failed"), false);
  assert.equal(isAuthFailure("fatal: unable to access 'https://example.com/': Could not resolve host"), false);
});

test("isPushRejected: 真正的失败不应触发自动更新重推", () => {
  assert.equal(isPushRejected("fatal: Authentication failed for 'https://example.com/repo'"), false);
  assert.equal(isPushRejected("remote: error: GH006: Protected branch update failed"), false);
  assert.equal(isPushRejected("Everything up-to-date"), false);
});

/* ---------- folder tree ---------- */

const PUSH_FILES = [
  "tests/test_openapi.py",
  "app/core/auth.py",
  "app/api/v1/openapi.py",
  "app/api/v1/__init__.py",
  "app/core/constants.py",
  "app/services/token_service.py",
  "app/utils/timeutil.py",
  "tests/test_token.py",
  "tests/conftest.py",
].map((path) => ({ path, status: "modified" }));

test("pathTree groups files by folder and counts them", () => {
  const root = pathTree(PUSH_FILES);
  assert.equal(root.count, 9);
  // Folders sort alphabetically, and each one knows its own total.
  assert.deepEqual(
    root.dirs.map((d) => [d.name, d.count]),
    [
      ["app", 6],
      ["tests", 3],
    ],
  );
  // Nothing sits loose at the root of this push.
  assert.equal(root.files.length, 0);
});

test("pathTree collapses single-child folder chains into one row", () => {
  const [app] = pathTree(PUSH_FILES).dirs;
  assert.deepEqual(
    app.dirs.map((d) => d.name),
    ["api/v1", "core", "services", "utils"],
  );
  assert.equal(app.dirs[0].files.length, 2);
});

test("pathTree keeps root-level files and does not swallow the root", () => {
  const root = pathTree([{ path: "README.md", status: "new" }, { path: "src/a.js", status: "new" }]);
  assert.equal(root.name, "");
  assert.deepEqual(root.files.map((f) => f.path), ["README.md"]);
  assert.deepEqual(root.dirs.map((d) => d.name), ["src"]);
  assert.equal(root.count, 2);
});
