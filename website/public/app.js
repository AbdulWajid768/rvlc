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
const reducedMotion = matchMedia("(prefers-reduced-motion: reduce)").matches;

const all = (selector) => [...document.querySelectorAll(selector)];
const setText = (selector, text) => all(selector).forEach((el) => (el.textContent = text));

// Two sources for the download total: the Firestore counter (website clicks)
// and GitHub's own download_count for every DMG ever released (which also
// includes downloads made straight from GitHub). The page shows the larger.
const state = {
  tag: FALLBACK.tag,
  url: RELEASES_PAGE,
  firestore: null,
  siteCount: null,
  githubCount: null,
  ownDownload: 0,
  shown: null,
};

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

// Just enough Markdown for release notes: headings, bullet and numbered lists,
// paragraphs, **bold**, `code` and https links. Text is escaped first, so notes
// cannot inject HTML. Sections the page already covers (Install) are left out.
function renderNotes(markdown) {
  const inline = (s) =>
    escapeHTML(s)
      .replace(/`([^`]+)`/g, "<code>$1</code>")
      .replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>")
      .replace(/\[([^\]]+)\]\((https:\/\/[^\s)]+)\)/g, '<a href="$2">$1</a>');
  const out = [];
  let list = null;
  const close = () => list && (out.push(`</${list}>`), (list = null));
  for (const raw of markdown.split(/\r?\n/)) {
    const line = raw.trim();
    if (/^#{1,6}\s+install\b/i.test(line)) break;
    const item = line.match(/^(?:[-*]|(\d+)\.)\s+(.*)/);
    if (item) {
      const kind = item[1] ? "ol" : "ul";
      if (list !== kind) close(), out.push(`<${kind}>`), (list = kind);
      out.push(`<li>${inline(item[2])}</li>`);
      continue;
    }
    close();
    if (/^#{1,6}\s/.test(line)) out.push(`<h4>${inline(line.replace(/^#+\s*/, ""))}</h4>`);
    else if (line) out.push(`<p>${inline(line)}</p>`);
  }
  close();
  return out.join("");
}

// ---------- Latest release (GitHub) ----------

async function loadRelease() {
  const cacheKey = "rvlc-release-v2";
  let release = null;
  try {
    const cached = JSON.parse(sessionStorage.getItem(cacheKey) || "null");
    if (cached && Date.now() - cached.at < 10 * 60 * 1000) release = cached.release;
  } catch { /* ignore */ }

  if (!release) {
    try {
      const res = await fetch(`https://api.github.com/repos/${REPO}/releases?per_page=100`, {
        headers: { Accept: "application/vnd.github+json" },
      });
      if (!res.ok) throw new Error(`GitHub API ${res.status}`);
      const published = (await res.json()).filter((r) => !r.draft && !r.prerelease);
      const isDmg = (a) => a.name.toLowerCase().endsWith(".dmg");
      const downloads = published.flatMap((r) => r.assets.filter(isDmg)).reduce((n, a) => n + a.download_count, 0);
      const data = published[0];
      if (!data) throw new Error("no published release");
      const dmgs = (data.assets || []).filter(isDmg);
      const dmg = dmgs.find((a) => /arm64|apple|universal/i.test(a.name)) || dmgs[0];
      release = {
        tag: data.tag_name,
        date: data.published_at,
        notes: data.body || "",
        page: data.html_url,
        url: dmg ? dmg.browser_download_url : null,
        size: dmg ? dmg.size : null,
        downloads,
      };
      try { sessionStorage.setItem(cacheKey, JSON.stringify({ at: Date.now(), release })); } catch { /* ignore */ }
    } catch (err) {
      console.info("Using built-in release info:", err.message);
      return;
    }
  }

  state.githubCount = release.downloads ?? null;
  renderCount();
  state.tag = release.tag;
  state.url = release.url || release.page || RELEASES_PAGE;
  all("[data-download]").forEach((a) => (a.href = state.url));
  setText("[data-version]", withV(release.tag));
  setText(
    "[data-release-meta]",
    ["Apple silicon · macOS 26+", release.size && formatSize(release.size)].filter(Boolean).join(" · "),
  );
  setText("[data-release-date]", `Released ${formatDate(release.date)}`);
  setText("[data-notes-title]", `RVLC ${release.tag.replace(/^v/, "")}`);
  if (release.notes.trim()) all("[data-notes]").forEach((el) => (el.innerHTML = renderNotes(release.notes)));
  if (release.page) {
    all("[data-notes-link]").forEach((a) => {
      a.href = release.page;
      a.textContent = "Release on GitHub →";
    });
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

function renderCount() {
  const known = [state.siteCount, state.githubCount === null ? null : state.githubCount + state.ownDownload];
  const values = known.filter((n) => n !== null);
  if (!values.length) return;
  const count = Math.max(...values);
  const from = state.shown ?? 0;
  state.shown = count;
  setText("[data-count-label]", count === 1 ? "download" : "downloads");
  all("[data-counter]").forEach((el) => (el.hidden = false));

  const format = (n) => new Intl.NumberFormat("en-US").format(Math.round(n));
  if (reducedMotion || count - from <= 1) return setText("[data-count]", format(count));
  // Count up from the previous value.
  const start = performance.now();
  const step = (now) => {
    const t = Math.min(1, (now - start) / 1400);
    setText("[data-count]", format(from + (count - from) * (1 - Math.pow(1 - t, 3))));
    if (t < 1 && state.shown === count) requestAnimationFrame(step);
  };
  requestAnimationFrame(step);
}

async function loadCount() {
  try {
    state.firestore = await firestoreConfig();
    const { base, root, key } = state.firestore;
    const res = await fetch(`${base}/${root}/${COUNTER_DOC}${key}`);
    if (res.status === 404) {
      state.siteCount = 0;
    } else {
      if (!res.ok) throw new Error(`Firestore ${res.status}`);
      const doc = await res.json();
      state.siteCount = Number(doc.fields?.count?.integerValue ?? 0);
    }
    renderCount();
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
  const button = event.currentTarget;
  const counted = `rvlc-dl-${state.tag}`;
  if (!storage.get(counted)) {
    button.setAttribute("aria-busy", "true");
    const ok = await Promise.race([incrementCount().catch(() => false), timeout(1500).then(() => false)]);
    if (ok && state.siteCount !== null) state.siteCount += 1;
    state.ownDownload = 1; // GitHub counts this download too, a little later
    storage.set(counted, "1");
    renderCount();
    button.removeAttribute("aria-busy");
  }
  location.href = state.url;
}

all("[data-download]").forEach((a) => a.addEventListener("click", onDownload));

loadRelease();
loadCount();
