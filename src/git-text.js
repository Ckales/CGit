/* Pure text/graph helpers, kept free of DOM and Tauri imports so they can be
   unit-tested with `node --test`. These are the functions that silently corrupt
   user data when they're wrong: a mis-built patch stages the wrong lines, a
   mis-parsed conflict writes the wrong merge result. */

/* ---------- conflict markers ---------- */

/** Split a file containing conflict markers into context and conflict blocks. */
export function parseConflicts(text) {
  const lines = text.split("\n");
  const blocks = [];
  let ctx = [];
  let hasConflict = false;
  let i = 0;
  const flushCtx = () => {
    if (ctx.length) {
      blocks.push({ type: "ctx", lines: ctx });
      ctx = [];
    }
  };
  while (i < lines.length) {
    if (lines[i].startsWith("<<<<<<<")) {
      hasConflict = true;
      flushCtx();
      i++;
      const ours = [];
      while (i < lines.length && !lines[i].startsWith("|||||||") && !lines[i].startsWith("=======")) {
        ours.push(lines[i]);
        i++;
      }
      const base = [];
      if (i < lines.length && lines[i].startsWith("|||||||")) {
        i++;
        while (i < lines.length && !lines[i].startsWith("=======")) {
          base.push(lines[i]);
          i++;
        }
      }
      if (i < lines.length && lines[i].startsWith("=======")) i++;
      const theirs = [];
      while (i < lines.length && !lines[i].startsWith(">>>>>>>")) {
        theirs.push(lines[i]);
        i++;
      }
      if (i < lines.length && lines[i].startsWith(">>>>>>>")) i++;
      blocks.push({ type: "conflict", ours, base, theirs, resolution: null });
    } else {
      ctx.push(lines[i]);
      i++;
    }
  }
  flushCtx();
  return { blocks, hasConflict };
}

/** Rebuild file content from blocks, applying each block's chosen resolution. */
export function assembleConflict(blocks) {
  const out = [];
  for (const b of blocks) {
    // Hand-edited result text wins over any side picking, for conflict and
    // context blocks alike — the merge window's middle column is editable.
    if (b.edited != null) out.push(...b.edited.split("\n"));
    else if (b.type === "ctx") out.push(...b.lines);
    else if (b.resolution === "none") continue; // both sides rejected
    else if (b.resolution === "theirs") out.push(...b.theirs);
    else if (b.resolution === "both") out.push(...b.ours, ...b.theirs);
    else out.push(...b.ours); // default / "ours"
  }
  return out.join("\n");
}

/* ---------- partial (line-level) staging ---------- */

export function parseHunkHeader(line) {
  const m = /^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@(.*)$/.exec(line);
  if (!m) return null;
  return { oldStart: Number(m[1]), newStart: Number(m[2]), tail: m[3] ?? "" };
}

/**
 * Rebuild a hunk containing only the selected body lines, so `git apply` stages
 * (or with --reverse, unstages) exactly those lines.
 *
 * An unselected `+` line is dropped — that addition stays out of the index.
 * An unselected `-` line becomes context — that deletion is not applied. Both
 * readings hold under --reverse too, which is why one function covers staging
 * and unstaging. `keep` holds indices into the hunk body (header excluded).
 */
export function buildPartialHunk(hunk, keep) {
  const lines = hunk.replace(/\n$/, "").split("\n");
  const head = parseHunkHeader(lines[0]);
  if (!head) return null;

  const out = [];
  let oldCount = 0;
  let newCount = 0;
  let kept = 0;
  let lastKept = false;

  lines.slice(1).forEach((line, i) => {
    const kind = line[0] ?? " ";
    if (kind === "\\") {
      // "\ No newline at end of file" qualifies the line above it.
      if (lastKept) out.push(line);
      return;
    }
    if (kind === "+") {
      if (keep.has(i)) {
        out.push(line);
        newCount++;
        kept++;
        lastKept = true;
      } else {
        lastKept = false;
      }
      return;
    }
    if (kind === "-") {
      if (keep.has(i)) {
        out.push(line);
        oldCount++;
        kept++;
      } else {
        out.push(" " + line.slice(1));
        oldCount++;
        newCount++;
      }
      lastKept = true;
      return;
    }
    out.push(line);
    oldCount++;
    newCount++;
    lastKept = true;
  });

  if (!kept) return null;
  return (
    `@@ -${head.oldStart},${oldCount} +${head.newStart},${newCount} @@${head.tail}\n` +
    out.join("\n") +
    "\n"
  );
}

