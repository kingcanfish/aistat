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

const LABELS = {
  operational: "Operational",
  degraded: "Degraded performance",
  partial_outage: "Partial outage",
  full_outage: "Full outage",
  maintenance: "Maintenance",
  unknown: "Unknown",
};

const label = (status) => LABELS[status] ?? status.replace(/_/g, " ");

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

/* ---------- Panel ---------- */

/** Stable per-name hue so a monogram keeps its color across restarts. */
function hueFor(name) {
  let hash = 0;
  for (const ch of name) hash = (hash * 31 + ch.codePointAt(0)) % 360;
  return hash;
}

/**
 * The site's own mark. The icon URL is resolved in Rust from the page's
 * `<link rel=icon>`; a lettered chip covers sites that don't publish one, or
 * whose icon fails to load.
 */
function siteIcon(site) {
  const wrap = el("span", "site-icon");

  const mono = el("span", "site-icon-mono", (site.name.trim()[0] ?? "?").toUpperCase());
  mono.style.setProperty("--mono-hue", String(hueFor(site.name)));
  wrap.appendChild(mono);

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
  const card = el("div", "incident");
  const head = el("div", "incident-head");
  head.appendChild(dot(inc.impact, true));
  head.appendChild(el("span", "incident-title", inc.title));
  card.appendChild(head);

  const meta = [inc.lifecycle, fmtTime(inc.updated_at)].filter(Boolean).join(" · ");
  if (meta) card.appendChild(el("div", "incident-time", meta));
  if (inc.latest_update) card.appendChild(el("div", "incident-update", inc.latest_update));
  return card;
}

function siteDetail(site) {
  const inner = el("div", "site-detail-inner");

  if (site.error) {
    inner.appendChild(el("div", "site-error", `Couldn't fetch: ${site.error}`));
  }

  const impaired = (site.components ?? []).filter((c) => c.status !== "operational");

  // Incidents first: they're what you opened the panel to read.
  if (site.incidents?.length) {
    inner.appendChild(el("div", "section-label", "Incidents"));
    for (const inc of site.incidents) inner.appendChild(incidentCard(inc));
  } else if (impaired.length) {
    // Providers often flip component statuses without filing an incident;
    // say so explicitly instead of leaving the section blank.
    inner.appendChild(el("div", "section-label", "Incidents"));
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
    inner.appendChild(el("div", "section-label", "Components"));
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
      row.appendChild(el("span", "site-status", label(c.status)));
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

function renderPanel(statuses) {
  const list = document.getElementById("site-list");
  // Remember which rows were expanded so a background refresh doesn't collapse them.
  const open = new Set([...list.querySelectorAll(".site-item.is-open")].map((n) => n.dataset.id));
  list.replaceChildren();

  if (!statuses?.length) {
    list.appendChild(el("li", "empty-state", "No sites configured."));
    return;
  }

  for (const site of statuses) {
    const li = el("li", "site-item");
    li.dataset.id = site.id;
    if (open.has(site.id)) li.classList.add("is-open");

    const row = el("div", "site-row");
    row.appendChild(siteIcon(site));
    row.appendChild(dot(site.overall));
    row.appendChild(el("span", "site-name", site.name));

    // Surface that there is something to read without expanding the row.
    const incidents = site.incidents?.length ?? 0;
    const impaired = (site.components ?? []).filter((c) => c.status !== "operational").length;
    if (incidents || impaired) {
      const count = incidents || impaired;
      const chip = el("span", `site-chip site-chip--${site.overall}`, String(count));
      chip.title = incidents
        ? `${incidents} open incident${incidents === 1 ? "" : "s"}`
        : `${impaired} component${impaired === 1 ? "" : "s"} affected`;
      row.appendChild(chip);
    }

    row.appendChild(el("span", "site-status", label(site.overall)));
    const chevron = icon("i-chevron");
    chevron.classList.add("site-chevron");
    row.appendChild(chevron);
    row.addEventListener("click", () => li.classList.toggle("is-open"));

    li.appendChild(row);
    li.appendChild(siteDetail(site));
    list.appendChild(li);
  }
}

function renderHeader(statuses) {
  const aggDot = document.getElementById("agg-dot");
  const aggText = document.getElementById("agg-text");
  const lastUpdated = document.getElementById("last-updated");

  if (!statuses?.length) {
    aggDot.className = "dot dot--unknown";
    aggText.textContent = "No sites";
    lastUpdated.textContent = "";
    return;
  }

  const worst = SEVERITY.find((s) => statuses.some((x) => x.overall === s)) ?? "unknown";
  aggDot.className = `dot dot--${worst}`;
  aggText.textContent = worst === "operational" ? "All systems operational" : label(worst);

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

function syncPanelHeight() {
  if (pendingResize) return;
  pendingResize = requestAnimationFrame(() => {
    pendingResize = null;
    const inSettings = !settingsView.classList.contains("hidden");
    const body = inSettings
      ? document.getElementById("settings-inner").offsetHeight + settingsFooter.offsetHeight
      : document.getElementById("site-list").offsetHeight;
    invoke("resize_panel", { height: titlebar.offsetHeight + body });
  });
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

  const badge = el("span", "adapter-badge", site.adapter ?? "");
  item.appendChild(badge);

  const remove = el("button", "remove-btn");
  remove.title = "Remove site";
  remove.setAttribute("aria-label", "Remove site");
  remove.appendChild(icon("i-minus"));
  remove.addEventListener("click", () => item.remove());
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

async function openSettings() {
  editingConfig = await invoke("get_config");
  document.getElementById("interval-input").value = editingConfig.refresh_interval_seconds;
  document.getElementById("notify-input").checked = editingConfig.notifications_enabled;
  renderSiteConfig(editingConfig.sites);
  document.getElementById("panel-view").classList.add("hidden");
  settingsView.classList.remove("hidden");
  document.body.classList.add("is-settings");
  document.getElementById("agg-text").textContent = "Settings";
  // Don't let a stray click outside the panel discard unsaved edits.
  invoke("set_panel_pinned", { pinned: true });
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

function closeSettings() {
  settingsView.classList.add("hidden");
  document.getElementById("panel-view").classList.remove("hidden");
  document.body.classList.remove("is-settings");
  invoke("set_panel_pinned", { pinned: false });
  load();
  syncPanelHeight();
}

/* ---------- Wiring ---------- */

refreshBtn.addEventListener("click", refresh);
document.getElementById("settings-btn").addEventListener("click", openSettings);
saveBtn.addEventListener("click", saveSettings);
document.getElementById("cancel-btn").addEventListener("click", closeSettings);
document.getElementById("add-site-btn").addEventListener("click", () => {
  const row = siteConfigRow({ name: "", url: "", adapter: "" });
  document.getElementById("site-config-list").appendChild(row);
  row._inputs.nameInput.focus();
});

document.addEventListener("keydown", (e) => {
  if (e.key !== "Escape") return;
  if (!dialogEl.classList.contains("hidden")) closeDialog();
  else if (!settingsView.classList.contains("hidden")) closeSettings();
});

listen("status-updated", (event) => render(event.payload));
listen("open-settings", () => openSettings());

load();
