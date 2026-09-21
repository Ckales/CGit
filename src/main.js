import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { open, save, ask } from "@tauri-apps/plugin-dialog";
import { homeDir } from "@tauri-apps/api/path";
import {
  parseConflicts,
  assembleConflict,
  buildPartialHunk,
  selectableLines,
  rangeBetween,
  splitPatchText,
  pairHunkLines,
  intraLineDiff,
  nextChangeTarget,
  layoutGraph,
  aiEndpoint,
  isPushRejected,
  authFailureInfo,
  isAuthFailure,
  credentialAction,
  pathTree,
} from "./git-text.js";

/* A workspace is one or more repos. `repos` is all of them; `repoPath` is the
   active one, which the single-repo panels (branches / history / stash /
   remotes / tags) follow. The changes list and commit span every repo, the way
   IDEA's commit panel does. */
let repos = [];
let repoPath = null;
/* Paths of the repos with something uncommitted, for the * in the repo list.
   Filled by refreshChanges, which already has every repo's status in hand. */
let dirtyRepos = new Set();

const repoName = (path) => repos.find((r) => r.path === path)?.name ?? path;
const isMulti = () => repos.length > 1;

/* ---------- recent repositories (persisted in localStorage) ---------- */
const RECENT_KEY = "cgit.recentRepos";
const RECENT_MAX = 5;

function loadRecent() {
  try {
    return JSON.parse(localStorage.getItem(RECENT_KEY)) || [];
  } catch {
    return [];
  }
}

function saveRecent(list) {
  localStorage.setItem(RECENT_KEY, JSON.stringify(list.slice(0, RECENT_MAX)));
}

function addRecent(path) {
  saveRecent([path, ...loadRecent().filter((p) => p !== path)]);
}

/* The project name shown on the pill, and the path shown under it. Paths are
   home-relative when we can resolve $HOME, and absolute when we can't. */
let homePrefix = "";

const projectName = (path) => path.split("/").filter(Boolean).pop() || path;

const prettyPath = (path) =>
  homePrefix && path.startsWith(`${homePrefix}/`) ? `~${path.slice(homePrefix.length)}` : path;

/* The path recorded in the recent list for whatever is open now — the workspace
   root for a multi-repo workspace, the repo itself otherwise. */
let workspaceRoot = null;

/* ---------- preferences (persisted in localStorage) ---------- */
const PREFS_KEY = "cgit.prefs";

const DEFAULT_AI_PROMPT = `你是一个 Git 提交说明生成器。根据用户给出的 git diff 生成一条提交说明。
要求：
1. 第一行是不超过 50 个字的概要，使用中文，不要加句号。
2. 如果改动涉及多个方面，空一行后用「- 」列出要点，每行一条。
3. 只描述改动本身，不要解释 diff 语法，不要输出代码块标记。
4. 直接输出提交说明正文，不要任何前缀或额外说明。`;

const DEFAULT_PREFS = {
  pullStrategy: "ff-only", // ff-only | merge | rebase
  historyPageSize: 100,
  theme: "dark", // dark | light
  fontSize: 13,
  diffView: "split", // split | unified
  historyHeight: null, // px; null = the CSS default ratio
  sidebarWidth: null, // px; null = the CSS default 220px
  editor: "", // 默认文本编辑器的 App 名；空串 = 系统默认程序
  editors: [], // 设置里勾选的编辑器 App 名，下面两处的可选项都来自它
  projectEditors: {}, // 项目路径 => 编辑器 App 名，只管「打开项目」，没有条目就用 editor
  // AI commit-message generation (OpenAI-compatible /chat/completions)
  aiBaseUrl: "",
  aiToken: "",
  aiModel: "",
  aiPrompt: DEFAULT_AI_PROMPT,
};

function loadPrefs() {
  let p;
  try {
    p = { ...DEFAULT_PREFS, ...(JSON.parse(localStorage.getItem(PREFS_KEY)) || {}) };
  } catch {
    return { ...DEFAULT_PREFS };
  }
  // 编辑器列表是后加的：老配置里只有单个 editor，把它收进列表，否则下拉里选不到自己在用的那个。
  if (!p.editors.length && p.editor) p.editors = [p.editor];
  return p;
}

let prefs = loadPrefs();

function savePrefs() {
  localStorage.setItem(PREFS_KEY, JSON.stringify(prefs));
}

function applyPrefs() {
  document.documentElement.dataset.theme = prefs.theme;
  document.documentElement.style.fontSize = `${prefs.fontSize}px`;
  document.documentElement.dataset.diffView = prefs.diffView;
  const btn = document.getElementById("diff-view-btn");
  if (btn) btn.textContent = prefs.diffView === "unified" ? "统一" : "并排";
}

/* ---------- reusable text prompt (native prompt() is blocked in webview) ---------- */
function textPrompt(title, def = "") {
  return new Promise((resolve) => {
    const overlay = $("modal-overlay");
    const input = $("modal-input");
    $("modal-title").textContent = title;
    input.value = def;
    overlay.style.display = "flex";
    input.focus();
    input.select();

    const done = (val) => {
      overlay.style.display = "none";
      $("modal-ok").onclick = null;
      $("modal-cancel").onclick = null;
      input.onkeydown = null;
      overlay.onclick = null;
      resolve(val);
    };
    $("modal-ok").onclick = () => done(input.value.trim() || null);
    $("modal-cancel").onclick = () => done(null);
    input.onkeydown = (e) => {
      if (e.key === "Enter") done(input.value.trim() || null);
      else if (e.key === "Escape") done(null);
    };
    overlay.onclick = (e) => {
      if (e.target === overlay) done(null);
    };
  });
}

/* ---------- lightweight context menu ---------- */
/* Items are `{label, onClick}`, plus two optional shapes: `{header}` for a
   non-clickable group title, and `sublabel` for a second, dimmer line. */
function renderMenu(menu, items) {
  menu.innerHTML = "";
  for (const it of items) {
    if (it.header) {
      const head = document.createElement("div");
      head.className = "context-header";
      head.textContent = it.header;
      menu.appendChild(head);
      continue;
    }
    const el = document.createElement("div");
    el.className =
      "context-item" + (it.danger ? " danger" : "") + (it.current ? " current" : "");
    // 带 icon 键的菜单项留一个图标位。没图标的用 visibility 占住，不然同一份菜单里
    // 有图标和没图标的两行文字会错开。
    if ("icon" in it) {
      el.classList.add("with-icon");
      const img = document.createElement("img");
      img.className = "context-icon";
      img.alt = "";
      if (it.icon) img.src = it.icon;
      else img.style.visibility = "hidden";
      el.appendChild(img);
    }
    if (it.sublabel) {
      const label = document.createElement("div");
      label.className = "context-label";
      label.textContent = it.label;
      const sub = document.createElement("div");
      sub.className = "context-sub";
      sub.textContent = it.sublabel;
      el.append(label, sub);
    } else {
      const label = document.createElement("span");
      label.textContent = it.label;
      el.appendChild(label);
    }
    if (it.submenu) {
      el.classList.add("has-sub");
      el.onmouseenter = () => showSubmenu(menu, el, it.submenu);
      // 父项自己不做事，也不能让点击冒到 document 上把整个菜单关掉。
      el.onclick = (e) => e.stopPropagation();
    } else {
      el.onclick = () => {
        hideMenu();
        it.onClick();
      };
    }
    menu.appendChild(el);
  }
}

/* 定位后再量尺寸：菜单从工具栏最右边的按钮弹出来时，照给定坐标放会有半截在窗口外。 */
function placeMenu(menu, x, y) {
  menu.style.left = "0px";
  menu.style.top = "0px";
  menu.style.display = "block";
  menu.style.left = `${Math.max(4, Math.min(x, innerWidth - menu.offsetWidth - 4))}px`;
  menu.style.top = `${Math.max(4, Math.min(y, innerHeight - menu.offsetHeight - 4))}px`;
}

function showMenu(x, y, items) {
  hideSubmenu();
  const menu = $("context-menu");
  renderMenu(menu, items);
  // 悬停到别的项上才收起二级菜单，而且是延迟收：鼠标斜着往二级菜单挪的路上一定会
  // 蹭过下面那一项，立刻收的话菜单在手伸到之前就没了。
  menu.onmouseover = (e) => {
    const item = e.target.closest(".context-item");
    if (item && !item.classList.contains("has-sub")) hideSubmenuSoon();
  };
  placeMenu(menu, x, y);
}

/* 二级菜单是独立浮层，不是一级菜单的子元素：一级菜单有 overflow-y: auto，
   嵌进去的绝对定位元素会被裁掉。 */
function showSubmenu(parentMenu, item, items) {
  clearTimeout(submenuTimer);
  const menu = $("context-submenu");
  renderMenu(menu, items);
  menu.onmouseover = () => clearTimeout(submenuTimer); // 进来了就别再收
  const r = item.getBoundingClientRect();
  // 贴着一级菜单面板的右外沿，纵向和触发它的那一项对齐（减掉面板的内边距和描边）。
  placeMenu(menu, parentMenu.getBoundingClientRect().right + 2, r.top - 5);
}

let submenuTimer = null;

function hideSubmenu() {
  clearTimeout(submenuTimer);
  $("context-submenu").style.display = "none";
}

/* 给鼠标留出横跨两个面板的时间，中途进了二级菜单就取消。 */
function hideSubmenuSoon() {
  clearTimeout(submenuTimer);
  submenuTimer = setTimeout(hideSubmenu, 300);
}

function hideMenu() {
  $("context-menu").style.display = "none";
  hideSubmenu();
}

const $ = (id) => document.getElementById(id);

/* Hook output (lint-staged, pre-commit) is many lines long and the bar is one
   line: the part that says what actually failed is the part that gets cut. Keep
   the full text and let a click open it. */
let statusFull = "";

/* Three ways to say something, pick by how much the user has to do about it:
   1. setStatus(msg)          — 状态栏。结果和进度，看不看都不耽误事。
   2. notify(msg)             — 弹窗 + 确定。一句话，必须点掉。
   3. setStatus(msg, true)    — 弹窗 + 复制 + 确定。报错，后面通常跟着 git 输出。
   Everything lands in the status bar either way; the box is what differs. */
function setStatus(msg, isError = false) {
  const bar = $("status-bar");
  statusFull = String(msg);
  bar.textContent = statusFull;
  bar.className = "status-bar" + (isError ? " error" : "");
  bar.onclick = () => {
    // Nothing hidden, nothing to open — don't offer a click that shows the
    // same line the bar is already showing.
    if (bar.classList.contains("clickable")) showStatusDetail();
  };
  bar.classList.toggle("clickable", bar.scrollWidth > bar.clientWidth);
  // A line in the status bar is easy to miss, and a failure that goes unnoticed
  // reads as "cgit did nothing" — so every error also opens a box that has to
  // be dismissed by hand.
  if (isError) announce(statusFull, true);
}

/* A short notice the user must acknowledge: something they asked for did not
   happen, and nothing else on screen says so. Plain results and progress stay
   in the bar; anything with git output behind it goes through setStatus's
   error path, which adds 复制. */
function notify(msg) {
  setStatus(msg);
  announce(msg);
}

function showStatusDetail(text = statusFull) {
  if (!text) return;
  showTextModal(text, { title: "详细信息", copy: true });
}

let msgBox = null;

/* Every notice worth seeing lands in one centred box that stays until the user
   dismisses it. Repeats fold into the box already open — clicking 提交 five
   times on a clean tree used to stack five of them — and an error arriving
   while it is up turns the whole box into an error. */
function announce(text, isError = false) {
  if (msgBox && document.body.contains(msgBox.overlay)) {
    msgBox.add(text, isError);
    return;
  }
  msgBox = showTextModal(text, { isError });
}

/* One box for "here is some text": the status bar's detail view and the error
   box differ only in title and button. `dialog-overlay` + `onEsc` puts it in
   the Esc chain, so Escape closes the top box and leaves the commit dialog
   underneath it open. */
function showTextModal(text, { title = null, isError = false, copy = isError } = {}) {
  const texts = [text];
  let error = isError;

  const overlay = document.createElement("div");
  overlay.className = "modal-overlay dialog-overlay";

  const box = document.createElement("div");
  box.className = "modal status-modal";

  const titleEl = document.createElement("div");

  const body = document.createElement("pre");
  body.className = "status-detail";

  const copyBtn = document.createElement("button");
  copyBtn.textContent = "复制";
  // Reads the box, not the original text: an error box collects later errors too.
  copyBtn.onclick = async () => {
    copyBtn.textContent = (await copyText(body.textContent)) ? "已复制" : "复制失败";
  };

  const render = () => {
    titleEl.className = "modal-title" + (error ? " error" : "");
    titleEl.textContent = title ?? (error ? "出错了" : "提示");
    body.textContent = texts.join("\n\n");
    // 复制 only where there is something worth copying — an error, or the
    // status bar's full text. A one-line 提示 gets 确定 alone.
    copyBtn.hidden = !copy && !error;
  };
  /* One repo failing to fetch is one line; four repos failing is four lines in
     the same box, and the same line twice is still one line. */
  const add = (more, asError) => {
    if (asError) error = true;
    if (!texts.includes(more)) texts.push(more);
    render();
  };
  render();

  const actions = document.createElement("div");
  actions.className = "modal-actions";

  const closeBtn = document.createElement("button");
  closeBtn.className = "primary";
  closeBtn.textContent = "确定";

  const close = () => overlay.remove();
  closeBtn.onclick = close;
  overlay.onEsc = close;
  overlay.onclick = (e) => {
    if (e.target === overlay) close();
  };

  actions.append(copyBtn, closeBtn);
  box.append(titleEl, body, actions);
  overlay.appendChild(box);
  document.body.appendChild(overlay);
  closeBtn.focus(); // Enter dismisses it
  return { overlay, body, close, add };
}