/** Body-line indices of a hunk that are selectable (i.e. +/- lines). */
export function selectableLines(hunk) {
  const body = hunk.replace(/\n$/, "").split("\n").slice(1);
  const out = [];
  body.forEach((line, i) => {
    if (line.startsWith("+") || line.startsWith("-")) out.push(i);
  });
  return out;
}

/**
 * The pickable line indices between two endpoints, inclusive, in either
 * direction. Context lines inside the span are skipped: a shift-range means
 * "these changes", and a context line is not a change you can stage.
 */
export function rangeBetween(pickable, a, b) {
  const lo = Math.min(a, b);
  const hi = Math.max(a, b);
  return new Set(pickable.filter((i) => i >= lo && i <= hi));
}

/* ---------- side-by-side diff ---------- */

/** Split a unified patch into its file header and hunks, verbatim. */
export function splitPatchText(text) {
  const lines = text.replace(/\n$/, "").split("\n");
  const header = [];
  const hunks = [];
  let cur = null;
  for (const line of lines) {
    if (line.startsWith("@@")) {
      if (cur) hunks.push(cur.join("\n") + "\n");
      cur = [line];
    } else if (cur) {
      cur.push(line);
    } else {
      header.push(line);
    }
  }
  if (cur) hunks.push(cur.join("\n") + "\n");
  return { header: header.length ? header.join("\n") + "\n" : "", hunks };
}

/**
 * Turn a unified hunk into aligned left/right rows for a two-column view.
 *
 * A run of `-` lines is paired positionally against the run of `+` lines that
 * follows it, which is what makes an edited line show up as one row with both
 * versions instead of two unrelated rows. Leftovers get an empty cell on the
 * other side, and a side's line number only advances when that side has a line.
 *
 * `picks` carries the original body indices, so `buildPartialHunk` can stage
 * exactly the rows the user selected.
 */
export function pairHunkLines(hunk) {
  const lines = hunk.replace(/\n$/, "").split("\n");
  const head = parseHunkHeader(lines[0]);
  if (!head) return null;
  const body = lines.slice(1);

  let oldNo = head.oldStart;
  let newNo = head.newStart;
  const rows = [];
  let i = 0;

  const skipMarkers = () => {
    while (i < body.length && body[i].startsWith("\\")) i++;
  };

  while (i < body.length) {
    const line = body[i];
    if (line.startsWith("\\")) {
      i++;
      continue;
    }
    if (!line.startsWith("+") && !line.startsWith("-")) {
      const text = line.startsWith(" ") ? line.slice(1) : line;
      rows.push({
        type: "ctx",
        left: { no: oldNo++, text },
        right: { no: newNo++, text },
        picks: [],
      });
      i++;
      continue;
    }

    const start = i;
    const dels = [];
    while (i < body.length && body[i].startsWith("-")) {
      dels.push({ text: body[i].slice(1), idx: i });
      i++;
    }
    skipMarkers();
    const adds = [];
    while (i < body.length && body[i].startsWith("+")) {
      adds.push({ text: body[i].slice(1), idx: i });
      i++;
    }
    skipMarkers();
    // Belt and braces: never leave the loop without consuming input.
    if (i === start) {
      i++;
      continue;
    }

    for (let k = 0; k < Math.max(dels.length, adds.length); k++) {
      const d = dels[k];
      const a = adds[k];
      rows.push({
        type: d && a ? "mod" : d ? "del" : "add",
        left: d ? { no: oldNo++, text: d.text } : null,
        right: a ? { no: newNo++, text: a.text } : null,
        picks: [d?.idx, a?.idx].filter((x) => x !== undefined),
      });
    }
  }
  return { head, rows };
}

