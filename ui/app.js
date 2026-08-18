const { invoke } = window.__TAURI__.core;
const { listen } = window.__TAURI__.event;

/** Worst-first, matching `Status::DEFAULT_PRIORITY` in crates/core. */
const SEVERITY = [
  "full_outage",
  "partial_outage",
  "maintenance",
  "degraded",
  "operational",
  "unknown",
];

/**
 * One name per status, used everywhere it appears — row, component, header.
 * Short on purpose: these are set as readouts, and "Degraded performance" spent
 * a third of a 348px row saying what "Degraded" says.
 */
const LABELS = {
  operational: "Operational",
  degraded: "Degraded",
  partial_outage: "Partial outage",
  full_outage: "Full outage",
  maintenance: "Maintenance",
  unknown: "Unknown",
};

const label = (status) => LABELS[status] ?? status.replace(/_/g, " ");

/** Where the GitHub mark in the settings footer goes. */
const REPO_URL = "https://github.com/kingcanfish/aistat";

function icon(id) {
  const span = document.createElement("span");
  span.innerHTML = `<svg class="icon"><use href="#${id}"/></svg>`;
  return span.firstElementChild;
}

function dot(status, small = false) {
  const el = document.createElement("span");
  el.className = `dot dot--${status}${small ? " dot--sm" : ""}`;
  return el;
}

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text != null) node.textContent = text;
  return node;
}

