/* Scan viewer enhancements. The page works fully without this file.
   Adds: zoom (fit / left page / right page / actual size), drag-to-pan,
   and keys (left/right arrows: previous/next scan; + and -: zoom;
   0: fit; L / R: left or right page). No dependencies. */
(function () {
  "use strict";

  var root = document.querySelector(".sv");
  if (!root) return;

  var frame = root.querySelector(".sv-frame");
  var object = root.querySelector(".sv-scan");
  var toolbar = root.querySelector(".sv-toolbar");
  var status = root.querySelector(".sv-status");
  var keysHint = root.querySelector(".sv-keys");
  var buttons = toolbar ? toolbar.querySelectorAll("button[data-zoom]") : [];
  var prevLink = root.querySelector('a[data-key="prev"]');
  var nextLink = root.querySelector('a[data-key="next"]');

  var LABELS = {
    fit: "Showing the whole scan",
    left: "Showing the left page",
    right: "Showing the right page",
    actual: "Showing actual size"
  };
  var zoom = "fit";
  var ready = false;
  var img = null;

  function setZoom(mode) {
    if (!ready || !LABELS[mode]) return;
    zoom = mode;
    frame.setAttribute("data-zoom", mode);
    for (var i = 0; i < buttons.length; i++) {
      buttons[i].setAttribute("aria-pressed", String(buttons[i].getAttribute("data-zoom") === mode));
    }
    // Put the right part of the scan in view.
    if (mode === "right") {
      frame.scrollLeft = frame.scrollWidth;
    } else if (mode === "actual") {
      frame.scrollLeft = (frame.scrollWidth - frame.clientWidth) / 2;
      frame.scrollTop = 0;
    } else {
      frame.scrollLeft = 0;
    }
    var pannable = frame.scrollWidth > frame.clientWidth + 1 || frame.scrollHeight > frame.clientHeight + 1;
    frame.classList.toggle("sv-pannable", pannable);
    if (pannable) {
      frame.setAttribute("tabindex", "0");
      frame.setAttribute("role", "region");
      frame.setAttribute("aria-label", "Scan, scrollable. Use arrow keys to move around.");
    } else {
      frame.removeAttribute("tabindex");
      frame.removeAttribute("role");
      frame.removeAttribute("aria-label");
    }
    if (status) status.textContent = LABELS[mode];
  }

  // Zoom steps for + and -: whole scan, one page, actual size.
  function step(dir) {
    var level = zoom === "fit" ? 0 : zoom === "actual" ? 2 : 1;
    level = Math.max(0, Math.min(2, level + dir));
    setZoom(level === 0 ? "fit" : level === 2 ? "actual" : (zoom === "right" ? "right" : "left"));
  }

  // Load the scan; only when it really arrives swap in a zoomable <img>.
  // If it fails, the <object>'s own "scan not available" message stays.
  function enhance() {
    var probe = new Image();
    probe.onload = function () {
      img = document.createElement("img");
      img.src = root.getAttribute("data-png");
      img.alt = root.getAttribute("data-alt");
      img.width = Number(root.getAttribute("data-scan-width"));
      img.height = Number(root.getAttribute("data-scan-height"));
      img.draggable = false;
      object.parentNode.replaceChild(img, object);
      ready = true;
      toolbar.hidden = false;
      if (keysHint) keysHint.hidden = false;
      setZoom("fit");
      if (status) status.textContent = "";
    };
    probe.src = root.getAttribute("data-png");
  }

  for (var i = 0; i < buttons.length; i++) {
    buttons[i].addEventListener("click", function (e) {
      setZoom(e.currentTarget.getAttribute("data-zoom"));
    });
  }

  // Drag to pan with a mouse (touch and trackpads scroll natively).
  var drag = null;
  frame.addEventListener("pointerdown", function (e) {
    if (e.pointerType !== "mouse" || e.button !== 0 || !frame.classList.contains("sv-pannable")) return;
    drag = { x: e.clientX, y: e.clientY, left: frame.scrollLeft, top: frame.scrollTop };
    frame.classList.add("sv-dragging");
    frame.setPointerCapture(e.pointerId);
  });
  frame.addEventListener("pointermove", function (e) {
    if (!drag) return;
    frame.scrollLeft = drag.left - (e.clientX - drag.x);
    frame.scrollTop = drag.top - (e.clientY - drag.y);
  });
  function endDrag() {
    drag = null;
    frame.classList.remove("sv-dragging");
  }
  frame.addEventListener("pointerup", endDrag);
  frame.addEventListener("pointercancel", endDrag);

  window.addEventListener("resize", function () {
    if (ready) frame.classList.toggle("sv-pannable",
      frame.scrollWidth > frame.clientWidth + 1 || frame.scrollHeight > frame.clientHeight + 1);
  });

  document.addEventListener("keydown", function (e) {
    if (e.defaultPrevented || e.altKey || e.ctrlKey || e.metaKey) return;
    var t = e.target;
    var tag = t && t.tagName;
    if (tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT" || (t && t.isContentEditable)) return;
    var inFrame = t === frame;

    switch (e.key) {
      case "ArrowLeft":
      case "ArrowRight":
        if (inFrame) return;          // arrows scroll the scan when it has focus
        var link = e.key === "ArrowLeft" ? prevLink : nextLink;
        if (link) {
          e.preventDefault();
          window.location.href = link.href;
        }
        return;
      case "+":
      case "=":
        if (ready) { e.preventDefault(); step(1); }
        return;
      case "-":
      case "_":
        if (ready) { e.preventDefault(); step(-1); }
        return;
      case "0":
        if (ready) { e.preventDefault(); setZoom("fit"); }
        return;
      case "l":
      case "L":
        if (ready) { e.preventDefault(); setZoom("left"); }
        return;
      case "r":
      case "R":
        if (ready) { e.preventDefault(); setZoom("right"); }
        return;
    }
  });

  enhance();
})();