/**
 * Where two versions of one line actually differ: the shared prefix and suffix
 * are trimmed off and what remains is the highlight.
 *
 * Iterating code points (not UTF-16 units) is what keeps CJK and emoji intact;
 * a `charAt` scan can stop mid-surrogate and render a broken glyph.
 *
 * ponytail: prefix/suffix trimming, not a token LCS. It gives the exact answer
 * for the common single-edit case and a coarse one for scattered edits —
 * upgrade to a word-level LCS if that ever actually reads badly.
 */
export function intraLineDiff(a, b) {
  if (a === b) return null;
  const A = [...a];
  const B = [...b];

  let p = 0;
  while (p < A.length && p < B.length && A[p] === B[p]) p++;
  let s = 0;
  while (
    s < A.length - p &&
    s < B.length - p &&
    A[A.length - 1 - s] === B[B.length - 1 - s]
  ) {
    s++;
  }

  const cut = (arr) => ({
    prefix: arr.slice(0, p).join(""),
    mid: arr.slice(p, arr.length - s).join(""),
    suffix: arr.slice(arr.length - s).join(""),
  });
  return { left: cut(A), right: cut(B) };
}

/* ---------- change navigation ---------- */

/**
 * Decide the first step of a prev/next-change move. Split out from the DOM so
 * the index arithmetic — the part that is all off-by-one risk — is testable.
 *
 * Returns `{kind:"block", index}` to move within the current file,
 * `{kind:"file", index}` to open an adjacent file, or `{kind:"none"}` when
 * there is nowhere left to go. The caller keeps walking files with `kind:"file"`
 * results until one actually renders a block.
 */
export function nextChangeTarget({ blockIndex, blockCount, navIndex, navCount, dir }) {
  const far = dir > 0 ? 0 : blockCount - 1;
  // Nothing focused yet: enter the current file from the end we came from.
  if (blockIndex === -1 && blockCount > 0) {
    return { kind: "block", index: far };
  }
  const next = blockIndex + dir;
  if (next >= 0 && next < blockCount) {
    return { kind: "block", index: next };
  }
  const file = navIndex + dir;
  if (file >= 0 && file < navCount) {
    return { kind: "file", index: file };
  }
  return { kind: "none" };
}

/* ---------- history DAG layout ---------- */

/** Assign each commit a lane (column) and record incoming/outgoing lane state. */
export function layoutGraph(commits) {
  const lanes = []; // lanes[col] = oid expected next in that column, or null
  const rows = [];
  const allocFree = () => {
    const i = lanes.indexOf(null);
    if (i !== -1) return i;
    lanes.push(null);
    return lanes.length - 1;
  };

  for (const c of commits) {
    const incoming = lanes.slice();
    const mergeCols = [];
    for (let i = 0; i < incoming.length; i++) {
      if (incoming[i] === c.id) mergeCols.push(i);
    }

    let myCol;
    if (mergeCols.length) {
      myCol = mergeCols[0];
      for (let k = 1; k < mergeCols.length; k++) lanes[mergeCols[k]] = null;
    } else {
      myCol = allocFree();
    }

    const parentCols = [];
    if (c.parents.length) {
      lanes[myCol] = c.parents[0];
      parentCols.push(myCol);
      for (let p = 1; p < c.parents.length; p++) {
        let pc = lanes.indexOf(c.parents[p]);
        if (pc === -1) pc = allocFree();
        lanes[pc] = c.parents[p];
        parentCols.push(pc);
      }
    } else {
      lanes[myCol] = null;
    }

    // trim trailing free lanes so the graph doesn't stay wide after branches end
    while (lanes.length && lanes[lanes.length - 1] == null) lanes.pop();

    rows.push({ commit: c, myCol, incoming, outgoing: lanes.slice(), parentCols });
  }

  let width = 1;
  for (const r of rows) width = Math.max(width, r.incoming.length, r.outgoing.length);
  return { rows, width };
}

