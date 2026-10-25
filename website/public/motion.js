// RVLC website motion: opening titles, scroll-linked effects, reveals, the
// interactive subtitle-sync demo and the small loops in the feature grid.
// Everything degrades to a static page when reduced motion is requested.

const reduced = matchMedia("(prefers-reduced-motion: reduce)").matches;
const $ = (s, root = document) => root.querySelector(s);
const $$ = (s, root = document) => [...root.querySelectorAll(s)];
const clamp = (v, lo = 0, hi = 1) => Math.min(hi, Math.max(lo, v));
const easeOut = (t) => 1 - Math.pow(1 - t, 3);
const easeInOut = (t) => (t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2);

function tween(from, to, ms, onFrame, ease = easeOut) {
  return new Promise((resolve) => {
    const start = performance.now();
    const step = (now) => {
      const t = clamp((now - start) / ms);
      onFrame(from + (to - from) * ease(t));
      t < 1 ? requestAnimationFrame(step) : resolve();
    };
    requestAnimationFrame(step);
  });
}

/** Runs `start` the first time `el` is on screen; `stop` when it leaves (optional). */
function whenVisible(el, start, stop, threshold = 0.25) {
  if (!el) return;
  new IntersectionObserver(
    (entries) => entries.forEach((e) => (e.isIntersecting ? start() : stop && stop())),
    { threshold },
  ).observe(el);
}

// ---------- Opening titles ----------

function openingTitles() {
  const delays = [
    [".hero .kicker", 350],
    [".title .line:nth-child(1) > *", 450],
    [".title .line:nth-child(2) > *", 600],
    [".hero .lede", 900],
    [".hero .cta", 1050],
    [".hero .meta", 1200],
  ];
  delays.forEach(([s, d]) => $$(s).forEach((el) => el.style.setProperty("--d", `${d}ms`)));
  const go = () => requestAnimationFrame(() => document.body.classList.add("loaded"));
  // Wait briefly for the display fonts so the headline doesn't reflow mid-animation.
  Promise.race([document.fonts?.ready ?? Promise.resolve(), new Promise((r) => setTimeout(r, 700))]).then(go);
  setTimeout(() => $(".curtain")?.remove(), 3200);

  $$("video").forEach((v) => {
    v.addEventListener("playing", () => v.classList.add("playing"), { once: true });
    if (reduced) v.removeAttribute("autoplay"), v.pause();
  });
}

// ---------- Scroll: header, scrub bar, timecode, tilt ----------

function scrollEffects() {
  const header = $(".site-header");
  const fill = $(".scrub-fill");
  const ticks = $(".scrub-ticks");
  const timecode = $("#timecode");
  const win = $(".window");
  const chapters = $$("[data-chapter]");
  const navLinks = $$(".site-header nav a");
  const RUNTIME = 102 * 60 + 16; // the "film" runs 1:42:16

  const placeTicks = () => {
    const max = document.documentElement.scrollHeight - innerHeight;
    ticks.innerHTML = "";
    chapters.forEach((c) => {
      const i = document.createElement("i");
      i.style.left = `${clamp((c.offsetTop - innerHeight * 0.3) / max) * 100}%`;
      ticks.append(i);
    });
  };

  const tc = (p) => {
    const total = p * RUNTIME;
    const pad = (n) => String(Math.floor(n)).padStart(2, "0");
    return `${pad(total / 3600)}:${pad((total / 60) % 60)}:${pad(total % 60)}:${pad((total % 1) * 24)}`;
  };

  let ticking = false;
  const update = () => {
    ticking = false;
    const max = document.documentElement.scrollHeight - innerHeight;
    const p = clamp(scrollY / max);
    fill.style.transform = `scaleX(${p})`;
    timecode.textContent = tc(p);
    header.classList.toggle("scrolled", scrollY > 24);

    if (win && !reduced) {
      const r = win.getBoundingClientRect();
      const k = easeOut(clamp((innerHeight * 0.95 - r.top) / (innerHeight * 0.75)));
      win.style.setProperty("--tilt", `${18 * (1 - k)}deg`);
      win.style.setProperty("--scale", `${0.9 + 0.1 * k}`);
    }

    let current = null;
    chapters.forEach((c) => {
      if (c.getBoundingClientRect().top < innerHeight * 0.4) current = c.id;
    });
    navLinks.forEach((a) => a.classList.toggle("active", a.getAttribute("href") === `#${current}`));
  };
  const onScroll = () => {
    if (!ticking) requestAnimationFrame(update);
    ticking = true;
  };

  addEventListener("scroll", onScroll, { passive: true });
  addEventListener("resize", () => (placeTicks(), onScroll()));
  addEventListener("load", placeTicks);
  placeTicks();
  update();
}

