# Release owner checklist

This is the required local release gate. Repository policy limits contributions to the resource; this release does not modify protected `.github` workflows. No hosted service or repository-admin change is required to run these gates.

1. Review public rules, guidance, SKU mappings, allowlist and permission boundaries. Record owner, review date and validity in `config/assessment-policy.v2.json`. Do not extend expiry merely to obtain a pass.
2. Run Pester with both 5.7.1 and 6.1.0. Include raw Graph contract mocks, fixed-scope collector-subset properties, evidence replay/freshness, drift transition matrix, and startup/resume failures. Do not run against a live tenant.
3. Parse every PowerShell file with the PowerShell AST parser. Validate JSON and generated full/sanitized reports against their schemas. Run the repository catalog metadata gate.
4. Run the real-browser packaged journey: initial assessment, answer download, corrected browser-suffixed download, explicit revision choice, second report with retained evidence, one changed answer, third report. Cover a SharePoint target and mocked certificate app-only plan.
5. Inspect 320/390/768/1440 layouts, dark mode, keyboard/focus, no JavaScript, printing after filtering, sharing-copy controls and 200+ findings. Run Chromium, Firefox and WebKit where installed. Record unavailable platforms explicitly; do not imply they were tested.
6. Complete a read-only security review and a separate frontend-design critique. Resolve actionable findings, rerun affected tests, and record disagreements.
7. Build twice with the same `-BuiltAtUtc` and compare ZIP SHA256. Validate every internal manifest hash and byte-identical LICENSE / LICENSE-CODE against the repository. Extract to a clean path containing spaces and non-English characters; run offline Sample and resume from there.
8. Scan the package for customer identifiers, secrets, raw content, local development paths and unexpected files. The ZIP contains only the runtime allowlist and generated manifest.
9. Commit only intended resource files with the required co-author trailer. Build the final candidate using `-Release` from that clean committed source. The manifest pins source commit, build UTC, minimum dependencies and every payload hash.
10. Publish the ZIP and its `.zip.sha256` sidecar through an approved channel. A checksum alone is not provenance. Until Authenticode is available, retain the prominent unsigned notice and honor organizations that require signatures.

Example local commands from the resource folder in the reviewed source checkout (tests and the builder are not shipped in the customer ZIP):

```powershell
Import-Module Pester -RequiredVersion 5.7.1 -Force
Invoke-Pester .\tests -Output Detailed
# Repeat in a fresh PowerShell process with -RequiredVersion 6.1.0.
.\Build-Agent365PreflightPackage.ps1 -OutputDirectory C:\ReleaseCandidate -BuiltAtUtc '2026-09-05T00:00:00Z' -Force
# After committing, create the final candidate with -Release and the actual build UTC.
```

With an installed Playwright test dependency and its browser binaries, run the packaged browser gate
from the source checkout. `A365_PLAYWRIGHT_PATH` may point to a session-local Playwright installation.
The second argument must be an extracted standalone package, not the source resource:

```powershell
node .\tests\BrowserJourney.cjs C:\ReleaseCandidate\Agent365Preflight-2.0.0 C:\ReleaseCandidate\BrowserResults
```

The normal gate runs Chromium, Firefox and WebKit across full/sharing, blocked, malformed,
missing-collector, stale, passing and high-volume states. It exercises native Chromium duplicate
download suffixes in a fresh local browser profile. `browser-results.json` records the result.
No live tenant is used. PowerShell test output under both supported Pester versions must discover
and pass the same named tests, not merely return a successful exit code.

The manifest is immutable within a released ZIP. Rebuilding with different contents or metadata requires a new release/version. Its own file and the archive checksum are excluded from its hash list because self-reference is impossible; the external ZIP checksum covers the manifest too.

## API break response

Treat a new envelope, missing field, unknown aggregate column or status as malformed evidence, never a successful empty result. Reproduce with synthetic raw responses; add a regression test; check the current public API documentation; update affected semantics and version; request a fresh operator-run canary; publish a new package. Tell users which rules and previous comparisons are invalidated.

Live canaries remain separate, disabled by default and require explicit test-tenant approval. They never run in CI or on a schedule. Optional usability studies are conducted outside this tool; do not add telemetry to infer customer behavior.