function fmtTime(iso) {
  if (!iso) return "";
  const d = new Date(iso);
  if (isNaN(d)) return iso;
  const sameDay = d.toDateString() === new Date().toDateString();
  return sameDay
    ? d.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" })
    : d.toLocaleString([], { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" });
}

/** A machine reading: status, count, timestamp, section heading. */
function readout(className, text) {
  return el("span", `readout ${className}`, text);
}

/* ---------- Panel ---------- */

/**
 * The site's own mark. The icon URL is resolved in Rust from the page's
 * `<link rel=icon>`; a lettered chip covers sites that don't publish one, or
 * whose icon fails to load.
 */
function siteIcon(site) {
  const wrap = el("span", "site-icon");
  wrap.appendChild(el("span", "site-icon-mono", (site.name.trim()[0] ?? "?").toUpperCase()));

  if (site.icon) {
    const img = el("img", "site-icon-img");
    img.decoding = "async";
    img.alt = "";
    // No loading="lazy" here: the image is stacked invisibly over the
    // monogram, and a lazy image inside a hidden box never enters the
    // viewport, so it would never load and never reveal itself.
    img.addEventListener("load", () => wrap.classList.add("has-img"));
    img.src = site.icon;
    wrap.appendChild(img);
  }
  return wrap;
}

function incidentCard(inc) {
  // Impact rides the card's rail rather than a dot in the heading.
  const card = el("div", `incident incident--${inc.impact}`);
  card.appendChild(el("div", "incident-title", inc.title));

  const meta = [inc.lifecycle, fmtTime(inc.updated_at)].filter(Boolean).join(" · ");
  if (meta) card.appendChild(readout("incident-time", meta));
  if (inc.latest_update) card.appendChild(el("div", "incident-update", inc.latest_update));
  return card;
}

function siteDetail(site) {
  const inner = el("div", "site-detail-inner");

  if (site.error) {
    inner.appendChild(el("div", "site-error", `Can't reach this status page. ${site.error}`));
  }

  const impaired = (site.components ?? []).filter((c) => c.status !== "operational");

  // Incidents first: they're what you opened the panel to read.
  if (site.incidents?.length) {
    inner.appendChild(readout("section-label", "Incidents"));
    for (const inc of site.incidents) inner.appendChild(incidentCard(inc));
  } else if (impaired.length) {
    // Providers often flip component statuses without filing an incident;
    // say so explicitly instead of leaving the section blank.
    inner.appendChild(readout("section-label", "Incidents"));
    inner.appendChild(
      el(
        "div",
        "no-incident",
        `No incident filed, but ${impaired.length} component${
          impaired.length === 1 ? "" : "s"
        } report degraded service.`
      )
    );
  }

  if (site.components?.length) {
    inner.appendChild(readout("section-label", "Components"));
    // Worst first, so problems don't hide at the bottom of a long list.
    const sorted = [...site.components].sort(
      (a, b) => SEVERITY.indexOf(a.status) - SEVERITY.indexOf(b.status)
    );
    for (const c of sorted) {
      const row = el("div", "component-row");
      row.appendChild(dot(c.status, true));
      const name = el("span", "component-name", c.name);
      name.title = c.name; // long names ellipsize at this width
      row.appendChild(name);
      row.appendChild(readout(`site-status site-status--${c.status}`, label(c.status)));
      inner.appendChild(row);
    }
  }

  const link = el("button", "site-link");
  link.appendChild(document.createTextNode("Open status page"));
  link.appendChild(icon("i-external"));
  link.addEventListener("click", (e) => {
    e.stopPropagation();
    invoke("open_url", { url: site.url }).catch((err) => console.error("open_url", err));
  });
  inner.appendChild(link);

  const detail = el("div", "site-detail");
  detail.appendChild(inner);
  const wrap = el("div", "site-detail-wrap");
  wrap.appendChild(detail);
  return wrap;
}

/**
 * An empty panel has one job: get the first site added. The title bar already
 * says nothing is being monitored, so this doesn't say it twice — it just gives
 * you the way out.
 */
function emptyState() {
  const li = el("li", "empty-state");
  li.appendChild(el("div", "empty-body", "Add a status page and AIStat will keep an eye on it."));
  const add = el("button", "btn btn--primary", "Add site");
  add.addEventListener("click", async () => {
    await openSettings();
    document.getElementById("add-site-btn").click();
  });
  li.appendChild(add);
  return li;
}

function renderPanel(statuses) {
  const list = document.getElementById("site-list");
  // Remember which rows were expanded so a background refresh doesn't collapse them.
  const open = new Set([...list.querySelectorAll(".site-item.is-open")].map((n) => n.dataset.id));
  list.replaceChildren();

  if (!statuses?.length) {
    list.appendChild(emptyState());
    return;
  }

  for (const site of statuses) {
    const li = el("li", "site-item");
    li.dataset.id = site.id;
    if (open.has(site.id)) li.classList.add("is-open");

    const row = el("div", "site-row");
    // Lamp first: down a list of sites the lamps line up into a single column
    // you can read without reading any of the names.
    row.appendChild(dot(site.overall));
    row.appendChild(siteIcon(site));
    row.appendChild(el("span", "site-name", site.name));

    // Surface that there is something to read without expanding the row.
    const incidents = site.incidents?.length ?? 0;
    const impaired = (site.components ?? []).filter((c) => c.status !== "operational").length;
    if (incidents || impaired) {
      const count = incidents || impaired;
      const chip = readout(`site-chip site-chip--${site.overall}`, String(count));
      chip.title = incidents
        ? `${incidents} open incident${incidents === 1 ? "" : "s"}`
        : `${impaired} component${impaired === 1 ? "" : "s"} affected`;
      row.appendChild(chip);
    }

    row.appendChild(readout(`site-status site-status--${site.overall}`, label(site.overall)));
    const chevron = icon("i-chevron");
    chevron.classList.add("site-chevron");
    row.appendChild(chevron);
    row.addEventListener("click", () => li.classList.toggle("is-open"));

    li.appendChild(row);
    li.appendChild(siteDetail(site));
    list.appendChild(li);
  }
}

/**
 * The one line the panel exists to show. It names the service, not just the
 * state: "Partial outage at Claude" is the answer to the question you opened
 * the panel with, where "Partial outage" is only half of it.
 */
function aggSentence(worst, statuses) {
  if (worst === "operational") return "All systems operational";
  // Nothing came back from anywhere; there's no service to name.
  if (worst === "unknown") return "Status unknown";

  // Named site is one at the worst level — that's the one the sentence is
  // about — and the count covers everything else that isn't operational.
  const named = statuses.find((s) => s.overall === worst);
  const others = statuses.filter((s) => s !== named && s.overall !== "operational").length;
  return others
    ? `${label(worst)} at ${named.name} and ${others} more`
    : `${label(worst)} at ${named.name}`;
}

function renderHeader(statuses) {
  const aggDot = document.getElementById("agg-dot");
  const aggText = document.getElementById("agg-text");
  const lastUpdated = document.getElementById("last-updated");

  if (!statuses?.length) {
    aggDot.className = "dot dot--unknown";
    document.body.dataset.agg = "unknown";
    aggText.textContent = "Nothing monitored";
    lastUpdated.textContent = "";
    return;
  }

  const worst = SEVERITY.find((s) => statuses.some((x) => x.overall === s)) ?? "unknown";
  aggDot.className = `dot dot--${worst}`;
  // Drives the wash across the title bar and whether the lamp breathes.
  document.body.dataset.agg = worst;
  aggText.textContent = aggSentence(worst, statuses);

  const latest = statuses.map((s) => s.fetched_at).filter(Boolean).sort().at(-1);
  lastUpdated.textContent = latest ? `Updated ${fmtTime(latest)}` : "";
}

function render(statuses) {
  renderHeader(statuses);
  renderPanel(statuses);
}

async function load() {
  render(await invoke("get_statuses"));
}

const refreshBtn = document.getElementById("refresh-btn");

async function refresh() {
  refreshBtn.classList.add("is-busy");
  try {
    render(await invoke("refresh_now"));
  } finally {
    refreshBtn.classList.remove("is-busy");
  }
}

/* ---------- Window sizing ---------- */

/**
 * Keeps the window exactly as tall as its content (Rust clamps to a maximum,
 * past which the list scrolls). Driven by a ResizeObserver so it also tracks
 * rows expanding and collapsing.
 */
const titlebar = document.querySelector(".titlebar");
const settingsFooter = document.querySelector(".settings-footer");
const settingsView = document.getElementById("settings-view");

let pendingResize = null;

/** Measures the visible view and hands the height to Rust. Synchronous. */
function applyPanelHeight() {
  const inSettings = !settingsView.classList.contains("hidden");
  const body = inSettings
    ? document.getElementById("settings-inner").offsetHeight + settingsFooter.offsetHeight
    : document.getElementById("site-list").offsetHeight;
  invoke("resize_panel", { height: titlebar.offsetHeight + body });
}

function syncPanelHeight() {
  if (pendingResize) return;
  pendingResize = requestAnimationFrame(() => {
    pendingResize = null;
    applyPanelHeight();
  });
}

/**
 * Runs the pending resize now instead of on the next frame.
 *
 * A hidden window's webview is throttled — `requestAnimationFrame` stops
 * firing entirely — so anything deferred while the panel is going away only
 * lands when it comes back, one frame *after* it is on screen again. That is
 * visible as a flash of the old view at the old height.
 */
function flushPanelHeight() {
  if (pendingResize) {
    cancelAnimationFrame(pendingResize);
    pendingResize = null;
  }
  applyPanelHeight();
}

new ResizeObserver(syncPanelHeight).observe(document.getElementById("site-list"));
new ResizeObserver(syncPanelHeight).observe(document.getElementById("settings-inner"));

/* ---------- Alert sheet ---------- */

const dialogEl = document.getElementById("dialog");

function showDialog(title, body) {
  document.getElementById("dialog-title").textContent = title;
  document.getElementById("dialog-body").textContent = body;
  dialogEl.classList.remove("hidden");
  document.getElementById("dialog-ok").focus();
}

function closeDialog() {
  dialogEl.classList.add("hidden");
}

document.getElementById("dialog-ok").addEventListener("click", closeDialog);
dialogEl.addEventListener("click", (e) => {
  if (e.target === dialogEl) closeDialog();
});

/* ---------- Settings ---------- */

let editingConfig = null;

function siteConfigRow(site) {
  const item = el("li", "site-config-item");

  const nameInput = el("input", "f-name");
  nameInput.type = "text";
  nameInput.placeholder = "Name";
  nameInput.value = site.name;
  item.appendChild(nameInput);

  const badge = readout("adapter-badge", site.adapter ?? "");
  item.appendChild(badge);

  const remove = el("button", "remove-btn");
  remove.title = "Remove site";
  remove.setAttribute("aria-label", "Remove site");
  remove.appendChild(icon("i-minus"));
  remove.addEventListener("click", () => {
    item.remove();
    setSettingsDirty(true);
  });
  item.appendChild(remove);

  const urlInput = el("input", "f-url");
  urlInput.type = "text";
  urlInput.placeholder = "https://status.example.com";
  urlInput.value = site.url;
  // The adapter is derived from the URL, so any edit invalidates it.
  urlInput.addEventListener("input", () => {
    item.classList.remove("is-invalid");
    if (urlInput.value.trim() !== item._detectedFor) badge.textContent = "";
  });
  item.appendChild(urlInput);

  item._inputs = { nameInput, urlInput, badge };
  item._detectedFor = site.url;
  return item;
}

function renderSiteConfig(sites) {
  document
    .getElementById("site-config-list")
    .replaceChildren(...sites.map(siteConfigRow));
}

/**
 * Pins the panel open once the settings form has edits worth protecting.
 *
 * Merely *looking* at settings isn't worth overriding dismiss-on-blur: a panel
 * that won't go away when clicked past reads as stuck. Only an actual edit
 * earns that, and only until it's saved or discarded.
 */
let settingsDirty = false;

function setSettingsDirty(dirty) {
  if (settingsDirty === dirty) return;
  settingsDirty = dirty;
  invoke("set_panel_pinned", { pinned: dirty });
}

const settingsBtn = document.getElementById("settings-btn");

/** Keeps the toolbar button describing what pressing it will now do. */
function markSettingsOpen(open) {
  settingsBtn.setAttribute("aria-pressed", String(open));
  const title = open ? "Close settings" : "Settings";
  settingsBtn.title = title;
  settingsBtn.setAttribute("aria-label", title);
}

async function openSettings() {
  if (!settingsView.classList.contains("hidden")) return;
  editingConfig = await invoke("get_config");
  document.getElementById("interval-input").value = editingConfig.refresh_interval_seconds;
  document.getElementById("notify-input").checked = editingConfig.notifications_enabled;
  renderSiteConfig(editingConfig.sites);
  document.getElementById("panel-view").classList.add("hidden");
  settingsView.classList.remove("hidden");
  document.body.classList.add("is-settings");
  document.getElementById("agg-text").textContent = "Settings";
  markSettingsOpen(true);
  setSettingsDirty(false);
  syncPanelHeight();
}

/**
 * Resolves the adapter for every row whose URL changed. Rows the backend
 * can't identify are marked invalid and reported, and the save is abandoned so
 * nothing is silently dropped.
 */
async function resolveAdapters() {
  const rows = [...document.querySelectorAll("#site-config-list .site-config-item")];
  const unsupported = [];

  await Promise.all(
    rows.map(async (row) => {
      const url = row._inputs.urlInput.value.trim();
      if (!url || (row._detectedFor === url && row._inputs.badge.textContent)) return;

      row.classList.add("is-checking");
      try {
        const adapter = await invoke("detect_adapter", { url });
        row._inputs.badge.textContent = adapter;
        row._detectedFor = url;
        row.classList.remove("is-invalid");
      } catch (err) {
        row.classList.add("is-invalid");
        row._inputs.badge.textContent = "";
        unsupported.push(String(err));
      } finally {
        row.classList.remove("is-checking");
      }
    })
  );

  return unsupported;
}

function collectSites() {
  const sites = [];
  for (const row of document.querySelectorAll("#site-config-list .site-config-item")) {
    const name = row._inputs.nameInput.value.trim();
    const url = row._inputs.urlInput.value.trim();
    const adapter = row._inputs.badge.textContent.trim();
    if (!name || !url || !adapter) continue;
    sites.push({
      id: name.toLowerCase().replace(/[^a-z0-9]+/g, "-"),
      name,
      url: /^https?:\/\//i.test(url) ? url : `https://${url}`,
      adapter,
    });
  }
  return sites;
}

const saveBtn = document.getElementById("save-btn");

async function saveSettings() {
  saveBtn.disabled = true;
  try {
    const unsupported = await resolveAdapters();
    if (unsupported.length) {
      showDialog("Unsupported status page", unsupported.join("\n\n"));
      return;
    }

    editingConfig.refresh_interval_seconds = Math.max(
      30,
      parseInt(document.getElementById("interval-input").value, 10) || 300
    );
    editingConfig.notifications_enabled = document.getElementById("notify-input").checked;
    editingConfig.sites = collectSites();
    await invoke("set_config", { config: editingConfig });
    closeSettings();
    refresh();
  } finally {
    saveBtn.disabled = false;
  }
}

function closeSettings({ immediate = false } = {}) {
  settingsView.classList.add("hidden");
  document.getElementById("panel-view").classList.remove("hidden");
  document.body.classList.remove("is-settings");
  markSettingsOpen(false);
  setSettingsDirty(false);
  load();
  if (immediate) flushPanelHeight();
  else syncPanelHeight();
}

/* ---------- Wiring ---------- */

refreshBtn.addEventListener("click", refresh);

// One button, one position, both directions: from the list it opens settings,
// and from settings it is the way back — same as Cancel, which is what the
// header button has always meant to anyone who pressed it a second time.
settingsBtn.addEventListener("click", () => {
  if (settingsView.classList.contains("hidden")) openSettings();
  else closeSettings();
});
saveBtn.addEventListener("click", saveSettings);
document.getElementById("cancel-btn").addEventListener("click", closeSettings);
document.getElementById("add-site-btn").addEventListener("click", () => {
  const row = siteConfigRow({ name: "", url: "", adapter: "" });
  document.getElementById("site-config-list").appendChild(row);
  row._inputs.nameInput.focus();
  setSettingsDirty(true);
});

// Typing in any field pins the panel. `input` bubbles from every control the
// form has — text boxes, the number field and the checkbox — so one listener
// on the view covers them; adding and removing rows mark themselves.
settingsView.addEventListener("input", () => setSettingsDirty(true));

document.addEventListener("keydown", (e) => {
  if (e.key !== "Escape") return;
  if (!dialogEl.classList.contains("hidden")) closeDialog();
  else if (!settingsView.classList.contains("hidden")) closeSettings();
});

// Losing focus is what makes Rust hide the panel, and an unpinned settings
// view has nothing worth keeping — so drop back to the list here, in the blur
// handler itself. Doing it now rather than reacting to the hide afterwards is
// the whole point: the window is still on screen, so the webview is not yet
// throttled and both the view switch and the resize actually run. The pin
// condition is the same one Rust checks, which is why the two agree on whether
// the panel is about to disappear.
window.addEventListener("blur", () => {
  if (settingsDirty) return;
  if (!settingsView.classList.contains("hidden")) closeSettings({ immediate: true });
});

// The footer signature: version from Rust so it tracks the crate, GitHub mark
// straight to the project.
document.getElementById("about-btn").addEventListener("click", () => {
  invoke("open_url", { url: REPO_URL }).catch((err) => console.error("open_url", err));
});

invoke("app_version")
  .then((v) => {
    document.getElementById("version-text").textContent = `v${v}`;
  })
  .catch((err) => console.error("app_version", err));

listen("status-updated", (event) => render(event.payload));
listen("open-settings", () => openSettings());

load();