// ---------- Reveals ----------

function reveals() {
  // Stagger siblings that reveal together (grid cells, list items).
  const groups = new Map();
  $$(".reveal").forEach((el) => {
    const list = groups.get(el.parentElement) ?? [];
    list.push(el);
    groups.set(el.parentElement, list);
  });
  groups.forEach((list) => list.length > 1 && list.forEach((el, i) => el.style.setProperty("--d", `${i * 90}ms`)));

  const io = new IntersectionObserver(
    (entries) =>
      entries.forEach((e) => {
        if (!e.isIntersecting) return;
        e.target.classList.add("in");
        io.unobserve(e.target);
      }),
    { threshold: 0.15, rootMargin: "0px 0px -8% 0px" },
  );
  $$(".reveal").forEach((el) => (reduced ? el.classList.add("in") : io.observe(el)));
}

// ---------- Marquee ----------

function marquee() {
  const track = $(".marquee-track");
  if (!track) return;
  $$("span", track).forEach((s) => {
    const copy = s.cloneNode(true);
    copy.setAttribute("aria-hidden", "true");
    track.append(copy);
  });
}

// ---------- Interactive subtitle sync demo ----------

function syncDemo() {
  const root = $("#demo");
  if (!root) return;
  const DURATION = 12;
  const LINES = [
    [0.6, 2.4, "Did you hear that?"],
    [3.1, 5.0, "It's only the train. Go back to sleep."],
    [5.8, 7.3, "Trains don't stop here."],
    [8.2, 10.6, "Then why is it slowing down?"],
  ];
  const START_OFFSET = 1200;

  const screenSub = $("#demo-sub");
  const status = $("#demo-status");
  const statusText = $("#demo-status-text");
  const out = $("#demo-offset");
  const range = $("#demo-range");
  const cuesEl = $("#demo-cues");
  const canvas = $("#demo-wave");
  const playhead = $("#demo-playhead");
  const timeline = $("#demo-timeline");
  const ruler = $("#demo-ruler");
  const auto = $("#demo-auto");

  let offset = START_OFFSET;
  let t = 0;
  let running = false;
  let last = 0;
  let listening = false;
  let geometry = { left: 0, width: 1 };

  for (let s = 0; s <= DURATION; s += 2) {
    const tick = document.createElement("span");
    tick.style.left = `${(s / DURATION) * 100}%`;
    tick.textContent = `0:${String(s).padStart(2, "0")}`;
    ruler.append(tick);
  }
  const cues = LINES.map(([a, b, text]) => {
    const el = document.createElement("div");
    el.className = "cue";
    el.textContent = text;
    el.style.width = `${((b - a) / DURATION) * 100}%`;
    cuesEl.append(el);
    return el;
  });

  // Deterministic "speech" envelope so the waveform is the same on every redraw.
  let seed = 7;
  const rand = () => ((seed = (seed * 16807) % 2147483647) / 2147483647);
  const BARS = 180;
  const amps = Array.from({ length: BARS }, (_, i) => {
    const time = (i / BARS) * DURATION;
    const line = LINES.find(([a, b]) => time >= a && time <= b);
    if (!line) return 0.05 + rand() * 0.07;
    const k = Math.sin(((time - line[0]) / (line[1] - line[0])) * Math.PI);
    return 0.25 + k * (0.45 + rand() * 0.3);
  });

  function measure() {
    const r = cuesEl.getBoundingClientRect();
    const tr = timeline.getBoundingClientRect();
    geometry = { left: r.left - tr.left, width: r.width };
    const dpr = devicePixelRatio || 1;
    canvas.width = canvas.clientWidth * dpr;
    canvas.height = canvas.clientHeight * dpr;
  }

  function drawWave() {
    const ctx = canvas.getContext("2d");
    const w = canvas.width;
    const h = canvas.height;
    const bw = w / BARS;
    ctx.clearRect(0, 0, w, h);
    const played = (t / DURATION) * w;
    amps.forEach((a, i) => {
      const x = i * bw;
      const bh = Math.max(2, a * h * 0.92);
      ctx.fillStyle = x < played ? "rgba(255,181,71,0.9)" : "rgba(236,235,230,0.22)";
      if (listening) ctx.fillStyle = `rgba(196,181,253,${0.35 + 0.5 * Math.abs(Math.sin(i / 6 + performance.now() / 180))})`;
      ctx.fillRect(x + bw * 0.2, (h - bh) / 2, bw * 0.6, bh);
    });
  }

  function render() {
    const off = offset / 1000;
    let text = "";
    LINES.forEach(([a, b, line], i) => {
      cues[i].style.left = `${((a + off) / DURATION) * 100}%`;
      const on = t >= a + off && t <= b + off;
      cues[i].classList.toggle("active", on);
      if (on) text = line;
    });
    if (screenSub.textContent !== text) screenSub.textContent = text;
    playhead.style.left = `${geometry.left + (t / DURATION) * geometry.width}px`;

    const synced = Math.abs(offset) < 60;
    out.textContent = `${offset >= 0 ? "+" : "−"}${(Math.abs(offset) / 1000).toFixed(3)} s`;
    out.classList.toggle("synced", synced);
    root.classList.toggle("synced-all", synced);
    if (!listening) {
      status.classList.toggle("synced", synced);
      statusText.textContent = synced
        ? "In sync"
        : `Subtitles ${(Math.abs(offset) / 1000).toFixed(2)} s ${offset > 0 ? "late" : "early"}`;
    }
    if (document.activeElement !== range) range.value = offset;
    drawWave();
  }

  function frame(now) {
    if (!running) return;
    const dt = Math.min(0.1, (now - last) / 1000);
    last = now;
    t += dt;
    if (t > DURATION + 0.6) t = 0;
    render();
    requestAnimationFrame(frame);
  }

  const setOffset = (v) => {
    offset = clamp(Math.round(v), -2000, 2000);
    render();
  };

  $$("[data-nudge]", root).forEach((b) => b.addEventListener("click", () => setOffset(offset + Number(b.dataset.nudge))));
  range.addEventListener("input", () => setOffset(Number(range.value)));

  auto.addEventListener("click", async () => {
    if (listening) return;
    listening = true;
    auto.disabled = true;
    status.classList.remove("synced");
    status.classList.add("listening");
    statusText.textContent = "Listening to the audio…";
    await new Promise((r) => setTimeout(r, 1400));
    statusText.textContent = `Found ${offset >= 0 ? "−" : "+"}${(Math.abs(offset) / 1000).toFixed(2)} s · high confidence`;
    await tween(offset, 0, 900, setOffset, easeInOut);
    await new Promise((r) => setTimeout(r, 900));
    listening = false;
    status.classList.remove("listening");
    auto.disabled = false;
    render();
  });

  addEventListener("keydown", (e) => {
    if (e.metaKey || e.ctrlKey || e.altKey || /input|textarea|select/i.test(e.target.tagName)) return;
    const r = root.getBoundingClientRect();
    if (r.bottom < 0 || r.top > innerHeight) return;
    const key = e.key.toLowerCase();
    if (key === "z" && e.shiftKey) setOffset(0);
    else if (key === "z") setOffset(offset - 100);
    else if (key === "x") setOffset(offset + 100);
    else return;
    e.preventDefault();
  });

  addEventListener("resize", () => (measure(), render()));
  measure();
  t = 1.2;
  render();

  if (!reduced) {
    whenVisible(
      root,
      () => {
        if (running) return;
        running = true;
        last = performance.now();
        requestAnimationFrame(frame);
      },
      () => (running = false),
      0.1,
    );
  }
}