function escapeHtml(s) {
  return s.replace(
    /[&<>"]/g,
    (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c],
  );
}

async function openRepoDialog() {
  const selected = await open({ directory: true, title: "选择一个 Git 仓库" });
  if (!selected) return;
  await openRepoByPath(selected);
}

/** Returns whether the workspace actually opened, so startup can fall back. */
async function openRepoByPath(path) {
  try {
    const ws = await invoke("open_workspace", { path });
    // A different project must not inherit the previous one's diff, nor the
    // commit message typed (or AI-generated) for it, nor a panel docked for a
    // repo the new workspace does not have.
    undockCommitPanel();
    hideDiffArea();
    $("commit-msg").value = "";
    $("author-input").value = "";
    $("author-input").placeholder = "名字 <邮箱>";
    commitIdentityGen++;
    $("amend-cb").checked = false;
    repos = ws.repos;
    repoPath = ws.repos[0].path;
    graphLimit = prefs.historyPageSize;
    for (const id of [
      "open-commit-btn",
      "fetch-btn",
      "pull-btn",
      "push-btn",
      "commit-btn",
      "commit-more-btn",
      "commit-history-btn",
      "ai-msg-btn",
      "open-project-btn",
      "open-project-menu-btn",
    ]) {
      $(id).disabled = false;
    }
    // Remember what the user picked, not what it resolved to, so reopening a
    // workspace folder reopens the workspace rather than its first repo.
    workspaceRoot = isMulti() ? ws.root : repoPath;
    addRecent(workspaceRoot);
    showProjectEditorIcon();
    renderRepos();
    await refreshAll();
    setStatus(isMulti() ? `已打开工作区：${repos.length} 个仓库` : "已打开仓库");
    backgroundFetch();
    return true;
  } catch (e) {
    // Deliberately does NOT prune the recent entry. It used to, and any single
    // failure — a transient one, or a bug in our own setup code below the
    // invoke — silently wiped the remembered repo, so the next launch came up
    // with nothing open and the changes list looked empty. A stale entry that
    // no longer opens is a visible annoyance; losing the entry is invisible.
    setStatus(`打开失败：${e}`, true);
    return false;
  }
}

function renderRepos() {
  $("repos-section").style.display = isMulti() ? "" : "none";
  const list = $("repos");
  list.innerHTML = "";
  for (const r of repos) {
    const li = document.createElement("li");
    li.className = r.path === repoPath ? "current" : "";
    li.title = `${r.path}\n右键切换分支`;
    const name = document.createElement("span");
    name.textContent = r.name;
    const branch = document.createElement("span");
    branch.className = "repo-branch";
    branch.textContent = r.branch;
    li.append(name);
    if (dirtyRepos.has(r.path)) {
      const dirty = document.createElement("span");
      dirty.className = "repo-dirty";
      dirty.textContent = "*";
      dirty.title = "有未提交的改动";
      li.append(dirty);
    }
    li.append(branch);
    li.onclick = () => openRepoCommit(r.path);
    li.oncontextmenu = (e) => {
      e.preventDefault();
      showRepoBranchMenu(r, e.clientX, e.clientY);
    };
    list.appendChild(li);
  }
  updateRepoLabel();
}

function labelMark(cls, text, title) {
  const el = document.createElement("span");
  el.className = cls;
  el.textContent = text;
  el.title = title;
  return el;
}

function updateRepoLabel() {
  const active = repos.find((r) => r.path === repoPath);
  if (!active) return;
  // Full path and branch on the left, short project name on the centre pill.
  $("repo-label").textContent = isMulti()
    ? `${active.path}   ·   ${active.branch}   （工作区共 ${repos.length} 个仓库）`
    : `${active.path}   ·   ${active.branch}`;
  $("project-name").textContent = isMulti()
    ? `${projectName(workspaceRoot ?? active.path)} / ${active.name}`
    : active.name;
  $("project-btn").title = isMulti()
    ? `${active.path}\n工作区共 ${repos.length} 个仓库`
    : `${active.path}   ·   ${active.branch}`;
  $("amend-label").textContent = isMulti() ? `修正提交（仅 ${active.name}）` : "修正提交";
}

/* Switching the active repo only re-aims the single-repo panels; the changes
   list already shows every repo, so it does not need reloading. */
async function setActiveRepo(path) {
  if (path === repoPath) return;
  repoPath = path;
  hideDiffArea(); // the open diff belongs to the repo we're leaving
  renderRepos();
  const gen = ++refreshGen;
  await Promise.all([
    refreshBranches(gen),
    refreshLog(gen),
    refreshRemotes(gen),
    refreshRemoteList(gen),
    refreshTags(gen),
    refreshStash(gen),
  ]);
  setStatus(`当前仓库：${repoName(path)}`);
}

/* ---------- refresh coordination ----------
   Each refresh round gets a generation number. A round that finishes after a
   newer one started discards its results, so bursts of file-watcher events
   can't paint stale data over fresh data. */
let refreshGen = 0;
const isStale = (gen) => gen !== refreshGen;

/* The same idea for the diff pane, on its own counter: clicking a file fires a
   git call, and clicking the next one before it lands must not let the first
   response paint over the second — the pane would show file A under file B's
   title, which reads as "the click did nothing". Separate from refreshGen so a
   background refresh doesn't discard the diff you are looking at. */
let diffGen = 0;
const isStaleDiff = (gen) => gen !== diffGen;

async function refreshAll() {
  const gen = ++refreshGen;
  await Promise.all([
    refreshChanges(gen),
    refreshRepoBranches(gen),
    refreshBranches(gen),
    refreshLog(gen),
    refreshRemotes(gen),
    refreshRemoteList(gen),
    refreshTags(gen),
    refreshStash(gen),
    refreshConflicts(gen),
  ]);
}

/* A working-tree change only affects these three; skip the expensive graph and
   the rarely-changing remotes/tags. */
async function refreshLight() {
  const gen = ++refreshGen;
  await Promise.all([refreshChanges(gen), refreshBranches(gen), refreshConflicts(gen)]);
}

/* Status of every repo in the workspace, fetched in parallel. A repo that fails
   to read reports itself rather than taking the whole list down with it. */
async function statusByRepo(useFilter = true) {
  const needle = useFilter ? $("changes-filter").value.trim().toLowerCase() : "";
  const results = await Promise.all(
    repos.map(async (r) => {
      try {
        let files = await invoke("get_status", { path: r.path });
        // `total` is the count before filtering: the * in the repo list means
        // "this repo has changes", not "has changes matching the filter box".
        const total = files.length;
        // 过滤前算：补丁导的是所有已暂存的改动，跟过滤框里打了什么无关。
        const staged = files.filter((f) => f.staged).length;
        if (needle) files = files.filter((f) => f.path.toLowerCase().includes(needle));
        return { repo: r, files, total, staged, error: null };
      } catch (e) {
        return { repo: r, files: [], total: 0, staged: 0, error: String(e) };
      }
    }),
  );
  return { results, needle };
}

async function refreshChanges(gen = ++refreshGen) {
  const list = $("changes");
  const { results, needle } = await statusByRepo();
  if (isStale(gen)) return;
  // #changes is the scroller itself, so emptying it below sends it back to the
  // top — halfway down a long list, every watcher event yanked the view away.
  const scrollTop = list.scrollTop;

  dirtyRepos = new Set(results.filter((r) => r.total > 0).map((r) => r.repo.path));
  renderRepos();
  // The dirty marks above come from every repo; the list itself shows only the
  // docked repo while the commit panel is scoped to one.
  const shown = results.filter(inScope);
  // 没勾任何文件就没得导，按钮灰着 —— 补丁的内容正是勾上的那些。
  $("patch-btn").disabled = !results.find((r) => r.repo.path === repoPath)?.staged;

  // Remember which file was selected so a refresh (e.g. after staging a hunk)
  // doesn't reset the ↑/↓ position.
  const prevKey = navFiles[navIndex]?.key ?? null;
  navFiles = [];

  list.innerHTML = "";
  if (!repos.length) {
    // Distinct from a clean worktree: claiming "clean" with no repo open sent
    // us hunting for a bug in the status code that was never there.
    list.innerHTML = '<li class="empty">未打开仓库 — 点工具栏「打开仓库」</li>';
    return;
  }
  const total = shown.reduce((n, r) => n + r.files.length, 0);
  const failed = shown.filter((r) => r.error);
  if (total === 0 && !failed.length) {
    list.innerHTML = `<li class="empty">${needle ? "没有匹配的文件" : "工作区干净"}</li>`;
    return;
  }

  for (const { repo, files, error } of shown) {
    // With one repo there's no hierarchy worth drawing.
    if (isMulti() && (files.length || error)) {
      const head = document.createElement("li");
      head.className = "repo-group" + (repo.path === repoPath ? " current" : "");
      head.title = `${repo.path}（点击设为当前仓库）`;
      const name = document.createElement("span");
      name.textContent = `${repo.name} · ${files.length} 个文件`;
      const branch = document.createElement("span");
      branch.className = "repo-branch";
      branch.textContent = repo.branch;
      head.append(name, branch);
      head.onclick = () => setActiveRepo(repo.path);
      list.appendChild(head);
    }
    if (error) {
      const li = document.createElement("li");
      li.className = "empty";
      li.textContent = `读取失败：${error}`;
      list.appendChild(li);
      continue;
    }

    // The same file can appear on both sides — staged one edit, then edited
    // again. Group by side, because two identical-looking rows differing only
    // by a checkbox is not something anyone should have to decode.
    const groups = [
      ["冲突", files.filter((f) => f.status === "conflict")],
      ["已暂存", files.filter((f) => f.staged)],
      ["未暂存", files.filter((f) => !f.staged && f.status !== "conflict")],
    ];
    for (const [label, group] of groups) {
      if (!group.length) continue;
      const head = document.createElement("li");
      head.className = "group-label" + (isMulti() ? " changes-indent" : "");
      head.textContent = `${label} (${group.length})`;
      list.appendChild(head);
      for (const f of group) {
        const index = navFiles.length;
        const row = changeRow(f, repo.path, index);
        navFiles.push({
          // The key distinguishes the staged and unstaged rows of one path,
          // which the display label deliberately does not.
          key: row.dataset.fileKey,
          label: (isMulti() ? `${repo.name}/` : "") + f.path,
          open: () =>
            f.status === "conflict"
              ? showConflict(f.path, repo.path)
              : showDiff(f.path, f.staged, repo.path),
        });
        list.appendChild(row);
      }
    }
  }
  navIndex = prevKey ? navFiles.findIndex((e) => e.key === prevKey) : -1;
  applyFileSelection();
  list.scrollTop = scrollTop;
  applyBranchDirtyMark();
}

/* The * on the current-branch row comes from here, but refreshChanges and
   refreshBranches run in parallel — whichever finishes last has to put it on. */
function applyBranchDirtyMark() {
  const row = document.querySelector("#branches li.current");
  if (!row) return;
  const mark = row.querySelector(".repo-dirty");
  const dirty = dirtyRepos.has(repoPath);
  if (dirty && !mark) {
    row.insertBefore(labelMark("repo-dirty", "*", "有未提交的改动"), row.querySelector(".tracking"));
  } else if (!dirty && mark) {
    mark.remove();
  }
}

function changeRow(f, repo = repoPath, navIdx = -1) {
  const li = document.createElement("li");
  li.className = "change-item" + (isMulti() ? " changes-indent" : "");
  li.dataset.fileKey = `${repo}|${f.path}|${f.staged}`;
  const conflict = f.status === "conflict";

  const cb = document.createElement("input");
  cb.type = "checkbox";
  cb.checked = f.staged;
  cb.disabled = conflict;
  cb.title = conflict ? "先解决冲突" : f.staged ? "取消暂存" : "暂存";
  cb.onclick = async (ev) => {
    ev.stopPropagation();
    try {
      await invoke(f.staged ? "unstage_file" : "stage_file", {
        path: repo,
        file: f.path,
      });
      await refreshChanges();
    } catch (e) {
      setStatus(String(e), true);
    }
  };

  const badge = document.createElement("span");
  badge.className = `badge ${f.status}`;
  badge.textContent = conflict ? "!" : f.status[0].toUpperCase();

  const name = document.createElement("span");
  name.className = "file-name";
  name.textContent = f.path;

  li.append(cb, badge, name);
  // Discarding restores the worktree from the index, so it means nothing on a
  // staged row — only offer it where it does something.
  if (!f.staged && !conflict) {
    const discard = document.createElement("button");
    discard.className = "discard-btn";
    discard.textContent = "丢弃";
    discard.title = "丢弃工作区改动";
    discard.onclick = (ev) => discardFile(f.path, ev, repo);
    li.appendChild(discard);
  }

  /* mousedown, not click: the watcher rebuilds this list from scratch, and a
     rebuild landing between press and release detaches the row, so the click
     never reaches it and the file just doesn't open. Acting on press also
     matches how a file list is expected to feel. The checkbox and 丢弃 keep
     their own click handlers — a press on them is not a press on the row. */
  li.onmousedown = (ev) => {
    if (ev.button !== 0 || ev.target.closest("input, button")) return;
    navIndex = navIdx; // clicking a file is where ↑/↓ continues from
    selectFileRow(li.dataset.fileKey);
    return conflict ? showConflict(f.path, repo) : showDiff(f.path, f.staged, repo);
  };
  li.oncontextmenu = (e) => {
    e.preventDefault();
    showMenu(e.clientX, e.clientY, fileMenuItems(f.path, !f.staged && !conflict, repo));
  };
  return li;
}

/* Two mechanisms, because WKWebView is stricter than Chromium about the async
   clipboard API and refusing silently would look like the menu item did
   nothing. The textarea trick needs the user gesture we are already inside. */
/* 复制走 Rust 的 pbcopy，不用 navigator.clipboard / execCommand：WKWebView 里只要复制
   不是紧挨着用户手势那一拍发生（这里要先 invoke 去取补丁内容），两者都会拒绝。
   失败原因在这里就报出来 —— 以前这函数把异常吞了，界面只剩一句「复制失败」。 */
async function copyText(text) {
  try {
    await invoke("write_clipboard", { text });
    return true;
  } catch (e) {
    setStatus(`复制失败：${e}`, true);
    return false;
  }
}

/* The absolute path: a bare `app/core/redis_keys.py` is not much use anywhere
   outside this repo, and in a workspace it does not even say which repo. */
async function copyFilePath(file, repo = repoPath) {
  const full = `${repo}/${file}`;
  if (await copyText(full)) setStatus(`已复制 ${full}`);
}

/* The file the row points at, in whatever editor the settings name. Past-commit
   rows go through here too: they open the working-tree copy, and a file that no
   longer exists there reports that rather than opening something stale. */
async function openInEditor(file, repo = repoPath) {
  try {
    await invoke("open_in_editor", { path: repo, file, editor: prefs.editor });
    setStatus(`已在编辑器中打开 ${file}`);
  } catch (e) {
    setStatus(String(e), true);
  }
}

/* Same editor the toolbar's 打开项目 uses — this is that button plus the file. */
async function openProjectAtFile(file, repo = repoPath) {
  try {
    await invoke("open_project_with_file", {
      project: workspaceRoot,
      path: repo,
      file,
      editor: projectEditor(),
    });
    setStatus(`已在 ${editorLabel(projectEditor())} 中打开项目并定位 ${file}`);
  } catch (e) {
    setStatus(String(e), true);
  }
}

function fileMenuItems(file, canDiscard, repo = repoPath) {
  const items = [
    { label: "从项目打开", onClick: () => openProjectAtFile(file, repo) },
    { label: "编辑文件", onClick: () => openInEditor(file, repo) },
    { label: "复制文件路径", onClick: () => copyFilePath(file, repo) },
    { label: "文件历史", onClick: () => showFileHistory(file, repo) },
    { label: "逐行归属 (blame)", onClick: () => showBlame(file, repo) },
  ];
  if (canDiscard) {
    items.push({
      label: "丢弃改动",
      danger: true,
      onClick: () => discardFile(file, new Event("click"), repo),
    });
  }
  return items;
}

/* With a filter active this means "everything I can see", not "the whole repo"
   — staging rows that are scrolled out of a filter would be a nasty surprise. */
/* Applies to every repo in the workspace. With a filter active it means
   "everything I can see" — staging rows hidden by a filter would be a nasty
   surprise. */
async function stageAll(stage) {
  if (!repoPath) return;
  const { results, needle } = await statusByRepo();
  const cmd = stage ? "stage_all" : "unstage_all";
  const done = [];
  const failed = [];
  let touched = 0;

  for (const { repo, files } of results.filter(inScope)) {
    // No filter: hand the backend an empty list so it uses one bulk git call.
    const paths = needle
      ? files.filter((f) => f.status !== "conflict").map((f) => f.path)
      : [];
    if (needle && !paths.length) continue;
    if (!needle && !files.length) continue;
    try {
      await invoke(cmd, { path: repo.path, files: paths });
      done.push(repo.name);
      touched += needle ? paths.length : files.length;
    } catch (e) {
      failed.push(`${repo.name}: ${e}`);
    }
  }

  await refreshChanges();
  if (!done.length && !failed.length) {
    setStatus(needle ? "过滤结果为空，没有可操作的文件" : "没有可操作的改动", true);
    return;
  }
  const verb = stage ? "已暂存" : "已取消暂存";
  const scope = isMulti() ? `${done.length} 个仓库共 ${touched} 个文件` : `${touched} 个文件`;
  if (failed.length) {
    setStatus(`${verb}${scope}；失败：${failed.join("；")}`, true);
  } else {
    setStatus(`${verb}${scope}`);
  }
}

/* Keeps the sidebar's per-repo branch labels honest after a checkout. */
async function refreshRepoBranches(gen = ++refreshGen) {
  await Promise.all(
    repos.map(async (r) => {
      try {
        const branches = await invoke("get_branches", { path: r.path });
        const current = branches.find((b) => b.is_current);
        r.branch = current ? current.name : "（分离 HEAD）";
      } catch {
        /* leave the last known branch in place */
      }
    }),
  );
  if (isStale(gen)) return;
  renderRepos();
}

async function refreshBranches(gen = ++refreshGen) {
  const list = $("branches");
  const branches = await invoke("get_branches", { path: repoPath });
  let tracking = null;
  try {
    tracking = await invoke("get_branch_tracking", { path: repoPath });
  } catch {
    /* ignore */
  }
  if (isStale(gen)) return;
  list.innerHTML = "";
  const currentName = branches.find((b) => b.is_current)?.name;
  for (const b of branches) {
    const li = document.createElement("li");
    li.className = b.is_current ? "current" : "";

    const nameSpan = document.createElement("span");
    nameSpan.textContent = b.name;
    li.appendChild(nameSpan);

    /* The checked-out branch carries the repo's state: * for uncommitted work,
       ↑N for commits waiting to be pushed. A single repo draws no 仓库 list and
       keeps its changes inside the commit dialog, so without these there was
       nothing on screen saying either. Zeros are left out — `↓0` is noise. */
    if (b.is_current) {
      if (dirtyRepos.has(repoPath)) {
        li.appendChild(labelMark("repo-dirty", "*", "有未提交的改动"));
      }
      if (tracking && tracking.ahead) {
        li.appendChild(
          labelMark("tracking ahead", `↑${tracking.ahead}`, `${tracking.ahead} 个提交待推送`),
        );
      }
      if (tracking && tracking.behind) {
        li.appendChild(
          labelMark("tracking", `↓${tracking.behind}`, `${tracking.behind} 个提交待拉取`),
        );
      }
    }

    li.onclick = () => switchBranch(b.name);
    /* The branch already checked out drops the two items that would do nothing
       on it: checking it out again, and merging it into itself. The patch items
       go the other way — a patch lands in the working tree, and that only ever
       belongs to the checked-out branch, so offering them elsewhere would either
       lie or smuggle in a checkout. */
    li.oncontextmenu = (e) => {
      e.preventDefault();
      showMenu(e.clientX, e.clientY, [
        ...(b.is_current ? [] : [{ label: "检出", onClick: () => switchBranch(b.name) }]),
        { label: `从 '${b.name}' 新建分支…`, onClick: () => newBranch(b.name) },
        ...(b.is_current || !currentName
          ? []
          : [
              {
                label: `将 '${b.name}' 合并到 '${currentName}' 中`,
                onClick: () => mergeBranch(b.name),
              },
            ]),
        { label: "更新", onClick: () => updateBranch(b.name, b.is_current) },
        // The ellipsis is the app's mark for "opens a dialog", which pushing
        // the current branch of a workspace does and pushing another does not.
        {
          label: b.is_current ? "推送…" : "推送",
          onClick: () => pushBranch(b.name, b.is_current),
        },
        ...(b.is_current
          ? [
              {
                label: "应用补丁",
                submenu: [
                  { label: "从补丁文件…", onClick: applyPatchFromFile },
                  { label: "从剪贴板", onClick: applyPatchFromClipboard },
                ],
              },
            ]
          : []),
        { label: "重命名…", onClick: () => renameBranch(b.name) },
        { label: "删除", danger: true, onClick: () => deleteBranch(b.name) },
      ]);
    };
    list.appendChild(li);
  }
}

async function switchBranch(name, path = repoPath) {
  try {
    await invoke("checkout_branch", { path, name });
    await refreshAll();
    setStatus(path === repoPath ? `已切换到 ${name}` : `${repoName(path)} 已切换到 ${name}`);
  } catch (e) {
    setStatus(String(e), true);
  }
}

/* 右键仓库列表里的一项：列出该仓库的本地和远端分支，点一下就在那个仓库里切换。
   只切分支，不改当前选中的仓库，其余面板照旧跟着 repoPath。 */
async function showRepoBranchMenu(repo, x, y) {
  let locals = [];
  let remotes = [];
  try {
    locals = await invoke("get_branches", { path: repo.path });
    remotes = await invoke("get_remote_branches", { path: repo.path });
  } catch (e) {
    setStatus(String(e), true);
    return;
  }
  const items = [{ header: `${repo.name} · 本地分支` }];
  for (const b of locals) {
    if (b.is_current) {
      items.push({ label: b.name, current: true, onClick: () => {} });
      continue;
    }
    items.push({ label: b.name, onClick: () => switchBranch(b.name, repo.path) });
  }
  // 远端分支照 git 的原样全列出来，跟「远端分支」面板对得上；跟本地同名也不省，
  // 省掉反而让人以为那条远端分支不存在。
  if (remotes.length) {
    items.push({ header: "远端分支" });
    for (const full of remotes) {
      items.push({
        label: full,
        onClick: () => checkoutRef(splitRemoteRef(full).branch, full, repo.path),
      });
    }
  }
  showMenu(x, y, items);
}

/* A branch can start at HEAD (the + button), at another local branch, or at a
   remote one — `base` is whatever it starts from, and the caller supplies the
   suggested name because only it knows whether `base` has a remote prefix to
   strip. Branching off a remote branch tracks it; see create_branch. */
async function newBranch(base = null, suggestion = "") {
  if (!repoPath) return;
  const name = await textPrompt(base ? `基于 ${base} 新建分支` : "新分支名称", suggestion);
  if (!name) return;
  try {
    await invoke("create_branch", { path: repoPath, name, checkout: true, base });
    await refreshAll();
    setStatus(base ? `已基于 ${base} 创建并切换到 ${name}` : `已创建并切换到 ${name}`);
  } catch (e) {
    setStatus(String(e), true);
  }
}

/* IDEA's 更新 on a branch: bring it level with its upstream. The current
   branch is a plain pull of this repo (the 拉取 button covers the workspace);
   any other branch is fast-forwarded in place, no checkout involved. */
async function updateBranch(name, isCurrent) {
  setStatus(`更新 ${name}…`);
  try {
    const out = isCurrent
      ? await invoke("git_pull", { path: repoPath, strategy: prefs.pullStrategy })
      : await invoke("update_branch", { path: repoPath, name });
    await refreshAll();
    setStatus(out.trim() || `已更新 ${name}`);
  } catch (e) {
    setStatus(String(e), true);
  }
}

/* IDEA's 推送 on a branch. The current branch goes through the normal push
   path, dialog and all; another branch is pushed in place — the one thing the
   push dialog cannot do, since git push only ever pushes HEAD. */
async function pushBranch(name, isCurrent) {
  if (isCurrent) return pushAction();
  setStatus(`推送 ${name}…`);
  try {
    const out = await invoke("push_branch", { path: repoPath, name });
    await refreshAll();
    setStatus(out.trim() || `已推送 ${name}`);
  } catch (e) {
    setStatus(String(e), true);
  }
}

async function renameBranch(name) {
  const newName = await textPrompt("重命名分支", name);
  if (!newName || newName === name) return;
  try {
    await invoke("rename_branch", { path: repoPath, name, newName });
    await refreshAll();
    setStatus(`已重命名 ${name} → ${newName}`);
  } catch (e) {
    setStatus(String(e), true);
  }
}

async function deleteBranch(name) {
  const ok = await ask(`删除分支 "${name}"？`, { title: "删除分支", kind: "warning" });
  if (!ok) return;
  try {
    await invoke("delete_branch", { path: repoPath, name });
    await refreshAll();
    setStatus(`已删除 ${name}`);
  } catch (e) {
    setStatus(String(e), true);
  }
}

async function refreshRemotes(gen = ++refreshGen) {
  const list = $("remotes");
  let remotes = [];
  try {
    remotes = await invoke("get_remote_branches", { path: repoPath });
  } catch {
    /* ignore */
  }
  if (isStale(gen)) return;
  list.innerHTML = "";
  if (!remotes.length) {
    list.innerHTML = '<li class="empty">—</li>';
    return;
  }
  for (const name of remotes) {
    const li = document.createElement("li");
    li.textContent = name;
    li.title = `检出 ${name}`;
    // strip the remote prefix so git DWIMs a local tracking branch
    li.onclick = () => checkoutRef(splitRemoteRef(name).branch, name);
    li.oncontextmenu = (e) => {
      e.preventDefault();
      showMenu(e.clientX, e.clientY, [
        { label: "检出", onClick: () => checkoutRef(splitRemoteRef(name).branch, name) },
        {
          // Checkout above reuses the remote's own name; this one is for any
          // other name, and tracks the remote branch either way.
          label: `从 '${name}' 新建分支…`,
          sublabel: `跟踪 ${name}`,
          onClick: () => newBranch(name, splitRemoteRef(name).branch),
        },
        { label: "删除远端分支", danger: true, onClick: () => deleteRemoteBranch(name) },
      ]);
    };
    list.appendChild(li);
  }
}

async function refreshTags(gen = ++refreshGen) {
  const list = $("tags");
  let tags = [];
  try {
    tags = await invoke("get_tags", { path: repoPath });
  } catch {
    /* ignore */
  }
  if (isStale(gen)) return;
  list.innerHTML = "";
  if (!tags.length) {
    list.innerHTML = '<li class="empty">—</li>';
    return;
  }
  for (const name of tags) {
    const li = document.createElement("li");
    li.textContent = name;
    li.title = `检出标签 ${name}（分离 HEAD）`;
    li.onclick = () => checkoutRef(name, name);
    li.oncontextmenu = (e) => {
      e.preventDefault();
      showMenu(e.clientX, e.clientY, [
        { label: "检出（分离 HEAD）", onClick: () => checkoutRef(name, name) },
        { label: "推送到 origin", onClick: () => pushTag(name) },
        { label: "删除标签", danger: true, onClick: () => deleteTag(name) },
      ]);
    };
    list.appendChild(li);
  }
}

async function checkoutRef(ref, label, path = repoPath) {
  if (!ref) return;
  try {
    await invoke("checkout_ref", { path, refName: ref });
    await refreshAll();
    setStatus(path === repoPath ? `已检出 ${label}` : `${repoName(path)} 已检出 ${label}`);
  } catch (e) {
    setStatus(String(e), true);
  }
}

/* ---------- stash ---------- */
async function refreshStash(gen = ++refreshGen) {
  const list = $("stash");
  let entries = [];
  try {
    entries = await invoke("stash_list", { path: repoPath });
  } catch {
    /* ignore */
  }
  if (isStale(gen)) return;
  list.innerHTML = "";
  if (!entries.length) {
    list.innerHTML = '<li class="empty">—</li>';
    return;
  }
  for (const s of entries) {
    const li = document.createElement("li");
    li.textContent = s.message;
    li.title = "右键查看操作";
    li.oncontextmenu = (e) => {
      e.preventDefault();
      showMenu(e.clientX, e.clientY, [
        { label: "弹出（应用并删除）", onClick: () => stashPop(s.index) },
        { label: "删除", danger: true, onClick: () => stashDrop(s.index) },
      ]);
    };
    list.appendChild(li);
  }
}

async function stashSave() {
  if (!repoPath) return;
  try {
    const out = await invoke("stash_save", { path: repoPath, message: "" });
    await refreshAll();
    setStatus(out.trim() || "已储藏改动");
  } catch (e) {
    setStatus(String(e), true);
  }
}

async function stashPop(index) {
  try {
    const out = await invoke("stash_pop", { path: repoPath, index });
    await refreshAll();
    setStatus(out.trim() || "已弹出储藏");
  } catch (e) {
    setStatus(String(e), true);
  }
}

async function stashDrop(index) {
  const ok = await ask("确定删除该储藏？", { title: "删除储藏", kind: "warning" });
  if (!ok) return;
  try {
    await invoke("stash_drop", { path: repoPath, index });
    await refreshAll();
    setStatus("已删除储藏");
  } catch (e) {
    setStatus(String(e), true);
  }
}

/* ---------- reset / revert / cherry-pick ---------- */
async function resetTo(oid, mode) {
  if (mode === "hard") {
    const ok = await ask(`Hard reset 到 ${oid.slice(0, 7)}？工作区未提交的改动会丢失。`, {
      title: "Hard reset",
      kind: "warning",
    });
    if (!ok) return;
  }
  try {
    await invoke("reset_to", { path: repoPath, oid, mode });
    await refreshAll();
    setStatus(`已重置(${mode})到 ${oid.slice(0, 7)}`);
  } catch (e) {
    setStatus(String(e), true);
  }
}

/* These stop mid-way on conflict. Refresh either way, or the conflict panel
   only appears once the file watcher happens to fire. */
async function runOnCommit(cmd, oid, label) {
  try {
    const out = await invoke(cmd, { path: repoPath, oid });
    await refreshAll();
    setStatus(out.split("\n").find(Boolean) || `已${label} ${oid.slice(0, 7)}`);
  } catch (e) {
    await refreshAll();
    setStatus(String(e), true);
  }
}

const revertCommit = (oid) => runOnCommit("revert_commit", oid, "回退");
const cherryPick = (oid) => runOnCommit("cherry_pick", oid, "拣选");

/* ---------- history DAG ---------- */
const LANE_W = 14;
const ROW_H = 26;
const DOT_R = 4;
const LANE_COLORS = [
  "#3574f0", "#57965c", "#c9a76c", "#cd5b5b",
  "#9a6cc9", "#4ba6b0", "#c96c9a", "#8d9199",
];
const laneColor = (c) => LANE_COLORS[((c % LANE_COLORS.length) + LANE_COLORS.length) % LANE_COLORS.length];

function buildRowSvg(row, width) {
  const x = (c) => c * LANE_W + LANE_W / 2;
  const top = 0;
  const mid = ROW_H / 2;
  const bot = ROW_H;
  const parts = [];
  const link = (x1, y1, x2, y2, color) => {
    const my = (y1 + y2) / 2;
    parts.push(
      `<path d="M${x1} ${y1} C ${x1} ${my}, ${x2} ${my}, ${x2} ${y2}" ` +
        `stroke="${color}" fill="none" stroke-width="1.5"/>`,
    );
  };

  row.incoming.forEach((oid, c) => {
    if (oid == null) return;
    if (oid === row.commit.id) {
      link(x(c), top, x(row.myCol), mid, laneColor(c)); // merge into node
    } else {
      let dest = row.outgoing.indexOf(oid);
      if (dest === -1) dest = c;
      link(x(c), top, x(dest), bot, laneColor(c)); // pass through
    }
  });
  row.parentCols.forEach((pc) => link(x(row.myCol), mid, x(pc), bot, laneColor(pc)));

  parts.push(
    `<circle cx="${x(row.myCol)}" cy="${mid}" r="${DOT_R}" fill="${laneColor(row.myCol)}" ` +
      `stroke="#1b1c1e" stroke-width="1"/>`,
  );

  const svgW = width * LANE_W;
  return `<svg class="graph-svg" width="${svgW}" height="${ROW_H}" viewBox="0 0 ${svgW} ${ROW_H}">${parts.join("")}</svg>`;
}

let graphLimit = 100;

function commitMenu(c) {
  return [
    { label: "重置(mixed)到此", onClick: () => resetTo(c.id, "mixed") },
    { label: "重置(soft)到此", onClick: () => resetTo(c.id, "soft") },
    { label: "重置(hard)到此", danger: true, onClick: () => resetTo(c.id, "hard") },
    { label: "回退此提交", onClick: () => revertCommit(c.id) },
    { label: "拣选到当前分支", onClick: () => cherryPick(c.id) },
    { label: "从此处交互式变基", onClick: () => openRebaseModal(c.id) },
    { label: "在此提交上打标签…", onClick: () => newTag(c.id) },
    {
      label: "创建补丁",
      submenu: [
        { label: "到文件…", onClick: () => createCommitPatch(c, false) },
        { label: "到剪贴板", onClick: () => createCommitPatch(c, true) },
      ],
    },
  ];
}

function commitColumns(c) {
  const refsHtml = (c.refs ?? [])
    .map((r) => `<span class="ref ${r === "HEAD" ? "head" : ""}">${escapeHtml(r)}</span>`)
    .join("");
  return (
    `<span class="sha">${c.id.slice(0, 7)}</span>` +
    `<span class="c-subject">${refsHtml}${escapeHtml(c.summary)}</span>` +
    `<span class="c-author">${escapeHtml(c.author)}</span>` +
    `<span class="c-date">${new Date(c.time * 1000).toLocaleDateString()}</span>`
  );
}

/* Search results are a flat list on purpose: a filtered set of commits has no
   meaningful DAG to draw — the lines between them would be fiction. */
async function renderSearchResults(gen, query, author) {
  const list = $("log");
  let commits = [];
  try {
    commits = await invoke("search_commits", {
      path: repoPath,
      query,
      author,
      limit: graphLimit,
    });
  } catch (e) {
    setStatus(String(e), true);
    return;
  }
  if (isStale(gen)) return;
  list.innerHTML = "";
  if (!commits.length) {
    list.innerHTML = '<li class="empty">没有匹配的提交</li>';
    return;
  }
  for (const c of commits) {
    const li = document.createElement("li");
    li.className = "commit-item";
    li.innerHTML = commitColumns(c);
    li.onclick = () => showCommitDetail(c, li);
    li.oncontextmenu = (e) => {
      e.preventDefault();
      showMenu(e.clientX, e.clientY, commitMenu(c));
    };
    list.appendChild(li);
  }
  setStatus(`找到 ${commits.length} 个匹配的提交`);
}

async function refreshLog(gen = ++refreshGen) {
  const list = $("log");
  const query = $("log-search").value.trim();
  const author = $("log-author").value.trim();
  if (query || author) return renderSearchResults(gen, query, author);

  let commits = [];
  try {
    commits = await invoke("get_graph", { path: repoPath, limit: graphLimit });
  } catch (e) {
    setStatus(String(e), true);
    return;
  }
  if (isStale(gen)) return;
  const scrollTop = list.scrollTop; // #log is the scroller now, not the panel
  list.innerHTML = "";
  const { rows, width } = layoutGraph(commits);
  for (const row of rows) {
    const c = row.commit;
    const li = document.createElement("li");
    li.className = "commit-item graph-row";
    li.innerHTML =
      `<span class="graph-cell">${buildRowSvg(row, width)}</span>` + commitColumns(c);
    li.onclick = () => showCommitDetail(c, li);
    li.oncontextmenu = (e) => {
      e.preventDefault();
      showMenu(e.clientX, e.clientY, commitMenu(c));
    };
    list.appendChild(li);
  }

  if (commits.length >= graphLimit) {
    const more = document.createElement("li");
    more.className = "empty load-more";
    more.textContent = "加载更多…";
    more.style.cursor = "pointer";
    more.onclick = () => {
      graphLimit += 200;
      refreshLog();
    };
    list.appendChild(more);
  }

  list.scrollTop = scrollTop;
}

let selectedCommitEl = null;

function clearCommitSelection() {
  if (selectedCommitEl) selectedCommitEl.classList.remove("selected");
  selectedCommitEl = null;
}

async function showDiff(file, staged, repo = repoPath) {
  const gen = ++diffGen;
  showDiffArea();
  paneView = () => showDiff(file, staged, repo);
  setPaneBack(null);
  $("commit-files").style.display = "none";
  clearCommitSelection();
  const prefix = isMulti() ? `${repoName(repo)} / ` : "";
  $("diff-title").textContent = `${staged ? "已暂存" : "未暂存"} — ${prefix}${file}`;
  // Drop the previous file's diff now, so a slow git call reads as loading and
  // not as a click that was ignored. A fast one resolves before the next frame,
  // so this never flashes.
  $("diff").textContent = "加载中…";
  try {
    const { header, hunks } = await invoke("get_hunks", { path: repo, file, staged });
    if (isStaleDiff(gen)) return;
    if (hunks.length === 0) {
      // untracked / new / binary file: show plain content, no hunk buttons
      const cmd = staged ? "get_staged_diff" : "get_unstaged_diff";
      const text = await invoke(cmd, { path: repo, file });
      if (isStaleDiff(gen)) return;
      renderDiff(text);
    } else {
      renderHunks(file, staged, header, hunks, repo);
    }
    lastDiffRender = () => showDiff(file, staged, repo);
  } catch (e) {
    if (isStaleDiff(gen)) return;
    setStatus(String(e), true);
  }
}

async function discardFile(file, ev, repo = repoPath) {
  ev.stopPropagation();
  const ok = await ask(`丢弃对 "${file}" 的改动？此操作不可撤销。`, {
    title: "丢弃改动",
    kind: "warning",
  });
  if (!ok) return;
  try {
    await invoke("discard_changes", { path: repo, file });
    await refreshChanges();
    $("diff").innerHTML = "";
    setStatus(`已丢弃 ${file} 的改动`);
  } catch (e) {
    setStatus(String(e), true);
  }
}

async function showCommitDetail(commit, el) {
  const gen = ++diffGen;
  // A past commit and a docked commit panel are two different jobs; showing
  // both at once leaves half the window staging files you are not looking at.
  undockCommitPanel();
  showDiffArea();
  paneView = () => showCommitDetail(commit, el);
  setPaneBack(null);
  clearCommitSelection();
  if (el) {
    el.classList.add("selected");
    selectedCommitEl = el;
  }
  $("diff-title").textContent = `${commit.id.slice(0, 7)} · ${commit.summary}`;
  $("diff").innerHTML = "";
  const filesEl = $("commit-files");
  filesEl.style.display = "block";
  filesEl.innerHTML = "";
  try {
    const files = await invoke("get_commit_files", { path: repoPath, oid: commit.id });
    if (isStaleDiff(gen)) return;
    navFiles = [];
    navIndex = -1;
    if (files.length === 0) {
      filesEl.innerHTML = '<li class="empty">无文件改动</li>';
      return;
    }
    for (const f of files) {
      const li = document.createElement("li");
      li.className = "change-item";
      li.dataset.fileKey = `${commit.id}|${f.path}`;
      const badge = document.createElement("span");
      badge.className = `badge ${f.status}`;
      badge.textContent = f.status[0].toUpperCase();
      const name = document.createElement("span");
      name.className = "file-name";
      name.textContent = f.path;
      li.append(badge, name);
      const index = navFiles.length;
      navFiles.push({
        key: li.dataset.fileKey,
        label: f.path,
        open: () => showCommitDiff(commit.id, f.path),
      });
      li.onclick = () => {
        navIndex = index;
        selectFileRow(li.dataset.fileKey);
        return showCommitDiff(commit.id, f.path);
      };
      li.oncontextmenu = (e) => {
        e.preventDefault();
        showMenu(e.clientX, e.clientY, fileMenuItems(f.path, false, repoPath));
      };
      filesEl.appendChild(li);
    }
  } catch (e) {
    setStatus(String(e), true);
  }
}

async function showCommitDiff(oid, file, repo = repoPath) {
  const gen = ++diffGen;
  showDiffArea();
  $("diff").textContent = "加载中…";
  try {
    const diff = await invoke("get_commit_diff", { path: repo, oid, file });
    if (isStaleDiff(gen)) return;
    renderDiff(diff);
    lastDiffRender = () => showCommitDiff(oid, file, repo);
  } catch (e) {
    if (isStaleDiff(gen)) return;
    setStatus(String(e), true);
  }
}

/* Re-runs whatever produced the diff currently on screen, so toggling the view
   doesn't require remembering how we got here. */
let lastDiffRender = null;

/* The pane-owning view on screen (file diff / commit detail / conflict), and
   the one the ← arrow returns to. File history and blame take over the whole
   pane, so without this the only way out is ✕, which closes everything. */
let paneView = null;
let paneBack = null;

function setPaneBack(fn) {
  paneBack = fn;
  $("diff-back-btn").hidden = !fn;
}

/* ---------- change navigation ----------
   `changeBlocks` holds the first element of each contiguous run of changed
   lines — what IDEA's ↑/↓ step through, rather than every single line.
   Collected while rendering instead of by querying the DOM afterwards, so the
   split and unified views need no separate traversal. */
let changeBlocks = [];
let blockIndex = -1;

/* The files ↑/↓ walk into once the current file runs out, in the order they
   appear in whatever list produced this diff (the changes list, or a commit's
   file list). */
let navFiles = [];
let navIndex = -1;

/* The row whose diff the pane is showing, held as the row key and not as the
   element: the changes list is rebuilt on every refresh, so an element
   reference would leave the highlight on a detached row. */
let selectedFileKey = null;

function selectFileRow(key) {
  selectedFileKey = key;
  applyFileSelection();
}

/* Re-run after any list re-render — both the changes list and a commit's file
   list carry the key on the row. */
function applyFileSelection() {
  for (const el of document.querySelectorAll(".change-item")) {
    el.classList.toggle("selected", !!selectedFileKey && el.dataset.fileKey === selectedFileKey);
  }
}

/* The diff area starts closed and opens on the first thing you click, so an
   empty pane never takes up half the window. The flag lays out the *main*
   window, so it follows where the pane currently lives: while the dialog holds
   it, the work area has no pane to make room for. */
function showDiffArea() {
  document.documentElement.dataset.diffOpen = commitDialogOpen() ? "0" : "1";
}

/** Closes it and drops the content, so nothing stale survives a repo switch. */
function hideDiffArea() {
  // Docked, the work area holds the commit panel too — closing the diff must
  // not take the panel down with it.
  document.documentElement.dataset.diffOpen = commitDocked() ? "1" : "0";
  $("diff").innerHTML = "";
  const filesEl = $("commit-files");
  filesEl.innerHTML = "";
  filesEl.style.display = "none";
  $("diff-title").textContent = "差异";
  navIndex = -1;
  selectFileRow(null);
  clearCommitSelection();
  resetChangeBlocks();
  lastDiffRender = null;
  paneView = null;
  setPaneBack(null);
}

function resetChangeBlocks() {
  changeBlocks = [];
  blockIndex = -1;
}

function focusBlock() {
  changeBlocks.forEach((el, i) => el.classList.toggle("change-focus", i === blockIndex));
  changeBlocks[blockIndex]?.scrollIntoView({ block: "center", behavior: "smooth" });
}

function blockStatus() {
  const where = navFiles[navIndex] ? ` — ${navFiles[navIndex].label}` : "";
  return `第 ${blockIndex + 1}/${changeBlocks.length} 处改动${where}`;
}

/**
 * Step to the previous (-1) or next (+1) change, continuing into the adjacent
 * file once the current one runs out — the behaviour of IDEA's ↑/↓.
 *
 * Buttons stay enabled and report "no more" instead of being greyed out:
 * knowing there is a next change means knowing whether some later file has one,
 * which is only knowable by opening it.
 */
async function navigateChange(dir) {
  if (!repoPath) return;

  const decide = () =>
    nextChangeTarget({
      blockIndex,
      blockCount: changeBlocks.length,
      navIndex,
      navCount: navFiles.length,
      dir,
    });

  let target = decide();
  if (target.kind === "block") {
    blockIndex = target.index;
    focusBlock();
    setStatus(blockStatus());
    return;
  }

  // Walk files until one actually renders a block: a binary file or a pure
  // rename has nothing to step through, and stopping on it would look broken.
  while (target.kind === "file") {
    navIndex = target.index;
    selectFileRow(navFiles[navIndex].key);
    await navFiles[navIndex].open();
    if (changeBlocks.length) {
      blockIndex = dir > 0 ? 0 : changeBlocks.length - 1;
      focusBlock();
      setStatus(blockStatus());
      return;
    }
    target = decide();
  }
  setStatus(dir > 0 ? "没有更多改动了" : "已经到第一处改动了");
}

/** Records `el` when it starts a new run of changed lines. */
function collectBlock(el, isChange, state) {
  if (isChange && !state.prev) changeBlocks.push(el);
  state.prev = isChange;
}

/**
 * Render one hunk's body in the user's chosen view.
 *
 * `interactive` ({ picked, pickable, onChange }) turns on line-level staging;
 * pass null for a read-only diff. Clicking a row toggles every body line it
 * covers — a modified row covers both its `-` and its `+`, which must move
 * together or the rebuilt patch won't apply.
 */
function renderHunkBody(el, hunk, interactive) {
  const rows = [];
  let anchor = null;

  const paint = () => {
    for (const r of rows) {
      r.el.classList.toggle("picked", r.picks.some((i) => interactive.picked.has(i)));
    }
    interactive.onChange();
  };

  const bind = (rowEl, picks) => {
    if (!interactive || !picks.length) return;
    rowEl.classList.add("pickable");
    rowEl.title = "点击选择该行，⇧ 点击选择范围";
    rows.push({ el: rowEl, picks });
    rowEl.onclick = (e) => {
      if (e.shiftKey && anchor !== null) {
        for (const j of rangeBetween(interactive.pickable, anchor, picks[0])) {
          interactive.picked.add(j);
        }
      } else {
        const on = picks.some((i) => interactive.picked.has(i));
        for (const i of picks) {
          if (on) interactive.picked.delete(i);
          else interactive.picked.add(i);
        }
      }
      anchor = picks[0];
      paint();
    };
  };

  if (prefs.diffView === "unified") {
    renderUnifiedBody(el, hunk, bind);
  } else {
    renderSplitBody(el, hunk, bind);
  }
}

function renderUnifiedBody(el, hunk, bind) {
  const lines = hunk.replace(/\n$/, "").split("\n");
  const head = document.createElement("span");
  head.className = "hunk";
  head.textContent = lines[0] + "\n";
  el.appendChild(head);

  const state = { prev: false };
  lines.slice(1).forEach((line, i) => {
    const span = document.createElement("span");
    span.className = lineClass(line);
    span.textContent = line + "\n";
    el.appendChild(span);
    const changed = line.startsWith("+") || line.startsWith("-");
    if (changed) bind(span, [i]);
    collectBlock(span, changed, state);
  });
}

/* Fixed-width number columns and two equal text columns, so rows stay aligned
   without synchronising two scroll positions. Long lines wrap inside their own
   half rather than scrolling — one less moving part than IDEA's synced panes,
   and the diff pane here is too narrow for horizontal scrolling to help. */
function renderSplitBody(el, hunk, bind) {
  const paired = pairHunkLines(hunk);
  if (!paired) {
    renderUnifiedBody(el, hunk, bind);
    return;
  }

  const grid = document.createElement("div");
  grid.className = "split-diff";

  const head = document.createElement("div");
  head.className = "split-hunk-head";
  head.textContent = hunk.split("\n")[0];
  grid.appendChild(head);

  const state = { prev: false };
  for (const row of paired.rows) {
    const rowEl = document.createElement("div");
    rowEl.className = `split-row ${row.type}`;
    rowEl.append(
      numCell(row.left),
      textCell(row, "left"),
      numCell(row.right),
      textCell(row, "right"),
    );
    grid.appendChild(rowEl);
    bind(rowEl, row.picks);
    collectBlock(rowEl, row.type !== "ctx", state);
  }
  el.appendChild(grid);
}

function numCell(cell) {
  const div = document.createElement("div");
  div.className = "split-no";
  div.textContent = cell ? String(cell.no) : "";
  return div;
}

function textCell(row, side) {
  const div = document.createElement("div");
  div.className = `split-text ${side}`;
  const cell = row[side];
  if (!cell) {
    div.classList.add("empty");
    return div;
  }
  // On a modified row, highlight only what actually changed within the line.
  if (row.type === "mod") {
    const d = intraLineDiff(row.left.text, row.right.text);
    if (d) {
      const part = d[side];
      div.appendChild(document.createTextNode(part.prefix));
      if (part.mid) {
        const mark = document.createElement("span");
        mark.className = `intra ${side === "left" ? "del" : "add"}`;
        mark.textContent = part.mid;
        div.appendChild(mark);
      }
      div.appendChild(document.createTextNode(part.suffix));
      return div;
    }
  }
  div.textContent = cell.text;
  return div;
}

function lineClass(line) {
  if (line.startsWith("+")) return "add";
  if (line.startsWith("-")) return "del";
  if (line.startsWith("@")) return "hunk";
  return "";
}

function renderDiff(text) {
  const el = $("diff");
  el.innerHTML = "";
  resetChangeBlocks();
  const { hunks } = splitPatchText(text);
  if (!hunks.length) {
    // No hunks at all: a binary file, a pure rename, or our "no text diff" note.
    el.textContent = text;
    return;
  }
  for (const hunk of hunks) renderHunkBody(el, hunk, null);
}

function renderHunks(file, staged, header, hunks, repo = repoPath) {
  const el = $("diff");
  el.innerHTML = "";
  resetChangeBlocks();
  hunks.forEach((hunk) => {
    const picked = new Set(); // body-line indices, for line-level staging

    const bar = document.createElement("div");
    bar.className = "hunk-bar";
    const partial = mkBtn(staged ? "取消暂存选中行" : "暂存选中行", () => {
      const patch = buildPartialHunk(hunk, picked);
      if (!patch) {
        setStatus("先点选要处理的行", true);
        return;
      }
      applyPatch(file, staged, header, patch, staged ? "已取消暂存选中行" : "已暂存选中行", repo);
    });
    partial.className = "hunk-btn";
    partial.disabled = true;
    const whole = mkBtn(staged ? "取消暂存此块" : "暂存此块", () =>
      applyPatch(file, staged, header, hunk, staged ? "已取消暂存此块" : "已暂存此块", repo),
    );
    whole.className = "hunk-btn";
    const hint = document.createElement("span");
    hint.className = "hunk-hint";
    hint.textContent = "点选行，⇧ 点选范围";
    bar.append(whole, partial, hint);
    el.appendChild(bar);

    renderHunkBody(el, hunk, {
      picked,
      pickable: selectableLines(hunk),
      onChange: () => (partial.disabled = picked.size === 0),
    });
  });
}

async function applyPatch(file, staged, header, body, okMsg, repo = repoPath) {
  const patch = header + (body.endsWith("\n") ? body : body + "\n");
  try {
    await invoke("apply_hunk", { path: repo, patch, reverse: staged });
    await refreshChanges();
    await showDiff(file, staged, repo);
    setStatus(okMsg);
  } catch (e) {
    setStatus(String(e), true);
  }
}

/* Commits to every repo that has staged content, with one shared message —
   the workspace equivalent of IDEA committing several roots at once. Amend is
   the exception: rewriting an existing commit in four repos from one checkbox
   is never what someone means, so it targets the active repo only. */
/* Both commit buttons plus the AI one, so nothing can fire a second git write
   into the same repo while the first is still running. */
function setCommitBusy(busy) {
  for (const id of ["commit-btn", "commit-more-btn", "commit-history-btn", "ai-msg-btn"]) {
    $(id).disabled = busy;
  }
  $("commit-btn").classList.toggle("busy", busy);
  $("commit-btn").textContent = busy ? "提交中…" : "提交";
}

async function doCommit(alsoPush = false) {
  const msg = $("commit-msg").value.trim();
  if (!msg) {
    setStatus("请先填写提交说明", true);
    return;
  }
  const amend = $("amend-cb").checked;
  const signoff = $("signoff-cb").checked;
  const author = $("author-input").value.trim();
  const verb = amend ? "已修补" : "已提交";

  let targets;
  if (amend) {
    targets = repos.filter((r) => r.path === repoPath);
  } else {
    const { results } = await statusByRepo(false);
    targets = results
      .filter(inScope)
      .filter((r) => r.files.some((f) => f.staged))
      .map((r) => r.repo);
    if (!targets.length) {
      setStatus("没有已暂存的改动 — 先勾选要提交的文件", true);
      return;
    }
  }

  const done = [];
  const failed = [];
  // A commit with pre-commit hooks takes seconds to minutes. Say so and lock
  // the buttons: without it the window just sits there and looks hung.
  setCommitBusy(true);
  try {
    for (const r of targets) {
      setStatus(targets.length > 1 ? `正在提交 ${r.name}…（共 ${targets.length} 个仓库）` : "正在提交…");
      try {
        const oid = await invoke("commit", {
          path: r.path,
          message: msg,
          amend,
          author,
          signoff,
        });
        done.push({ repo: r, oid });
      } catch (e) {
        failed.push(`${r.name}: ${e}`);
      }
    }
  } finally {
    setCommitBusy(false);
  }

  if (done.length) {
    $("commit-msg").value = "";
    $("author-input").value = "";
    $("amend-cb").checked = false;
    // Close on any success so the status bar is readable; a total failure keeps
    // the dialog up so the user can see which repo refused.
    closeCommitDialog();
  }
  const describe = (d) => (isMulti() ? `${d.repo.name} ${d.oid.slice(0, 8)}` : d.oid.slice(0, 8));
  const summary = done.map(describe).join("、");

  if (!alsoPush) {
    await refreshAll();
    if (failed.length) {
      // With nothing committed there is no summary, and `已提交 ；失败：…` reads
      // as if part of it had gone through.
      const ok = done.length ? `${verb} ${summary}；` : "";
      setStatus(`${ok}失败：${failed.join("；")}`, true);
    } else {
      setStatus(`${verb} ${summary}`);
    }
    return;
  }

  // Committed successfully — a push failure must not read as a commit failure.
  setStatus(`${verb} ${summary}，正在推送…`);
  const pushed = [];
  const pushFailed = [...failed];
  for (const d of done) {
    try {
      await pushRepo(d.repo);
      pushed.push(d.repo.name);
    } catch (e) {
      const hint = amend ? "（修补改写了历史，需右键「推送」→ 强制推送）" : "";
      pushFailed.push(`${d.repo.name} 推送失败：${e}${hint}`);
    }
  }
  await refreshAll();
  if (pushFailed.length) {
    setStatus(`${verb} ${summary}；${pushFailed.join("；")}`, true);
  } else {
    setStatus(`${verb} ${summary} 并推送`);
  }
}

/* The ↑↓ counts come from refs/remotes/*, so they are only as fresh as the
   last fetch: a workspace opened in the morning keeps reporting "nothing to
   push" until git rejects the push with "fetch first". One silent fetch when
   a workspace opens keeps the counts honest. Failures stay silent — the user
   did not ask for a fetch, and being offline is not an error worth a banner. */
async function backgroundFetch() {
  const mine = repos;
  // 离线仍然静默（见上），但凭证失效要说：它会让 ↑↓ 一直停在旧数据上，
  // 用户看着"没东西可推"，直到手动推送才发现推不上去。
  const authFailed = [];
  await Promise.all(
    mine.map((r) =>
      invoke("git_fetch", { path: r.path }).catch((e) => {
        if (isAuthFailure(e)) authFailed.push(r.name);
      }),
    ),
  );
  // Bail if the user switched projects while the fetch was in flight.
  if (repos !== mine) return;
  await refreshAll();
  if (authFailed.length) {
    setStatus(`${authFailed.join("、")} 远程认证失败，请到设置 → Git 信息 → 远程认证检查凭据`, true);
  }
}

/* Asked only when nothing else can answer — see `updateMethodFor`. */
function askUpdateMethod(repoName) {
  return new Promise((resolve) => {
    const overlay = document.createElement("div");
    overlay.className = "modal-overlay dialog-overlay";
    overlay.style.display = "flex";
    overlay.onEsc = () => done(null);
    const box = document.createElement("div");
    box.className = "modal";
    const title = document.createElement("div");
    title.className = "modal-title";
    title.textContent = `${repoName} 落后于远端，推送被拒绝`;
    const hint = document.createElement("div");
    hint.className = "settings-hint";
    hint.textContent = "远端有你本地没有的提交。先更新本地分支，再重新推送。";
    const remember = document.createElement("label");
    const cb = document.createElement("input");
    cb.type = "checkbox";
    remember.append(cb, document.createTextNode(" 记住此选择（同时作为拉取策略）"));
    const actions = document.createElement("div");
    actions.className = "modal-actions";

    const done = (strategy) => {
      if (strategy && cb.checked) {
        prefs.pullStrategy = strategy;
        savePrefs();
      }
      overlay.remove();
      resolve(strategy);
    };
    const button = (text, strategy, primary = false) => {
      const b = document.createElement("button");
      if (primary) b.className = "primary";
      b.textContent = text;
      b.onclick = () => done(strategy);
      return b;
    };
    actions.append(
      button("取消", null),
      button("合并", "merge"),
      button("变基", "rebase", true),
    );
    box.append(title, hint, remember, actions);
    overlay.appendChild(box);
    overlay.onclick = (e) => {
      if (e.target === overlay) done(null);
    };
    document.body.appendChild(overlay);
  });
}

/* How to update a branch the remote has moved past, in IDEA's order:
   1. an explicit 拉取策略 (merge / rebase) — the user already decided;
   2. otherwise git config, the way IDEA's default "Branch default" does it —
      branch.<name>.rebase, then pull.rebase. This is why cgit has no second
      setting of its own: the answer already lives in git config.
   3. only when git config is silent too, ask — and remember the answer. */
async function updateMethodFor(r) {
  if (prefs.pullStrategy !== "ff-only") return prefs.pullStrategy;
  let rebase = null;
  try {
    rebase = await invoke("get_pull_rebase", { path: r.path });
  } catch {
    /* unreadable config is not worth a message — fall through and ask */
  }
  if (rebase === null) return askUpdateMethod(r.name);
  return rebase ? "rebase" : "merge";
}

/* 凭证失效时 git 的原话（could not read Username…）看不出该做什么，补一句人话。
   其余错误保持原样 —— git 自己说得比我们清楚。 */
function netErrorText(e) {
  const text = String(e).trim();
  const auth = authFailureInfo(text);
  if (auth?.kind === "github-403") {
    return `GitHub 当前使用账号 ${auth.username}，没有该仓库的推送权限。请到设置 → Git 信息 → 远程认证切换账号 — ${text}`;
  }
  return auth ? `远程认证失败，请到设置 → Git 信息 → 远程认证检查凭据 — ${text}` : text;
}

/* Push, and treat "the remote moved ahead" as something to resolve rather
   than report: update with the chosen method, then push again. Every other
   failure (no auth, hook refused, protected branch) still throws. */
async function pushRepo(r) {
  try {
    return (await invoke("git_push", { path: r.path })).trim();
  } catch (e) {
    if (!isPushRejected(e)) throw e;
    const strategy = await updateMethodFor(r);
    if (!strategy) throw e;
    setStatus(`${r.name} 落后于远端，正在${strategy === "rebase" ? "变基" : "合并"}更新…`);
    await invoke("git_pull", { path: r.path, strategy });
    return (await invoke("git_push", { path: r.path })).trim();
  }
}

/* Push several repos as one action, so a workspace push reads as one line in
   the status bar and one rejected repo does not hide the ones that went. */
async function pushMany(targets) {
  if (!targets.length) return;
  setStatus("推送…");
  const failed = [];
  const pushed = [];
  let last = "";
  for (const r of targets) {
    try {
      last = await pushRepo(r);
      pushed.push(r.name);
    } catch (e) {
      failed.push(`${r.name}: ${netErrorText(e)}`);
    }
  }
  await refreshAll();
  if (failed.length) {
    const ok = pushed.length ? `已推送 ${pushed.join("、")}；` : "";
    setStatus(`${ok}推送失败 — ${failed.join("；")}`, true);
    return;
  }
  const scope = targets.length > 1 ? `${targets.length} 个仓库` : repoName(targets[0].path);
  setStatus(`推送完成（${scope}）。${last}`.trim());
}

/** IDEA's wording for where a repo's push lands: `main → origin : main`. */
function pushTargetText(tracking) {
  if (!tracking?.branch) return "HEAD 不在分支上";
  if (!tracking.upstream) return `${tracking.branch} → origin : ${tracking.branch}（新分支）`;
  const cut = tracking.upstream.indexOf("/");
  const remote = tracking.upstream.slice(0, cut);
  const branch = tracking.upstream.slice(cut + 1);
  return `${tracking.branch} → ${remote} : ${branch}`;
}

function treeRow(label, depth, kind) {
  const li = document.createElement("li");
  li.className = `push-tree-row ${kind}`;
  li.style.paddingLeft = `${6 + depth * 14}px`;
  li.textContent = label;
  return li;
}

/* Folders first with their file counts, then the files themselves — the same
   shape as the tree IDEA shows next to the repo list. */
function appendTreeRows(node, into, depth) {
  for (const dir of node.dirs) {
    // <details> so collapsing costs no state of our own: open by default, the
    // triangle and its rotation come from CSS.
    const li = document.createElement("li");
    li.className = "push-tree-node";
    const details = document.createElement("details");
    details.open = true;
    const summary = document.createElement("summary");
    summary.className = "push-tree-row folder";
    summary.style.paddingLeft = `${6 + depth * 14}px`;
    summary.textContent = `${dir.name}  ${dir.count} 个文件`;
    const sub = document.createElement("ul");
    sub.className = "list";
    appendTreeRows(dir, sub, depth + 1);
    details.append(summary, sub);
    li.appendChild(details);
    into.appendChild(li);
  }
  for (const f of node.files) {
    const li = treeRow("", depth, "file");
    const badge = document.createElement("span");
    badge.className = `badge ${f.status}`;
    badge.textContent = f.status[0].toUpperCase();
    const name = document.createElement("span");
    name.className = "file-name";
    name.textContent = f.path.split("/").pop();
    name.title = f.path;
    li.append(badge, name);
    into.appendChild(li);
  }
}

/* The workspace push dialog: one row per repo with where it lands, the repos
   that actually have commits pre-checked, and the files those commits carry.
   Without it a workspace push is impossible — a bare button can only ever
   mean the active repo, with no way to say "these three, not that one". */
async function openPushDialog() {
  const rows = await Promise.all(
    repos.map(async (repo) => {
      try {
        return { repo, tracking: await invoke("get_branch_tracking", { path: repo.path }) };
      } catch {
        return { repo, tracking: null };
      }
    }),
  );

  const overlay = document.createElement("div");
  overlay.className = "modal-overlay dialog-overlay";
  overlay.style.display = "flex";
  const box = document.createElement("div");
  box.className = "modal push-modal";
  const title = document.createElement("div");
  title.className = "modal-title";
  title.textContent = "推送提交";

  const body = document.createElement("div");
  body.className = "push-body";
  const list = document.createElement("ul");
  list.className = "list push-repos";
  const files = document.createElement("div");
  files.className = "push-files";
  body.append(list, files);

  const actions = document.createElement("div");
  actions.className = "modal-actions";
  const cancel = document.createElement("button");
  cancel.textContent = "取消";
  const push = document.createElement("button");
  push.className = "primary";

  const checks = new Map();
  const items = new Map();
  const picked = () => rows.filter((r) => checks.get(r.repo.path).checked).map((r) => r.repo);
  const syncPushBtn = () => {
    const n = picked().length;
    push.textContent = n > 1 ? `推送 ${n} 个仓库` : "推送";
    push.disabled = n === 0;
  };

  let selectGen = 0;
  const select = async (row) => {
    const gen = ++selectGen;
    for (const [path, li] of items) li.classList.toggle("current", path === row.repo.path);
    files.textContent = "载入中…";
    if (!row.tracking?.upstream) {
      files.textContent = `${row.repo.name}：新分支，推送后在 origin 上创建`;
      return;
    }
    let pushFiles;
    try {
      pushFiles = await invoke("get_push_files", { path: row.repo.path });
    } catch (e) {
      if (gen === selectGen) files.textContent = String(e);
      return;
    }
    if (gen !== selectGen) return; // a faster click won
    files.textContent = "";
    if (!pushFiles.length) {
      files.textContent = `${row.repo.name}：没有要推送的提交`;
      return;
    }
    const tree = document.createElement("ul");
    tree.className = "list push-tree";
    const root = pathTree(pushFiles);
    tree.appendChild(treeRow(`${row.repo.name}  ${root.count} 个文件`, 0, "repo"));
    appendTreeRows(root, tree, 1);
    files.appendChild(tree);
  };

  for (const row of rows) {
    const li = document.createElement("li");
    li.className = "change-item push-repo";
    const cb = document.createElement("input");
    cb.type = "checkbox";
    // Pre-check what actually has something to push, as IDEA does: commits
    // ahead of the upstream, or a branch the remote does not have yet.
    cb.checked = row.tracking ? row.tracking.ahead > 0 || !row.tracking.upstream : false;
    cb.onclick = (e) => {
      e.stopPropagation();
      syncPushBtn();
    };
    const name = document.createElement("span");
    name.className = "push-repo-name";
    name.textContent = row.repo.name;
    const target = document.createElement("span");
    target.className = "push-target";
    target.textContent = pushTargetText(row.tracking);
    li.append(cb, name, target);
    li.onclick = () => select(row);
    list.appendChild(li);
    checks.set(row.repo.path, cb);
    items.set(row.repo.path, li);
  }

  const close = () => overlay.remove();
  overlay.onEsc = close;
  cancel.onclick = close;
  push.onclick = () => {
    const targets = picked();
    close();
    pushMany(targets);
  };
  overlay.onclick = (e) => {
    if (e.target === overlay) close();
  };
  actions.append(cancel, push);
  box.append(title, body, actions);
  overlay.appendChild(box);
  document.body.appendChild(overlay);
  syncPushBtn();
  // Open on a repo worth looking at: the first one that has commits to push.
  await select(rows.find((r) => checks.get(r.repo.path).checked) ?? rows[0]);
}

/* One repo needs no dialog — there is nothing to choose. */
function pushAction() {
  if (!repoPath) return;
  if (isMulti()) return openPushDialog();
  return pushMany(repos.filter((r) => r.path === repoPath));
}

/* Fetch and pull both run across the whole workspace: one click updates every
   repo, the way IDEA's Update Project does. A repo that refuses (diverged
   under --ff-only, no network) is reported by name and does not stop the rest.
   Push is the exception — it has a dialog, so you pick the repos. */
async function runNet(cmd, label) {
  setStatus(`${label}…`);
  const targets = repos;
  const done = [];
  const failed = [];
  let last = "";
  for (const r of targets) {
    const args = { path: r.path };
    if (cmd === "git_pull") args.strategy = prefs.pullStrategy;
    try {
      last = (await invoke(cmd, args)).trim();
      done.push(r.name);
    } catch (e) {
      failed.push(`${r.name}: ${netErrorText(e)}`);
    }
  }
  await refreshAll();
  if (failed.length) {
    // Name what went through: with four repos, "拉取失败" alone reads as if
    // none of them had been updated.
    const ok = done.length ? `${done.join("、")} 已${label}；` : "";
    setStatus(`${ok}${label}失败 — ${failed.join("；")}`, true);
    return;
  }
  const scope = targets.length > 1 ? `${targets.length} 个仓库` : repoName(targets[0]?.path);
  // One repo's git output is worth showing; four repos' is noise, and showing
  // only the last one would read as if it covered all of them.
  const detail = targets.length > 1 ? "" : last;
  setStatus(`${label}完成（${scope}）。${detail}`.trim());
}

/* ---------- M4.2 merge & conflicts ---------- */
async function mergeBranch(name) {
  try {
    const out = await invoke("merge_branch", { path: repoPath, name });
    await refreshAll();
    setStatus(out.split("\n")[0] || `已合并 ${name}`);
  } catch (e) {
    setStatus(String(e), true);
  }
}

/* A merge, cherry-pick, revert and rebase all stop on conflict, but each has
   its own --continue / --abort. `git merge --abort` during a cherry-pick fails
   with "There is no merge to abort", which used to leave the user stuck. */
const OP_LABELS = {
  rebase: "变基",
  "cherry-pick": "拣选",
  revert: "回退",
  merge: "合并",
};

/* Any repo in the workspace can be mid-merge, so the banner reports each one
   separately — a shared "continue" button would be ambiguous about what it
   continues. */
async function refreshConflicts(gen = ++refreshGen) {
  const banner = $("conflict-banner");
  const states = await Promise.all(
    repos.map(async (r) => {
      try {
        return {
          repo: r,
          conflicts: await invoke("get_conflicts", { path: r.path }),
          op: await invoke("get_repo_state", { path: r.path }),
        };
      } catch {
        return { repo: r, conflicts: [], op: "none" };
      }
    }),
  );
  if (isStale(gen)) return;

  const active = states.filter((st) => st.conflicts.length || st.op !== "none");
  if (!active.length) {
    banner.style.display = "none";
    banner.innerHTML = "";
    return;
  }

  banner.style.display = "block";
  banner.innerHTML = "";
  for (const { repo, conflicts, op } of active) {
    const label = OP_LABELS[op] ?? "操作";
    const where = isMulti() ? `${repo.name}：` : "";
    const title = document.createElement("div");
    title.className = "conflict-title";
    title.textContent = conflicts.length
      ? `${where}${label}进行中 — ${conflicts.length} 处冲突待解决`
      : `${where}${label}进行中 — 冲突已解决，可继续`;
    banner.appendChild(title);

    const ul = document.createElement("ul");
    ul.className = "list";
    for (const f of conflicts) {
      const li = document.createElement("li");
      li.className = "change-item";
      const badge = document.createElement("span");
      badge.className = "badge deleted";
      badge.textContent = "!";
      const name = document.createElement("span");
      name.className = "file-name";
      name.textContent = f;
      li.append(badge, name);
      li.onclick = () => showConflict(f, repo.path);
      ul.appendChild(li);
    }
    banner.appendChild(ul);

    const actions = document.createElement("div");
    actions.className = "conflict-actions";
    if (op !== "none") {
      const cont = mkBtn(
        `继续${label}`,
        () => opAction(op, "continue", label, repo.path),
        true,
      );
      cont.disabled = conflicts.length > 0;
      actions.append(
        cont,
        mkBtn(`中止${label}`, () => opAction(op, "abort", label, repo.path)),
      );
      if (op === "rebase" || op === "cherry-pick" || op === "revert") {
        actions.append(
          mkBtn("跳过此提交", () => opAction(op, "skip", label, repo.path)),
        );
      }
    }
    banner.appendChild(actions);
  }
}

async function opAction(op, action, label, repo = repoPath) {
  const verb = { continue: "继续", abort: "中止", skip: "跳过" }[action];
  if (action === "abort") {
    const ok = await ask(`中止${label}？已解决的内容会被丢弃。`, {
      title: `中止${label}`,
      kind: "warning",
    });
    if (!ok) return;
  }
  try {
    const out = await invoke("op_action", { path: repo, op, action });
    await refreshAll();
    setStatus(out.split("\n").filter(Boolean).pop() || `已${verb}${label}`);
  } catch (e) {
    await refreshAll();
    setStatus(String(e), true);
  }
}

function mkBtn(label, onClick, primary = false) {
  const b = document.createElement("button");
  if (primary) b.className = "primary";
  b.textContent = label;
  b.onclick = onClick;
  return b;
}

/* Conflicts open in their own window: a three-pane merge view (ours | result |
   theirs) needs the width, and the diff pane behind it stays where it was. */
async function showConflict(file, repo = repoPath) {
  let working;
  try {
    working = await invoke("read_worktree_file", { path: repo, file });
  } catch (e) {
    setStatus(String(e), true);
    return;
  }
  const { blocks, hasConflict } = parseConflicts(working);

  document.getElementById("merge-overlay")?.remove(); // re-entrant: base toggle reopens
  const overlay = document.createElement("div");
  overlay.className = "modal-overlay";
  overlay.id = "merge-overlay";
  const modal = document.createElement("div");
  modal.className = "modal merge-modal";

  const title = document.createElement("div");
  title.className = "modal-title";
  const prefix = isMulti() ? `${repoName(repo)} / ` : "";
  title.textContent = `合并 — ${prefix}${file}`;
  modal.appendChild(title);

  if (hasConflict) renderMergeView(file, modal, blocks, repo);
  else renderWholeFileConflict(file, modal, working, repo);

  overlay.appendChild(modal);
  overlay.onclick = (e) => {
    if (e.target === overlay) overlay.remove();
  };
  document.body.appendChild(overlay);
}

// Fallback for conflicts without text markers (binary, add/add, etc.).
function renderWholeFileConflict(file, host, working, repo = repoPath) {
  const h = document.createElement("div");
  h.className = "conflict-pane-label";
  h.textContent = "无文本冲突标记 — 整文件处理";
  const ta = document.createElement("textarea");
  ta.className = "conflict-edit";
  ta.value = working;
  host.append(h, ta);
  const bar = document.createElement("div");
  bar.className = "modal-actions";
  bar.append(
    mkBtn("采用我方", () => resolveSide(file, "ours", repo)),
    mkBtn("采用对方", () => resolveSide(file, "theirs", repo)),
    mkBtn("取消", () => document.getElementById("merge-overlay")?.remove()),
    mkBtn("标记为已解决", () => resolveManual(file, ta.value, repo), true),
  );
  host.appendChild(bar);
}

/* Three panes — ours | result | theirs — as one grid inside one scroll box.
   Cells go in row-wise triplets, so a row is as tall as its tallest pane and
   the three stay aligned block by block with no scroll-syncing code. */
function renderMergeView(file, host, blocks, repo = repoPath) {
  const conflicts = blocks.filter((b) => b.type === "conflict");
  const hasBase = conflicts.some((b) => b.base.length);
  // Per side, like IDEA: null = undecided, true = merged in, false = dropped.
  for (const b of conflicts) {
    b.takeOurs = null;
    b.takeTheirs = null;
  }

  const scroll = document.createElement("div");
  scroll.className = "mv-scroll";
  const grid = document.createElement("div");
  grid.className = "mv-grid";
  scroll.appendChild(grid);
  host.appendChild(scroll);

  /* Panes keep their third of the window and clip their code; this one bar
     shifts all three at once (--mv-x translates every .mv-text), which is what
     makes the columns comparable while scrolling sideways. */
  const hbar = document.createElement("div");
  hbar.className = "mv-hbar";
  const hbarInner = document.createElement("div");
  hbar.appendChild(hbarInner);
  host.appendChild(hbar);
  hbar.onscroll = () => grid.style.setProperty("--mv-x", `${-hbar.scrollLeft}px`);

  // The bar is 10px tall and lives under the panes; a sideways trackpad swipe
  // anywhere over the panes should drive it too.
  scroll.onwheel = (e) => {
    if (hbar.hidden || Math.abs(e.deltaX) <= Math.abs(e.deltaY)) return;
    hbar.scrollLeft += e.deltaX;
    e.preventDefault();
  };

  function sizeHbar() {
    let widest = 0;
    for (const t of grid.querySelectorAll(".mv-text")) widest = Math.max(widest, t.offsetWidth);
    // The bar spans all three panes, so its travel is how far the widest line
    // sticks out of one pane, not the line's full width.
    const cell = grid.firstElementChild;
    const overflow = cell ? Math.max(0, Math.ceil(widest - (cell.clientWidth - 16))) : 0;
    hbar.hidden = overflow === 0;
    if (!overflow) {
      grid.style.setProperty("--mv-x", "0px");
      return;
    }
    hbarInner.style.width = `${hbar.clientWidth + overflow}px`;
  }

  const actions = document.createElement("div");
  actions.className = "modal-actions mv-actions";
  const count = document.createElement("span");
  count.className = "mv-count";
  const save = mkBtn("应用", () => resolveManual(file, assembleConflict(blocks), repo), true);
  actions.append(
    count,
    mkBtn("全部采用我方", () => setAll(true, false)),
    mkBtn("全部采用对方", () => setAll(false, true)),
    mkBtn(hasBase ? "隐藏共同祖先" : "显示共同祖先", () =>
      toggleConflictBase(file, hasBase, repo),
    ),
    mkBtn("取消", () => document.getElementById("merge-overlay")?.remove()),
    save,
  );
  host.appendChild(actions);

  function decided(b) {
    return b.edited != null || (b.takeOurs !== null && b.takeTheirs !== null);
  }

  /* The two side decisions collapse into the resolution assembleConflict
     understands; "none" is both sides dropped. */
  function syncResolution(b) {
    if (b.takeOurs && b.takeTheirs) b.resolution = "both";
    else if (b.takeOurs) b.resolution = "ours";
    else if (b.takeTheirs) b.resolution = "theirs";
    else if (b.takeOurs === false && b.takeTheirs === false) b.resolution = "none";
    else b.resolution = null;
  }

  function setAll(ours, theirs) {
    for (const b of conflicts) {
      b.takeOurs = ours;
      b.takeTheirs = theirs;
      b.edited = null;
      refresh(b);
    }
  }

  function sideState(b, side) {
    const take = side === "ours" ? b.takeOurs : b.takeTheirs;
    return take === null ? "" : take ? " mv-pick" : " mv-drop";
  }

  /* Chevron points at the result pane and ✕ drops that side, like IDEA's
     gutter controls. Merging both sides in is two clicks: » then «. */
  function sideCell(b, side) {
    const d = document.createElement("div");
    d.className = `mv-cell mv-side mv-${side}`;
    const text = document.createElement("div");
    text.className = "mv-text";
    text.textContent = (side === "ours" ? b.ours : b.theirs).join("\n");
    const acc = mkBtn(side === "ours" ? "»" : "«", () => decide(b, side, true));
    acc.className = "mv-acc";
    acc.title = side === "ours" ? "合并我方这段 → 结果" : "合并对方这段 → 结果";
    const drop = mkBtn("✕", () => decide(b, side, false));
    drop.className = "mv-acc mv-drop-btn";
    drop.title = side === "ours" ? "不合并我方这段" : "不合并对方这段";
    const gutter = document.createElement("div");
    gutter.className = "mv-gutter";
    gutter.append(...(side === "ours" ? [drop, acc] : [acc, drop]));
    d.append(text, gutter);
    b.cells = b.cells || {};
    b.cells[side] = d;
    return d;
  }

  function resultCell(b) {
    const d = document.createElement("div");
    d.className = "mv-cell mv-res mv-unres"; // nothing decided yet
    // Base is reference only: it lives outside .mv-text, so it can never end
    // up in the saved file.
    if (b.base.length) {
      const hint = document.createElement("div");
      hint.className = "mv-basehint";
      hint.textContent = `共同祖先：${b.base.join(" ⏎ ")}`;
      d.appendChild(hint);
    }
    d.appendChild(editable(b, () => resultLines(b).join("\n")));
    b.cells = b.cells || {};
    b.cells.res = d;
    return d;
  }

  /* Every result cell is editable — that is the only way to touch the lines
     git merged cleanly, since those carry no conflict for a side button. */
  function editable(b, initial) {
    const text = document.createElement("div");
    text.className = "mv-text mv-edit";
    text.contentEditable = "plaintext-only";
    text.spellcheck = false;
    text.textContent = b.edited != null ? b.edited : initial();
    text.oninput = () => {
      b.edited = text.innerText.replace(/\n$/, ""); // contenteditable's trailing break
      if (b.type === "conflict") b.cells.res.classList.remove("mv-unres");
      updateFooter();
      sizeHbar();
    };
    b.cells = b.cells || {};
    b.cells.text = text;
    return text;
  }

  function resultLines(b) {
    return [...(b.takeOurs ? b.ours : []), ...(b.takeTheirs ? b.theirs : [])];
  }

  function decide(b, side, take) {
    if (side === "ours") b.takeOurs = take;
    else b.takeTheirs = take;
    b.edited = null; // an explicit pick replaces whatever was typed
    refresh(b);
  }

  function refresh(b) {
    syncResolution(b);
    b.cells.ours.className = `mv-cell mv-side mv-ours${sideState(b, "ours")}`;
    b.cells.theirs.className = `mv-cell mv-side mv-theirs${sideState(b, "theirs")}`;
    b.cells.res.classList.toggle("mv-unres", !decided(b));
    b.cells.text.textContent = resultLines(b).join("\n");
    updateFooter();
    sizeHbar();
  }

  function updateFooter() {
    const left = conflicts.filter((b) => !decided(b)).length;
    count.textContent = left
      ? `${conflicts.length} 处冲突，${left} 处未处理`
      : `${conflicts.length} 处冲突，已全部处理`;
    save.disabled = left > 0;
  }

  for (const label of ["我方（当前分支）", "结果（可编辑）", "对方（传入）"]) {
    const h = document.createElement("div");
    h.className = "mv-head";
    h.textContent = label;
    grid.appendChild(h);
  }
  for (const b of blocks) {
    if (b.type === "ctx") {
      if (!b.lines.join("").length) continue; // blank filler: still saved, just not shown
      const text = b.lines.join("\n");
      grid.append(cellOf("mv-ctx", text), resultCtxCell(b, text), cellOf("mv-ctx", text));
      continue;
    }
    grid.append(sideCell(b, "ours"), resultCell(b), sideCell(b, "theirs"));
  }
  updateFooter();
  // The modal is still detached on first render, so measure after layout.
  requestAnimationFrame(sizeHbar);

  function cellOf(cls, text) {
    const d = document.createElement("div");
    d.className = `mv-cell ${cls}`;
    const t = document.createElement("div");
    t.className = "mv-text";
    t.textContent = text;
    d.appendChild(t);
    return d;
  }

  function resultCtxCell(b, text) {
    const d = document.createElement("div");
    d.className = "mv-cell mv-ctx mv-res";
    d.appendChild(editable(b, () => text));
    return d;
  }
}

/* Per-block base only exists in diff3-style markers, so getting it means asking
   git to regenerate the file's markers. That discards manual edits to the file,
   hence the confirmation. */
async function toggleConflictBase(file, hasBase, repo = repoPath) {
  const style = hasBase ? "merge" : "diff3";
  const ok = await ask(
    `将重新生成 "${file}" 的冲突标记${hasBase ? "（移除 base 段）" : "（加入 base 段）"}。` +
      `该文件上的手工修改会丢失，已选择的取舍也会重置。继续？`,
    { title: hasBase ? "隐藏共同祖先" : "显示共同祖先", kind: "warning" },
  );
  if (!ok) return;
  try {
    await invoke("set_conflict_style", { path: repo, file, style });
    await showConflict(file, repo); // re-read and re-parse the regenerated markers
    setStatus(hasBase ? "已隐藏共同祖先" : "已显示共同祖先");
  } catch (e) {
    setStatus(String(e), true);
  }
}

async function resolveSide(file, side, repo = repoPath) {
  try {
    await invoke("resolve_conflict", { path: repo, file, side });
    await afterResolve(file);
  } catch (e) {
    setStatus(String(e), true);
  }
}

async function resolveManual(file, content, repo = repoPath) {
  try {
    await invoke("resolve_with_content", { path: repo, file, content });
    await afterResolve(file);
  } catch (e) {
    setStatus(String(e), true);
  }
}

async function afterResolve(file) {
  document.getElementById("merge-overlay")?.remove();
  await refreshAll();
  setStatus(`已解决 ${file}`);
}

/* ---------- M4.3 interactive rebase ---------- */
async function openRebaseModal(base) {
  let todo = [];
  try {
    todo = await invoke("get_rebase_todo", { path: repoPath, base });
  } catch (e) {
    setStatus(String(e), true);
    return;
  }
  if (!todo.length) {
    setStatus("所选提交之后没有可变基的提交", true);
    return;
  }
  // newest first for display, but git applies oldest-first (todo order)
  const rows = todo.slice();

  const overlay = document.createElement("div");
  overlay.className = "modal-overlay";
  overlay.style.display = "flex";

  const modal = document.createElement("div");
  modal.className = "modal rebase-modal";
  modal.innerHTML = `<div class="modal-title">交互式变基（${rows.length} 个提交，从上到下依次应用）</div>`;

  const listEl = document.createElement("div");
  listEl.className = "rebase-list";
  modal.appendChild(listEl);

  const render = () => {
    listEl.innerHTML = "";
    rows.forEach((r, i) => {
      const row = document.createElement("div");
      row.className = "rebase-row";

      const up = document.createElement("button");
      up.className = "icon-btn";
      up.textContent = "↑";
      up.disabled = i === 0;
      up.onclick = () => {
        [rows[i - 1], rows[i]] = [rows[i], rows[i - 1]];
        render();
      };
      const down = document.createElement("button");
      down.className = "icon-btn";
      down.textContent = "↓";
      down.disabled = i === rows.length - 1;
      down.onclick = () => {
        [rows[i + 1], rows[i]] = [rows[i], rows[i + 1]];
        render();
      };

      r.action = r.action || "pick";
      const sel = document.createElement("select");
      sel.className = "recent-select";
      for (const a of ["pick", "reword", "squash", "fixup", "drop"]) {
        const o = document.createElement("option");
        o.value = a;
        o.textContent = ({ pick: "保留", reword: "改写说明", squash: "压缩合并", fixup: "并入上一个", drop: "删除" })[a] || a;
        if (r.action === a) o.selected = true;
        sel.appendChild(o);
      }
      sel.onchange = () => {
        r.action = sel.value;
        render();
      };

      const txt = document.createElement("span");
      txt.className = "rebase-summary";
      if (r.action === "reword") {
        const input = document.createElement("input");
        input.className = "rebase-reword";
        input.value = r.message ?? r.summary;
        input.oninput = () => (r.message = input.value);
        r.message = r.message ?? r.summary;
        txt.appendChild(document.createTextNode(`${r.oid.slice(0, 7)} `));
        txt.appendChild(input);
      } else {
        txt.textContent = `${r.oid.slice(0, 7)} ${r.summary}`;
      }

      row.append(up, down, sel, txt);
      listEl.appendChild(row);
    });
  };
  render();

  // git refuses to rebase a dirty worktree. Offer autostash, but as a visible
  // choice pre-checked only when it's actually needed — silently stashing
  // someone's work is not ours to decide.
  let dirty = false;
  try {
    dirty = (await invoke("get_status", { path: repoPath })).length > 0;
  } catch {
    /* ignore — the checkbox just stays unchecked */
  }
  const stashRow = document.createElement("label");
  stashRow.className = "amend-row";
  const stashCb = document.createElement("input");
  stashCb.type = "checkbox";
  stashCb.checked = dirty;
  const stashText = document.createElement("span");
  stashText.textContent = dirty
    ? "工作区有未提交改动 — 变基前自动储藏并在结束后恢复 (--autostash)"
    : "变基前自动储藏工作区改动 (--autostash)";
  stashRow.append(stashCb, stashText);
  modal.appendChild(stashRow);

  const actions = document.createElement("div");
  actions.className = "modal-actions";
  const cancel = document.createElement("button");
  cancel.textContent = "取消";
  cancel.onclick = () => overlay.remove();
  const start = document.createElement("button");
  start.className = "primary";
  start.textContent = "开始变基";
  start.onclick = async () => {
    const todoText = rows.map((r) => `${r.action} ${r.oid} ${r.summary}`).join("\n") + "\n";
    // reword messages in todo order (single line each)
    const messages = rows
      .filter((r) => r.action === "reword")
      .map((r) => ((r.message ?? r.summary).trim() || r.summary));
    overlay.remove();
    try {
      const out = await invoke("rebase_interactive", {
        path: repoPath,
        base,
        todo: todoText,
        messages,
        autostash: stashCb.checked,
      });
      await refreshAll();
      setStatus(out.split("\n").slice(-1)[0] || "变基完成");
    } catch (e) {
      setStatus(String(e), true);
    }
  };
  actions.append(cancel, start);
  modal.appendChild(actions);

  overlay.appendChild(modal);
  overlay.onclick = (e) => {
    if (e.target === overlay) overlay.remove();
  };
  document.body.appendChild(overlay);
}

/* ---------- B3: file history & blame ---------- */
async function showFileHistory(file, repo = repoPath) {
  showDiffArea();
  clearCommitSelection();
  // Cross-file stepping has no meaning here; block stepping still works.
  navFiles = [];
  navIndex = -1;
  setPaneBack(paneView || hideDiffArea);
  const prefix = isMulti() ? `${repoName(repo)} / ` : "";
  $("diff-title").textContent = `文件历史 — ${prefix}${file}`;
  $("diff").innerHTML = "";
  const filesEl = $("commit-files");
  filesEl.style.display = "block";
  filesEl.innerHTML = "";
  let commits = [];
  try {
    commits = await invoke("get_file_history", { path: repo, file, limit: 200 });
  } catch (e) {
    setStatus(String(e), true);
    return;
  }
  if (!commits.length) {
    filesEl.innerHTML = '<li class="empty">没有涉及该文件的提交</li>';
    return;
  }
  for (const c of commits) {
    const li = document.createElement("li");
    li.className = "commit-item";
    li.innerHTML = commitColumns(c);
    li.onclick = () => showCommitDiff(c.id, file, repo);
    li.oncontextmenu = (e) => {
      e.preventDefault();
      showMenu(e.clientX, e.clientY, commitMenu(c));
    };
    filesEl.appendChild(li);
  }
  setStatus(`${file}：${commits.length} 个提交`);
}

async function showBlame(file, repo = repoPath) {
  showDiffArea();
  $("commit-files").style.display = "none";
  clearCommitSelection();
  navFiles = [];
  navIndex = -1;
  resetChangeBlocks();
  setPaneBack(paneView || hideDiffArea);
  const prefix = isMulti() ? `${repoName(repo)} / ` : "";
  $("diff-title").textContent = `逐行归属 — ${prefix}${file}`;
  const el = $("diff");
  el.innerHTML = "";
  let lines = [];
  try {
    lines = await invoke("get_blame", { path: repo, file });
  } catch (e) {
    setStatus(String(e), true);
    return;
  }
  lines.forEach((l, i) => {
    const row = document.createElement("div");
    row.className = "blame-row";

    const sha = document.createElement("span");
    sha.className = "blame-sha";
    sha.textContent = l.oid.slice(0, 7);
    sha.title = `${l.summary}\n${l.author}`;
    sha.onclick = () => showCommitDiff(l.oid, file, repo);

    const author = document.createElement("span");
    author.className = "blame-author";
    author.textContent = l.author;

    const no = document.createElement("span");
    no.className = "blame-no";
    no.textContent = String(i + 1);

    const code = document.createElement("span");
    code.className = "blame-code";
    code.textContent = l.content;

    row.append(sha, author, no, code);
    el.appendChild(row);
  });
}

/* ---------- B5: clone ---------- */
async function cloneRepo() {
  const url = await textPrompt("远端仓库地址");
  if (!url) return;
  const dir = await open({ directory: true, title: "克隆到哪个目录" });
  if (!dir) return;
  setStatus(`正在克隆 ${url} …`);

  // git reports progress on stderr; the backend forwards each line as an event.
  // Subscribe only for the duration of this clone.
  const unlisten = await listen("clone-progress", (e) => {
    setStatus(`克隆中：${e.payload}`);
  });
  try {
    const path = await invoke("clone_repo", { url, dir });
    await openRepoByPath(path);
    setStatus(`已克隆到 ${path}`);
  } catch (e) {
    setStatus(String(e), true);
  } finally {
    unlisten();
  }
}

/* ---------- B6: tags ---------- */
async function newTag(oid = null) {
  if (!repoPath) return;
  const name = await textPrompt(oid ? `在 ${oid.slice(0, 7)} 上打标签` : "在 HEAD 上打标签");
  if (!name) return;
  try {
    await invoke("create_tag", { path: repoPath, name, message: "", oid });
    await refreshAll();
    setStatus(`已创建标签 ${name}`);
  } catch (e) {
    setStatus(String(e), true);
  }
}

async function deleteTag(name) {
  const ok = await ask(`删除标签 "${name}"？`, { title: "删除标签", kind: "warning" });
  if (!ok) return;
  try {
    await invoke("delete_tag", { path: repoPath, name });
    await refreshAll();
    setStatus(`已删除标签 ${name}`);
  } catch (e) {
    setStatus(String(e), true);
  }
}

async function pushTag(name) {
  setStatus(`正在推送标签 ${name} …`);
  try {
    const out = await invoke("push_tag", { path: repoPath, name });
    setStatus(out.trim() || `已推送标签 ${name}`);
  } catch (e) {
    setStatus(String(e), true);
  }
}

/* ---------- B7: remotes ---------- */
async function refreshRemoteList(gen = ++refreshGen) {
  const list = $("remote-list");
  let remotes = [];
  try {
    remotes = await invoke("get_remotes", { path: repoPath });
  } catch {
    /* ignore */
  }
  if (isStale(gen)) return;
  list.innerHTML = "";
  if (!remotes.length) {
    list.innerHTML = '<li class="empty">—</li>';
    return;
  }
  for (const r of remotes) {
    const li = document.createElement("li");
    li.textContent = r.name;
    li.title = r.url;
    li.oncontextmenu = (e) => {
      e.preventDefault();
      showMenu(e.clientX, e.clientY, [
        { label: "删除该远端", danger: true, onClick: () => removeRemote(r.name) },
      ]);
    };
    list.appendChild(li);
  }
}

async function addRemote() {
  if (!repoPath) return;
  const name = await textPrompt("远端名称", "origin");
  if (!name) return;
  const url = await textPrompt(`${name} 的地址`);
  if (!url) return;
  try {
    await invoke("add_remote", { path: repoPath, name, url });
    await refreshAll();
    setStatus(`已添加远端 ${name}`);
  } catch (e) {
    setStatus(String(e), true);
  }
}

async function removeRemote(name) {
  const ok = await ask(`删除远端 "${name}"？`, { title: "删除远端", kind: "warning" });
  if (!ok) return;
  try {
    await invoke("remove_remote", { path: repoPath, name });
    await refreshAll();
    setStatus(`已删除远端 ${name}`);
  } catch (e) {
    setStatus(String(e), true);
  }
}

/* `origin/feature/x` -> remote `origin`, branch `feature/x` */
function splitRemoteRef(full) {
  const parts = full.split("/");
  return { remote: parts[0], branch: parts.slice(1).join("/") };
}

async function deleteRemoteBranch(full) {
  const { remote, branch } = splitRemoteRef(full);
  const ok = await ask(`删除远端分支 "${full}"？这会影响所有协作者。`, {
    title: "删除远端分支",
    kind: "warning",
  });
  if (!ok) return;
  setStatus(`正在删除 ${full} …`);
  try {
    await invoke("delete_remote_branch", { path: repoPath, remote, branch });
    await refreshAll();
    setStatus(`已删除远端分支 ${full}`);
  } catch (e) {
    setStatus(String(e), true);
  }
}

async function pushForce() {
  const ok = await ask(
    "强制推送当前分支？将使用 --force-with-lease：若远端有你尚未抓取的提交，推送会被拒绝。",
    { title: "强制推送", kind: "warning" },
  );
  if (!ok) return;
  setStatus("正在强制推送…");
  try {
    const out = await invoke("git_push_force", { path: repoPath });
    await refreshAll();
    setStatus(`强制推送完成。${out.trim()}`.trim());
  } catch (e) {
    setStatus(String(e), true);
  }
}

/* ---------- AI commit messages (OpenAI-compatible /chat/completions) ---------- */
/* Big diffs cost tokens and get truncated by the model anyway. */
const AI_DIFF_LIMIT = 60000;

function aiConfig() {
  return {
    baseUrl: prefs.aiBaseUrl.trim(),
    token: prefs.aiToken.trim(),
    model: prefs.aiModel.trim(),
    prompt: prefs.aiPrompt,
  };
}

/* One non-streaming chat round, sent from Rust rather than with fetch(): the
   webview needs the endpoint to answer CORS preflights (relay services often
   answer OPTIONS with 404) and blocks plain http:// targets from the packaged
   app's tauri:// origin. The command reports HTTP status and response body, so
   a wrong URL, a dead token and an unknown model each say which one it was. */
function aiChat(cfg, userContent) {
  return invoke("ai_chat", {
    url: aiEndpoint(cfg.baseUrl),
    token: cfg.token,
    model: cfg.model,
    system: cfg.prompt,
    user: userContent,
  });
}

/* The staged patch of every repo that has staged content — the same set
   doCommit() will commit, not just the active repo, or a workspace commit gets
   a message written from one repo's diff. Built from the same command the hunk
   view uses, so the text is exactly what git would commit. */
async function stagedPatch() {
  const { results } = await statusByRepo(false);

  const parts = [];
  let size = 0;
  let truncated = false;
  for (const { repo, files } of results.filter(inScope)) {
    const staged = files.filter((f) => f.staged);
    if (!staged.length) continue;
    if (isMulti()) parts.push(`# 仓库：${repo.name}`);

    for (let i = 0; i < staged.length; i++) {
      const { header, hunks } = await invoke("get_hunks", {
        path: repo.path,
        file: staged[i].path,
        staged: true,
      });
      const patch = header + hunks.join("");
      if (size + patch.length > AI_DIFF_LIMIT) {
        const rest = staged.slice(i).map((f) => f.path).join("、");
        parts.push(`\n(diff 过长已截断，未包含的文件：${rest})`);
        truncated = true;
        break;
      }
      size += patch.length;
      parts.push(patch);
    }
    if (truncated) break;
  }

  if (!parts.length) throw new Error("没有已暂存的改动 — 先勾选要提交的文件");
  return parts.join("\n");
}

async function generateCommitMessage() {
  const btn = $("ai-msg-btn");
  if (btn.classList.contains("busy")) return;

  const cfg = aiConfig();
  if (!cfg.baseUrl || !cfg.model) {
    setStatus("请先在设置 (⌘,) → AI 里填写请求地址和模型", true);
    return;
  }

  btn.classList.add("busy");
  setStatus("AI 正在生成提交说明…");
  try {
    const patch = await stagedPatch();
    const msg = await aiChat(cfg, `以下是已暂存的 git diff：\n\n${patch}`);
    $("commit-msg").value = msg;
    setStatus("AI 已生成提交说明");
  } catch (e) {
    setStatus(`AI 生成失败：${e}`, true);
  } finally {
    btn.classList.remove("busy");
  }
}

/* ---------- settings ---------- */
async function openSettings() {
  const overlay = document.createElement("div");
  overlay.className = "modal-overlay";
  overlay.style.display = "flex";

  const modal = document.createElement("div");
  modal.className = "modal settings-modal";
  modal.innerHTML = `<div class="modal-title">设置</div>`;

  const body = document.createElement("div");
  body.className = "settings-body";
  const nav = document.createElement("div");
  nav.className = "settings-nav";
  const panes = document.createElement("div");
  panes.className = "settings-panes";
  body.append(nav, panes);

  const groups = [];
  const selectPane = (form) => {
    for (const g of groups) {
      const on = g.form === form;
      g.btn.classList.toggle("active", on);
      g.form.style.display = on ? "" : "none";
    }
  };
  const addPane = (label) => {
    const form = document.createElement("div");
    form.className = "settings-form";
    const btn = document.createElement("button");
    btn.type = "button";
    btn.textContent = label;
    btn.onclick = () => selectPane(form);
    nav.appendChild(btn);
    panes.appendChild(form);
    groups.push({ btn, form });
    return form;
  };

  const field = (form, label, control) => {
    const row = document.createElement("label");
    row.className = "settings-row";
    const l = document.createElement("span");
    l.className = "settings-label";
    l.textContent = label;
    row.append(l, control);
    form.appendChild(row);
    return control;
  };

  /* Label above the control — for anything too wide for the two-column row. */
  const wideField = (form, label, control) => {
    const row = field(form, label, control);
    row.parentElement.classList.add("column");
    return row;
  };

  const hint = (form, text) => {
    const p = document.createElement("div");
    p.className = "settings-hint";
    p.textContent = text;
    form.appendChild(p);
  };

  const sectionTitle = (form, text) => {
    const title = document.createElement("div");
    title.className = "settings-section-title";
    title.textContent = text;
    form.appendChild(title);
  };

  const mkInput = (value, placeholder = "", type = "text") => {
    const i = document.createElement("input");
    i.type = type;
    i.spellcheck = false;
    i.value = value ?? "";
    i.placeholder = placeholder;
    return i;
  };
  const fillSelect = (s, opts, value) => {
    s.innerHTML = "";
    for (const [v, text] of opts) {
      const o = document.createElement("option");
      o.value = v;
      o.textContent = text;
      if (v === String(value)) o.selected = true;
      s.appendChild(o);
    }
    return s;
  };
  const mkSelect = (opts, value) => {
    const s = document.createElement("select");
    s.className = "recent-select";
    return fillSelect(s, opts, value);
  };

  /* 勾选了哪些编辑器 —— 「编辑器」页改它，「通用」页的下拉跟着重建，保存时才落盘。 */
  const chosen = new Set(prefs.editors);
  const editorOpts = () => [["", "系统默认"], ...[...chosen].sort().map((n) => [n, n])];

  /* ----- 通用 ----- */
  const generalPane = addPane("通用");
  const pullEl = field(
    generalPane,
    "拉取策略",
    mkSelect(
      [
        ["ff-only", "仅快进 (--ff-only)"],
        ["merge", "合并 (--no-rebase)"],
        ["rebase", "变基 (--rebase)"],
      ],
      prefs.pullStrategy,
    ),
  );
  hint(
    generalPane,
    "「仅快进」还表示推送被拒时跟随 git config（branch.<分支>.rebase → pull.rebase）决定合并还是变基，与 IDEA 的 Branch default 一致；选合并或变基则固定用它。",
  );
  const pageEl = field(
    generalPane,
    "历史每页条数",
    mkSelect([["50", "50"], ["100", "100"], ["200", "200"], ["500", "500"]], prefs.historyPageSize),
  );

  /* ----- 外观 ----- */
  const lookPane = addPane("外观");
  const themeEl = field(lookPane, "主题", mkSelect([["dark", "深色"], ["light", "浅色"]], prefs.theme));
  const fontEl = field(
    lookPane,
    "字号",
    mkSelect([["12", "小 (12)"], ["13", "标准 (13)"], ["15", "大 (15)"]], prefs.fontSize),
  );
  const viewEl = field(
    lookPane,
    "差异视图",
    mkSelect([["split", "并排（含词级高亮）"], ["unified", "统一"]], prefs.diffView),
  );

  // live preview for theme / font
  themeEl.onchange = () => {
    prefs.theme = themeEl.value;
    applyPrefs();
  };
  fontEl.onchange = () => {
    prefs.fontSize = Number(fontEl.value);
    applyPrefs();
  };

  /* ----- 编辑器 ----- */
  const editorPane = addPane("编辑器");
  const editorEl = field(editorPane, "默认文本编辑器", mkSelect(editorOpts(), prefs.editor));
  hint(
    editorPane,
    "右键文件 →「编辑文件」用它打开，工具栏「打开项目」没单独设过的项目也用它。" +
      "按应用名调用，不依赖 code / subl 这类命令行工具。",
  );

  let installed = [];
  try {
    installed = await invoke("list_editors");
  } catch (e) {
    hint(editorPane, `扫描本机编辑器失败：${e}`);
  }
  // 已勾选但现在扫不到的（换了机器、应用被删）也列出来，否则用户取消不掉这一条。
  const editorRows = [...new Set([...installed, ...chosen])].sort();
  if (!editorRows.length) {
    hint(editorPane, "没在 /Applications、/System/Applications、~/Applications 里找到已知的编辑器。");
  }
  // 并行取，串行的话开一次设置就要等上十几次 sips。
  const rowIcons = await Promise.all(editorRows.map((name) => editorIconUrl(name)));
  for (const [i, name] of editorRows.entries()) {
    const cb = document.createElement("input");
    cb.type = "checkbox";
    cb.checked = chosen.has(name);
    cb.onchange = () => {
      if (cb.checked) chosen.add(name);
      else chosen.delete(name);
      fillSelect(editorEl, editorOpts(), editorEl.value);
    };
    field(editorPane, installed.includes(name) ? name : `${name}（已不在本机）`, cb);

    const img = document.createElement("img");
    img.className = "settings-icon";
    img.alt = "";
    if (rowIcons[i]) img.src = rowIcons[i];
    else img.style.visibility = "hidden";
    cb.closest(".settings-row").querySelector(".settings-label").prepend(img);
  }
  hint(
    editorPane,
    "只列出本机装了的编辑器。勾上的才会出现在上面的下拉和工具栏「打开项目」的下拉里。",
  );

  /* ----- Git 信息（read from the open repo） ----- */
  const gitPane = addPane("Git 信息");
  sectionTitle(gitPane, "提交身份");
  let ident = { name: "", email: "" };
  if (repoPath) {
    try {
      ident = await invoke("get_identity", { path: repoPath });
    } catch {
      /* ignore */
    }
  }
  const nameEl = field(gitPane, "用户名 (user.name)", mkInput(ident.name, "你的名字"));
  const emailEl = field(gitPane, "邮箱 (user.email)", mkInput(ident.email, "you@example.com"));
  const globalEl = document.createElement("input");
  globalEl.type = "checkbox";
  field(gitPane, "写入全局配置 (--global)", globalEl);
  if (!repoPath) {
    hint(gitPane, "当前没有打开仓库，身份信息不会被写入。");
  }

  sectionTitle(gitPane, "远程认证");
  if (!repoPath) {
    hint(gitPane, "打开仓库后可查看和切换当前仓库的远程认证账号。");
  } else {
    let auth = null;
    try {
      auth = await invoke("get_git_credential", { path: repoPath });
    } catch (e) {
      hint(gitPane, `读取远程认证失败：${e}`);
    }

    if (auth) {
      const remoteValue = document.createElement("span");
      remoteValue.className = "settings-value";
      remoteValue.textContent = `${auth.remote} · ${auth.host}/${auth.repository}`;
      field(gitPane, "推送远端", remoteValue);

      if (auth.transport === "https") {
        const currentValue = document.createElement("span");
        currentValue.className = "settings-value";
        const renderCurrentCredential = (info) => {
          const helper = info.helper ? ` · ${info.helper}` : "";
          currentValue.textContent = info.hasCredential
            ? `${info.username || "未知账号"}${helper}`
            : `${info.username || "未找到凭据"}${helper}`;
        };
        renderCurrentCredential(auth);
        field(gitPane, "Git 当前凭据", currentValue);

        const remoteUserEl = field(
          gitPane,
          "远端用户名",
          mkInput(auth.username, "例如 Ckales"),
        );
        const remoteTokenEl = field(
          gitPane,
          "访问令牌 (PAT)",
          mkInput("", auth.hasCredential ? "••••••••" : "请输入 Personal Access Token", "password"),
        );
        remoteTokenEl.autocomplete = "new-password";
        hint(
          gitPane,
          "新令牌通过 Git credential helper 写入系统钥匙串，CGit 不保存；不修改凭据时可留空并直接测试。",
        );

        const authRow = document.createElement("div");
        authRow.className = "settings-test";
        const credentialBtn = document.createElement("button");
        credentialBtn.type = "button";
        credentialBtn.textContent = "保存凭据并测试";
        const credentialResult = document.createElement("span");
        credentialResult.className = "test-result";
        authRow.append(credentialBtn, credentialResult);
        gitPane.appendChild(authRow);

        credentialBtn.onclick = async () => {
          const username = remoteUserEl.value.trim();
          const token = remoteTokenEl.value.trim();
          const action = credentialAction(auth, username, token);
          if (action === "missing-username" || action === "missing-token") {
            credentialResult.className = "test-result bad";
            credentialResult.textContent = action === "missing-username"
              ? "请填写远端用户名"
              : "切换账号时请填写访问令牌";
            return;
          }

          credentialBtn.disabled = true;
          credentialResult.className = "test-result";
          try {
            if (action === "save-and-test") {
              credentialResult.textContent = "正在保存凭据…";
              auth = await invoke("save_git_credential", {
                path: repoPath,
                username,
                token,
              });
              renderCurrentCredential(auth);
            }
            credentialResult.textContent = "正在验证…";
            credentialResult.textContent = await invoke("test_git_credential", { path: repoPath });
            credentialResult.className = "test-result ok";
          } catch (e) {
            credentialResult.className = "test-result bad";
            const failure = authFailureInfo(e);
            credentialResult.textContent = failure?.kind === "github-403"
              ? `当前账号 ${failure.username} 没有该仓库的推送权限，请切换账号`
              : failure
                ? "远程认证失败，请检查用户名和访问令牌"
                : String(e).trim();
          } finally {
            remoteTokenEl.value = "";
            credentialBtn.disabled = false;
          }
        };
      } else if (auth.transport === "ssh") {
        hint(gitPane, "当前远端使用 SSH，认证由系统 SSH Key 和 ~/.ssh/config 管理。");
      } else {
        hint(gitPane, `当前远端使用 ${auth.transport || "未知"} 协议，CGit 不保存该协议的凭据。`);
      }
    }
  }

  /* ----- AI ----- */
  const aiPane = addPane("AI");
  const aiUrlEl = field(
    aiPane,
    "请求地址",
    mkInput(prefs.aiBaseUrl, "https://api.openai.com/v1"),
  );
  const aiTokenEl = field(aiPane, "令牌", mkInput(prefs.aiToken, "sk-…", "password"));
  const aiModelEl = field(aiPane, "模型", mkInput(prefs.aiModel, "gpt-4o-mini"));
  const aiPromptEl = wideField(aiPane, "提示词", document.createElement("textarea"));
  aiPromptEl.value = prefs.aiPrompt;
  aiPromptEl.spellcheck = false;
  hint(
    aiPane,
    "兼容 OpenAI 的 /chat/completions 接口。填基址即可，会自动补 /chat/completions。" +
      "配置好后点提交按钮左边的 ✦ 图标，用已暂存的 diff 生成提交说明。",
  );

  const testRow = document.createElement("div");
  testRow.className = "settings-test";
  const testBtn = document.createElement("button");
  testBtn.type = "button";
  testBtn.textContent = "测试";
  const testResult = document.createElement("span");
  testResult.className = "test-result";
  testRow.append(testBtn, testResult);
  aiPane.appendChild(testRow);

  testBtn.onclick = async () => {
    const cfg = {
      baseUrl: aiUrlEl.value.trim(),
      token: aiTokenEl.value.trim(),
      model: aiModelEl.value.trim(),
      prompt: aiPromptEl.value,
    };
    if (!cfg.baseUrl || !cfg.model) {
      testResult.className = "test-result bad";
      testResult.textContent = "请先填写请求地址和模型";
      return;
    }
    testBtn.disabled = true;
    testResult.className = "test-result";
    testResult.textContent = "请求中…";
    try {
      const reply = await aiChat(
        cfg,
        "以下是已暂存的 git diff：\n\ndiff --git a/README.md b/README.md\n" +
          "--- a/README.md\n+++ b/README.md\n@@ -1 +1,2 @@\n # cgit\n+一个 Git 客户端\n",
      );
      testResult.className = "test-result ok";
      testResult.textContent = `连接正常，返回：${reply.split("\n")[0].slice(0, 80)}`;
    } catch (e) {
      testResult.className = "test-result bad";
      testResult.textContent = String(e).slice(0, 300);
    } finally {
      testBtn.disabled = false;
    }
  };

  selectPane(groups[0].form);
  modal.appendChild(body);

  const actions = document.createElement("div");
  actions.className = "modal-actions";
  const cancel = document.createElement("button");
  cancel.textContent = "取消";
  cancel.onclick = () => {
    prefs = loadPrefs(); // discard live preview
    applyPrefs();
    overlay.remove();
  };
  const save = document.createElement("button");
  save.className = "primary";
  save.textContent = "保存";
  save.onclick = async () => {
    prefs.pullStrategy = pullEl.value;
    prefs.historyPageSize = Number(pageEl.value);
    prefs.theme = themeEl.value;
    prefs.fontSize = Number(fontEl.value);
    prefs.diffView = viewEl.value;
    prefs.aiBaseUrl = aiUrlEl.value.trim();
    prefs.aiToken = aiTokenEl.value.trim();
    prefs.aiModel = aiModelEl.value.trim();
    prefs.aiPrompt = aiPromptEl.value;
    prefs.editors = [...chosen].sort();
    prefs.editor = editorEl.value;
    // 编辑器被取消勾选后，还指着它的项目设置就作废了 —— 留着只会让「打开项目」去调一个
    // 列表里已经没有、界面上也看不见的应用。
    for (const [path, name] of Object.entries(prefs.projectEditors)) {
      if (name && !prefs.editors.includes(name)) delete prefs.projectEditors[path];
    }
    savePrefs();
    applyPrefs();
    showProjectEditorIcon(); // 默认编辑器变了，没单独设过的项目按钮也跟着换图标
    if (lastDiffRender) lastDiffRender();

    if (repoPath && (nameEl.value.trim() || emailEl.value.trim())) {
      try {
        await invoke("set_identity", {
          path: repoPath,
          name: nameEl.value,
          email: emailEl.value,
          global: globalEl.checked,
        });
      } catch (e) {
        setStatus(String(e), true);
      }
    }
    overlay.remove();
    if (repoPath) {
      graphLimit = prefs.historyPageSize;
      await refreshAll();
    }
    setStatus("设置已保存");
  };
  actions.append(cancel, save);
  modal.appendChild(actions);

  overlay.appendChild(modal);
  overlay.onclick = (e) => {
    if (e.target === overlay) cancel.onclick();
  };
  document.body.appendChild(overlay);
}

/* ---------- commit dialog ---------- */
/* The dialog markup lives in index.html rather than being built on demand, so
   `#changes`, `#commit-msg` and friends are always in the DOM and every
   existing refresh path keeps working while the dialog is closed. */
const commitDialogOpen = () => $("commit-overlay").style.display !== "none";

/* The diff pane is *moved*, not duplicated: clicking a file in the dialog has
   to show its diff next to the list, and a second render target would mean
   parameterising every render / navigation / staging path by destination. */
const diffPane = () => document.querySelector(".diff-pane");

/* Asked live rather than read off `dirtyRepos`, which is only as fresh as the
   last refresh — a commit or a discard made outside cgit would leave it stale.
   `repo` narrows it to one repo; without it the whole workspace counts. */
async function hasChanges(repo = null) {
  if (repo) return (await invoke("get_status", { path: repo })).length > 0;
  const { results } = await statusByRepo(false);
  return results.some((r) => r.total > 0);
}

let commitIdentityGen = 0;

async function refreshCommitIdentity(path) {
  const gen = ++commitIdentityGen;
  const input = $("author-input");
  input.placeholder = "正在读取当前 Git 身份…";
  try {
    const identity = await invoke("get_identity", { path });
    if (gen !== commitIdentityGen || path !== (commitScope || repoPath)) return;
    const current = identity.name && identity.email
      ? `${identity.name} <${identity.email}>`
      : identity.name || identity.email || "未配置 Git 身份";
    input.placeholder = current;
    input.closest(".author-field").title = `当前仓库 Git 身份：${current}；填写后仅覆盖本次提交`;
  } catch {
    if (gen !== commitIdentityGen || path !== (commitScope || repoPath)) return;
    input.placeholder = "未读取到 Git 身份";
  }
}

async function openCommitDialog() {
  if (!repoPath) return;
  // Nothing staged or modified anywhere: the dialog would only have a "工作区
  // 干净" list and a dead 提交 button to show.
  if (!(await hasChanges())) {
    notify("当前没有可提交内容");
    return;
  }
  undockCommitPanel(); // one panel, one place at a time
  $("commit-overlay").style.display = "flex";
  $("commit-body").appendChild(diffPane());
  await refreshCommitIdentity(repoPath);
  // A diff left open in the main window would otherwise keep its half of the
  // window reserved with the pane no longer in it.
  document.documentElement.dataset.diffOpen = "0";
  $("commit-msg").focus();
}

function closeCommitDialog() {
  // Guarded: callers fire this after any successful commit, and while the
  // panel is docked that would rip the diff pane out of it.
  if (!commitDialogOpen()) return;
  // Put the pane back first, so the main window is never left without it.
  document.querySelector(".work").appendChild(diffPane());
  $("commit-overlay").style.display = "none";
  // The diff being shown belonged to the dialog. Leaving it open drops it into
  // the main window on its own — undockCommitPanel() closes it for the same
  // reason when the docked panel goes away.
  hideDiffArea();
}

/* ---------- docked per-repo commit panel ----------
   Clicking a repo in the sidebar docks the commit panel — the same element the
   dialog uses, moved like the diff pane is — into the work area, scoped to
   that one repo, so a single repo of a workspace can be reviewed and committed
   on its own. */
let commitScope = null;
const commitDocked = () => commitScope !== null;
const commitPanel = () => document.querySelector(".commit-modal");
/* Applied to `statusByRepo` results wherever the scope matters: the changes
   list, stage-all, the AI message's diff, and the commit itself. */
const inScope = (r) => !commitScope || r.repo.path === commitScope;

async function dockCommitPanel(path) {
  closeCommitDialog();
  // Drop whatever the diff pane was showing — clicking a repo replaces a
  // commit's detail rather than sitting beside it. Re-clicking the repo that
  // is already active gets here too, where setActiveRepo returns early.
  hideDiffArea();
  commitScope = path;
  document.querySelector(".work").prepend(commitPanel());
  $("commit-body").appendChild(diffPane());
  document.documentElement.dataset.diffOpen = "1";
  $("commit-panel-title").textContent = `提交 · ${repoName(path)}`;
  await Promise.all([refreshChanges(), refreshCommitIdentity(path)]);
}

function undockCommitPanel() {
  if (!commitDocked()) return;
  commitScope = null;
  // Pane out of the panel first, then the panel back to its overlay.
  document.querySelector(".work").appendChild(diffPane());
  $("commit-overlay").appendChild(commitPanel());
  $("commit-panel-title").textContent = "提交";
  hideDiffArea();
  refreshChanges();
}

/* Sidebar click: aim the single-repo panels at the repo, then dock its commit
   panel under the history. */
async function openRepoCommit(path) {
  await setActiveRepo(path);
  // A clean repo gets no commit panel — it would be an empty box under the
  // history. Clicking it still switches the single-repo panels to it, and that
  // is what the user asked for: the bar, not a box. `notify` is for a request
  // that did NOT happen (see the three-way rule above setStatus) — the switch
  // happened, so making it click-to-dismiss turned every repo switch into a
  // dialog.
  if (!(await hasChanges(path))) {
    undockCommitPanel();
    setStatus(`${repoName(path)} 没有可提交内容`);
    return;
  }
  await dockCommitPanel(path);
}

/* ---------- draggable history / work divider ---------- */
const MIN_HISTORY_PX = 90;
const MIN_WORK_PX = 180;

/* Clamped against the live container height, so a height stored on a big
   window can't push the work area off a small one. */
function applyHistoryHeight(px) {
  const panel = document.querySelector(".history-panel");
  const container = document.querySelector(".main-right");
  const splitter = $("v-splitter");
  const room = container.clientHeight - splitter.offsetHeight - MIN_WORK_PX;
  const height = Math.max(MIN_HISTORY_PX, Math.min(px, Math.max(MIN_HISTORY_PX, room)));
  panel.style.flex = `0 0 ${height}px`;
  return height;
}

/* Same idea one axis over: the sidebar's width. Clamped against the live window
   so a width stored on a wide screen can't swallow a narrow one. */
const MIN_SIDEBAR_PX = 150;
const MIN_RIGHT_PX = 420;

function applySidebarWidth(px) {
  const sidebar = document.querySelector(".sidebar");
  const layout = document.querySelector(".layout");
  const splitter = $("h-splitter");
  const room = layout.clientWidth - splitter.offsetWidth - MIN_RIGHT_PX;
  const width = Math.max(MIN_SIDEBAR_PX, Math.min(px, Math.max(MIN_SIDEBAR_PX, room)));
  sidebar.style.width = `${width}px`;
  return width;
}

function initSidebarSplitter() {
  const splitter = $("h-splitter");
  const sidebar = document.querySelector(".sidebar");
  if (prefs.sidebarWidth) applySidebarWidth(prefs.sidebarWidth);

  splitter.onpointerdown = (e) => {
    e.preventDefault();
    const startX = e.clientX;
    const startWidth = sidebar.getBoundingClientRect().width;
    splitter.setPointerCapture(e.pointerId);
    splitter.classList.add("dragging");
    document.body.classList.add("resizing-h");

    const move = (ev) => applySidebarWidth(startWidth + ev.clientX - startX);
    const end = (ev) => {
      splitter.releasePointerCapture(ev.pointerId);
      splitter.classList.remove("dragging");
      document.body.classList.remove("resizing-h");
      splitter.removeEventListener("pointermove", move);
      splitter.removeEventListener("pointerup", end);
      splitter.removeEventListener("pointercancel", end);
      prefs.sidebarWidth = Math.round(sidebar.getBoundingClientRect().width);
      savePrefs();
    };
    splitter.addEventListener("pointermove", move);
    splitter.addEventListener("pointerup", end);
    splitter.addEventListener("pointercancel", end);
  };

  splitter.ondblclick = () => {
    sidebar.style.width = "";
    prefs.sidebarWidth = null;
    savePrefs();
  };

  window.addEventListener("resize", () => {
    if (prefs.sidebarWidth) applySidebarWidth(prefs.sidebarWidth);
  });
}

function initSplitter() {
  const splitter = $("v-splitter");
  const panel = document.querySelector(".history-panel");
  if (prefs.historyHeight) applyHistoryHeight(prefs.historyHeight);

  splitter.onpointerdown = (e) => {
    e.preventDefault();
    const startY = e.clientY;
    const startHeight = panel.getBoundingClientRect().height;
    // Pointer capture keeps the drag alive when the cursor outruns the strip.
    splitter.setPointerCapture(e.pointerId);
    splitter.classList.add("dragging");
    document.body.classList.add("resizing-v");

    const move = (ev) => applyHistoryHeight(startHeight + ev.clientY - startY);
    const end = (ev) => {
      splitter.releasePointerCapture(ev.pointerId);
      splitter.classList.remove("dragging");
      document.body.classList.remove("resizing-v");
      splitter.removeEventListener("pointermove", move);
      splitter.removeEventListener("pointerup", end);
      splitter.removeEventListener("pointercancel", end);
      prefs.historyHeight = Math.round(panel.getBoundingClientRect().height);
      savePrefs();
    };
    splitter.addEventListener("pointermove", move);
    splitter.addEventListener("pointerup", end);
    splitter.addEventListener("pointercancel", end);
  };

  // Double-click goes back to the default ratio.
  splitter.ondblclick = () => {
    panel.style.flex = "";
    prefs.historyHeight = null;
    savePrefs();
  };

  window.addEventListener("resize", () => {
    if (prefs.historyHeight) applyHistoryHeight(prefs.historyHeight);
  });
}

/* ---------- keyboard shortcuts ---------- */
function isTyping(el) {
  return el && (el.tagName === "INPUT" || el.tagName === "TEXTAREA");
}

document.addEventListener("keydown", (e) => {
  const mod = e.metaKey || e.ctrlKey;

  if (e.key === "Escape") {
    // Innermost layer first: a context menu over a dialog, then the dialogs
    // built on the fly (push, update method), then the commit dialog. Each
    // on-the-fly dialog cancels through its own `onEsc` — the update method
    // one has a promise waiting on it, so it must resolve, not just vanish.
    const dialogs = document.querySelectorAll(".dialog-overlay");
    if ($("context-menu").style.display === "block") {
      hideMenu();
    } else if (dialogs.length) {
      dialogs[dialogs.length - 1].onEsc();
    } else if (commitDialogOpen()) {
      closeCommitDialog();
    }
    return;
  }
  if (!mod) return;

  const k = e.key.toLowerCase();
  // Cmd+Enter opens the commit dialog, or commits when it is already open.
  if (e.key === "Enter") {
    e.preventDefault();
    if (!repoPath) return;
    if (commitDialogOpen() || commitDocked()) doCommit(e.shiftKey);
    else openCommitDialog();
    return;
  }
  if (isTyping(e.target) && k !== "o" && k !== ",") return;

  const run = (fn) => {
    e.preventDefault();
    fn();
  };
  switch (k) {
    case "o":
      return run(openRepoDialog);
    case ",":
      return run(openSettings);
    case "r":
      return run(() => repoPath && refreshAll());
    case "t":
      return run(() => repoPath && runNet("git_fetch", "抓取"));
    case "l":
      return run(() => repoPath && runNet("git_pull", "拉取"));
    case "p":
      return run(pushAction);
    case "n":
      return run(() => repoPath && newBranch());
    case "s":
      return run(() => repoPath && stashSave());
  }
});

async function showCommitMessageHistory(e) {
  e.stopPropagation();
  const rect = e.currentTarget.getBoundingClientRect();
  const path = commitScope || repoPath;
  if (!path) return;
  let messages;
  try {
    messages = await invoke("get_commit_messages", { path, limit: 30 });
  } catch (error) {
    setStatus(String(error), true);
    return;
  }
  if (!messages.length) {
    notify("当前仓库没有历史提交说明");
    return;
  }

  const items = [{ header: `历史提交说明 · ${repoName(path)}` }];
  for (const message of messages) {
    const lines = message.split("\n").map((line) => line.trim()).filter(Boolean);
    const label = (lines[0] || message).slice(0, 80);
    const sublabel = lines.slice(1).join(" ").slice(0, 120);
    items.push({
      label,
      sublabel,
      onClick: () => {
        $("commit-msg").value = message;
        $("commit-msg").focus();
      },
    });
  }
  showMenu(rect.left, rect.bottom + 4, items);
}

/* Amending replaces HEAD's message, so start from it rather than making the
   user retype it. Only when the box is empty — never clobber a draft. */
$("amend-cb").onchange = async () => {
  if (!$("amend-cb").checked || !repoPath || $("commit-msg").value.trim()) return;
  try {
    $("commit-msg").value = await invoke("get_head_message", { path: repoPath });
  } catch (e) {
    setStatus(String(e), true);
  }
};

$("open-commit-btn").onclick = openCommitDialog;
$("commit-close-btn").onclick = () =>
  commitDocked() ? undockCommitPanel() : closeCommitDialog();
$("commit-overlay").onclick = (e) => {
  if (e.target === $("commit-overlay")) closeCommitDialog();
};

$("diff-close-btn").onclick = hideDiffArea;
$("diff-back-btn").onclick = () => paneBack && paneBack();

$("prev-change-btn").onclick = () => navigateChange(-1);
$("next-change-btn").onclick = () => navigateChange(1);

$("diff-view-btn").onclick = () => {
  prefs.diffView = prefs.diffView === "split" ? "unified" : "split";
  savePrefs();
  applyPrefs();
  if (lastDiffRender) lastDiffRender();
};

$("add-remote-btn").onclick = addRemote;
$("new-tag-btn").onclick = () => newTag();
$("stage-all-btn").onclick = () => stageAll(true);
$("unstage-all-btn").onclick = () => stageAll(false);
$("push-btn").oncontextmenu = (e) => {
  e.preventDefault();
  if (!repoPath) return;
  showMenu(e.clientX, e.clientY, [
    { label: "强制推送 (--force-with-lease)", danger: true, onClick: pushForce },
  ]);
};

/* Debounced so typing doesn't fire a git log per keystroke. */
const debounce = (fn, ms) => {
  let t = null;
  return () => {
    clearTimeout(t);
    t = setTimeout(fn, ms);
  };
};
const onLogSearch = debounce(() => repoPath && refreshLog(), 250);
$("log-search").oninput = onLogSearch;
$("log-author").oninput = onLogSearch;
$("changes-filter").oninput = debounce(() => repoPath && refreshChanges(), 150);

$("settings-btn").onclick = openSettings;
$("new-branch-btn").onclick = () => newBranch();
$("stash-btn").onclick = stashSave;
$("commit-btn").onclick = () => doCommit(false);
$("commit-history-btn").onclick = showCommitMessageHistory;
$("ai-msg-btn").onclick = generateCommitMessage;
$("commit-more-btn").onclick = (e) => {
  e.stopPropagation();
  const r = e.currentTarget.getBoundingClientRect();
  showMenu(r.right - 150, r.bottom + 4, [
    { label: "提交并推送", onClick: () => doCommit(true) },
  ]);
};
/* Every left click closes the menu — which is also why a left-click handler
   cannot open one: the click bubbles up here immediately after. Menus hang off
   oncontextmenu. */
document.addEventListener("click", hideMenu);
document.addEventListener("scroll", hideMenu, true);
$("fetch-btn").onclick = () => runNet("git_fetch", "抓取");
$("pull-btn").onclick = () => runNet("git_pull", "拉取");
$("push-btn").onclick = pushAction;
/* This menu is now the only way in, so it must open even with no recents —
   otherwise there'd be nowhere to open the first repo from. */
$("project-btn").onclick = (e) => {
  e.stopPropagation(); // or the document-level click closes it immediately
  const r = e.currentTarget.getBoundingClientRect();
  const items = [
    { label: "打开…", onClick: openRepoDialog },
    { label: "克隆仓库…", onClick: cloneRepo },
  ];
  const list = loadRecent();
  if (list.length) {
    items.push({ header: "最近的项目" });
    for (const path of list) {
      items.push({
        label: projectName(path),
        sublabel: prettyPath(path),
        current: path === workspaceRoot,
        onClick: () => openRepoByPath(path),
      });
    }
  }
  showMenu(r.left, r.bottom + 4, items);
};

/* ---------- 补丁 ---------- */
/* 作用范围是当前活跃仓库，不是整个工作区：跨仓库拼一个补丁，路径在哪边都对不上。 */
const PATCH_FILTER = [{ name: "补丁", extensions: ["patch", "diff"] }];

/* 文件名照 IDEA 的做法从标题来：空格和路径里不能用的字符统统换成下划线。 */
const patchFileName = (title) =>
  `${title.replace(/[^\p{L}\p{N}._-]+/gu, "_").slice(0, 80) || "patch"}.patch`;

async function deliverPatch(text, toClipboard, defaultName, note = "") {
  if (toClipboard) {
    if (await copyText(text)) setStatus(`补丁已复制到剪贴板${note}`);
    return;
  }
  const file = await save({ title: "保存补丁", defaultPath: defaultName, filters: PATCH_FILTER });
  if (!file) return;
  try {
    await invoke("save_patch", { file, content: text });
    setStatus(`补丁已保存到 ${file}${note}`);
  } catch (e) {
    setStatus(String(e), true);
  }
}

async function createPatch(toClipboard) {
  if (!repoPath) return;
  let text;
  try {
    text = await invoke("create_patch", { path: repoPath });
  } catch (e) {
    return setStatus(String(e), true);
  }
  if (!text.trim()) return setStatus("没有勾选任何改动", true);
  await deliverPatch(text, toClipboard, patchFileName(repoName(repoPath)));
}

async function createCommitPatch(commit, toClipboard) {
  let text;
  try {
    text = await invoke("create_commit_patch", { path: repoPath, oid: commit.id });
  } catch (e) {
    return setStatus(String(e), true);
  }
  if (!text.trim()) return setStatus("这个提交没有可导出的改动", true);
  await deliverPatch(text, toClipboard, patchFileName(commit.summary));
}

/* git apply 是全有或全无的：对不上就整个不动，所以失败时工作区还是原样。 */
async function applyPatchText(patch, source) {
  if (!patch.trim()) return setStatus(`${source}里没有补丁内容`, true);
  try {
    await invoke("apply_patch", { path: repoPath, patch });
    setStatus(`已应用来自${source}的补丁`);
    await refreshAll();
  } catch (e) {
    setStatus(String(e), true);
  }
}

async function applyPatchFromFile() {
  const file = await open({ title: "选择补丁文件", filters: PATCH_FILTER });
  if (!file) return;
  try {
    await applyPatchText(await invoke("read_patch_file", { file }), file);
  } catch (e) {
    setStatus(String(e), true);
  }
}

async function applyPatchFromClipboard() {
  try {
    await applyPatchText(await invoke("read_clipboard"), "剪贴板");
  } catch (e) {
    setStatus(String(e), true);
  }
}

$("patch-btn").onclick = (e) => {
  e.stopPropagation(); // or the document-level click closes it immediately
  const r = e.currentTarget.getBoundingClientRect();
  // 应用补丁不在这儿：补丁落到工作区，入口挂在当前分支的右键菜单上。
  showMenu(r.left, r.bottom + 4, [
    ...(isMulti() ? [{ header: repoName(repoPath) }] : []),
    { label: "创建补丁到文件…", onClick: () => createPatch(false) },
    { label: "创建补丁到剪贴板", onClick: () => createPatch(true) },
  ]);
};

/* ---------- 打开项目 ---------- */
/* 当前项目用哪个编辑器：项目自己设过就用它，否则退到默认文本编辑器（空串 = 系统默认）。 */
const projectEditor = () => prefs.projectEditors[workspaceRoot] ?? prefs.editor;

const editorLabel = (name) => name || "系统默认";

/* 应用图标按编辑器名缓存 blob URL。取不到的记成空串，免得每次刷新都再问一遍系统。 */
const editorIcons = new Map();

/* 空串（系统默认）和取不到图标的都返回空串，调用方按「没图标」处理。 */
async function editorIconUrl(name) {
  if (!name) return "";
  if (!editorIcons.has(name)) {
    try {
      const png = await invoke("editor_icon", { name });
      editorIcons.set(name, URL.createObjectURL(new Blob([new Uint8Array(png)], { type: "image/png" })));
    } catch {
      editorIcons.set(name, "");
    }
  }
  return editorIcons.get(name);
}

async function showProjectEditorIcon() {
  const img = $("open-project-icon");
  const url = await editorIconUrl(projectEditor());
  img.hidden = !url;
  if (url) img.src = url;
}

$("open-project-btn").onclick = async () => {
  if (!workspaceRoot) return;
  try {
    await invoke("open_path", { path: workspaceRoot, editor: projectEditor() });
  } catch (e) {
    setStatus(String(e), true);
  }
};

$("open-project-menu-btn").onclick = async (e) => {
  e.stopPropagation(); // or the document-level click closes it immediately
  const r = e.currentTarget.getBoundingClientRect();
  const current = projectEditor();
  const names = [...prefs.editors];
  // 并行取：第一次开菜单每个图标都要现拉一次，串行的话几个编辑器就能拖出肉眼可见的延迟。
  const icons = await Promise.all(names.map((name) => editorIconUrl(name)));
  const items = [];
  for (const [i, name] of names.entries()) {
    items.push({
      label: editorLabel(name),
      icon: icons[i],
      current: name === current,
      onClick: () => {
        prefs.projectEditors[workspaceRoot] = name;
        savePrefs();
        showProjectEditorIcon();
        setStatus(`「${projectName(workspaceRoot)}」以后用${editorLabel(name)}打开`);
      },
    });
  }
  if (!prefs.editors.length) {
    items.push({ label: "去设置里添加编辑器…", onClick: openSettings });
  }
  showMenu(r.right, r.bottom + 4, items);
};

/* ---------- auto-refresh on file-system changes ---------- */
let refreshTimer = null;
let pendingRefs = false;
listen("repo-changed", (e) => {
  if (!repoPath) return;
  // Sticky across the debounce window: one edit event must not downgrade the
  // ref move that arrived with it.
  if (e.payload === "refs") pendingRefs = true;
  clearTimeout(refreshTimer);
  // Working-tree edits don't change the commit graph or the branch labels, so
  // they get the light refresh. A checkout or commit made outside cgit does,
  // and only the watcher tells us about it — our own ones call refreshAll().
  refreshTimer = setTimeout(() => {
    const full = pendingRefs;
    pendingRefs = false;
    return full ? refreshAll() : refreshLight();
  }, 250);
});

/* ---------- startup: restore last repo ---------- */
(async function init() {
  hideDiffArea(); // closed until the user clicks something
  applyPrefs();
  // Best effort: without it, paths in the project menu just stay absolute.
  try {
    homePrefix = (await homeDir()).replace(/\/$/, "");
  } catch {
    /* ignore */
  }
  initSplitter();
  initSidebarSplitter();
  graphLimit = prefs.historyPageSize;
  // Walk the recent list in order: a path that has since been moved or deleted
  // must not block startup, and nothing is pruned behind the user's back.
  for (const path of loadRecent()) {
    if (await openRepoByPath(path)) break;
  }
})();
