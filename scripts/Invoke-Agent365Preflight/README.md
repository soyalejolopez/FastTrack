---
title: "Invoke-Agent365Preflight"
type: script
category: "PowerShell"
summary: "Run a read-only Agent 365 technical pre-flight and generate self-contained HTML and JSON reports."
author:
  - "Microsoft FastTrack"
version: 1.4.1
published: 2026-09-01
updated: 2026-09-04
tags:
  - agent-365
  - readiness
  - governance
  - security
format: bundle
featured: false
status: active
whatItIs: >-
  A PowerShell 7 evidence collector that checks Microsoft Agent 365 technical prerequisites and
  creates local HTML and JSON reports without changing tenant configuration.
whyUseIt:
  - "Separate technical blockers, authorization gaps, manual decisions, and evidence coverage before an Agent 365 pilot."
  - "Collect public-rule-based evidence across licensing, roles, registry, Entra, Defender, Purview, and selected profiles."
  - "Generate a full local report and an optional redacted support copy."
howToUse: |-
  1. Download and extract the resource.
  2. Open Windows Terminal with PowerShell 7 in this folder.
  3. Run:

     ```powershell
     .\Start-Agent365Preflight.ps1
     ```
prerequisites:
  - "PowerShell 7"
  - "Microsoft.Graph.Authentication 2.20.0 or later"
  - "Interactive sign-in with the documented read permissions, or Graph-only certificate app authentication"
---

# Microsoft FastTrack Open Source - Invoke-Agent365Preflight

## START HERE

Choose the acquisition path available to you:

### FastTrack catalog or GitHub resource page

Read the rendered README first. If the catalog entry provides a standalone
`Agent365Preflight-<version>.zip`, download and extract it. Do not assume a standalone package is
attached unless the catalog or resource page shows one.

Open the extracted `Agent365Preflight-<version>` folder. `START-HERE.txt` and
`Start-Agent365Preflight.ps1` are visible at that root.

### Repository clone or full repository ZIP

