# Changelog

All notable changes to this resource are documented in this file.

## 1.2.1 - 2026-09-02

- Corrected the ActionRequired and exit-code documentation to match the enforced pass gates.
- Added a regression check that prevents customer-facing pass-gate language from drifting.

## 1.2.0 - 2026-09-02

- Made every ActionRequired result a pass gate for Pilot and Production.
- Added controlled manual evidence for approved rules and selected profiles.
- Added Path to Ready, safe rerun metadata, and resolved required-action drift.
- Added an offline remediation checklist, answers builder, and remediation workspace report.
- Bumped the report schema to 1.1 while retaining schema 1.0 baseline comparison.
- Redacted preserved observations for sensitive attestable results in support copies.

## 1.1.5 - 2026-09-02

- Added safe reuse of compatible process-scoped delegated Graph contexts.
- Added `-UseDeviceCode` for terminal-based delegated authentication.
- Fixed empty granted-scope handling so authentication failures produce incomplete reports.

## 1.1.4 - 2026-09-02

- Fixed strict-mode authentication failure handling before a Graph connection context is returned.
- Preserved the original authentication error and intended delegated or app-only mode.

## 1.1.3 - 2026-09-02

- Replaced the fixed Purview Audit Search poll count with a configurable deadline.
- Added timeout, terminal-state, elapsed-time, and Retry-After handling for audit queries.
- Kept timed-out Purview evidence incomplete while allowing the server-side query job to continue.

## 1.1.2 - 2026-09-02

- Fixed strict-mode evaluation when active or eligible role evidence contains exactly one item.
- Normalized live role collections to arrays before evaluation and report rendering.

## 1.1.1 - 2026-09-02

- Added delegated tenant targeting with `-TenantId`.
- Added post-connect assertions for tenant GUIDs and verified domains.
- Added full-report assertion evidence with sanitized-copy redaction.
- Added safe startup failures for tenant mismatch and incomplete app-only parameters.

## 1.1.0 - 2026-09-01

- Added report-wide search, status pills, and compact advanced filters.
- Added collapsible finding groups with expand and collapse controls.
- Added an accessible desktop detail blade and mobile detail sheet.
- Preserved complete no-JavaScript and print-friendly result detail.

## 1.0.0 - 2026-09-01

- Added the read-only Microsoft Agent 365 technical pre-flight collector.
- Added interactive delegated and certificate app-only Microsoft Graph authentication.
- Added offline fixture mode, manual attestations, baseline comparison, sanitization, and HTML/JSON reports.
- Added versioned rules, SKU mappings, operation allowlists, JSON schemas, and Pester coverage.
