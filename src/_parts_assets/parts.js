/* Parts preview: drawing stage (drag, zoom, rotate, page tabs, key markers),
   part selection and card, chassis fit ("Your bus"), lightbox, search.
   Plain JavaScript, no dependencies. Pages list their parts without it. */
(function () {
  "use strict";

  var $ = function (id) { return document.getElementById(id); };
  function el(tag, cls, text) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text !== undefined && text !== null) e.textContent = text;
    return e;
  }
  function store(k, v) {
    try { if (v === undefined) return window.localStorage.getItem(k); window.localStorage.setItem(k, v); } catch (e) { return null; }
    return null;
  }

  /* ---- chassis numbers: same rule as scripts/parts/lib/parts.rb ----------------
     "20-NNN NNN" and plain 6/7-digit serials are one ascending sequence:
     seq = the digits after "20-", or the 6/7-digit number. */
  function parseChassis(s) {
    if (!s) return { empty: true };
    var t = String(s).replace(/\s/g, "").replace(/[–—]/g, "-");
    var m = t.match(/^20-?(\d{6})$/);
    if (m) return { seq: parseInt(m[1], 10) };
    m = t.match(/^(\d{6,7})$/);
    if (m) return { seq: parseInt(m[1], 10) };
    if (/^\d{9}$/.test(t)) return { nine: true };
    return { bad: true };
  }
  function fitOf(row, c) {
    if (!c || c.seq === undefined) return null;
    if (row.unparsed) return { cls: "info", msg: "Check the printed range" };
    var bounded = row.ranges.filter(function (r) { return r.f !== null || r.t !== null; });
    if (!bounded.length) {
      if (row.engine) return { cls: "info", msg: "Check: by engine number" };
      return { cls: "yes", msg: "Fits (no chassis limit)" };
    }
    var ok = bounded.some(function (r) { return (r.f === null || c.seq >= r.f) && (r.t === null || c.seq <= r.t); });
    return ok ? { cls: "yes", msg: "Fits your bus" } : { cls: "no", msg: "Not for your bus" };
  }

  var data = null;
  var dataEl = $("pp-data");
  if (dataEl) { try { data = JSON.parse(dataEl.textContent); } catch (e) { data = null; } }
  var chassis = null;

  /* ---- "Your bus" band --------------------------------------------------------- */
  var chassisIn = $("pp-chassis"), chassisMsg = $("pp-chassis-msg");
  function setBadge(node, f, empty) {
    node.className = "pp-fit pp-fit-" + (f ? f.cls : "none");
    node.textContent = f ? f.msg : (empty || "–");
  }
  function applyChassis() {
    var c = parseChassis(chassisIn ? chassisIn.value : "");
    chassis = c;
    if (chassisMsg) {
      if (c.empty) setBadge(chassisMsg, { cls: "info", msg: "Enter a chassis number to see which parts fit" });
      else if (c.nine) setBadge(chassisMsg, { cls: "info", msg: "9-digit chassis numbers (1964 on) are not compared yet" });
      else if (c.bad) setBadge(chassisMsg, { cls: "info", msg: "Use 20-NNN NNN or a 6- or 7-digit number" });
      else setBadge(chassisMsg, { cls: "yes", msg: "Showing fit for chassis " + chassisIn.value.trim() });
    }
    if (data) {
      var rows = document.querySelectorAll(".pp-row[data-i]");
      for (var i = 0; i < rows.length; i++) {
        var badge = rows[i].querySelector("[data-fit]");
        if (badge) setBadge(badge, fitOf(data.rows[+rows[i].getAttribute("data-i")], c));
      }
      if (selected !== null) renderCard(selected);
    }
  }
  if (chassisIn) {
    var saved = store("pp-chassis");
    if (saved) chassisIn.value = saved;
    chassisIn.addEventListener("input", function () { store("pp-chassis", chassisIn.value); applyChassis(); });
  }

  /* ---- illustration page: stage --------------------------------------------------- */
  var stage = $("pp-stage"), cam = $("pp-cam"), img = $("pp-stage-img"), markersBox = $("pp-markers");
  var view = { s: 1, tx: 0, ty: 0, rot: 0, page: 0 };
  var rotBox = null;
  var selected = null;

  function pageOf(i) { return data.pages[i]; }
  function boxSize() {
    var p = pageOf(view.page);
    return view.rot % 180 === 0 ? { w: p.w, h: p.h } : { w: p.h, h: p.w };
  }
  function applyView(anim) {
    var p = pageOf(view.page);
    cam.classList.toggle("pp-anim", !!anim);
    cam.style.width = p.w + "px";
    cam.style.height = p.h + "px";
    var r = view.rot, rt = "";
    if (r === 90) rt = "translate(" + p.h + "px,0) rotate(90deg)";
    else if (r === 180) rt = "translate(" + p.w + "px," + p.h + "px) rotate(180deg)";
    else if (r === 270) rt = "translate(0," + p.w + "px) rotate(270deg)";
    rotBox.style.transform = rt;
    cam.style.transform = "translate(" + view.tx + "px," + view.ty + "px) scale(" + view.s + ")";
  }
  function fit(anim) {
    var b = boxSize(), W = stage.clientWidth, H = stage.clientHeight;
    view.s = Math.min(W / b.w, H / b.h) * 0.96;
    view.tx = (W - b.w * view.s) / 2;
    view.ty = (H - b.h * view.s) / 2;
    applyView(anim);
  }
  function zoomAt(f, cx, cy, anim) {
    var ns = Math.max(0.05, Math.min(4, view.s * f));
    view.tx = cx - (cx - view.tx) * (ns / view.s);
    view.ty = cy - (cy - view.ty) * (ns / view.s);
    view.s = ns;
    applyView(anim);
  }
  // page coordinates (fractions of the unrotated page) -> stage pixels
  function toStage(fx, fy) {
    var p = pageOf(view.page), x = fx * p.w, y = fy * p.h, X, Y;
    if (view.rot === 0) { X = x; Y = y; }
    else if (view.rot === 90) { X = p.h - y; Y = x; }
    else if (view.rot === 180) { X = p.w - x; Y = p.h - y; }
    else { X = y; Y = p.w - x; }
    return { x: view.tx + X * view.s, y: view.ty + Y * view.s };
  }
  function focusOn(fx, fy) {
    var ns = Math.max(view.s, Math.min(stage.clientWidth / 900, 1.2));
    view.s = ns;
    var pt = toStage(fx, fy);
    view.tx += stage.clientWidth / 2 - pt.x;
    view.ty += stage.clientHeight / 2 - pt.y;
    applyView(true);
  }
  function drawMarkers() {
    markersBox.textContent = "";
    var p = pageOf(view.page);
    (data.markers || []).forEach(function (m) {
      if (m.pdf !== p.pdf) return;
      var b = el("button", "pp-marker");
      b.type = "button";
      b.style.left = (m.x * 100) + "%";
      b.style.top = (m.y * 100) + "%";
      b.setAttribute("aria-label", "Key " + m.key + " on the drawing");
      b.setAttribute("data-key", m.key);
      b.addEventListener("click", function (ev) {
        ev.stopPropagation();
        for (var i = 0; i < data.rows.length; i++) if (String(data.rows[i].key) === String(m.key)) { select(i, true); return; }
      });
      markersBox.appendChild(b);
    });
    highlightMarkers();
  }
  function highlightMarkers() {
    var key = selected !== null ? String(data.rows[selected].key) : null;
    var ms = markersBox.querySelectorAll(".pp-marker");
    for (var i = 0; i < ms.length; i++) ms[i].classList.toggle("pp-on", key !== null && ms[i].getAttribute("data-key") === key);
  }
  function showPage(i, keepView) {
    view.page = i;
    var p = pageOf(i);
    img.src = p.img;
    img.width = p.w;
    img.height = p.h;
    img.alt = "Page " + p.label + " of the parts list";
    var tabs = document.querySelectorAll(".pp-tab[data-page]");
    for (var t = 0; t < tabs.length; t++) {
      var on = +tabs[t].getAttribute("data-page") === i;
      tabs[t].classList.toggle("pp-on", on);
      tabs[t].setAttribute("aria-pressed", String(on));
    }
    var cap = $("pp-stage-cap");
    if (cap) cap.textContent = (p.type === "drawing" ? "Drawing" : "Parts list") + ", PDF page " + p.pdf + (p.fold_out ? " (fold-out)" : "");
    if (selected === null) { $("pp-chip-k").textContent = data.pages.length + (data.pages.length > 1 ? " pages" : " page"); $("pp-chip-t").textContent = "Page " + p.label; }
    if (!keepView) { view.rot = 0; }
    drawMarkers();
    fit(false);
  }

  if (stage && data && data.pages.length) {
    rotBox = el("div", "pp-rot");
    rotBox.style.position = "absolute";
    rotBox.style.left = "0";
    rotBox.style.top = "0";
    rotBox.style.transformOrigin = "0 0";
    cam.insertBefore(rotBox, img);
    rotBox.appendChild(img);
    rotBox.appendChild(markersBox);

    var drag = null;
    stage.addEventListener("pointerdown", function (ev) {
      if (ev.target.closest("button")) return;
      drag = { x: ev.clientX, y: ev.clientY, tx: view.tx, ty: view.ty };
      stage.classList.add("pp-dragging");
      stage.setPointerCapture(ev.pointerId);
    });
    stage.addEventListener("pointermove", function (ev) {
      if (!drag) return;
      view.tx = drag.tx + ev.clientX - drag.x;
      view.ty = drag.ty + ev.clientY - drag.y;
      applyView(false);
    });
    var endDrag = function () { drag = null; stage.classList.remove("pp-dragging"); };
    stage.addEventListener("pointerup", endDrag);
    stage.addEventListener("pointercancel", endDrag);
    stage.addEventListener("wheel", function (ev) {
      ev.preventDefault();
      var r = stage.getBoundingClientRect();
      zoomAt(ev.deltaY < 0 ? 1.15 : 1 / 1.15, ev.clientX - r.left, ev.clientY - r.top, false);
    }, { passive: false });
    stage.addEventListener("keydown", function (ev) {
      var W = stage.clientWidth / 2, H = stage.clientHeight / 2;
      if (ev.key === "+" || ev.key === "=") { zoomAt(1.3, W, H, true); ev.preventDefault(); }
      else if (ev.key === "-") { zoomAt(1 / 1.3, W, H, true); ev.preventDefault(); }
      else if (ev.key === "0") { fit(true); ev.preventDefault(); }
      else if (ev.key.indexOf("Arrow") === 0) {
        var d = 60;
        if (ev.key === "ArrowLeft") view.tx += d; if (ev.key === "ArrowRight") view.tx -= d;
        if (ev.key === "ArrowUp") view.ty += d; if (ev.key === "ArrowDown") view.ty -= d;
        applyView(false); ev.preventDefault();
      }
    });
    stage.querySelectorAll("[data-act]").forEach(function (b) {
      b.addEventListener("click", function () {
        var act = b.getAttribute("data-act"), W = stage.clientWidth / 2, H = stage.clientHeight / 2;
        if (act === "zoomin") zoomAt(1.3, W, H, true);
        else if (act === "zoomout") zoomAt(1 / 1.3, W, H, true);
        else if (act === "fit") fit(true);
        else if (act === "rotate") { view.rot = (view.rot + 90) % 360; fit(true); }
      });
    });
    document.querySelectorAll(".pp-tab[data-page]").forEach(function (t) {
      t.addEventListener("click", function () { showPage(+t.getAttribute("data-page")); });
    });
    window.addEventListener("resize", function () { fit(false); });
    if (img.complete) showPage(0); else img.addEventListener("load", function once() { img.removeEventListener("load", once); showPage(0); });
  }

  /* ---- part card ------------------------------------------------------------------ */
  var REASONS = {
    only_text_layer: "only the text layer saw this row", only_tesseract: "only tesseract saw this row",
    part_no_differs: "the part number was read differently", bad_shape: "the part number doesn't have a normal shape",
    marker_differs: "the readings differ on the * mark", key_differs: "the key number was read differently",
    qty_differs: "the quantity was read differently", applicability_differs: "the chassis/engine range was read differently",
    sp_set_layout: "SP-set page layout", colour_date_lines: "colour or date lines that need a person"
  };
  var CONF_LABELS = { person: "Checked by a person", agree: "Machine-read, readings agree",
    check: "Machine-read, needs checking", ai: "Read by AI, not yet checked" };
  function confText(r) {
    if (r.conf === "person") return "A person has checked this row against the page.";
    if (r.conf === "ai") return "AI reading of the page; not yet checked by a person.";
    if (r.conf === "agree") return "Both machine readings agree; not yet checked by a person.";
    var why = (r.why || []).map(function (w) { return REASONS[w] || w; });
    return "Needs checking: " + (why.length ? why.join("; ") : "the readings differ") + ".";
  }
  function pageImg(pdf) {
    for (var i = 0; i < data.pages.length; i++) if (data.pages[i].pdf === pdf) return data.pages[i];
    return { img: "scans/page-" + ("00" + pdf).slice(-3) + ".png", label: "PDF " + pdf, pdf: pdf };
  }
  function renderCard(i) {
    var r = data.rows[i];
    $("pp-part-empty").hidden = true;
    $("pp-part-body").hidden = false;
    $("pp-part-k").textContent = r.key !== null && r.key !== undefined ? "Key " + r.key + (data.markers && data.markers.length ? " on the drawing" : "") : "No key number";
    $("pp-part-d").textContent = r.d || "(description not read)";
    $("pp-part-pn").textContent = (r.mk || "") + (r.pn || "");
    var badges = $("pp-part-badges");
    badges.textContent = "";
    var f = fitOf(r, chassis);
    if (f) { var fb = el("span"); setBadge(fb, f); badges.appendChild(fb); }
    (r.oc || []).forEach(function (o) { badges.appendChild(el("span", "pp-fit pp-fit-info", "Option " + o)); });
    badges.appendChild(el("span", "pp-conf pp-conf-" + r.conf, CONF_LABELS[r.conf] || CONF_LABELS.check));
    $("pp-part-q").textContent = r.q || "–";
    $("pp-part-tm").textContent = r.tm || "–";
    $("pp-part-a").textContent = r.a || "No limit printed";
    var vars = data.rows.map(function (x, j) { return [x, j]; }).filter(function (xj) { return r.pos && xj[0].pos === r.pos && xj[1] !== i; });
    var vl = $("pp-part-varlist");
    vl.textContent = "";
    vars.forEach(function (xj) {
      var x = xj[0], row = el("div", "pp-var"), left = el("div");
      var b = el("button", "pp-var-pn pp-num", (x.mk || "") + x.pn);
      b.type = "button";
      b.addEventListener("click", function () { select(xj[1], true); });
      left.appendChild(b);
      left.appendChild(el("div", "pp-muted", (x.d || "") + (x.a ? ". " + x.a.replace(/\n/g, "; ") : "")));
      row.appendChild(left);
      var vf = fitOf(x, chassis);
      if (vf) { var vb = el("span"); setBadge(vb, vf); row.appendChild(vb); }
      vl.appendChild(row);
    });
    $("pp-part-vars").hidden = vars.length === 0;
    var pg = pageImg(r.pdf);
    $("pp-part-img").src = pg.img;
    $("pp-part-img").alt = "Page " + (r.pp || "PDF " + r.pdf);
    $("pp-part-src").textContent = "Source: page " + (r.pp || "PDF " + r.pdf) + " (PDF " + r.pdf + "), August 1963 parts list";
    $("pp-part-conf").textContent = confText(r) + " Confirm against the original before ordering.";
    $("pp-chip-k").textContent = r.key !== null && r.key !== undefined ? "Key " + r.key : "No key";
    $("pp-chip-t").textContent = r.d || "(description not read)";
    $("pp-chip-pn").textContent = (r.mk || "") + (r.pn || "");
  }
  function select(i, focusDrawing) {
    selected = i;
    var rows = document.querySelectorAll(".pp-row[data-i]");
    for (var k = 0; k < rows.length; k++) {
      var on = +rows[k].getAttribute("data-i") === i;
      rows[k].classList.toggle("pp-on", on);
      rows[k].setAttribute("aria-pressed", String(on));
    }
    renderCard(i);
    var r = data.rows[i];
    try { history.replaceState(null, "", "#row-" + r.id); } catch (e) { /* file:// or sandbox */ }
    if (stage && focusDrawing) {
      var m = (data.markers || []).filter(function (x) { return String(x.key) === String(r.key); })[0];
      if (m) {
        for (var p = 0; p < data.pages.length; p++) if (data.pages[p].pdf === m.pdf && p !== view.page) { showPage(p, true); break; }
        highlightMarkers();
        focusOn(m.x, m.y);
      } else { highlightMarkers(); }
    }
  }
  if (data) {
    document.querySelectorAll(".pp-row[data-i]").forEach(function (b) {
      b.addEventListener("click", function () { select(+b.getAttribute("data-i"), true); });
    });
    var h = decodeURIComponent((location.hash || "").replace(/^#row-/, ""));
    if (h) for (var i = 0; i < data.rows.length; i++) if (data.rows[i].id === h) {
      select(i, true);
      var rowEl = document.getElementById("row-" + h);
      if (rowEl) rowEl.scrollIntoView({ block: "center" });
      break;
    }
  }

  /* ---- lightbox ------------------------------------------------------------------- */
  var lb = $("pp-lightbox"), lastFocus = null;
  function openLightbox() {
    if (selected === null || !lb) return;
    var r = data.rows[selected], pg = pageImg(r.pdf);
    $("pp-lightbox-img").src = pg.img;
    $("pp-lightbox-img").alt = "Original page " + (r.pp || "PDF " + r.pdf);
    $("pp-lightbox-t").textContent = "Page " + (r.pp || "PDF " + r.pdf) + " (PDF " + r.pdf + "), August 1963 parts list";
    lastFocus = document.activeElement;
    lb.hidden = false;
    $("pp-lightbox-close").focus();
  }
  function closeLightbox() { if (!lb || lb.hidden) return; lb.hidden = true; if (lastFocus) lastFocus.focus(); }
  if (lb) {
    $("pp-part-thumb").addEventListener("click", openLightbox);
    $("pp-part-open").addEventListener("click", openLightbox);
    $("pp-lightbox-close").addEventListener("click", closeLightbox);
    lb.addEventListener("click", function (ev) { if (ev.target === lb) closeLightbox(); });
    document.addEventListener("keydown", function (ev) { if (ev.key === "Escape") closeLightbox(); });
  }

  /* ---- "report a problem" (needs scripts/parts/preview-server.rb) ------------------- */
  var rep = $("pp-report");
  if (rep && data) {
    var slug = rep.getAttribute("data-illustration"), token = null, scope = "row", lastFocusR = null;
    var reported = {}; // row id -> count
    var getToken = function () {
      if (token) return Promise.resolve(token);
      return fetch("/api/token", { cache: "no-store" }).then(function (r) {
        if (!r.ok) throw new Error("no server");
        return r.json();
      }).then(function (j) { token = j.token; return token; });
    };
    var markReported = function () {
      document.querySelectorAll(".pp-row[data-i]").forEach(function (b) {
        var r = data.rows[+b.getAttribute("data-i")], old = b.querySelector(".pp-reported");
        if (old) old.remove();
        if (reported[r.id]) b.querySelector(".pp-c-d").appendChild(el("span", "pp-reported", "Reported"));
      });
      var n = Object.keys(reported).reduce(function (a, k) { return a + reported[k]; }, 0); // rows + "__page"
      var cnt = $("pp-report-count");
      if (cnt) cnt.textContent = n ? n + " report" + (n > 1 ? "s" : "") + " on this page so far" : "";
      if (selected !== null) {
        var rid = data.rows[selected].id, note = $("pp-row-reported");
        note.hidden = !reported[rid];
        note.textContent = reported[rid] ? "You reported this part (" + reported[rid] + ")" : "";
      }
    };
    fetch("/api/reports?illustration=" + encodeURIComponent(slug), { cache: "no-store" }).then(function (r) {
      return r.ok ? r.json() : { reports: [] };
    }).then(function (j) {
      (j.reports || []).forEach(function (x) { var k = x.row_id || "__page"; reported[k] = (reported[k] || 0) + 1; });
      markReported();
    }).catch(function () { /* plain static server: no reports */ });

    var openReport = function (sc) {
      scope = sc;
      $("pp-report-row-choices").hidden = sc !== "row";
      $("pp-report-row-choices").disabled = sc !== "row";
      $("pp-report-page-choices").hidden = sc !== "page";
      $("pp-report-page-choices").disabled = sc !== "page";
      rep.querySelectorAll("input[name=problem]").forEach(function (i) { i.checked = false; });
      $("pp-report-note").value = "";
      $("pp-report-status").textContent = "";
      var p = pageOf(view.page);
      if (sc === "row") {
        var r = data.rows[selected];
        $("pp-report-h").textContent = "Report a problem with this part";
        $("pp-report-what").textContent = ((r.mk || "") + (r.pn || "(no part number)")) + ", " + (r.d || "") + " (page " + (r.pp || "PDF " + r.pdf) + ")";
      } else {
        $("pp-report-h").textContent = "Report a problem with this page";
        $("pp-report-what").textContent = "Page " + p.label + " (PDF " + p.pdf + ") of " + document.querySelector("h1").textContent;
      }
      lastFocusR = document.activeElement;
      rep.hidden = false;
      rep.querySelector("input[name=problem]:not(:disabled)").focus();
    };
    var closeReport = function () { if (rep.hidden) return; rep.hidden = true; if (lastFocusR) lastFocusR.focus(); };
    $("pp-report-row").addEventListener("click", function () { if (selected !== null) openReport("row"); });
    $("pp-report-page").addEventListener("click", function () { openReport("page"); });
    $("pp-report-close").addEventListener("click", closeReport);
    rep.addEventListener("click", function (ev) { if (ev.target === rep) closeReport(); });
    document.addEventListener("keydown", function (ev) { if (ev.key === "Escape") closeReport(); });
    $("pp-report-form").addEventListener("submit", function (ev) {
      ev.preventDefault();
      var choice = rep.querySelector("input[name=problem]:checked:not(:disabled)");
      var st = $("pp-report-status");
      if (!choice) { st.textContent = "Pick what's wrong first."; return; }
      var p = pageOf(view.page), body = { scope: scope, problem: choice.value, illustration: slug,
        illustration_number: rep.getAttribute("data-number"), note: $("pp-report-note").value };
      if (scope === "row") {
        var r = data.rows[selected];
        body.row_id = r.id; body.part_no = (r.mk || "") + (r.pn || ""); body.pdf_page = r.pdf; body.printed_page = r.pp;
      } else { body.pdf_page = p.pdf; body.printed_page = p.label; }
      st.textContent = "Saving…";
      getToken().then(function (t) {
        return fetch("/api/report", { method: "POST", headers: { "Content-Type": "application/json", "X-Report-Token": t }, body: JSON.stringify(body) });
      }).then(function (r) { return r.json().then(function (j) { if (!r.ok) throw new Error(j.error || "not saved"); return j; }); })
        .then(function () {
          if (scope === "row") reported[body.row_id] = (reported[body.row_id] || 0) + 1;
          else reported.__page = (reported.__page || 0) + 1;
          markReported();
          st.textContent = "Saved. Thank you.";
          setTimeout(closeReport, 900);
        }).catch(function (e) {
          st.textContent = e.message === "no server" ? "Not saved: start the preview with scripts/parts/preview.sh to save reports." : "Not saved: " + e.message;
        });
    });
    var origRender = renderCard;
    renderCard = function (i) { origRender(i); markReported(); };
  }

  /* ---- search page ------------------------------------------------------------------ */
  var results = $("pp-results");
  if (results) {
    var slugs = {};
    try { slugs = JSON.parse($("pp-slugs").textContent); } catch (e) { slugs = {}; }
    var status = $("pp-search-status"), qIn = $("pp-q");
    var q = new URLSearchParams(location.search).get("q") || "";
    qIn.value = q;
    var index = null;
    var run = function () {
      var query = qIn.value.trim();
      results.textContent = "";
      if (!query) { status.textContent = "Type a part number or a word from the description."; return; }
      var qn = query.replace(/\s+/g, "").toUpperCase();
      var isNumber = /^[N*]?\d/.test(qn) && (qn.match(/\d/g) || []).length >= 3;
      var words = query.toLowerCase().split(/\s+/).filter(Boolean);
      var hits = index.rows.filter(function (r) {
        if (isNumber) return r.n && r.n.indexOf(qn.replace(/^\*/, "")) !== -1;
        var d = (r.d || "").toLowerCase();
        return words.every(function (w) { return d.indexOf(w) !== -1; });
      });
      var groups = {}, order = [];
      hits.forEach(function (r) { var k = r.n || r.p; if (!groups[k]) { groups[k] = []; order.push(k); } groups[k].push(r); });
      if (isNumber) order.sort(function (a, b) { return (a.indexOf(qn) === 0 ? 0 : 1) - (b.indexOf(qn) === 0 ? 0 : 1) || (a < b ? -1 : 1); });
      status.textContent = hits.length ? hits.length + " rows, " + order.length + " part numbers" + (order.length > 150 ? " (showing the first 150)" : "") + "." : "No rows found. Machine readings can misread a digit: try fewer digits.";
      order.slice(0, 150).forEach(function (k) {
        var rs = groups[k], box = el("div", "pp-result");
        box.appendChild(el("div", "pp-result-pn pp-num", rs[0].p));
        box.appendChild(el("div", "pp-muted", rs[0].d || ""));
        var ul = el("ul"), seen = {};
        rs.forEach(function (r) {
          var ill = r.i && slugs[r.i];
          var key = (r.i || "?") + "|" + r.pdf;
          if (seen[key]) return;
          seen[key] = true;
          var li = el("li");
          if (ill) {
            var a = el("a", null, "Illustration " + r.i + (ill.title ? ": " + ill.title : ""));
            a.href = ill.slug + ".html#row-" + r.id;
            li.appendChild(a);
          } else { li.appendChild(document.createTextNode("Not matched to an illustration")); }
          li.appendChild(document.createTextNode(", page " + (r.pp || "PDF " + r.pdf) + (r.c === "a" ? " (machine-read, readings agree)" : " (machine-read, needs checking)")));
          ul.appendChild(li);
        });
        box.appendChild(el("div", "pp-muted", "Found in " + Object.keys(seen).length + " place" + (Object.keys(seen).length > 1 ? "s" : "") + ":"));
        box.appendChild(ul);
        results.appendChild(box);
      });
    };
    status.textContent = "Loading the index…";
    fetch("search-index.json").then(function (r) { return r.json(); }).then(function (j) {
      index = j;
      status.textContent = "";
      run();
      $("pp-search-form").addEventListener("submit", function (ev) {
        ev.preventDefault();
        try { history.replaceState(null, "", "?q=" + encodeURIComponent(qIn.value.trim())); } catch (e) { /* ignore */ }
        run();
      });
    }).catch(function () { status.textContent = "Could not load the search index."; });
  }

  if (chassisIn) applyChassis();
})();
