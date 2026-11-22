// Parts review tool (dev only). Plain JavaScript, no dependencies.
"use strict";

let DATA = null;
let mode = "rows";
let list = [];       // rows currently in the filtered list
let idx = 0;         // position in `list`
let zoom = 2;
let context = false;
let selCallout = null;

const $ = (sel, el = document) => el.querySelector(sel);
const esc = (s) => String(s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
const reviewed = (s) => s === "verified" || s === "corrected";

async function load() {
  const r = await fetch("/api/data", { cache: "no-store" });
  DATA = await r.json();
  // files without a drawing or callouts (e.g. the whole-book spot check): no Callouts mode
  const cb = $('.tabs [data-mode="callouts"]');
  if (cb) cb.hidden = !(DATA.illustration.drawing?.pdf_page && DATA.callouts.length);
  const pf = $("#page-filter");
  if (pf.options.length === 1) {
    DATA.pages.filter((p) => p.pdf_page !== DATA.illustration.drawing?.pdf_page).forEach((p) => {
      pf.add(new Option(`${p.printed_page} (PDF ${p.pdf_page})`, p.pdf_page));
    });
  }
}

async function post(path, body) {
  const r = await fetch(path, {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-Review-Token": window.REVIEW_TOKEN },
    body: JSON.stringify(body)
  });
  const j = await r.json();
  if (!r.ok) throw new Error(j.error || r.statusText);
  return j;
}

// ---- progress ---------------------------------------------------------------
function progress() {
  const rows = DATA.rows.filter((r) => reviewed(r.status)).length;
  const cos = DATA.callouts.filter((c) => reviewed(c.status)).length;
  const pgs = DATA.pages.filter((p) => reviewed(p.stamp_status)).length;
  const done = rows + cos + pgs, total = DATA.rows.length + DATA.callouts.length + DATA.pages.length;
  $("#progress-text").textContent = `Rows ${rows}/${DATA.rows.length} · Callouts ${cos}/${DATA.callouts.length} · Page stamps ${pgs}/${DATA.pages.length}`;
  $("#progress-bar").style.width = `${(100 * done) / total}%`;
}

// ---- character diff (marks characters of b that are not in the LCS of a, b) --
function diffMark(a, b) {
  a = String(a ?? ""); b = String(b ?? "");
  const n = a.length, m = b.length;
  if (n * m > 40000) return esc(b);
  const L = Array.from({ length: n + 1 }, () => new Uint16Array(m + 1));
  for (let i = n - 1; i >= 0; i--) for (let j = m - 1; j >= 0; j--)
    L[i][j] = a[i] === b[j] ? L[i + 1][j + 1] + 1 : Math.max(L[i + 1][j], L[i][j + 1]);
  let i = 0, j = 0, out = "";
  while (j < m) {
    if (i < n && a[i] === b[j]) { out += esc(b[j]); i++; j++; }
    else if (i < n && L[i + 1][j] >= L[i][j + 1]) { i++; }
    else { out += `<mark>${esc(b[j])}</mark>`; j++; }
  }
  return out;
}

function asText(field, v) {
  if (v === null || v === undefined) return "";
  if (field === "quantity" && Array.isArray(v)) return v.join(" / ");
  return String(v);
}

// ---- rows mode ------------------------------------------------------------------
function buildList() {
  const f = $("#filter").value, pg = $("#page-filter").value;
  list = DATA.rows.filter((r) =>
    (!pg || String(r.pdf_page) === pg) &&
    (f === "all" || (f === "unverified" && r.status === "unverified") ||
     (f === "disagree" && r.disagreements.length && r.status === "unverified")));
  if (idx >= list.length) idx = Math.max(0, list.length - 1);
}

function crop(row) {
  const [iw, ih] = DATA.image_sizes[row.pdf_page];
  let [x0, y0, x1, y1] = row.bbox_px;
  if (context) { y0 = Math.max(0, y0 - 160); y1 = Math.min(ih, y1 + 160); }
  const base = Math.min(1, 860 / (x1 - x0));
  const s = base * zoom;
  return `<div class="crop-wrap"><div class="crop" role="img" aria-label="Scan of row ${esc(row.id)}"
    style="width:${(x1 - x0) * s}px;height:${(y1 - y0) * s}px;background-image:url('/img/page-${row.pdf_page}.png');
    background-size:${iw * s}px ${ih * s}px;background-position:${-x0 * s}px ${-y0 * s}px"></div></div>`;
}

const FIELDS = [
  ["key", "Key number (blank = dash)", "input"],
  ["marker", "Marker before part number (e.g. *)", "input"],
  ["part_no", "Part number (as printed, without marker)", "input"],
  ["description", "Description (as printed; one line per printed line)", "textarea"],
  ["quantity", "Quantity (as printed; use / for two lines)", "input"],
  ["applicability", "Applicability (chassis text, verbatim)", "textarea"],
  ["type_and_model", "Type and model column", "input"]
];

function readingsHtml(row, field) {
  const srcs = [["pdf_text", "text layer"], ["tesseract", "tesseract"], ["claude", "Claude (AI)"]];
  const cur = asText(field, row[field]);
  return `<div class="readings">${srcs.map(([k, label]) => {
    if (!(k in row.readings)) return "";   // this file has no such reading (e.g. no AI reading)
    const r = row.readings[k];
    if (!r) return `<span class="src">${label}</span><span class="missed">row not found</span>`;
    if (!(field in r)) return "";
    const v = asText(field, r[field]);
    return `<span class="src">${label}</span><span>${v === "" ? '<span class="missed">(none)</span>' : diffMark(cur, v)}</span>`;
  }).join("")}</div>`;
}

function renderRows() {
  buildList();
  const main = $("#main");
  if (!list.length) {
    main.innerHTML = `<div class="card"><p><strong>Nothing to review with this filter.</strong> Switch the filter to "unverified rows" or "all rows", or open Callouts / Pages.</p></div>`;
    return;
  }
  const row = list[idx];
  const page = DATA.pages.find((p) => p.pdf_page === row.pdf_page);
  const siblings = DATA.rows.filter((r) => r.position === row.position && r.id !== row.id);
  const posIds = DATA.positions.map((p) => p.id);
  const dis = new Set(row.disagreements.map((d) => (d === "marker" ? "marker" : d)));
  main.innerHTML = `
  <div class="grid">
    <section class="card" aria-label="Scan">
      <p class="meta">Page <strong>${esc(row.printed_page)}</strong> (PDF ${row.pdf_page}), row ${row.row_order} ·
        stamp: <span class="stamp">${esc(page.revision_stamp ?? "none")}</span> <span class="badge ${page.stamp_status}">${page.stamp_status}</span>
        ${row.row_mark ? ` · row mark: <strong>${esc(row.row_mark)}</strong>` : ""}${row.print_note ? ` · ${esc(row.print_note)}` : ""}</p>
      ${crop(row)}
      <div class="tools">
        <label class="inline">Zoom <input id="zoom" type="range" min="1" max="3" step="0.25" value="${zoom}"></label>
        <label class="inline"><input id="context" type="checkbox" ${context ? "checked" : ""}> show more context</label>
        <span class="hint">box from ${esc(row.bbox_source)}</span>
      </div>
    </section>
    <section class="card" aria-label="Fields">
      <p class="meta"><strong>${esc(row.id)}</strong> <span class="badge ${row.status}">${row.status}</span>
        ${row.reviewed_by ? ` by ${esc(row.reviewed_by)} ${esc(row.reviewed_at)}` : ""} · ${idx + 1} of ${list.length} in this list</p>
      <form id="rowform" autocomplete="off">
        ${FIELDS.map(([f, label, kind]) => {
          const v = asText(f, row[f]);
          const ctl = kind === "textarea" ? `<textarea name="${f}" rows="${Math.max(2, v.split("\n").length)}">${esc(v)}</textarea>`
                                          : `<input name="${f}" value="${esc(v)}">`;
          return `<div class="field ${dis.has(f) ? "disagree" : ""}"><label>${label}</label>${ctl}${readingsHtml(row, f)}</div>`;
        }).join("")}
        <div class="field"><label>Position (groups versions of the same part; ${esc(row.position_status)})</label>
          <input name="position" list="positions" value="${esc(row.position ?? "")}">
          <datalist id="positions">${posIds.map((p) => `<option value="${esc(p)}">`).join("")}</datalist>
          <ul class="siblings">${siblings.map((s) => `<li>${esc((s.marker ?? "") + s.part_no)} — ${esc(s.description.split("\n")[0])} (${esc(s.printed_page)}${s.key ? `, key ${s.key}` : ""})</li>`).join("") || "<li>no other rows in this position</li>"}</ul>
        </div>
        <div class="field"><label>Note for a correction (optional)</label><input name="note"></div>
        <div class="buttons">
          <button type="button" class="primary" id="confirm">Confirm as printed <kbd>C</kbd></button>
          <button type="button" class="correct" id="correct">Save correction <kbd>S</kbd></button>
          <button type="button" id="back">Back <kbd>B</kbd></button>
          <button type="button" id="next">Skip <kbd>N</kbd></button>
        </div>
        <p class="msg" id="msg" role="status" aria-live="polite"></p>
        <p class="hint">Confirm only if every field matches the scan exactly. Edit a field, then Save correction, if it doesn't.
          Changing only the position and pressing Confirm keeps the row verified and records the new position.</p>
      </form>
    </section>
  </div>`;
  $("#zoom").oninput = (e) => { zoom = Number(e.target.value); renderRows(); };
  $("#context").onchange = (e) => { context = e.target.checked; renderRows(); };
  $("#confirm").onclick = () => saveRow("confirm");
  $("#correct").onclick = () => saveRow("correct");
  $("#back").onclick = () => { idx = Math.max(0, idx - 1); renderRows(); };
  $("#next").onclick = () => { idx = Math.min(list.length - 1, idx + 1); renderRows(); };
  progress();
}

function formFields() {
  const fd = new FormData($("#rowform"));
  const fields = {};
  FIELDS.forEach(([f]) => { fields[f] = fd.get(f); });
  return { fields, position: fd.get("position"), note: fd.get("note") };
}

async function saveRow(action) {
  const row = list[idx];
  const { fields, position, note } = formFields();
  try {
    const j = await post("/api/row", { id: row.id, action, fields, position, note });
    Object.assign(row, j.row);
    await load();
    const keepId = row.id;
    buildList();
    // move on to the next row that is still in the list
    const pos = list.findIndex((r) => r.id === keepId);
    idx = pos === -1 ? Math.min(idx, list.length - 1) : Math.min(pos + 1, list.length - 1);
    renderRows();
    $("#msg").className = "msg ok";
    $("#msg").textContent = `${keepId} saved as ${j.row.status}.`;
  } catch (e) {
    $("#msg").className = "msg err";
    $("#msg").textContent = e.message;
  }
}

// ---- callouts mode ----------------------------------------------------------------
function renderCallouts() {
  const pg = DATA.illustration.drawing.pdf_page;
  const [iw, ih] = DATA.image_sizes[pg];
  const sel = DATA.callouts.find((c) => c.id === selCallout);
  $("#main").innerHTML = `
  <div class="grid">
    <section class="card" aria-label="Drawing">
      <p class="meta">Drawing, page ${esc(DATA.illustration.drawing.printed_page)} (PDF ${pg}). Click a marker to select it; drag it to move it onto the label.</p>
      <div class="drawing" id="drawing"><img src="/img/page-${pg}.png" alt="Illustration ${DATA.illustration.number} drawing" draggable="false">
        ${DATA.callouts.map((c) => `<button type="button" class="pin ${c.status} ${c.id === selCallout ? "sel" : ""}" data-id="${esc(c.id)}"
          aria-label="Callout ${esc(c.label)} (${c.status})"
          style="left:${(100 * c.page_px[0]) / iw}%;top:${(100 * c.page_px[1]) / ih}%"><span class="tag">${esc(c.label)}</span></button>`).join("")}
      </div>
    </section>
    <section class="card" aria-label="Selected callout">
      ${sel ? `
        <p class="meta"><strong>Callout ${esc(sel.label)}</strong> (${esc(sel.id)}) → key ${sel.key} <span class="badge ${sel.status}">${sel.status}</span></p>
        <p>Row with this key: <strong>${esc(rowForKey(sel.key))}</strong></p>
        <p class="hint">Position ${sel.page_px.join(", ")} px · source: ${esc(sel.position_source)}<br>
          Claude: ${esc(sel.readings.claude_px?.join(", "))} · tesseract (rotated): ${esc(sel.readings.tesseract_rotated_px?.join(", ") ?? "not found")}</p>
        <div class="buttons">
          <button type="button" class="primary" id="c-confirm">Confirm position <kbd>C</kbd></button>
          <button type="button" class="correct" id="c-save" ${sel._moved ? "" : "disabled"}>Save moved position <kbd>S</kbd></button>
        </div>` : `<p>Select a marker on the drawing.</p>`}
      <p class="msg" id="msg" role="status" aria-live="polite"></p>
      <p class="hint">Markers: red = not yet reviewed, green = confirmed, amber = moved.</p>
    </section>
  </div>`;
  const drawing = $("#drawing");
  drawing.querySelectorAll(".pin").forEach((pin) => {
    pin.onclick = () => { if (!pin._dragged) { selCallout = pin.dataset.id; renderCallouts(); } };
    pin.onpointerdown = (e) => {
      const c = DATA.callouts.find((x) => x.id === pin.dataset.id);
      selCallout = c.id;
      pin.setPointerCapture(e.pointerId);
      pin._dragged = false;
      pin.onpointermove = (ev) => {
        const r = drawing.getBoundingClientRect();
        const x = Math.max(0, Math.min(1, (ev.clientX - r.left) / r.width));
        const y = Math.max(0, Math.min(1, (ev.clientY - r.top) / r.height));
        pin.style.left = `${x * 100}%`; pin.style.top = `${y * 100}%`;
        c._newpx = [Math.round(x * iw), Math.round(y * ih)];
        pin._dragged = true;
      };
      pin.onpointerup = () => {
        pin.onpointermove = null;
        if (pin._dragged) { c._moved = true; c.page_px_pending = c._newpx; renderCallouts(); }
      };
    };
  });
  if (sel) {
    $("#c-confirm").onclick = () => saveCallout(sel, "confirm");
    const s = $("#c-save");
    if (s) s.onclick = () => saveCallout(sel, "correct");
  }
  progress();
}

function rowForKey(k) {
  const r = DATA.rows.find((x) => x.key === k);
  return r ? `${(r.marker ?? "") + r.part_no} — ${r.description.split("\n")[0]} (page ${r.printed_page})` : "none";
}

async function saveCallout(c, action) {
  try {
    const body = { id: c.id, action };
    if (action === "correct") body.page_px = c.page_px_pending;
    await post("/api/callout", body);
    await load();
    const next = DATA.callouts.find((x) => x.status === "unverified");
    selCallout = next ? next.id : c.id;
    renderCallouts();
    $("#msg").className = "msg ok";
    $("#msg").textContent = `Callout ${c.label} saved.`;
  } catch (e) {
    $("#msg").className = "msg err";
    $("#msg").textContent = e.message;
  }
}

// ---- pages mode (revision stamps) -------------------------------------------------------
function renderPages() {
  $("#main").innerHTML = `<p class="hint">Each page's revision stamp (bottom-left), recorded exactly as printed. Leave the box empty if the page has none. "[?]" marks a character Claude could not read.</p>
  <div class="pages">${DATA.pages.map((p) => {
    const [iw, ih] = DATA.image_sizes[p.pdf_page];
    const x0 = 120, y0 = Math.round(ih * 0.89), w = 900, h = Math.round(ih * 0.09), s = 0.4;
    return `<section class="card" data-page="${p.pdf_page}">
      <p class="meta"><strong>${esc(p.printed_page)}</strong> (PDF ${p.pdf_page}) <span class="badge ${p.stamp_status}">${p.stamp_status}</span>
        ${p.margin_text ? `<br>margin text: ${esc(p.margin_text)}` : ""}${p.notes ? `<br><span class="hint">${esc(p.notes)}</span>` : ""}</p>
      <div class="crop-wrap"><div class="crop" role="img" aria-label="Footer of page ${esc(p.printed_page)}"
        style="width:${w * s * 2}px;height:${h * s * 2}px;background-image:url('/img/page-${p.pdf_page}.png');background-size:${iw * s * 2}px ${ih * s * 2}px;background-position:${-x0 * s * 2}px ${-y0 * s * 2}px"></div></div>
      <div class="field"><label>Revision stamp</label><input name="stamp" value="${esc(p.revision_stamp ?? "")}">
        <div class="readings"><span class="src">text layer</span><span>${esc(p.stamp_readings.pdf_text ?? "(none)")}</span>
        <span class="src">tesseract</span><span>${esc(p.stamp_readings.tesseract ?? "(none)")}</span>
        <span class="src">Claude (AI)</span><span>${esc(p.stamp_readings.claude ?? "(none)")}</span></div></div>
      <div class="buttons"><button type="button" class="primary" data-act="confirm">Confirm</button><button type="button" class="correct" data-act="correct">Save correction</button></div>
      <p class="msg" role="status" aria-live="polite"></p>
    </section>`; }).join("")}</div>`;
  document.querySelectorAll("[data-page]").forEach((card) => {
    card.querySelectorAll("[data-act]").forEach((b) => {
      b.onclick = async () => {
        const msg = card.querySelector(".msg");
        try {
          await post("/api/page", { pdf_page: Number(card.dataset.page), action: b.dataset.act, revision_stamp: card.querySelector("[name=stamp]").value });
          await load(); renderPages();
        } catch (e) { msg.className = "msg err"; msg.textContent = e.message; }
      };
    });
  });
  progress();
}

// ---- wiring --------------------------------------------------------------------------------
function render() {
  document.querySelectorAll(".tabs button").forEach((b) => b.setAttribute("aria-pressed", String(b.dataset.mode === mode)));
  ({ rows: renderRows, callouts: renderCallouts, pages: renderPages })[mode]();
}

document.querySelectorAll(".tabs button").forEach((b) => { b.onclick = () => { mode = b.dataset.mode; render(); }; });
$("#filter").onchange = () => { idx = 0; render(); };
$("#page-filter").onchange = () => { idx = 0; render(); };
document.addEventListener("keydown", (e) => {
  if (e.altKey || e.ctrlKey || e.metaKey) return;
  const tag = e.target.tagName;
  if (tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT") return;
  const k = e.key.toLowerCase();
  if (mode === "rows") {
    if (k === "c") $("#confirm")?.click();
    if (k === "s") $("#correct")?.click();
    if (k === "n") $("#next")?.click();
    if (k === "b") $("#back")?.click();
  } else if (mode === "callouts") {
    if (k === "c") $("#c-confirm")?.click();
    if (k === "s") $("#c-save")?.click();
  }
});

load().then(render).catch((e) => { $("#main").textContent = "Could not load data: " + e.message; });