// ---------- Feature-grid loops ----------

function loopWhileVisible(el, intervalMs, step) {
  let timer = null;
  whenVisible(
    el,
    () => {
      if (!timer) timer = setInterval(step, intervalMs);
    },
    () => {
      clearInterval(timer);
      timer = null;
    },
  );
}

function featureLoops() {
  if (reduced) return;

  const speed = $("#speed-readout");
  const speeds = [1, 1.5, 2, 4, 0.25, 0.5];
  let si = 0;
  loopWhileVisible(speed, 2200, () => {
    const from = speeds[si];
    si = (si + 1) % speeds.length;
    tween(from, speeds[si], 700, (v) => (speed.textContent = v.toFixed(2)), easeInOut);
  });

  const encText = $("#enc-text");
  const encName = $("#enc-name");
  const samples = [
    ["こんにちは", "Shift JIS"],
    ["你好，世界", "GB18030"],
    ["Привет", "KOI8-R"],
    ["안녕하세요", "EUC-KR"],
    ["مرحبا", "Windows-1256"],
    ["Grüß Gott", "Windows-1252"],
    ["您好", "Big5"],
  ];
  let ei = 0;
  loopWhileVisible(encText, 2000, () => {
    encText.classList.add("out");
    setTimeout(() => {
      ei = (ei + 1) % samples.length;
      [encText.textContent, encName.textContent] = samples[ei];
      encText.classList.remove("out");
    }, 380);
  });

  const typing = $("#ed-typing");
  const phrases = ["I was at the station.", "Waiting for a train that never came.", "I told you. I was home."];
  let pi = 0;
  let ci = 0;
  let deleting = false;
  let pause = 0;
  loopWhileVisible(typing, 55, () => {
    if (pause > 0) return pause--;
    const phrase = phrases[pi];
    ci += deleting ? -1 : 1;
    typing.textContent = phrase.slice(0, ci);
    if (!deleting && ci === phrase.length) (deleting = true), (pause = 30);
    else if (deleting && ci === 0) (deleting = false), (pi = (pi + 1) % phrases.length), (pause = 6);
  });
}

