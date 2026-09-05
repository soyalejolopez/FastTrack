/* Offline packaged-artifact gate. Run with node; dependencies stay outside the package. */
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { pathToFileURL } = require("node:url");
const { spawnSync } = require("node:child_process");
const playwright = require(process.env.A365_PLAYWRIGHT_PATH || "playwright");
const resource = path.resolve(process.argv[2]);
const output = path.resolve(process.argv[3]);
fs.mkdirSync(output, { recursive: true });
const quote = value => "'" + value.replace(/'/g, "''") + "'";
function ps(code) {
  const result = spawnSync("pwsh", ["-NoLogo", "-NoProfile", "-NonInteractive", "-EncodedCommand",
    Buffer.from("$ErrorActionPreference='Stop'; & { " + code + " } 6>$null", "utf16le").toString("base64")],
  { encoding: "utf8", maxBuffer: 8 * 1024 * 1024 });
  if (result.status !== 0) throw new Error(result.stderr || result.stdout);
  return JSON.parse(result.stdout);
}
function engine(extra = "") {
  return ps(`Import-Module ${quote(path.join(resource, "Agent365Preflight.psd1"))} -Force; $o=Invoke-Agent365Preflight -FixturePath ${quote(path.join(resource, "fixtures", "commercial-ready.json"))} -Profile SharePointAgents -SharePointSiteUrl 'https://example.sharepoint.com/sites/pilot' -IncludeSanitizedCopy -OutputPath ${quote(output)} ${extra}; $o | ConvertTo-Json -Depth 100`);
}
function resume(report, answers, automatedOnly = false) {
  return ps(`$o=& ${quote(path.join(resource, "Start-Agent365Preflight.ps1"))} -Mode Resume -PreviousResultPath ${quote(report.Paths.Json)} ${answers ? "-AnswersPath " + quote(answers) : ""} ${automatedOnly ? "-AutomatedOnly" : ""} -NonInteractive -PassThru -OpenReport Never; $o.Outcome | ConvertTo-Json -Depth 100`);
}
async function download(page, button, destination) {
  const pending = page.waitForEvent("download");
  await page.locator(button).click();
  const item = await pending;
  await item.saveAs(destination);
  return item.suggestedFilename();
}
async function approve(page, editNote) {
  await page.getByRole("link", { name: "Evidence workspace", exact: true }).click();
  const ids = await page.locator("[data-answer-gate]").evaluateAll(els => els.map(el => el.dataset.answerGate));
  for (const id of ids) {
    await page.locator(`[data-gate-id="${id}"]`).click();
    const gate = page.locator(`[data-answer-gate="${id}"]`);
    await gate.locator("[data-review-decision]").selectOption("Revalidate");
    await gate.locator('[data-answer-value="Yes"]').check();
    await gate.locator("[data-answer-owner]").fill("Synthetic accountable owner");
    await gate.locator("[data-answer-reference]").fill("Synthetic approved record");
    await gate.locator("[data-answer-notes]").fill(editNote || "Browser journey evidence, not customer data.");
  }
}
async function matrix(type, first, samples) {
  const browser = await playwright[type].launch({ headless: true });
  const errors = [];
  const context = await browser.newContext({ acceptDownloads: true });
  const page = await context.newPage();
  page.on("pageerror", error => errors.push(error.message));
  const results = [];
  try {
    await page.goto(pathToFileURL(first.Paths.Html).href);
    for (const width of [320, 390, 768, 1440]) {
      const height = { 320: 568, 390: 844, 768: 1024, 1440: 900 }[width];
      await page.setViewportSize({ width, height });
      await page.evaluate(() => window.scrollTo(0, 0));
      const bounds = await page.evaluate(() => {
        const box = selector => {
          const r = document.querySelector(selector).getBoundingClientRect();
          return { top: r.top, bottom: r.bottom, height: r.height };
        };
        return { overflow: document.documentElement.scrollWidth > innerWidth, artifact: box(".cc-badge"), verdict: box("#verdict-h"), scope: box(".cc-scope"), action: box(".cta-primary") };
      });
      assert.equal(bounds.overflow, false, `${type} ${width}: horizontal overflow`);
      for (const key of ["artifact", "verdict", "scope", "action"]) assert.ok(bounds[key].bottom < height, `${type} ${width}: ${key} not in first viewport`);
      await page.screenshot({ path: path.join(output, `${type}-${width}.png`) });
      results.push({ width, height, ...bounds });
    }
    await page.setViewportSize({ width: 320, height: 900 });
    await page.evaluate(() => document.querySelectorAll(".pi-open").forEach(el => { el.textContent = "LongLocalizationLabelForEvidenceReview".repeat(4); }));
    assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth), false, `${type}: long localized control labels overflow`);
    await page.goto(pathToFileURL(first.Paths.Html).href);
    await page.emulateMedia({ colorScheme: "dark" });
    await page.screenshot({ path: path.join(output, `${type}-dark.png`) });
    await page.getByRole("link", { name: "Evidence workspace", exact: true }).click();
    assert.equal(await page.locator("[data-answer-gate]:visible").count(), 1);
    const firstGate = page.locator("[data-answer-gate]:visible");
    await firstGate.locator('[data-answer-value="Yes"]').check();
    await page.locator("#downloadAnswers").click();
    assert.equal(await page.locator('[data-review-decision][aria-invalid="true"]').count(), 1);
    assert.equal(await page.evaluate(() => document.activeElement.hasAttribute("data-review-decision")), true);
    await approve(page);
    const draft = path.join(output, `${type}-answers-draft.json`);
    await download(page, "#exportDraft", draft);
    assert.equal(JSON.parse(fs.readFileSync(draft, "utf8")).draft, true);
    await page.locator("#importEvidence").setInputFiles(draft);
    await page.waitForFunction(() => document.querySelector("#answersFeedback").textContent.includes("imported"));
    const answers = path.join(output, `${type}-answers.json`);
    const suggested = await download(page, "#downloadAnswers", answers);
    assert.equal(suggested, first.Report.Resume.AnswerFileName);
    const second = resume(first, answers);
    assert.equal(second.ExitCode, 0, `${type}: reviewed answers must pass`);
    assert.deepEqual(second.Report.RunSpecification.TargetSites, first.Report.RunSpecification.TargetSites);
    await page.goto(pathToFileURL(second.Paths.Html).href);
    await page.getByRole("link", { name: "Evidence workspace", exact: true }).click();
    assert.equal(await page.locator("[data-answer-gate]:visible [data-answer-owner]").inputValue(), "Synthetic accountable owner");
    assert.equal(await page.locator("[data-answer-gate]:visible [data-review-decision]").inputValue(), "");
    // Explicitly retain every existing approval, then edit exactly one gate.
    for (const id of await page.locator("[data-answer-gate]").evaluateAll(els => els.map(el => el.dataset.answerGate))) {
      await page.locator(`[data-gate-id="${id}"]`).click();
      await page.locator(`[data-answer-gate="${id}"] [data-review-decision]`).selectOption("Retain");
    }
    const changed = page.locator("[data-answer-gate]:visible");
    await changed.locator("[data-review-decision]").selectOption("Edit");
    await changed.locator("[data-answer-notes]").fill("One owner corrected this note on the third run.");
    const thirdAnswers = path.join(output, `${type}-third-answers.json`);
    await download(page, "#downloadAnswers", thirdAnswers);
    const third = resume(second, thirdAnswers);
    assert.equal(third.ExitCode, 0);
    const oldDates = new Map(second.Report.Results.filter(r => r.Attestation?.Applied).map(r => [r.Id, r.Attestation.AnsweredAtUtc]));
    const retained = third.Report.Results.filter(r => r.Attestation?.ReviewDecision === "Retain");
    assert.ok(retained.length > 5);
    retained.forEach(r => assert.equal(r.Attestation.AnsweredAtUtc, oldDates.get(r.Id)));
    await page.goto(pathToFileURL(third.Paths.Html).href);
    await page.locator("#resultSearch").fill("no-such-finding");
    assert.equal(await page.locator("[data-result-card]:visible").count(), 0);
    await page.evaluate(() => window.dispatchEvent(new Event("beforeprint")));
    await page.emulateMedia({ media: "print" });
    assert.equal(await page.locator("[data-result-card]:visible").count(), third.Report.Results.length);
    await page.emulateMedia({ media: "screen" });
    await page.evaluate(() => window.dispatchEvent(new Event("afterprint")));
    assert.equal(await page.locator("[data-result-card]:visible").count(), 0);
    await page.goto(pathToFileURL(third.Paths.SanitizedHtml).href);
    assert.equal(await page.locator("#answersBuilder, #evidenceBootstrap, [data-local-complete], #downloadRemediation, #resumeCommand, #rerunCommand").count(), 0);
    const noJs = await browser.newContext({ javaScriptEnabled: false });
    const staticPage = await noJs.newPage();
    await staticPage.goto(pathToFileURL(third.Paths.Html).href);
    assert.equal(await staticPage.locator("#verdict-h").innerText(), "Ready for pilot");
    assert.equal(await staticPage.locator("[data-result-card]:visible").count(), third.Report.Results.length);
    await noJs.close();
    for (const sample of samples) {
      const file = sample.Paths ? sample.Paths.Html : sample.Html;
      await page.goto(pathToFileURL(file).href);
      for (const width of [320, 390, 768, 1440]) {
        await page.setViewportSize({ width, height: 900 });
        assert.equal(await page.evaluate(() => document.documentElement.scrollWidth > innerWidth), false, `${type} ${sample.Scenario} ${width}: overflow`);
      }
      if (sample.Paths) {
        await page.goto(pathToFileURL(sample.Paths.SanitizedHtml).href);
        assert.equal(await page.locator("#answersBuilder, #evidenceBootstrap, [data-local-complete], #resumeCommand, #rerunCommand").count(), 0);
      } else {
        const count = await page.locator("[data-result-card]").count();
        assert.ok(count >= 200, "High-volume fixture must exceed 200 findings");
        const start = Date.now();
        await page.locator("#resultSearch").fill("synthetic performance row 3");
        await page.waitForFunction(() => {
          const cards = [...document.querySelectorAll("[data-result-card]")];
          return cards.some(el => el.hidden) && cards.some(el => !el.hidden);
        });
        assert.ok(Date.now() - start < 2000, `${type}: high-volume filtering exceeded 2s`);
      }
    }
    assert.deepEqual(errors, []);
    return { engine: type, version: browser.version(), cases: results, thirdReport: third.Paths.Json, errors };
  } finally { await browser.close(); }
}
async function duplicateDownloads(first) {
  const downloads = path.join(output, "redirected downloads");
  const profile = path.join(output, "download-profile");
  fs.mkdirSync(downloads, { recursive: true });
  fs.mkdirSync(path.join(profile, "Default"), { recursive: true });
  fs.writeFileSync(path.join(profile, "Default", "Preferences"), JSON.stringify({
    download: { default_directory: downloads, prompt_for_download: false, directory_upgrade: true },
    profile: { default_content_setting_values: { automatic_downloads: 1 } }
  }));
  const context = await playwright.chromium.launchPersistentContext(profile, { headless: true, channel: "chromium", acceptDownloads: true });
  try {
    const page = await context.newPage();
    const cdp = await context.newCDPSession(page);
    const { targetInfo } = await cdp.send("Target.getTargetInfo");
    // Restore the real browser download manager; CDP "allow" overwrites instead of uniquifying.
    await cdp.send("Browser.setDownloadBehavior", { behavior: "default", browserContextId: targetInfo.browserContextId, eventsEnabled: true });
    await page.goto(pathToFileURL(first.Paths.Html).href);
    await approve(page, "Initial owner note");
    await page.locator("#downloadAnswers").click();
    const original = path.join(downloads, first.Report.Resume.AnswerFileName);
    await page.waitForFunction(() => document.querySelector("#answersFeedback").textContent.includes("Answers exported"));
    for (let i = 0; !fs.existsSync(original) && i < 100; i++) await new Promise(resolve => setTimeout(resolve, 50));
    assert.ok(fs.existsSync(original), "Browser must save the original named download");
    await page.locator("[data-answer-gate]:visible [data-answer-notes]").fill("Corrected duplicate from the browser");
    await page.locator("#downloadAnswers").click();
    const duplicate = original.replace(".json", " (1).json");
    for (let i = 0; !fs.existsSync(duplicate) && i < 100; i++) await new Promise(resolve => setTimeout(resolve, 50));
    assert.ok(fs.existsSync(duplicate), "Chromium must create the real (1) duplicate filename");
    const candidates = ps(`. ${quote(path.join(resource, "Start-Agent365Preflight.ps1"))}; $previous=Read-A365FullReport ${quote(first.Paths.Json)}; @(Get-A365AnswerCandidates -Previous $previous -DownloadsPath ${quote(downloads)}) | ConvertTo-Json -Depth 10`);
    const nativeCandidates = candidates.filter(candidate => path.dirname(candidate.Path).toLowerCase() === downloads.toLowerCase());
    assert.equal(nativeCandidates.length, 2);
    assert.ok(candidates.length >= 2);
    assert.notEqual(nativeCandidates[0].ContentHash, nativeCandidates[1].ContentHash);
    const corrected = resume(first, duplicate);
    assert.equal(corrected.ExitCode, 0);
    assert.ok(corrected.Report.Results.some(r => r.Attestation?.Notes === "Corrected duplicate from the browser"));
    return { original, duplicate, candidates: candidates.length, nativeCandidates: nativeCandidates.length };
  } finally { await context.close(); }
}
(async () => {
  const first = engine();
  const duplicateOnly = process.env.A365_DUPLICATES_ONLY === "1";
  const samples = duplicateOnly ? [] : ps(`$s=& ${quote(path.join(__dirname, "New-ReportSamples.ps1"))} -ResourceRoot ${quote(resource)} -OutputPath ${quote(path.join(output, "states"))}; @($s) | ConvertTo-Json -Depth 30`);
  const results = [];
  for (const type of duplicateOnly ? [] : ["chromium", "firefox", "webkit"]) {
    results.push(await matrix(type, first, samples));
    console.log(`${type}: responsive, dark, bound three-run journey, print and no-JS passed`);
  }
  const duplicates = await duplicateDownloads(first);
  const result = { mode: duplicateOnly ? "duplicates-only" : "full", generatedAtUtc: new Date().toISOString(), resource, results, duplicates };
  fs.writeFileSync(path.join(output, "browser-results.json"), JSON.stringify(result, null, 2));
  console.log(JSON.stringify({ engines: results.length, duplicateCandidates: duplicates.candidates }));
})().catch(error => { console.error(error); process.exitCode = 1; });