/* ---------- AI endpoint ---------- */

/** Normalize the AI 请求地址 preference into a /chat/completions endpoint. */
export function aiEndpoint(baseUrl) {
  const url = String(baseUrl).trim().replace(/\/+$/, "");
  return url.endsWith("/chat/completions") ? url : `${url}/chat/completions`;
}

/* ---------- push rejection ---------- */

/** Whether a `git push` failure is "the remote moved ahead" — i.e. updating
    the local branch and pushing again can resolve it. Everything else (auth,
    a refusing hook, a protected branch) is a real failure. */
export function isPushRejected(stderr) {
  const s = String(stderr);
  return s.includes("[rejected]") || s.includes("fetch first") || s.includes("non-fast-forward");
}

/** Classify credential failures and retain the authenticated GitHub account
 * when the remote names it. An HTTP 403 alone is not enough: repositories and
 * proxies use it for failures unrelated to credentials. */
export function authFailureInfo(stderr) {
  const s = String(stderr);
  const denied = /^remote: Permission to .+ denied to ([A-Za-z0-9-]+)\.\s*$/m.exec(s);
  if (denied && s.includes("The requested URL returned error: 403")) {
    return { kind: "github-403", username: denied[1] };
  }
  if (s.includes("could not read Username") || s.includes("could not read Password")) {
    return { kind: "https-prompt", username: null };
  }
  if (s.includes("Authentication failed")) return { kind: "https-auth", username: null };
  if (s.includes("Permission denied (publickey)")) {
    return { kind: "ssh-publickey", username: null };
  }
  return null;
}

export const isAuthFailure = (stderr) => authFailureInfo(stderr) !== null;

/** Decide whether the combined credential button can reuse the current helper
 * entry or needs a new token. The token itself stays in the input element. */
export function credentialAction(info, username, token) {
  username = String(username).trim();
  token = String(token).trim();
  if (!username) return "missing-username";
  if (token) return "save-and-test";
  if (info?.hasCredential && username === info.username) return "test";
  return "missing-token";
}

/* ---------- folder tree (push dialog) ---------- */

/** Groups `{path, status}` entries into a folder tree. Folders sort before
    files and carry the number of files below them. Single-child folder chains
    collapse by default; interactive callers can keep every level visible.
    The root keeps an empty name — the caller labels it with the repo name. */
export function pathTree(files, collapseSingleChild = true) {
  const root = { name: "", dirs: new Map(), files: [] };
  for (const f of files) {
    const parts = String(f.path).split("/");
    let node = root;
    for (const dir of parts.slice(0, -1)) {
      if (!node.dirs.has(dir)) node.dirs.set(dir, { name: dir, dirs: new Map(), files: [] });
      node = node.dirs.get(dir);
    }
    node.files.push(f);
  }
  return closeTree(root, collapseSingleChild);
}

function closeTree(node, collapseSingleChild) {
  // Collapse a chain of single-child folders into one row. The root is exempt:
  // it is the repo, and swallowing "app" into it would hide a real folder.
  while (
    collapseSingleChild &&
    node.name !== "" &&
    node.files.length === 0 &&
    node.dirs.size === 1
  ) {
    const only = [...node.dirs.values()][0];
    node = { name: `${node.name}/${only.name}`, dirs: only.dirs, files: only.files };
  }
  const dirs = [...node.dirs.values()]
    .map((dir) => closeTree(dir, collapseSingleChild))
    .sort((a, b) => a.name.localeCompare(b.name));
  const byName = (a, b) => a.path.localeCompare(b.path);
  const own = node.files.slice().sort(byName);
  let count = own.length;
  for (const d of dirs) count += d.count;
  return { name: node.name, dirs, files: own, count };
}
