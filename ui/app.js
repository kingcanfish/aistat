const { invoke } = window.__TAURI__.core;
const { listen } = window.__TAURI__.event;

const COLORS = {
  green: "#2ec27e",
  yellow: "#f0c832",
  orange: "#f58a1f",
  red: "#e03e3e",
  blue: "#3b82f6",
  gray: "#9ca3af",
};

function dotEl(status) {
  const el = document.createElement("span");
  el.className = `dot dot--${status}`;
  return el;
}

function fmtTime(iso) {
  if (!iso) return "";
  const d = new Date(iso);
  return isNaN(d) ? iso : d.toLocaleString();
}

function renderPanel(statuses) {
  const list = document.getElementById("site-list");
  list.innerHTML = "";

  if (!statuses || statuses.length === 0) {
    const empty = document.createElement("li");
    empty.className = "site-item";
    empty.style.padding = "14px";
    empty.style.color = "var(--text-dim)";
    empty.textContent = "No sites configured.";
    list.appendChild(empty);
    return;
  }

  for (const site of statuses) {
    const li = document.createElement("li");
    li.className = "site-item";

    const row = document.createElement("div");
    row.className = "site-row";
    row.appendChild(dotEl(site.overall));
    const name = document.createElement("span");
    name.className = "site-name";
    name.textContent = site.name;
    row.appendChild(name);
    const statusText = document.createElement("span");
    statusText.className = "site-status";
    statusText.textContent = site.overall.replace(/_/g, " ");
    row.appendChild(statusText);
    li.appendChild(row);

    const detail = document.createElement("div");
    detail.className = "site-detail";
    detail.style.display = "none";

    if (site.error) {
      const err = document.createElement("div");
      err.className = "incident-update";
      err.textContent = `Error: ${site.error}`;
      detail.appendChild(err);
    }

    if (site.components && site.components.length > 0) {
      const label = document.createElement("div");
      label.className = "section-label";
      label.textContent = "Components";
      detail.appendChild(label);
      for (const c of site.components) {
        const r = document.createElement("div");
        r.className = "component-row";
        r.appendChild(dotEl(c.status));
        const n = document.createElement("span");
        n.className = "component-name";
        n.textContent = c.name;
        r.appendChild(n);
        detail.appendChild(r);
      }
    }

    if (site.incidents && site.incidents.length > 0) {
      const label = document.createElement("div");
      label.className = "section-label";
      label.textContent = "Incidents";
      detail.appendChild(label);
      for (const inc of site.incidents) {
        const wrap = document.createElement("div");
        wrap.className = "incident-row";
        wrap.style.alignItems = "flex-start";
        wrap.style.flexDirection = "column";
        wrap.style.gap = "2px";

        const head = document.createElement("div");
        head.style.display = "flex";
        head.style.alignItems = "center";
        head.style.gap = "8px";
        head.style.width = "100%";
        head.appendChild(dotEl(inc.impact));
        const t = document.createElement("span");
        t.className = "incident-title";
        t.textContent = inc.title;
        head.appendChild(t);
        wrap.appendChild(head);

        if (inc.updated_at) {
          const time = document.createElement("div");
          time.className = "incident-time";
          time.textContent = fmtTime(inc.updated_at);
          wrap.appendChild(time);
        }
        if (inc.latest_update) {
          const upd = document.createElement("div");
          upd.className = "incident-update";
          upd.textContent = inc.latest_update;
          wrap.appendChild(upd);
        }
        detail.appendChild(wrap);
      }
    }

    const link = document.createElement("a");
    link.className = "site-link";
    link.textContent = "Open status page ↗";
    link.addEventListener("click", (e) => {
      e.stopPropagation();
      invoke("open_url", { url: site.url });
    });
    detail.appendChild(link);

    li.appendChild(detail);

    row.addEventListener("click", () => {
      const hidden = detail.style.display === "none";
      detail.style.display = hidden ? "flex" : "none";
    });

    list.appendChild(li);
  }
}

