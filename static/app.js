// gondor static/app.js — SSE bridge + modal helpers + table-row toggles.
// Loaded by templates/skip_trace.html via <script src="/static/app.js">.
//
// Contract with the server:
//   /api/events                       — SSE stream, emits "refresh" events
//   HX-Trigger: dashboard-refresh     — response header on mutations;
//                                       hx-trigger="dashboard-refresh from:body"
//                                       on slot divs picks it up
//   #workflow-dialog                  — modal target for the new-run form

(function () {
  "use strict";

  // ── SSE bridge ────────────────────────────────────────────────────
  var main = document.getElementById("kh-main");
  if (main && typeof EventSource !== "undefined") {
    var source = new EventSource("/api/events");
    var lastRevision = null;

    source.addEventListener("refresh", function (evt) {
      if (evt.data === lastRevision) return;
      lastRevision = evt.data;

      // Don't clobber an open modal — finish whatever the operator is
      // doing first; the next refresh will pick up the new state.
      var openDialog = document.querySelector("#workflow-dialog .modal-overlay");
      if (openDialog) return;

      fetch(window.location.pathname + window.location.search,
        { credentials: "same-origin" })
        .then(function (resp) { return resp.text(); })
        .then(function (html) {
          var doc = new DOMParser().parseFromString(html, "text/html");
          var newMain = doc.getElementById("kh-main");
          if (newMain && main.innerHTML !== newMain.innerHTML) {
            main.innerHTML = newMain.innerHTML;
            if (window.htmx) window.htmx.process(main);
          }
        })
        .catch(function (err) {
          console.error("[gondor] refresh failed:", err);
        });
    });

    source.addEventListener("error", function () {
      // EventSource auto-reconnects; just log.
      console.warn("[gondor] SSE disconnected, reconnecting…");
    });
  }

  // ── Modal helpers ────────────────────────────────────────────────
  // Bound globally so onclick handlers in dialog HTML can invoke without
  // an import dance. evt-aware to support both backdrop click and the
  // [×] / [Cancel] buttons.
  window.closeWorkflowDialog = function (evt) {
    if (evt && evt.target && !evt.target.classList.contains("modal-overlay")) return;
    var dialog = document.getElementById("workflow-dialog");
    if (dialog) dialog.innerHTML = "";
  };

  // Close on Escape — better keyboard UX than only the [×] button.
  document.addEventListener("keydown", function (evt) {
    if (evt.key === "Escape") window.closeWorkflowDialog();
  });

  // ── Recent-runs row expand ───────────────────────────────────────
  // Toggles the next sibling <tr class="pipeline-history-detail">.
  // Bound on window so inline onclick="togglePipelineDetail('id')" works.
  window.togglePipelineDetail = function (id) {
    var detail = document.getElementById(id);
    if (!detail) return;
    detail.style.display = detail.style.display === "none" ? "" : "none";
  };

  // ── Step click → log filter ──────────────────────────────────────
  // Ported from gitops/knowhere's static/app.js. Two flavours:
  //   • toggleStepDetail(stepEl)             — for the live active-card
  //   • toggleRunStepDetail(stepEl, runId)   — for the expanded row in
  //                                            the recent-runs table
  // Both filter the run's log to entries matching the clicked step's
  // data-step index, mark that step .step-selected, and toggle a
  // sibling step-detail panel. Click the same step again to release.

  function setActivePipelineStep(scope, stepIndex) {
    if (!scope) return;
    scope.querySelectorAll(".pipeline-step").forEach(function (s) {
      var on = stepIndex !== null && s.getAttribute("data-step") === stepIndex;
      s.classList.toggle("step-selected", on);
    });
  }

  window.toggleStepDetail = function (stepEl) {
    var stepIndex = stepEl.getAttribute("data-step");
    var detailPanel = document.getElementById("step-detail");
    var logPanel = document.getElementById("step-log");
    var mainLog = document.getElementById("pipeline-log");
    var stepsScope = stepEl.closest(".pipeline-steps");
    if (!detailPanel || !logPanel) return;

    if (detailPanel.style.display !== "none"
        && detailPanel.getAttribute("data-active-step") === stepIndex) {
      detailPanel.style.display = "none";
      if (mainLog) mainLog.style.display = "";
      setActivePipelineStep(stepsScope, null);
      return;
    }

    var allEntries = mainLog ? mainLog.querySelectorAll(".log-entry") : [];
    var filtered = [];
    allEntries.forEach(function (entry) {
      if (entry.getAttribute("data-step") === stepIndex) {
        filtered.push(entry.outerHTML);
      }
    });

    logPanel.innerHTML = filtered.length > 0
      ? filtered.join("")
      : '<div class="log-entry meta">No log entries for this step yet.</div>';
    detailPanel.style.display = "";
    detailPanel.setAttribute("data-active-step", stepIndex);
    if (mainLog) mainLog.style.display = "none";
    setActivePipelineStep(stepsScope, stepIndex);

    var nameEl = document.getElementById("step-detail-name");
    if (nameEl) {
      var nameNode = stepEl.querySelector(".step-name");
      nameEl.textContent = nameNode ? nameNode.textContent.trim()
                                    : "step " + (parseInt(stepIndex, 10) + 1);
    }
  };

  // ── Runs table — filter + per-column sort ────────────────────────
  // The runs table is rendered server-side. For volume <500 rows
  // client-side filter + sort is fine; no round-trip per keystroke.
  // Filter: case-insensitive substring match across visible cells.
  // Sort:   click any th[data-sort] to toggle asc/desc; numeric vs text
  //         is selected by data-sort="num" vs "text" on the th.
  window.filterPipelineRuns = function (query) {
    var q = (query || "").trim().toLowerCase();
    var rows = document.querySelectorAll(
      "#skip-trace-runs-fragment tbody tr.pipeline-history-row");
    rows.forEach(function (row) {
      var detail = row.nextElementSibling;
      if (!q) {
        row.classList.remove("filter-hidden");
        if (detail && detail.classList.contains("pipeline-history-detail")) {
          detail.classList.remove("filter-hidden");
        }
        return;
      }
      var hay = row.textContent.toLowerCase();
      var match = hay.indexOf(q) !== -1;
      row.classList.toggle("filter-hidden", !match);
      if (detail && detail.classList.contains("pipeline-history-detail")) {
        detail.classList.toggle("filter-hidden", !match);
      }
    });
  };

  window.sortPipelineRuns = function (th, columnIndex) {
    var table = th.closest("table");
    if (!table) return;
    var tbody = table.querySelector("tbody");
    if (!tbody) return;

    // Each "row" is actually a pair: a .pipeline-history-row + its
    // sibling .pipeline-history-detail. Group them so sort keeps the
    // pair adjacent.
    var pairs = [];
    var rows = tbody.querySelectorAll("tr.pipeline-history-row");
    rows.forEach(function (r) {
      pairs.push([r, r.nextElementSibling]);
    });

    var dir = th.dataset.sortDir === "asc" ? "desc" : "asc";
    table.querySelectorAll("th.sortable").forEach(function (h) {
      h.removeAttribute("data-sort-dir");
      h.classList.remove("sort-asc", "sort-desc");
    });
    th.dataset.sortDir = dir;
    th.classList.add(dir === "asc" ? "sort-asc" : "sort-desc");

    var mode = th.dataset.sort || "text";
    function key(rowPair) {
      var cell = rowPair[0].cells[columnIndex];
      if (!cell) return "";
      var v = cell.dataset.sortValue;
      if (v == null) v = (cell.textContent || "").trim();
      return mode === "num" ? parseFloat(v) || 0 : v.toLowerCase();
    }

    pairs.sort(function (a, b) {
      var ka = key(a), kb = key(b);
      if (ka < kb) return dir === "asc" ? -1 : 1;
      if (ka > kb) return dir === "asc" ? 1 : -1;
      return 0;
    });

    pairs.forEach(function (p) {
      tbody.appendChild(p[0]);
      if (p[1]) tbody.appendChild(p[1]);
    });
  };

  window.toggleRunStepDetail = function (stepEl, runId) {
    var container = document.querySelector('[data-run-id="' + runId + '"]');
    if (!container) return;
    var stepIndex = stepEl.getAttribute("data-step");
    var mainLog = container.querySelector(".pipeline-log-main");
    var detailPanel = container.querySelector(".pipeline-step-detail");
    var logPanel = container.querySelector(".pipeline-step-log");
    if (!detailPanel || !logPanel) return;

    var stepsScope = stepEl.closest(".pipeline-steps");

    if (detailPanel.style.display !== "none"
        && detailPanel.getAttribute("data-active-step") === stepIndex) {
      detailPanel.style.display = "none";
      if (mainLog) mainLog.style.display = "";
      setActivePipelineStep(stepsScope, null);
      return;
    }

    var entries = mainLog ? mainLog.querySelectorAll(".log-entry") : [];
    var filtered = [];
    entries.forEach(function (entry) {
      if (entry.getAttribute("data-step") === stepIndex) {
        filtered.push(entry.outerHTML);
      }
    });

    setActivePipelineStep(stepsScope, stepIndex);
    logPanel.innerHTML = filtered.length > 0
      ? filtered.join("")
      : '<div class="log-entry meta">No log entries for this step.</div>';
    detailPanel.style.display = "";
    detailPanel.setAttribute("data-active-step", stepIndex);
    if (mainLog) mainLog.style.display = "none";
  };
})();

// Sidebar: collapsible <details data-section> persistence + click mutex
// for grouped sidebar entries. Mirrors libs/sysops/static/app.js since
// gondor overrides /static/app.js.
(function () {
  document.querySelectorAll('details[data-section]').forEach(function (el) {
    var key = 'sidebar.' + el.dataset.section;
    var saved = localStorage.getItem(key);
    if (saved === 'open') el.open = true;
    if (saved === 'closed') el.open = false;
    el.addEventListener('toggle', function () {
      localStorage.setItem(key, el.open ? 'open' : 'closed');
    });
  });
  document.querySelectorAll('details[data-section] > summary').forEach(function (s) {
    s.addEventListener('click', function () {
      document.querySelectorAll('aside.sidebar a.active').forEach(function (a) {
        a.classList.remove('active');
      });
      document.querySelectorAll('summary.summary-selected').forEach(function (other) {
        if (other !== s) other.classList.remove('summary-selected');
      });
      s.classList.add('summary-selected');
    });
  });
  document.querySelectorAll('aside.sidebar a').forEach(function (a) {
    a.addEventListener('click', function () {
      document.querySelectorAll('summary.summary-selected').forEach(function (s) {
        s.classList.remove('summary-selected');
      });
    });
  });
})();
