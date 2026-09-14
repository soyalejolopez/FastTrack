# Agent 365 pre-flight: permissions and consent

**Yes, the complete permission set is broad. Your identity and security teams should formally review it before a live run.** Read access to directory, policy, application and security data is still sensitive access. Do not approve it merely because the checker is described as read-only.

This guide covers the customer-run checker in the Commercial cloud. It is community/as-is software, not a certification. Tool-specific statements describe the shipped source and package; Microsoft identity and API statements link to public Microsoft Learn documentation. **Public sources reviewed: 2026-09-14.**

## What "read-only" means here

The checker performs **no tenant configuration remediation**: it does not assign licenses, change policies or deploy agents. It makes allowlisted Microsoft Graph reads and these two disclosed query operations:

| Operation | What the checker does | What to consider |
| --- | --- | --- |
| `POST /v1.0/security/runHuntingQuery` | Runs fixed aggregate queries against Defender `AgentsInfo` and `BehaviorInfo`. | The permission can support other hunting queries and detailed results. The checker retains counts and timestamps, not raw hunting events. See [runHuntingQuery](https://learn.microsoft.com/graph/api/security-security-runhuntingquery?view=graph-rest-1.0). |
| `POST /v1.0/security/auditLog/queries` | Creates a Purview Audit Search job, waits for its status, and counts matching record IDs without saving the records. | This creates service-side state. A job can outlive the local wait, and query-job history may remain. The checker does not delete jobs. See [Create auditLogQuery](https://learn.microsoft.com/graph/api/security-auditcoreroot-post-auditlogqueries?view=graph-rest-1.0) and [Audit search jobs and history](https://learn.microsoft.com/purview/audit-new-search). |

Interactive consent can also create **persistent permission grants** in Microsoft Entra ID. Read-only does not mean "no side effects," "no access to sensitive data" or "all traces disappear when PowerShell closes."

The operation allowlist and data minimization limit what this version of the checker does and retains. They are **not a security sandbox** and do not reduce the token's granted capabilities. Other code using the authenticated context, a modified script, or a stolen usable token could attempt other operations allowed by the token and account. Review the source, workstation and account as well as the consent request.

## Which permissions are requested, and why?

A **scope** is a delegated permission that lets an application act on behalf of a signed-in user. Effective access depends on both the application's scopes and that user's permissions, including relevant directory and workload roles. Consent does not assign those roles. A role does not grant application consent. See [Graph permission types and effective access](https://learn.microsoft.com/graph/permissions-overview#permission-types).

The maximum boundaries below are broader than this checker's queries. They remain subject to the signed-in user's access and service authorization rules. These are not permissions limited to a pilot group, a few selected agents or aggregate output.

| Group and scope | Purpose in this checker | Maximum delegated permission boundary |
| --- | --- | --- |
| Users and organization: [`User.Read.All`](https://learn.microsoft.com/graph/permissions-reference#userreadall), [`Organization.Read.All`](https://learn.microsoft.com/graph/permissions-reference#organizationreadall) | Identify the tenant and subscriptions; count users with the qualifying service plan enabled. | Read users' full profiles, including reporting relationships, and organization-related resources such as subscribed SKUs and branding. Not limited to license counts. |
| Roles and PIM: [`RoleManagement.Read.Directory`](https://learn.microsoft.com/graph/permissions-reference#rolemanagementreaddirectory), [`RoleEligibilitySchedule.Read.Directory`](https://learn.microsoft.com/graph/permissions-reference#roleeligibilityschedulereaddirectory) | Summarize active management roles; read eligible roles only when `-RolePolicy PIM` is selected. PIM means Privileged Identity Management. | Read directory role-based access control settings, roles and memberships; the second scope reads eligible directory role assignments. Not limited to Agent 365 roles. |
| Applications and Agent ID: [`Application.Read.All`](https://learn.microsoft.com/graph/permissions-reference#applicationreadall), [`AgentIdentityBlueprint.Read.All`](https://learn.microsoft.com/graph/permissions-reference#agentidentityblueprintreadall) | Read blueprint sponsors; summarize blueprints, owners, credential-expiry metadata and requested permissions. | Read applications and service principals, and all agent identity blueprints. Not limited to the selected pilot agents or the summary fields. |
| Policy: [`Policy.Read.All`](https://learn.microsoft.com/graph/permissions-reference#policyreadall) | Read security defaults and Conditional Access policy inventory. | Read organization policies beyond these two checks. Policy presence is not proof that a control is enforced. |
| Package registry: [`CopilotPackages.Read.All`](https://learn.microsoft.com/graph/permissions-reference#copilotpackagesreadall) | Summarize the package catalog. | Read package information beyond the summary. The catalog is not a complete agent inventory. |
| Defender hunting: [`ThreatHunting.Read.All`](https://learn.microsoft.com/graph/permissions-reference#threathuntingreadall) | Run the aggregate hunting probes above. | Run hunting queries on behalf of the user. The scope is not restricted to those probes or aggregate results. |
| Purview Audit: [`AuditLogsQuery.Read.All`](https://learn.microsoft.com/graph/permissions-reference#auditlogsqueryreadall) | Create and read the audit query described above. | Read and query audit logs from all services within the user's authorized access. Not limited to the selected operations or time window. |
| Service health: [`ServiceHealth.Read.All`](https://learn.microsoft.com/graph/permissions-reference#servicehealthreadall) | Summarize service health. | Read tenant service-health information, including issues and overviews. |

The full set requires administrator involvement. The [permissions reference](https://learn.microsoft.com/graph/permissions-reference) identifies which scopes require admin consent; tenant consent policy can impose further restrictions. Do not assume every individual scope has the same consent requirement.

Optional SharePoint and Purview policy-metadata checks use separately authorized, preconnected workload module sessions. They are not covered solely by the Graph consent grant.

## Default application and repeat use

You do **not** need to create a new app registration for the default interactive delegated path. The Graph PowerShell authentication module uses the existing **Microsoft Graph PowerShell application/client**. Your organization still reviews its permissions and consent. That application identity is separate from the publisher or provenance of this community script package. See [Graph PowerShell authentication](https://learn.microsoft.com/powershell/microsoftgraph/authentication-commands).

Check the actual application name, client ID, account and tenant in the trust receipt, consent experience and full report. The checker can reuse a compatible process-scoped delegated context, including a preconnected custom client. It records the actual identity when available; the display name alone is not an identity check.

**This is reusable, not one-time access.** Each live run needs a valid authenticated context. A run in a new process, or after disconnecting, authenticates again. Repeated runs in the same process may reuse a compatible context. Existing consent and broker single sign-on can avoid a fresh consent or password prompt; no new prompt is not proof that access was removed. Permissions may remain consented until an authorized review/revocation. See [consent and existing grants](https://learn.microsoft.com/entra/identity-platform/permissions-consent-overview#consent).

## What persists?

| Item | What happens after the run |
| --- | --- |
| Graph token/session | The checker uses `Connect-MgGraph -ContextScope Process`, not the SDK's default cross-session `CurrentUser` context. `Disconnect-MgGraph` clears the cached token and ends the current context. Ending the process ends that local session. Neither action is tenant-wide consent revocation. |
| OAuth consent grant | The tenant's record allowing the client to request particular permissions can persist independently of a PowerShell process or access token. Administrators review it separately. |
| WAM/broker/browser sign-in state | Web Account Manager (WAM) is the Windows authentication broker. It and the browser can maintain sign-in state outside this PowerShell process. Disconnecting Graph is not a promise to sign out all Windows accounts or erase every broker/browser cache. |
| Reports, answers and browser preferences | Full HTML/JSON reports and exported answer/draft files remain until handled under your retention policy. Browser `localStorage` holds theme, task-checklist marks and the last gate ID, not automatically saved evidence text. |
| Audit query jobs | Purview can retain service-side search-job history. Ending the checker does not delete the query job or the underlying audit logs. |

Sources: [process scope and Disconnect-MgGraph](https://learn.microsoft.com/powershell/microsoftgraph/authentication-commands#use-disconnect-mggraph), [permissions and consent](https://learn.microsoft.com/entra/identity-platform/permissions-consent-overview), [WAM token maintenance and system sign-in](https://learn.microsoft.com/entra/msal/dotnet/acquiring-tokens/desktop-mobile/wam), [Audit search history](https://learn.microsoft.com/purview/audit-new-search).

## Recommended controls before consenting

1. Try **Sample** mode first. It uses synthetic data without Graph sign-in or tenant requests.
2. Obtain the package from an approved source. Compare its ZIP SHA256 with an independently published approved checksum, then run `Test-Agent365Package.ps1` to verify the manifest. The package is unsigned; a matching hash alone does not authenticate the publisher. Follow signing and execution policy, without a blanket bypass.
3. Have identity, security and workload owners approve the selected collectors, maximum scope boundaries, roles and local evidence handling. Use a dedicated assessment account with the least directory/workload roles needed. Avoid routine Global Administrator use.
4. Use a trusted workstation and the checker's process-scoped authentication. Inspect any existing context rather than assuming a smaller request removes previously granted scopes. Restrict who can read full reports, answers and Downloads duplicates.
5. Keep multifactor authentication (MFA) and Conditional Access requirements in place. WAM and device code are sign-in methods, **not bypasses**. Policies can require further authentication or block a flow. Microsoft recommends allowing device code only where necessary; do not relax policy just to run the checker. See [Conditional Access authentication flows](https://learn.microsoft.com/entra/identity/conditional-access/concept-authentication-flows) and [WAM](https://learn.microsoft.com/entra/msal/dotnet/acquiring-tokens/desktop-mobile/wam).
6. Never share a password, access token, device code, private key or certificate credential. Do not put credentials in answers or evidence references.

## Isolate consent with your own delegated client

A dedicated client is preferable when your organization wants separate permissions, approved users and cleanup for assessments instead of sharing the Graph PowerShell client's grants with other administration workflows. It improves separation; it does not make a broad scope narrow or turn the script into a sandbox.

Follow Microsoft's [custom delegated application instructions](https://learn.microsoft.com/powershell/microsoftgraph/authentication-commands#use-delegated-access-with-a-custom-application-for-microsoft-graph-powershell). An authorized administrator should create a **single-tenant** application, configure the documented public-client/desktop redirect URIs (including the WAM redirect where used), set **Assignment required? = Yes** on its enterprise application, and assign approved users or groups. Review and grant only the needed delegated permissions. The checker does not create the application, assign users or change consent policy for you.

In this checker's launcher or advanced entry point, specify **`-DelegatedClientId`** together with **`-TenantId`**. No client secret or certificate is required for this delegated path. Microsoft Learn's direct `Connect-MgGraph -ClientId` example maps to the checker's **`-DelegatedClientId`**, not its `-ClientId`.

**Certificate app-only is separate.** In this checker, `-ClientId` selects app-only mode and requires `-TenantId` and `-CertificateThumbprint`. It acts as the application without a signed-in user, uses separately approved application permissions, and does not inherit the delegated user's role boundary. Do not use app-only to avoid reviewing delegated consent or user sign-in policy. See [delegated versus application permissions](https://learn.microsoft.com/graph/permissions-overview#permission-types).

## Remove access and clean up deliberately

Run `Disconnect-MgGraph` or end the process. Securely retain or delete full reports, answers, downloaded duplicates and printed copies under your policy. Clear the report's browser site/file storage for local checklist/navigation preferences. Remove optional module dependencies only if other approved workflows do not need them.

For persistent grants, an authorized administrator should identify the **actual client ID**, then review **Entra ID > Enterprise apps > All applications > the application > Permissions**. Review both **Admin consent** and **User consent**. The portal supports revoking admin-consented permissions; user-consented grants require the documented Graph/PowerShell method. Use the current [enterprise application permission review/revocation instructions](https://learn.microsoft.com/entra/identity/enterprise-apps/manage-application-permissions).

**Do not blindly revoke the shared Microsoft Graph PowerShell application's grants.** Other administration workflows may depend on them. A dedicated assessment client's grants are easier to isolate and revoke after checking its other uses. The checker never performs revocation automatically.

[Deleting a delegated grant does not invalidate existing access tokens before their lifetime ends](https://learn.microsoft.com/graph/api/oauth2permissiongrant-delete?view=graph-rest-1.0). Follow your organization's session-revocation procedures too. If future use must be prevented, review user assignment and consent policy as well, because permissions can be consented to again.

For local cleanup and dependency details, see the shipped `OFFBOARDING.md`. Purview query-job history is separate from Graph session cleanup and local report deletion.

## FAQ

### Is this too much permission?

It may be more than your organization will approve for an assessment. The complete set spans several sensitive services. Review the maximum boundaries and decline or narrow collection if they do not fit your policy. The tool does not decide acceptable risk for you.

### Why no app registration?

The default delegated path uses the existing Microsoft Graph PowerShell client, so you do not create another registration. Application consent, user permissions and package trust still require review. A customer-owned client is an optional isolation choice, not the default.

### Does it work only once?

No. It supports repeated assessments. Every live run needs authentication, with compatible same-process context reuse where available. Consent can remain for later runs; consent and a sign-in prompt are not the same thing.

### What persists after closing PowerShell?

Tenant consent, broker/browser sign-in state, local reports and exports, browser preferences, and service-side audit search history can remain. Closing PowerShell ends the local process context, not all of those items.

### Can we reduce the scopes?

Yes, by selecting fewer collectors in Advanced mode; `TenantFoundation` still requires `Organization.Read.All`. PIM's additional scope is requested only when PIM policy is selected. This reduces what the tool requests, **not existing tenant grants or the capabilities of a reused token**. Applicable omitted requirements remain `NotAssessed` and prevent passing. Omitting collection does not remove a requirement from the assessment.

### Can we use our own app registration?

Yes. Use a reviewed, single-tenant delegated application with assignment required and approved users, then pass `-DelegatedClientId` and `-TenantId`. Keep this distinct from certificate app-only parameters.

### How do we remove access afterward?

Disconnect the local context, handle local evidence and preferences, and have an administrator separately review/revoke the correct client's consent. Check dependencies before touching shared-client grants. Use the official revocation guidance above, not an indiscriminate delete-all command.

### Does the tool store tokens or raw tenant content?

The checker does not write access/refresh tokens, private keys or certificate material into its reports, answers or resume helpers. The Graph authentication library and WAM/broker manage authentication state; process scope is not a claim that the operating system has no cached credentials.

The checker processes API responses to retain aggregates and selected metadata, not raw prompts, messages, files, audit records or hunting events. Full reports still contain tenant/account identifiers, target URLs, configuration summaries, diagnostic text and customer-entered evidence. Keep them protected and review even a sanitized copy before sharing.

## Suggested SME response

```text
Yes, the complete permission set is broad and should go through your security and identity review. The default path uses the existing Microsoft Graph PowerShell client with delegated access, constrained by both its scopes and the signed-in user's permissions. No new app registration is required, but consent can persist for later runs.

The checker performs no tenant configuration remediation. It uses Graph reads plus disclosed Defender hunting and Purview Audit query-job POSTs, and retains aggregate evidence rather than raw tenant content. Its allowlist is not a sandbox or a limit on the token's capabilities. We recommend sample mode first, an approved account and package, and a dedicated delegated client if you want separate consent and cleanup. Disconnecting PowerShell is not consent revocation.

Public guidance: https://learn.microsoft.com/graph/permissions-overview
Authentication and custom clients: https://learn.microsoft.com/powershell/microsoftgraph/authentication-commands
Review/revoke consent: https://learn.microsoft.com/entra/identity/enterprise-apps/manage-application-permissions
```