function renderHeader(statuses) {
  const aggDot = document.getElementById("agg-dot");
  const aggText = document.getElementById("agg-text");
  const lastUpdated = document.getElementById("last-updated");

  if (!statuses || statuses.length === 0) {
    aggDot.className = "dot dot--gray";
    aggText.textContent = "No sites";
    lastUpdated.textContent = "";
    return;
  }

  // worst = full_outage > partial_outage > maintenance > degraded > operational > unknown
  const order = ["full_outage", "partial_outage", "maintenance", "degraded", "operational", "unknown"];
  let worst = "operational";
  for (const s of order) {
    if (statuses.some((x) => x.overall === s)) {
      worst = s;
      break;
    }
  }

  aggDot.className = `dot dot--${worst}`;
  aggText.textContent = worst.replace(/_/g, " ");

  const times = statuses.map((s) => s.fetched_at).filter(Boolean);
  const latest = times.sort().at(-1);
  lastUpdated.textContent = latest ? `Updated ${fmtTime(latest)}` : "";
}

async function load() {
  const statuses = await invoke("get_statuses");
  renderHeader(statuses);
  renderPanel(statuses);
}

async function refresh() {
  const statuses = await invoke("refresh_now");
  renderHeader(statuses);
  renderPanel(statuses);
}

/* ---------- Settings ---------- */

function siteRow(site, onRemove) {
  const item = document.createElement("div");
  item.className = "site-config-item";

  const nameInput = document.createElement("input");
  nameInput.type = "text";
  nameInput.placeholder = "Name";
  nameInput.value = site.name;
  item.appendChild(nameInput);

  const urlInput = document.createElement("input");
  urlInput.type = "text";
  urlInput.placeholder = "URL";
  urlInput.value = site.url;
  item.appendChild(urlInput);

  const adapterSelect = document.createElement("select");
  for (const kind of ["statuspage", "flashduty"]) {
    const opt = document.createElement("option");
    opt.value = kind;
    opt.textContent = kind;
    if (site.adapter === kind) opt.selected = true;
    adapterSelect.appendChild(opt);
  }
  item.appendChild(adapterSelect);

  const remove = document.createElement("button");
  remove.className = "remove-btn";
  remove.textContent = "✕";
  remove.title = "Remove site";
  remove.addEventListener("click", () => onRemove(item));
  item.appendChild(remove);

  item._nameInput = nameInput;
  item._urlInput = urlInput;
  item._adapterSelect = adapterSelect;
  return item;
}

let editingConfig = null;

async function openSettings() {
  editingConfig = await invoke("get_config");
  document.getElementById("panel-view").classList.add("hidden");
  document.getElementById("settings-view").classList.remove("hidden");
  document.getElementById("interval-input").value = editingConfig.refresh_interval_seconds;
  document.getElementById("notify-input").checked = editingConfig.notifications_enabled;
  renderSiteConfig();
}

function renderSiteConfig() {
  const list = document.getElementById("site-config-list");
  list.innerHTML = "";
  editingConfig.sites.forEach((site, i) => {
    const row = siteRow(site, () => {
      editingConfig.sites.splice(i, 1);
      renderSiteConfig();
    });
    list.appendChild(row);
  });
}

function collectSites() {
  const rows = document.querySelectorAll("#site-config-list .site-config-item");
  const sites = [];
  for (const row of rows) {
    const name = row._nameInput.value.trim();
    const url = row._urlInput.value.trim();
    const adapter = row._adapterSelect.value;
    if (!name || !url) continue;
    sites.push({
      id: name.toLowerCase().replace(/[^a-z0-9]+/g, "-"),
      name,
      url,
      adapter,
    });
  }
  return sites;
}

async function saveSettings() {
  editingConfig.refresh_interval_seconds = Math.max(
    30,
    parseInt(document.getElementById("interval-input").value, 10) || 300
  );
  editingConfig.notifications_enabled = document.getElementById("notify-input").checked;
  editingConfig.sites = collectSites();
  await invoke("set_config", { config: editingConfig });
  closeSettings();
}

function closeSettings() {
  document.getElementById("settings-view").classList.add("hidden");
  document.getElementById("panel-view").classList.remove("hidden");
}

/* ---------- Wiring ---------- */

document.getElementById("refresh-btn").addEventListener("click", refresh);
document.getElementById("settings-btn").addEventListener("click", openSettings);
document.getElementById("save-btn").addEventListener("click", saveSettings);
document.getElementById("cancel-btn").addEventListener("click", closeSettings);
document.getElementById("add-site-btn").addEventListener("click", () => {
  editingConfig.sites.push({
    id: "new-site",
    name: "",
    url: "https://status.example.com",
    adapter: "statuspage",
  });
  renderSiteConfig();
});

listen("status-updated", (event) => {
  renderHeader(event.payload);
  renderPanel(event.payload);
});

load();