// ---------- Privacy counter ----------

function zeroCounter() {
  const el = $("#zero");
  if (!el || reduced) return;
  const fmt = new Intl.NumberFormat("en-US");
  // Long numbers are scaled down to fit narrow screens; the final "0" is full size.
  const show = (n) => {
    el.textContent = fmt.format(n);
    el.style.transform = "";
    const room = el.parentElement.clientWidth;
    if (el.scrollWidth > room) el.style.transform = `scale(${room / el.scrollWidth})`;
  };
  show(1048576);
  let done = false;
  whenVisible(el, () => {
    if (done) return;
    done = true;
    tween(1048576, 0, 2400, (v) => show(Math.round(v)), (t) => 1 - Math.pow(1 - t, 4));
  }, null, 0.5);
}

// ---------- Pointer niceties ----------

function pointer() {
  if (reduced || !matchMedia("(hover: hover)").matches) return;

  $$(".cell").forEach((cell) =>
    cell.addEventListener("pointermove", (e) => {
      const r = cell.getBoundingClientRect();
      cell.style.setProperty("--mx", `${e.clientX - r.left}px`);
      cell.style.setProperty("--my", `${e.clientY - r.top}px`);
    }),
  );

  $$(".magnetic").forEach((btn) => {
    btn.addEventListener("pointermove", (e) => {
      const r = btn.getBoundingClientRect();
      const x = (e.clientX - r.left - r.width / 2) * 0.18;
      const y = (e.clientY - r.top - r.height / 2) * 0.3;
      btn.style.transform = `translate(${x}px, ${y}px)`;
    });
    btn.addEventListener("pointerleave", () => (btn.style.transform = ""));
  });
}

// ---------- Copy button ----------

function copyButtons() {
  $$("[data-copy]").forEach((b) =>
    b.addEventListener("click", async () => {
      try {
        await navigator.clipboard.writeText(b.dataset.copy);
        b.textContent = "Copied";
        b.classList.add("done");
        setTimeout(() => ((b.textContent = "Copy"), b.classList.remove("done")), 1800);
      } catch {
        getSelection().selectAllChildren($("#xattr-cmd"));
      }
    }),
  );
}

openingTitles();
scrollEffects();
reveals();
marquee();
syncDemo();
featureLoops();
zeroCounter();
pointer();
copyButtons();
