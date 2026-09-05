(function () {
  "use strict";
  const body = document.body;
  const working = body.dataset.artifact === "working";
  const byId = id => document.getElementById(id);
  const all = (selector, root = document) => Array.from(root.querySelectorAll(selector));

  // Printing never inherits a screen-only search, collapsed group, or workspace.
  let printState = null;
  function beforePrint() {
    if (printState) return;
    printState = all("[data-result-card], [data-result-group]").map(el => [el, el.hidden]);
    printState.forEach(([el]) => { el.hidden = false; });
  }
  function afterPrint() {
    if (!printState) return;
    printState.forEach(([el, hidden]) => { el.hidden = hidden; });
    printState = null;
  }
  window.addEventListener("beforeprint", beforePrint);
  window.addEventListener("afterprint", afterPrint);
  window.matchMedia("print").addEventListener("change", e => e.matches ? beforePrint() : afterPrint());

  function reportView() { delete body.dataset.workspace; }
  all("#workspaceNav a, .cc-actions a").forEach(link => link.addEventListener("click", () => {
    if (link.hash !== "#evidenceWorkspace") reportView();
  }));
  all("[data-findings-filter]").forEach(link => link.addEventListener("click", () => {
    reportView();
    const reset = byId("resetFilters");
    if (reset) reset.click();
    const filter = all("[data-status-filter]").find(el => el.dataset.statusFilter === link.dataset.findingsFilter);
    if (filter) filter.click();
  }));
  all("time[data-evidence-time]").forEach(el => {
    const date = new Date(el.dateTime);
    if (!Number.isNaN(date.valueOf())) {
      const hours = Math.max(0, Math.floor((Date.now() - date.valueOf()) / 3600000));
      el.textContent = date.toLocaleString() + " (" + hours + "h old)";
    }
  });

  const root = byId("answersBuilder");
  const bootstrap = byId("evidenceBootstrap");
  if (!working || !root || !bootstrap) return;
  const context = JSON.parse(bootstrap.textContent);
  const strings = context.strings;
  const feedback = byId("answersFeedback");
  const gateList = byId("evidenceGateList");
  const filter = byId("evidenceFilter");
  const elements = all("[data-answer-gate]", root);
  const records = new Map(context.gates.map(g => [g.Id, g]));
  const initial = new Map();
  const edited = new Map();
  let dirty = false;
  let activeId = elements.length ? elements[0].dataset.answerGate : "";
  let revision = "";
  const started = new Date().toISOString();
  const storageKey = "a365-last-gate:" + context.reportId;
  const text = value => value == null ? "" : String(value);
  const fields = ["id", "answer", "owner", "evidenceReference", "notes", "answeredAtUtc", "modifiedAtUtc", "justification", "binding", "reviewDecision", "baseHash"];
  const selectors = { owner: "[data-answer-owner]", evidenceReference: "[data-answer-reference]", notes: "[data-answer-notes]", justification: "[data-answer-justification]" };
  function say(message, error = false) {
    feedback.textContent = message;
    feedback.className = "tool-feedback " + (error ? "is-error" : "is-ok");
  }
  async function digest(value) {
    if (!window.crypto || !crypto.subtle) throw new Error("This browser cannot hash local evidence. Open the file in a current supported browser.");
    const bytes = new TextEncoder().encode(JSON.stringify(value));
    return Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", bytes))).map(n => n.toString(16).padStart(2, "0")).join("");
  }
  function canonical(bundle) {
    const result = {};
    ["sourceReportId", "assessmentFingerprint", "generatedAtUtc", "modifiedAtUtc", "bundleId", "baseRevision"].forEach(key => { result[key] = text(bundle[key]); });
    result.draft = !!bundle.draft;
    result.answers = bundle.answers.slice().sort((a, b) => a.id < b.id ? -1 : a.id > b.id ? 1 : 0).map(answer => {
      const entry = {};
      fields.forEach(key => { entry[key] = text(answer[key]); });
      return entry;
    });
    return result;
  }
  function element(id) { return elements.find(el => el.dataset.answerGate === id); }
  function read(el) {
    const id = el.dataset.answerGate;
    const source = records.get(id);
    const previous = source.PreviousAnswer || {};
    const selected = el.querySelector("[data-answer-value]:checked");
    const decision = el.querySelector("[data-review-decision]").value;
    const item = { id, answer: selected ? selected.value : "" };
    Object.keys(selectors).forEach(key => { const field = el.querySelector(selectors[key]); item[key] = field ? field.value.trim() : ""; });
    item.answeredAtUtc = decision === "Retain" ? text(previous.AnsweredAtUtc) : (edited.get(id) || "");
    item.modifiedAtUtc = edited.get(id) || text(previous.ModifiedAtUtc) || text(previous.AnsweredAtUtc);
    item.binding = decision === "Retain" ? text(previous.Binding) : source.Binding;
    item.reviewDecision = decision;
    item.baseHash = initial.get(id) || "";
    return item;
  }
  function status(el) {
    const entry = read(el);
    const old = records.get(entry.id).PreviousAnswer;
    if (!entry.answer) return "Unanswered";
    if (old && old.Freshness !== "Current" && !entry.reviewDecision) return old.Freshness;
    return "Answered";
  }
  function choose(id, focus = false) {
    activeId = id;
    elements.forEach(el => { el.hidden = el.dataset.answerGate !== id; });
    all("button", gateList).forEach(button => button.setAttribute("aria-current", String(button.dataset.gateId === id)));
    try { localStorage.setItem(storageKey, id); } catch (_) { /* Navigation persistence is optional; evidence remains in memory. */ }
    if (focus && element(id)) element(id).querySelector("[data-review-decision]").focus();
  }
  function refresh() {
    const matches = elements.filter(el => filter.value === "All" || status(el) === filter.value);
    gateList.replaceChildren();
    matches.forEach(el => {
      const id = el.dataset.answerGate;
      const button = document.createElement("button");
      button.type = "button";
      button.dataset.gateId = id;
      button.append(document.createTextNode(records.get(id).Title));
      const small = document.createElement("small");
      small.textContent = id + " | " + status(el);
      button.append(small);
      button.addEventListener("click", () => choose(id, true));
      gateList.append(button);
    });
    if (!matches.some(el => el.dataset.answerGate === activeId)) activeId = matches.length ? matches[0].dataset.answerGate : "";
    choose(activeId);
    byId("evidenceCounter").textContent = elements.filter(el => !!read(el).answer).length + " / " + elements.length + " answered in this draft";
    if (!matches.length) {
      const empty = document.createElement("p");
      empty.textContent = strings.emptyGates;
      gateList.append(empty);
    }
  }
  function fill(el, answer, carry = false) {
    all("[data-answer-value]", el).forEach(radio => { radio.checked = radio.value === answer.answer; });
    Object.keys(selectors).forEach(key => { const field = el.querySelector(selectors[key]); if (field) field.value = text(answer[key]); });
    el.querySelector("[data-review-decision]").value = carry ? "" : text(answer.reviewDecision);
    if (!carry && answer.modifiedAtUtc) edited.set(answer.id, answer.modifiedAtUtc);
  }
  function comparison(entry) {
    return JSON.stringify(["answer", "owner", "evidenceReference", "notes", "justification"].map(key => text(entry[key])));
  }
  elements.forEach(el => {
    const id = el.dataset.answerGate;
    const old = records.get(id).PreviousAnswer;
    if (old && old.Submitted) {
      fill(el, { id, answer: old.Answer, owner: old.Owner, evidenceReference: old.EvidenceReference, notes: old.Notes, justification: old.Justification }, true);
    }
    el.querySelector("[data-evidence-freshness]").textContent = old && old.Submitted ?
      "Previous evidence: " + old.Freshness + ". Approved " + text(old.AnsweredAtUtc) + ". Choose retain, revalidate, or edit; nothing is auto-approved." :
      strings.unansweredGuidance;
    initial.set(id, comparison(read(el)));
  });
  function openWorkspace(id) {
    body.dataset.workspace = "evidence";
    filter.value = "All";
    if (id && records.has(id)) activeId = id;
    refresh();
  }
  all('a[href="#evidenceWorkspace"]').forEach(link => link.addEventListener("click", () => openWorkspace(link.dataset.recordEvidence)));
  try {
    const saved = localStorage.getItem(storageKey);
    if (saved && records.has(saved)) activeId = saved;
  } catch (_) { /* Optional gate navigation only. */ }
  root.hidden = false;
  refresh();
  if (location.hash === "#evidenceWorkspace") openWorkspace(activeId);
  filter.addEventListener("change", refresh);
  root.addEventListener("input", event => {
    const el = event.target.closest("[data-answer-gate]");
    if (!el) return;
    dirty = true;
    edited.set(el.dataset.answerGate, new Date().toISOString());
    event.target.removeAttribute("aria-invalid");
    const id = el.dataset.answerGate;
    const button = all("button", gateList).find(item => item.dataset.gateId === id);
    if (button) button.querySelector("small").textContent = id + " | " + status(el);
    byId("evidenceCounter").textContent = elements.filter(item => !!read(item).answer).length + " / " + elements.length + " answered in this draft";
  });
  window.addEventListener("beforeunload", event => {
    if (dirty) { event.preventDefault(); event.returnValue = ""; }
  });
  function invalid(el, target, message) {
    openWorkspace(el.dataset.answerGate);
    target.setAttribute("aria-invalid", "true");
    target.setAttribute("aria-describedby", "answersFeedback");
    target.focus();
    throw new Error(message);
  }
  async function exportBundle(draft) {
    all('[aria-invalid="true"]', root).forEach(el => el.removeAttribute("aria-invalid"));
    const answers = [];
    for (const el of elements) {
      const item = read(el);
      if (!item.answer && !Object.keys(selectors).some(key => item[key])) continue;
      if (!draft) {
        if (!item.answer) invalid(el, el.querySelector("[data-answer-value]"), item.id + ": choose an answer.");
        if (!item.reviewDecision) invalid(el, el.querySelector("[data-review-decision]"), item.id + ": explicitly retain, revalidate, or edit.");
        if (item.answer === "Yes" && !item.owner) invalid(el, el.querySelector(selectors.owner), item.id + ": an accountable owner is required.");
        if (item.answer === "Yes" && !item.evidenceReference) invalid(el, el.querySelector(selectors.evidenceReference), item.id + ": an evidence reference is required.");
        if (item.answer === "NotApplicable" && !item.justification) invalid(el, el.querySelector(selectors.justification), item.id + ": justify why this is out of scope.");
        if (item.reviewDecision === "Retain") {
          const old = records.get(item.id).PreviousAnswer;
          if (!old || !old.Submitted || old.Freshness !== "Current" || comparison(item) !== initial.get(item.id)) {
            invalid(el, el.querySelector("[data-review-decision]"), item.id + ": changed, stale, or missing evidence must be revalidated, not retained.");
          }
        }
      }
      answers.push(item);
    }
    const now = new Date().toISOString();
    const bundle = { schemaVersion: "2.0", sourceReportId: context.reportId, assessmentFingerprint: context.assessmentFingerprint,
      generatedAtUtc: started, modifiedAtUtc: now, bundleId: crypto.randomUUID(), baseRevision: revision, draft, answers };
    bundle.contentHash = await digest(canonical(bundle));
    const url = URL.createObjectURL(new Blob([JSON.stringify(bundle, null, 2)], { type: "application/json" }));
    const a = document.createElement("a");
    a.href = url;
    a.download = root.dataset.answerFilename.replace(".json", draft ? "-draft.json" : ".json");
    document.body.append(a); a.click(); a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 4000);
    revision = bundle.contentHash;
    dirty = false;
    say(draft ? strings.draftExported : strings.answersExported);
  }
  byId("downloadAnswers").addEventListener("click", () => exportBundle(false).catch(error => say(error.message, true)));
  byId("exportDraft").addEventListener("click", () => exportBundle(true).catch(error => say(error.message, true)));
  byId("importEvidence").addEventListener("change", async event => {
    try {
      const file = event.target.files[0];
      if (!file) return;
      if (file.size > 2 * 1024 * 1024) throw new Error("Bundle exceeds 2 MB.");
      const bundle = JSON.parse(await file.text());
      if (bundle.schemaVersion !== "2.0" || bundle.sourceReportId !== context.reportId || bundle.assessmentFingerprint !== context.assessmentFingerprint || !Array.isArray(bundle.answers)) throw new Error("This bundle belongs to a different report or assessment.");
      if (await digest(canonical(bundle)) !== bundle.contentHash) throw new Error("Bundle hash mismatch. No evidence was imported.");
      const seen = new Set();
      const conflicts = [];
      for (const item of bundle.answers) {
        const el = element(item.id);
        if (!el || seen.has(item.id) || item.binding !== records.get(item.id).Binding) throw new Error("Unknown, duplicate, or version-mismatched gate: " + item.id);
        seen.add(item.id);
        const current = read(el);
        if (comparison(current) !== initial.get(item.id) && comparison(current) !== comparison(item)) conflicts.push(item.id);
      }
      if (conflicts.length) throw new Error("Concurrent edits conflict for " + conflicts.join(", ") + ". Nothing was merged. Export both drafts and resolve with the owners.");
      bundle.answers.forEach(item => fill(element(item.id), item));
      revision = bundle.contentHash;
      dirty = true;
      refresh();
      say(strings.bundleImported);
    } catch (error) { say(error.message, true); }
    finally { event.target.value = ""; }
  });
  const copyResume = byId("copyResumeAnswers");
  if (copyResume && root.dataset.resumeCommand) {
    copyResume.hidden = false;
    copyResume.addEventListener("click", () => {
      if (!navigator.clipboard) { say("Clipboard unavailable. Copy the command in Run summary & resume.", true); return; }
      navigator.clipboard.writeText(root.dataset.resumeCommand).then(() => say("Resume command copied."), () => say("Clipboard denied. Select the command in Run summary & resume.", true));
    });
  }
})();