Clone [microsoft/FastTrack](https://github.com/microsoft/FastTrack), or download its
[master branch ZIP](https://github.com/microsoft/FastTrack/archive/refs/heads/master.zip). Then
navigate to:

```text
scripts\Invoke-Agent365Preflight
```

For either path, open **Windows Terminal** with PowerShell 7 in the resource folder and run:

```powershell
.\Start-Agent365Preflight.ps1
```

The launcher checks prerequisites, explains permissions before sign-in, offers a safe sample run,
runs the recommended Control Plane pre-flight, opens the **full local working report**, and guides
the answer-and-rerun flow. `Invoke-Agent365Preflight.ps1` remains available for advanced or
unattended automation. When the launcher asks whether to open the report, pressing Enter accepts the
documented default of opening the full report; the sanitized sharing copy is never auto-opened.

Maintainers can build the standalone archive without downloading or executing remote code:

```powershell
.\Build-Agent365PreflightPackage.ps1 -OutputDirectory C:\Temp -Force
```

The builder uses a strict customer-runtime allowlist. It excludes tests, Git files, generated
reports, browser artifacts, and customer evidence.

`Invoke-Agent365Preflight` is a read-only Microsoft Agent 365 technical pre-flight checker. It
collects evidence, applies versioned public rules, and creates a self-contained HTML report plus a
JSON sidecar. It never configures the tenant, grants consent, assigns licenses, changes policies,
or deploys agents.

> This output is a technical pre-flight, not a security or compliance certification. A passed
> result means the documented evidence was collected and met that rule. It does not prove that a
> control is effective in every scenario.

## What it does and does not prove

The tool checks whether documented technical prerequisites and evidence are available for the
selected Agent 365 pilot scope. It helps administrators find blockers, authorization gaps, follow-up
actions, and decisions that still need a person to confirm.

It does **not** certify the tenant, approve an agent, prove that a policy is enforced in every
scenario, or replace security, privacy, responsible AI, legal, or compliance review. It does not
change configuration.

### Technical checks

- Local PowerShell, module, platform, and safe endpoint prerequisites
- Commercial-cloud availability and Agent 365 service-plan assignment
- Agent management active roles and optional PIM eligibility
- Microsoft 365 service health
- Agent package catalog summary through the v1.0 Package Management API
- Agent identity blueprint inventory, owner/sponsor coverage, credential expiry, and permission counts
- Security defaults before Conditional Access policy inventory
- Aggregate-only `AgentsInfo` and `BehaviorInfo` Defender hunting probes
- Aggregate Purview Audit Search evidence for Copilot and AI interaction operations
- Optional first-party Purview policy metadata and target SharePoint site evidence
- Manual owner, approval, responsible AI, incident, pilot, rollback, and retirement attestations
- Regressions and resolved blockers compared with a previous JSON report

The package catalog is not treated as complete agent inventory. Policy presence is not treated as
proof of enforcement. An empty audit result means no evidence was found in the selected window, not
that auditing is disabled.

## How the evidence flow works

1. **Load inputs.** The script validates PowerShell, versioned rules, SKU mappings, the operation
   allowlist, optional manual answers, and an optional previous report.
2. **Build the collection plan.** `TenantFoundation` is always included. The script adds the selected
   collectors and derives the exact Microsoft Graph scopes required for that run.
3. **Show permissions before sign-in.** The complete scope list is written to the console before
   interactive authentication. Fixture mode stops here and makes no tenant request.
4. **Collect read-only evidence.** Microsoft Graph requests and optional workload commands must match
   the versioned allowlist. An unselected collector does not run.
5. **Reduce evidence immediately.** Defender, Purview, package, role, license, and identity results
   are reduced to counts, states, and timestamps. Raw events and content are not written to disk.
6. **Evaluate each rule.** Every applicable rule receives one documented status, expected and
   observed evidence, collection method and time, required access, remediation, and public source.
7. **Add customer decisions and drift.** Manual answers are evaluated, then the current result can
   be compared with a previous JSON report.
8. **Write reports even after partial failure.** The script produces HTML and JSON when individual
   collectors fail. Optional sanitized copies remove tenant identity and sensitive result details.
9. **Resume without rebuilding the command.** Each run writes a local resume helper and a unique
   expected answers filename. The helper validates the previous full report and matching answers,
   preserves the original scope, and runs the next comparison in the same output folder.

## How to remediate and rerun

The report is designed as a customer remediation workspace. It never changes tenant settings.

1. Open **Path to Ready** and review blockers, collection gaps, required actions, and unresolved
   manual gates in order.
2. Make the documented change in the owning Microsoft admin portal. Use the public documentation
   link on the finding.
3. Capture accountable manual evidence in the full report's guided Answers Builder and download
   the report-linked answers JSON file. Do not remediate from the sanitized sharing copy.
4. Run the one-command `Resume-Agent365Preflight.ps1` helper in the output folder. It finds the
   matching answers file in Downloads or beside the report, preserves the original settings, and
   uses the current JSON report as the baseline.
5. Confirm that Blocker, ActionRequired, NotAuthorized, Error, and unresolved required manual counts
   are all zero. Then review resolved items, drift, and nonblocking advisories.

Local checklist marks in the HTML report are planning aids only. They store boolean completion state
in the browser and never change the official verdict. A rerun is always required to collect current
evidence and calculate a new verdict.

### Controlled manual evidence

Only rules explicitly approved in `config/rules.v1.json` can accept manual evidence. The current
contract supports:

- Blueprint permission review (`A365-ENTRA-005`)
- Conditional Access coverage by authentication pattern (`A365-ENTRA-007`)
- Defender portal controls (`A365-DEFENDER-003`)
- Purview policy scope and enforcement review (`A365-PURVIEW-002`)
- SharePoint boundary review when selected (`A365-SHAREPOINT-001`)
- Stable selected-profile gates such as `A365-PROFILE-COPILOTSTUDIO`
- The seven customer control gates `A365-MANUAL-001` through `A365-MANUAL-007`

A valid `Yes` requires an accountable owner or role and an evidence reference. `No` becomes the
rule's configured `ActionRequired` or `Blocker` status. `NotApplicable` is accepted only for rules
that explicitly allow it and requires a justification. Evidence never overrides an automated
Blocker, ActionRequired, NotAuthorized, or Error result; the tenant or collection issue must be
resolved and recollected.

Every Answers Builder item includes **Review guidance**. Open it before answering to see what the
decision means, why it matters, who should confirm it, the specific `Yes` criteria, evidence to
retain, verification steps, `No` remediation, and the rule for `NotApplicable`. The guidance is
stored in the versioned public `config/guidance.v1.json` contract and is also included in print and
no-JavaScript output. Microsoft Learn links support the in-report steps rather than replacing them.

Guidance helps the accountable customer reviewer make and document a defensible decision. It does
not approve the control, infer an answer, replace customer policy, or change the current verdict.
Only a valid answers file supplied on a rerun can apply manual evidence.

Each downloaded answers file uses the report-linked name
`Agent365Preflight-<run-id>-answers.json`. The report and generated resume helper look for that
exact name, so the customer does not need to move the browser download or edit a command.

Answers schema `1.1` adds rule and profile gates, timestamps, and N/A justification while accepting
legacy `1.0` files. The sample includes every static gate and every supported stable profile ID.
Remove unselected profile entries or leave them in the template; only selected, applicable gates are
evaluated.

## Safety and data handling

- Every tenant operation is checked against `config/operation-allowlist.v1.json`.
- Microsoft Graph uses `GET` plus the query-only `POST` operations
  `/security/runHuntingQuery` and `/security/auditLog/queries`.
- The Purview Audit Search `POST` creates a search-job record in the tenant's audit workspace.
  The script reads only aggregate counts and does not create or change an audit policy, but the
  service can retain query-job history that other authorized audit administrators can see.
- Optional workload adapters call only explicitly approved `Get-*` or `Search-*` commands.
- The script does not save tokens, secrets, prompts, responses, message bodies, file content, or raw
  audit and hunting records.
- Defender and Purview data is reduced to counts and timestamps while it is collected.
- Partial failures still produce a report.
- A sanitized support copy removes tenant identity and sensitive result details.
- When `-TenantId` is supplied, the full report records the requested tenant, assertion method,
  connected tenant ID, and matched domain. Sanitized copies remove those identifiers.

Review local report handling with your security and privacy teams. The full report can contain
tenant name, tenant ID, primary domain, signed-in account, site URLs, and summarized configuration
evidence.

## Prerequisites

### PowerShell and modules

PowerShell 7 is required. The only required external module is
`Microsoft.Graph.Authentication` 2.20.0 or later. Dependencies are never installed by default.

To opt in to installing the Graph authentication module for the current user:

```powershell
.\Invoke-Agent365Preflight.ps1 -InstallDependencies
```

Optional evidence is collected only when the supported first-party workload commands are already
available. Establish any workload session outside this script before running it.

### Prepare consent and roles

Microsoft Graph permission consent and Microsoft Entra or workload roles are separate requirements.
Granting a scope does not assign an administrator role, and assigning a role does not grant Graph
consent.

Before a live run:

1. Select only the collectors needed for the pilot.
2. Review the derived scopes in the table below.
3. Have an authorized tenant administrator grant consent where tenant policy requires it.
4. Use an account with the least-privileged role listed by each check. The report identifies missing
   scope, consent, role, license, workload, and API failures separately where the service response
   allows that distinction.
5. Use a dedicated read account where your operating model supports one. Avoid routine use of Global
   Administrator.

Some APIs impose specific roles. The Package Management API requires **AI Administrator** or
**Global Administrator**. Agent Identity Blueprint reads for nonowners require **Agent ID
Administrator**. Defender, Purview, service health, Conditional Access, and SharePoint checks also
require their documented read roles.

### Delegated Microsoft Graph scopes

The script derives consent from the selected evidence collectors and prints the exact scope set
before interactive authentication. `TenantFoundation` is always added so the tool can identify the
tenant and enforce the commercial-cloud availability gate.

| Collector | Delegated Microsoft Graph scopes |
| --- | --- |
| `TenantFoundation` | `Organization.Read.All` |
| `Licensing` | `Organization.Read.All`, `User.Read.All` |
| `Roles` | `RoleManagement.Read.Directory`, `RoleEligibilitySchedule.Read.Directory` |
| `ServiceHealth` | `ServiceHealth.Read.All` |
| `Registry` | `CopilotPackages.Read.All` |
| `AgentIdentity` | `AgentIdentityBlueprint.Read.All`, plus `Application.Read.All` only for sponsors |
| `ConditionalAccess` | `Policy.Read.All` |
| `Defender` | `ThreatHunting.Read.All` |
| `Purview` | `AuditLogsQuery.Read.All` |
| `SharePoint` | No Microsoft Graph scope; uses the optional first-party module |

All collectors are selected by default for backward-compatible complete coverage. Use `-Collector`
to request only the adapters needed for the run. Checks owned by an unselected collector are
reported as `NotApplicable`, not as passed.

The report separates a missing delegated scope from tenant consent, user role, license, workload
availability, HTTP errors, and schema errors where the service response allows that distinction.
Use the least-privileged supported role for each check. See each result's required permission and
role.

If the current process already has a delegated Graph context for an actual tenant and contains every
requested scope, the script reuses it. A context with missing scopes, the wrong requested tenant
GUID, or app-only authentication is never reused for a delegated run.

### Certificate app-only mode

Certificate app-only authentication is Microsoft Graph only. Client secrets are not accepted.
Supplying `-ClientId` or `-CertificateThumbprint` selects app-only mode, which requires all three
certificate parameters. Configure the required application permissions and admin consent on the app
registration, then run:

```powershell
.\Invoke-Agent365Preflight.ps1 `
  -TenantId "00000000-0000-0000-0000-000000000000" `
  -ClientId "00000000-0000-0000-0000-000000000000" `
  -CertificateThumbprint "CERTIFICATE_THUMBPRINT" `
  -OutputPath "C:\Temp\Agent365Preflight"
```

All three certificate parameters are required together.
`-UseDeviceCode` cannot be combined with certificate app-only parameters.

## Setup and first run

### Get the resource

Download the `scripts/Invoke-Agent365Preflight` folder or clone the FastTrack repository, then open
PowerShell 7 in the resource folder:

```powershell
git clone https://github.com/microsoft/FastTrack.git
Set-Location .\FastTrack\scripts\Invoke-Agent365Preflight
```

Confirm the required Graph authentication module is available:

```powershell
Get-Module Microsoft.Graph.Authentication -ListAvailable |
  Sort-Object Version -Descending |
  Select-Object -First 1 Name, Version
```

The script never installs a module unless you explicitly use `-InstallDependencies`.

### Start with the guided launcher

Run the launcher and choose **Try safely with sample data** before connecting to a tenant:

```powershell
.\Start-Agent365Preflight.ps1
```

Fixture mode demonstrates the first-run `Incomplete` journey without authentication or tenant
access. The report explains each manual gate and produces a local resume helper.

### First live run

Run the launcher in a native Windows Terminal and choose **Run the recommended Control Plane
pre-flight**. It asks for the tenant verified domain or GUID and stage, then selects the standard
Graph collectors and explains every derived scope before authentication.

```powershell
.\Start-Agent365Preflight.ps1
```

On Windows, normal interactive authentication is the recommended path because the same process keeps
the delegated Graph context for collection and later resume runs. Microsoft.Graph.Authentication
2.34 and later uses Windows Authentication Manager (WAM) for normal Windows interactive sign-in.
Run it directly in Windows Terminal or PowerShell so the broker has a parent window. Embedded or
background terminals can fail with a window-handle error; the launcher detects common embedded
hosts, explains the problem, and offers device code.

Device code remains a portable fallback. Be ready to open `https://microsoft.com/devicelogin`,
enter the code, and complete consent immediately. Recent module versions can provide about 120
seconds. If the code expires, the launcher stays open and offers **Try again now**.

Do not use `Set-MgGraphOption -DisableLoginByWAM` as this tool's standard workaround. Use a native
Windows terminal for WAM, or choose device code. A custom app registration is not required for the
normal interactive first-use flow.

If consent or a required role is missing, collection continues where safe and records the gap.
`Incomplete` is expected on the first run because required customer evidence has not been supplied.

### Pin delegated sign-in to the intended tenant

Use `-TenantId` by itself with either the tenant GUID or a verified domain. The script passes that
value to `Connect-MgGraph` for interactive delegated sign-in, then performs a second assertion before
running non-foundation collectors:

- For a GUID, the requested value must match the tenant ID returned by `Get-MgContext`.
- For a verified domain, the organization query is the first authorized Graph request and the
  requested domain must exist in `verifiedDomains`.

If either assertion fails, the script stops immediately and writes no normal tenant report. A
successful full report records the expected and connected tenant evidence under
**Tenant > TargetAssertion**. Sanitized copies remove the tenant identifiers.

## Recommended pilot run

For most customers, use the guided **Recommended** mode:

```powershell
.\Start-Agent365Preflight.ps1 -Mode Recommended -TenantId "contoso.onmicrosoft.com"
```

`ControlPlane` and the standard Graph collectors are selected automatically. Use **Advanced/custom**
only when adding platform profiles, SharePoint target sites, optional workload sessions, or a
different collector scope.

After reviewing and fixing the full report, download the guided answers file and run:

```powershell
& "C:\Temp\Agent365Preflight\Resume-Agent365Preflight.ps1"
```

The helper contains no secrets. It locates the exact report-linked answers file in Downloads or the
output folder, validates it, reuses the report's stage, profiles, collectors, audit settings, and
tenant target, and opens the new full report after the rerun.

### Production technical pre-flight

```powershell
.\Invoke-Agent365Preflight.ps1 `
  -Profile ControlPlane,CopilotStudio,Foundry,CustomProCode `
  -Stage Production `
  -AnswersPath .\answers.customer.json `
  -OutputPath "C:\Temp\Agent365Preflight"
```

### Offline fixture mode reference

Fixture mode never authenticates or calls a tenant. It is suitable for demos and tests.

```powershell
.\Invoke-Agent365Preflight.ps1 `
  -FixturePath .\fixtures\commercial-ready.json `
  -AnswersPath .\samples\answers.sample.json `
  -Profile ControlPlane,CopilotStudio,AgentBuilder,SharePointAgents,Foundry `
  -OutputPath .\out
```

### Compare with a previous run

```powershell
.\Invoke-Agent365Preflight.ps1 `
  -PreviousResultPath "C:\Temp\Previous\Agent365Preflight.json" `
  -OutputPath "C:\Temp\Current"
```

## Parameters

### Guided launcher

| Parameter | Purpose |
| --- | --- |
| `-Mode` | `Guided`, `Sample`, `Recommended`, `Resume`, or `Advanced`. No argument starts the wizard. |
| `-Authentication` | `Auto`, `Interactive`, or `DeviceCode`. Auto favors normal interactive WAM in a native Windows terminal. |
| `-PreviousResultPath` | Full report JSON used by Resume mode. Sanitized reports are rejected. |
| `-AnswersPath` | Optional explicit answers path. Otherwise Resume finds the exact report-linked filename. |
| `-OpenReport` | `Ask`, `Always`, or `Never`. Only the full local report is opened. |
| `-NonInteractive` | Uses supplied parameters without prompts. Intended for repeatable tests and automation. |
| `-InstallDependencies` | Explicit opt-in to install Microsoft.Graph.Authentication for CurrentUser. |

### Advanced engine

| Parameter | Purpose |
| --- | --- |
| `-Profile` | Selects optional workload profiles. `ControlPlane` is always added. |
| `-Collector` | Selects evidence adapters and derives incremental Graph consent. `TenantFoundation` is always added; all collectors are the default. |
| `-Stage` | `Pilot` or `Production`. |
| `-OutputPath` | Output directory for HTML and JSON reports. |
| `-AnswersPath` | Manual attestation answers JSON. |
| `-PreviousResultPath` | Previous full JSON report for drift comparison. |
| `-FixturePath` | Offline synthetic evidence file. No authentication or tenant calls occur. |
| `-SharePointSiteUrl` | Intended target sites for optional SharePoint evidence. |
| `-AuditWindowDays` | Purview audit window, from 1 through 90 days. |
| `-AuditQueryTimeoutSeconds` | Overall Purview Audit Search query timeout, from 30 through 900 seconds. Defaults to 300. |
| `-IncludeSanitizedCopy` | Writes redacted HTML and JSON support copies. |
| `-InstallDependencies` | Explicitly opts in to CurrentUser installation of the required Graph authentication module. |
| `-IncludeBeta` | Records explicit beta opt-in. Version 1 rules do not require beta endpoints. |
| `-UseDeviceCode` | Uses device-code flow for a new delegated connection. Incompatible with certificate app-only parameters. |
| `-TenantId` | Pins delegated sign-in to a tenant GUID or verified domain. With app-only parameters, identifies the app's tenant. |
| `-ClientId`, `-CertificateThumbprint` | Selects Graph-only certificate app authentication. TenantId, ClientId, and CertificateThumbprint are all required together. |

## Profiles

Available profiles are `ControlPlane`, `CopilotStudio`, `AgentBuilder`, `SharePointAgents`,
`Foundry`, `CustomProCode`, `ExternalRegistrySync`, `LocalAgents`, `WorkIQ`, and `AITeammate`.
Profile-specific product setup that has no supported read API remains a clearly labeled manual
validation.

## Collectors

Collectors control which evidence adapters run. Available values are `TenantFoundation`,
`Licensing`, `Roles`, `ServiceHealth`, `Registry`, `AgentIdentity`, `ConditionalAccess`,
`Defender`, `Purview`, and `SharePoint`.

For example, this command requests only tenant context, licensing, registry, and Agent Identity
evidence:

```powershell
.\Invoke-Agent365Preflight.ps1 `
  -Collector TenantFoundation,Licensing,Registry,AgentIdentity `
  -OutputPath "C:\Temp\Agent365Preflight"
```

The Package Management API requires the `CopilotPackages.Read.All` permission and an
**AI Administrator** or **Global Administrator** role. The broader AI Reader and Global Reader
roles remain useful for portal visibility but aren't presented as sufficient for this API.

## Verdicts, states, and exit codes

### Passing criteria

| Gate | Required value for passing |
| --- | --- |
| `Blocker` | 0 |
| `ActionRequired` | 0 |
| `NotAuthorized` | 0 |
| `Error` | 0 |
| Unresolved required manual gates | 0 |

Advisories do not block passing, but the customer should review and acknowledge their impact.
Passing Pilot remains `Ready for pilot`; passing Production remains
`Technical pre-flight complete`.

### Verdicts

| Verdict | Meaning |
| --- | --- |
| `Ready for pilot` | Every required pass gate is clear for the selected pilot scope. Review nonblocking advisories. |
| `Blocked` | At least one blocking technical condition or required manual answer of `No` must be resolved. |
| `Incomplete` | One or more ActionRequired, authorization, collection-error, or unresolved required manual gates prevent passing. |
| `Technical pre-flight complete` | Every required Production pass gate is clear. It is not a certification. |

### Check statuses

| Status | Meaning |
| --- | --- |
| `Passed` | Collected evidence met the rule as written. |
| `Blocker` | The selected stage must not proceed until the condition is resolved. |
| `ActionRequired` | The finding must be resolved before passing. Until then, the overall verdict is `Incomplete`. |
| `Advisory` | Review the observation and decide whether it affects the pilot. |
| `ManualValidation` | A person must validate a condition that the supported read interfaces cannot prove. |
| `NotApplicable` | The collector, profile, cloud, or scenario does not apply to this run. It is not a pass. |
| `NotAuthorized` | The collector could not read evidence because scope, consent, or role access was insufficient. |
| `Error` | Collection failed because of an API, schema, timeout, throttling, or other technical error. |

### Actions, coverage, and attestations

- **Path to Ready** and **Ordered actions** place blockers, collection gaps, required actions, and
  unresolved evidence before advisories.
- **Coverage** shows how much evidence was collected. It is separate from the verdict and is not a
  compliance or security score.
- **Manual attestations** record customer-owned decisions for ownership, approval boundaries,
  responsible AI, privacy and legal review, incident response, success criteria, rollback, and
  retirement. The tool does not make these decisions for you.

| Exit code | Meaning |
| --- | --- |
| `0` | All pass gates are clear: zero Blocker, ActionRequired, NotAuthorized, Error, and unresolved required manual gates. |
| `1` | One or more blockers were found. |
| `2` | One or more ActionRequired, NotAuthorized, Error, unresolved required manual gates, or other collection gaps prevent passing. |
| `3` | Invalid execution, input, or unrecoverable startup failure. |

## Interactive report experience

The self-contained HTML report starts with the executive verdict and ordered actions, then supports
progressive disclosure for detailed findings:

- Use the Readiness Command Center and **Open Path to Ready** to see exactly what prevents passing.
- Use the local-only checklist to plan work without changing the official verdict.
- Build and download a validated answers JSON file in memory; no evidence is sent over a network.
- Open **Review guidance** beside any answer to use the acceptance criteria, evidence checklist, and
  verification steps without leaving the report.
- Copy the safe rerun command or download the remediation checklist for offline planning.
- Search across status, title, ID, area, pillar, expected and observed evidence, remediation, roles,
  and permissions. Press `/` to focus search and `Escape` to clear it.
- Combine status pills with compact pillar, area, and profile filters. Use **Reset filters** to
  return to the complete result set.
- Expand or collapse result groups, then open any finding in an accessible desktop detail blade or
  mobile bottom sheet.
- Use keyboard navigation, the close button, backdrop, or `Escape` to close details. Focus returns
  to the finding that opened the blade.
- Print or save as PDF with all finding evidence expanded inline. Interactive controls and the blade
  are omitted from print.

The report requires no remote fonts, styles, scripts, images, or libraries. Without JavaScript, all
verdict, Path to Ready, rerun, finding, remediation, and evidence content remains visible and
readable.

## Output

Each run writes:

- `Agent365Preflight-<timestamp>.html`
- `Agent365Preflight-<timestamp>.json`
- Optional `Agent365Preflight-<timestamp>-sanitized.html`
- Optional `Agent365Preflight-<timestamp>-sanitized.json`

The JSON report follows `schema/agent365-preflight-report.schema.json`. Manual answers follow
`schema/agent365-preflight-answers.schema.json`.

## Sanitized support copies

Use `-IncludeSanitizedCopy` to create matching `-sanitized.html` and `-sanitized.json` files. These
copies remove the tenant display name, tenant ID, primary domain, signed-in account, attestation
owner and evidence references, site details, and result details marked sensitive.

Sanitization reduces exposure but does not approve a file for sharing. Review the copy before
providing it to Microsoft, a partner, or another team. Keep the full report under the same handling
rules as other tenant administration evidence.

## Baseline comparison

Pass a previous full JSON result with `-PreviousResultPath`. The report compares stable rule IDs and
shows:

- **Regressions:** the current status is more severe than the previous status.
- **Resolved blockers:** a previous blocker is no longer a blocker.
- **Resolved required actions:** a previous ActionRequired or ManualValidation gate is now passed,
  advisory, or explicitly permitted as not applicable.
- **Other changes:** the status changed without meeting either condition above.

The current report schema is `1.3`. Baseline comparison accepts report schema `1.0` through `1.3`
so earlier results can be carried forward. It detects status drift; it does not prove that
configuration changes caused the drift.

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| Windows says running scripts is disabled or the extracted script is blocked | Confirm the ZIP came from the canonical Microsoft FastTrack repository. From the extracted resource folder, use `Get-ChildItem -Recurse -File | Unblock-File` if your organization permits it. Do not lower the computer-wide execution policy. |
| Microsoft.Graph.Authentication is missing or too old | Install version 2.20.0 or later yourself, or explicitly use `-InstallDependencies`. The default run never installs it. |
| Sign-in succeeds but checks show `NotAuthorized` | Compare `RequestedScopes`, `GrantedScopes`, and `MissingScopes`. Confirm tenant consent and the signed-in user's required role separately. |
| A result remains `ActionRequired` after adding Yes evidence | Manual evidence cannot override automated evidence. Apply the documented tenant or access change, then rerun the collector. |
| A result remains `ManualValidation` | Confirm the ID is manually attestable and provide `Yes` with owner and evidence reference. Use the Answers Builder to validate and download the file. |
| An answers file is rejected | Check for unknown or duplicate IDs, automated-only rules, missing owner/reference for Yes, or missing justification for permitted NotApplicable evidence. |
| Device-code sign-in expires | Complete the code flow within the time shown by Microsoft.Graph.Authentication. Some versions show about 120 seconds. The guided launcher keeps running and offers **Try again now**. |
| Interactive sign-in reports a WAM or parent-window error | Open Windows Terminal or PowerShell directly and rerun the launcher, or choose device code. Embedded and background terminals cannot reliably host the WAM parent window. |
| I opened the sanitized report | Use it only as a sharing copy. Open the full local HTML generated beside it to complete remediation and build answers. |
| The resume helper cannot find answers | Download answers again from the same full report. The unique filename must match the report ID and can remain in Downloads or the output folder. |
| The script prompts even though Graph is connected | The existing context is reused only when it is delegated, has a tenant ID, matches an explicitly requested tenant GUID, and contains every requested scope. |
| Package catalog returns 403 | Confirm `CopilotPackages.Read.All` and an AI Administrator or Global Administrator role. AI Reader and Global Reader aren't sufficient for this API. |
| Agent Identity owners or sponsors return 403 | Owners use `AgentIdentityBlueprint.Read.All`; sponsors require `Application.Read.All`. Nonowners also need Agent ID Administrator. |
| The script stops with a tenant target mismatch | Confirm the `-TenantId` GUID or verified domain and the account selected during sign-in. No normal report is written after a mismatch. |
| The report shows the commercial availability gate | Agent 365 Commercial availability is not inferred for national clouds. Confirm current availability before proceeding; dependent checks are `NotApplicable`. |
| `AgentsInfo` or `BehaviorInfo` is empty | Empty evidence is not proof that Defender is disabled. Confirm Agent 365 licensing, Defender Security for AI setup, telemetry timing, and the selected audit window. |
| Purview audit returns zero records | Zero means no matching evidence in the window. Confirm the window, recent agent activity, permissions, and Purview Audit availability. |
| Purview audit remains `running` until timeout | The default deadline is 300 seconds. The result is `Error` and the verdict is `Incomplete`; the retained query job may continue server-side. Retry later or increase `-AuditQueryTimeoutSeconds` up to 900. |
| Purview policy metadata is manual | Install the supported first-party module and establish its read session before running. Policy counts still do not prove policy scope or enforcement. |
| SharePoint target checks are manual or unavailable | Select `SharePointAgents` and the `SharePoint` collector, supply intended site URLs, install the supported SharePoint Online module, and establish a read session first. |
| A collector reports 429, timeout, 404, or schema error | Review `CollectionIssues`, `Retry-After`, workload availability, cloud support, and the rule/API review date. Rerun after resolving the underlying issue. |

## Known limitations and privacy

- Microsoft Agent 365 is treated as generally available for the Commercial segment. Other clouds
  receive one availability gate instead of commercial capability assumptions.
- The package catalog is a package summary, not guaranteed complete agent inventory.
- Conditional Access policy presence does not prove coverage. Agent authentication flow, token
  audience, agent user accounts, and API-key access require manual review.
- Defender portal enablement, connectors, and real-time protection rules remain manual checks.
- Purview DLP, retention, and label counts are metadata only. Presence does not prove scope or
  enforcement.
- SharePoint evidence covers only supplied target sites and requires an existing supported module
  session.
- `-IncludeBeta` records explicit opt-in, but the current v1 rules use no beta API.
- Certificate app-only mode covers Microsoft Graph only. Optional Purview and SharePoint module
  collectors are skipped.
- The generated resume helper references the extracted resource location. If the resource folder is
  moved or deleted after a run, extract it again or start a new guided run.
- The Purview Audit Search API creates a query-job record that the service can retain. A query that
  times out locally can continue running server-side.
- The report can contain tenant identifiers, account information, site URLs, summarized policy
  metadata, target-assertion evidence, errors, and customer-entered attestation notes. Store it in
  an approved location.
- The sanitized copy is a reduced support artifact, not a guarantee that all information is
  non-sensitive.
- Local remediation checklist state is stored only as booleans in browser localStorage. Answers
  Builder text remains in memory unless the customer downloads the JSON file.

## Validation and safe testing

Fixture tests cover blocked, incomplete, and passing-after-remediation states without tenant access.
Commercial-tenant testing was also used to harden authentication, single-item role evidence, and
asynchronous Purview Audit Search behavior. No tenant names, tenant-specific counts, credentials, or
raw events are included in this resource.

Run the automated suite with Pester 5.7.1 or 6.1.0:

```powershell
Invoke-Pester .\tests
```

## Rule and API freshness

Rules, public documentation links, SKU IDs, and operation allowlists are reviewed independently of
the code. Each report records the rule-set version, review date, evidence time, and source URL.
Review `config/rules.v1.json`, `config/sku-catalog.v1.json`, and
`config/operation-allowlist.v1.json` before relying on the tool after material product or API
changes.

Review `config/guidance.v1.json` with the rule set because it controls the customer-facing answer
criteria, evidence checklists, verification steps, and public sources.

## Public sources

- [Microsoft Agent 365 overview](https://learn.microsoft.com/microsoft-agent-365/overview)
- [Microsoft Agent 365 service description](https://learn.microsoft.com/office365/servicedescriptions/microsoft-agent-365/microsoft-agent-365)
- [Agent management roles and permissions](https://learn.microsoft.com/microsoft-365/admin/manage/agent-roles-perms)
- [Agent 365 Package Management API](https://learn.microsoft.com/microsoft-365/copilot/extensibility/api/admin-settings/package/overview)
- [List Agent Identity Blueprint objects](https://learn.microsoft.com/graph/api/agentidentityblueprint-list?view=graph-rest-1.0)
- [Conditional Access for agents](https://learn.microsoft.com/entra/identity/conditional-access/agent-id)
- [Defender Security for AI](https://learn.microsoft.com/defender-xdr/security-for-ai/defender-security-for-ai)
- [Purview support for Agent 365](https://learn.microsoft.com/purview/ai-agent-365)
- [Agent 365 integration with SharePoint and OneDrive](https://learn.microsoft.com/microsoft-agent-365/admin/sharepoint-integration)
- [Microsoft Graph PowerShell authentication commands](https://learn.microsoft.com/powershell/microsoftgraph/authentication-commands)

## Applies To

- Microsoft Agent 365 Commercial
- Microsoft Entra ID
- Microsoft Defender XDR
- Microsoft Purview
- Microsoft 365 admin center
- SharePoint Online

## Author

| Author | Original Publish Date |
| --- | --- |
| Microsoft FastTrack | 2026-09-01 |

## Issues

Please report any issues you find to the [issues list](https://github.com/microsoft/FastTrack/issues).

<!-- DO NOT DELETE OR ALTER THE SECTIONS BELOW. -->

## Support Statement

The scripts, samples, and tools made available through the FastTrack Open Source initiative are provided as-is. These resources are developed in partnership with the community and do not represent official Microsoft software. As such, support is not available through premier or other official support channels. If you find an issue or have questions please reach out through the issues list and we'll do our best to assist, but there is no support SLA associated with these tools.

## Code of Conduct

This project has adopted the [Microsoft Open Source Code of Conduct](https://opensource.microsoft.com/codeofconduct/).
For more information see the [Code of Conduct FAQ](https://opensource.microsoft.com/codeofconduct/faq/) or
contact [opencode@microsoft.com](mailto:opencode@microsoft.com) with any additional questions or comments.

## Legal Notices

Microsoft and any contributors grant you a license to the Microsoft documentation and other content
in this repository under the [Creative Commons Attribution 4.0 International Public License](https://creativecommons.org/licenses/by/4.0/legalcode),
see the [LICENSE](https://github.com/Microsoft/FastTrack/blob/master/LICENSE) file, and grant you a license to any code in the repository under the [MIT License](https://opensource.org/licenses/MIT), see the
[LICENSE-CODE](https://github.com/Microsoft/FastTrack/blob/master/LICENSE-CODE) file.

Microsoft, Windows, Microsoft Azure and/or other Microsoft products and services referenced in the documentation
may be either trademarks or registered trademarks of Microsoft in the United States and/or other countries.
The licenses for this project do not grant you rights to use any Microsoft names, logos, or trademarks.
Microsoft's general trademark guidelines can be found at http://go.microsoft.com/fwlink/?LinkID=254653.

Privacy information can be found at https://privacy.microsoft.com/en-us/

Microsoft and any contributors reserve all others rights, whether under their respective copyrights, patents,
or trademarks, whether by implication, estoppel or otherwise.
