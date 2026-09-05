# Offboarding and local data

The checker has no telemetry, hosted storage or automatic remediation. It does not revoke access or remove dependencies for you.

## End the session

Run `Disconnect-MgGraph` or end the PowerShell process. This ends the SDK connection. It does **not** revoke tenant consent or guarantee removal of Windows Authentication Manager (WAM), broker, browser or operating-system sign-in state. Follow organizational identity-session policy for those systems.

## Handle local artifacts

Full HTML/JSON reports and answer/draft bundles contain customer evidence. Retain or delete them, their Downloads duplicates, extracted packages and printed copies under your organization policy. A sanitized report reduces detail but still describes your posture; review it before sharing.

Evidence text is held in browser memory until an explicit export. Browser storage contains theme preference, local task check marks and the last gate ID only. Clear site/file storage using browser settings to remove those preferences. Closing a tab discards unexported evidence; heed the unsaved-work warning.

## Review grants separately

Interactive consent may establish persistent delegated grants. App-only permissions and certificates are managed separately on the customer application. An authorized administrator should review the client identity recorded in the full report and the organization's approved permissions.

Never automatically revoke grants for the shared Microsoft Graph PowerShell client. Other workflows may use them. A customer-owned delegated client (`-DelegatedClientId`) provides a separate consent boundary when configured using [Microsoft's custom application guidance](https://learn.microsoft.com/powershell/microsoftgraph/authentication-commands#use-delegated-access-with-a-custom-application-for-microsoft-graph-powershell). `-ClientId` remains certificate app-only and must not be substituted for `-DelegatedClientId`.

Defender hunting executes queries; Purview Audit Search creates server-side query jobs. A timed-out job may continue. The checker neither deletes those jobs nor changes service retention.

## Optional dependency removal

Only remove CurrentUser modules if no other scripts need them. Inspect installed versions with `Get-InstalledModule Microsoft.Graph.Authentication -AllVersions`, then use your approved module-management process. Do not delete module folders shared with other users or automation.

**Sourcing: public Microsoft Learn.** [Authentication commands](https://learn.microsoft.com/powershell/microsoftgraph/authentication-commands), [permissions and consent](https://learn.microsoft.com/entra/identity-platform/permissions-consent-overview), [Audit Search API](https://learn.microsoft.com/graph/api/security-auditcoreroot-post-auditlogqueries).
