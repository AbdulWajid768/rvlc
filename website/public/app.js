// RVLC website: latest release from GitHub and the download counter in Firestore.
//
// The counter uses Firestore's REST API instead of the Firebase SDK, so the page
// loads nothing from third parties except the GitHub API. The project config
// comes from Firebase Hosting's reserved /__/firebase/init.json.

const REPO = "AbdulWajid768/rvlc";
const RELEASES_PAGE = `https://github.com/${REPO}/releases/latest`;
const FALLBACK = { tag: "v0.1.0", date: "2026-10-20" };
const COUNTER_DOC = "stats/downloads";
const isLocal = ["localhost", "127.0.0.1"].includes(location.hostname);

const $ = (id) => document.getElementById(id);
const els = {
  download: $("download"),
  badge: $("version-badge"),
  meta: $("release-meta"),
  counter: $("counter"),
  count: $("download-count"),
  countLabel: $("download-label"),
  notes: $("notes"),
  notesTitle: $("notes-title"),
  notesLink: $("notes-link"),
};

const state = { tag: FALLBACK.tag, url: RELEASES_PAGE, count: null, firestore: null };

// ---------- Helpers ----------

const storage = {
  get(key) {
    try { return localStorage.getItem(key); } catch { return null; }
  },
  set(key, value) {
    try { localStorage.setItem(key, value); } catch { /* private mode: ignore */ }
  },
};

const withV = (tag) => (tag.startsWith("v") ? tag : `v${tag}`);
const formatDate = (iso) =>
  new Date(iso).toLocaleDateString("en-US", { year: "numeric", month: "short", day: "numeric", timeZone: "UTC" });
const formatSize = (bytes) => `${(bytes / 1_000_000).toFixed(1)} MB`;
const timeout = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function escapeHTML(text) {
  return text.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
}

// Just enough Markdown for release notes: headings, bullet lists, paragraphs,
// **bold** and `code`. Text is escaped first, so notes cannot inject HTML.
function renderNotes(markdown) {
  const inline = (s) =>
    escapeHTML(s)
      .replace(/`([^`]+)`/g, "<code>$1</code>")
      .replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>");
  const out = [];
  let list = false;
  for (const raw of markdown.split(/\r?\n/)) {
    const line = raw.trim();
    const item = line.match(/^[-*]\s+(.*)/);
    if (!item && list) { out.push("</ul>"); list = false; }
    if (item) {
      if (!list) { out.push("<ul>"); list = true; }
      out.push(`<li>${inline(item[1])}</li>`);
    } else if (/^#{1,6}\s/.test(line)) {
      out.push(`<h4>${inline(line.replace(/^#+\s*/, ""))}</h4>`);
    } else if (line) {
      out.push(`<p>${inline(line)}</p>`);
    }
  }
  if (list) out.push("</ul>");
  return out.join("");
}

// ---------- Latest release (GitHub) ----------

async function loadRelease() {
  const cacheKey = "rvlc-release";
  let release = null;
  try {
    const cached = JSON.parse(sessionStorage.getItem(cacheKey) || "null");
    if (cached && Date.now() - cached.at < 10 * 60 * 1000) release = cached.release;
  } catch { /* ignore */ }

  if (!release) {
    try {
      const res = await fetch(`https://api.github.com/repos/${REPO}/releases/latest`, {
        headers: { Accept: "application/vnd.github+json" },
      });
      if (!res.ok) throw new Error(`GitHub API ${res.status}`);
      const data = await res.json();
      const dmgs = (data.assets || []).filter((a) => a.name.toLowerCase().endsWith(".dmg"));
      const dmg = dmgs.find((a) => /arm64|apple|universal/i.test(a.name)) || dmgs[0];
      release = {
        tag: data.tag_name,
        date: data.published_at,
        notes: data.body || "",
        page: data.html_url,
        url: dmg ? dmg.browser_download_url : null,
        size: dmg ? dmg.size : null,
      };
      try { sessionStorage.setItem(cacheKey, JSON.stringify({ at: Date.now(), release })); } catch { /* ignore */ }
    } catch (err) {
      console.info("Using built-in release info:", err.message);
      return;
    }
  }

  state.tag = release.tag;
  state.url = release.url || release.page || RELEASES_PAGE;
  els.download.href = state.url;
  els.badge.textContent = withV(release.tag);
  els.meta.textContent = [`Released ${formatDate(release.date)}`, release.size && formatSize(release.size)]
    .filter(Boolean)
    .join(" · ");
  els.notesTitle.textContent = `RVLC ${release.tag.replace(/^v/, "")}`;
  if (release.notes.trim()) els.notes.innerHTML = renderNotes(release.notes);
  if (release.page) {
    els.notesLink.href = release.page;
    els.notesLink.textContent = "Release on GitHub →";
  }
}

// ---------- Download counter (Firestore REST) ----------

async function firestoreConfig() {
  const res = await fetch("/__/firebase/init.json");
  if (!res.ok) throw new Error(`init.json ${res.status}`);
  const { projectId, apiKey } = await res.json();
  if (!projectId) throw new Error("no projectId");
  const base = isLocal ? "http://127.0.0.1:8085/v1" : "https://firestore.googleapis.com/v1";
  const root = `projects/${projectId}/databases/(default)/documents`;
  const key = !isLocal && apiKey ? `?key=${encodeURIComponent(apiKey)}` : "";
  return { base, root, key };
}

function showCount(count) {
  state.count = count;
  els.count.textContent = new Intl.NumberFormat("en-US").format(count);
  els.countLabel.textContent = count === 1 ? "download" : "downloads";
  els.counter.hidden = false;
}

async function loadCount() {
  try {
    state.firestore = await firestoreConfig();
    const { base, root, key } = state.firestore;
    const res = await fetch(`${base}/${root}/${COUNTER_DOC}${key}`);
    if (res.status === 404) return showCount(0);
    if (!res.ok) throw new Error(`Firestore ${res.status}`);
    const doc = await res.json();
    showCount(Number(doc.fields?.count?.integerValue ?? 0));
  } catch (err) {
    console.info("Download counter unavailable:", err.message);
  }
}

// Adds exactly one to the counter (creating it on the first download). The
// security rules reject anything else.
async function incrementCount() {
  if (!state.firestore) return false;
  const { base, root, key } = state.firestore;
  const name = `${root}/${COUNTER_DOC}`;
  const res = await fetch(`${base}/${root.replace(/\/documents$/, "/documents:commit")}${key}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    keepalive: true,
    body: JSON.stringify({
      writes: [
        {
          update: { name, fields: {} },
          updateMask: { fieldPaths: [] },
          updateTransforms: [{ fieldPath: "count", increment: { integerValue: "1" } }],
        },
      ],
    }),
  });
  return res.ok;
}

// Each browser counts once per release, so repeat clicks don't inflate the total.
async function onDownload(event) {
  event.preventDefault();
  const counted = `rvlc-dl-${state.tag}`;
  if (!storage.get(counted)) {
    els.download.setAttribute("aria-busy", "true");
    const ok = await Promise.race([incrementCount().catch(() => false), timeout(1500).then(() => false)]);
    if (ok) {
      storage.set(counted, "1");
      if (state.count !== null) showCount(state.count + 1);
    }
    els.download.removeAttribute("aria-busy");
  }
  location.href = state.url;
}

els.download.addEventListener("click", onDownload);
document.querySelectorAll("[data-download]").forEach((a) => a.addEventListener("click", onDownload));

loadRelease();
loadCount();
