# Custom MCP Server Builder

> Build governed, scenario-specific MCP servers for PowerClaw by using the Microsoft MCP Management Server.

## At a Glance

| | |
|---|---|
| **Best for** | Platform admins, Copilot Studio makers, solution architects, AI Center of Excellence teams |
| **Complexity** | Hard |
| **Status** | Preview |
| **Activation** | MCP Management Server + tenant-specific MCP server |
| **Requires** | Agent 365 / Copilot Studio access, Power Platform environment ID, tenant admin publishing rights, connector/API permissions |
| **Outputs** | A governed custom MCP server with focused tools that PowerClaw can use interactively or on heartbeat |
| **Works in** | Both |
| **Owner** | Tenant platform admin or business system owner |

## What This Skill Does

Custom MCP Server Builder gives PowerClaw a safe extension path for line-of-business workflows that are not covered by the built-in Work IQ MCP catalog. Instead of adding broad connectors directly to the core agent, admins can create a focused MCP server for one scenario, publish only the tools PowerClaw needs, and govern those tools through Agent 365 controls.

Use this for specialized systems such as CRM, ITSM, finance, HR operations, project portfolio tools, internal REST APIs, or Dataverse custom APIs. Do not use it to duplicate the baseline Work IQ Mail, Calendar, Teams, User, Word, Copilot, or SharePoint tools that PowerClaw already ships with.

## When to Use It

- Build a customer-specific tool pack for a CRM pulse, renewal risk review, or account brief
- Wrap a ServiceNow, Jira, Azure DevOps, SAP, Dynamics, or internal API workflow as a focused MCP server
- Expose a Dataverse custom API to PowerClaw with clearer tool names and least-privilege operations
- Create an admin-governed MCP server for a repeatable business process before adding it as a PowerClaw skill
- Prototype a scenario in the demo environment, then document it as optional customer setup guidance

## Trigger Phrases

- "Create a custom MCP server for PowerClaw."
- "Add our CRM renewal workflow as a PowerClaw tool."
- "Build a scenario MCP server for this connector."
- "Package these Dataverse actions as an MCP server."
- "What custom MCP tools should PowerClaw expose for this process?"

## Prerequisites

- Microsoft MCP Management Server preview is available in your tenant and region
- Tenant admin rights to publish custom MCP servers
- Power Platform environment ID for the target environment
- Admin-approved connector, Graph API, Dataverse custom API, or REST endpoint
- Clear business owner for the server and each tool
- A demo environment for validation before any customer-facing template update
- Microsoft 365 Copilot / Work IQ licensing where the scenario depends on Work IQ MCP tools

## Governance

| Area | Requirement |
|---|---|
| **Permissions** | Use the narrowest connector, Graph, Dataverse, or REST permissions possible. Avoid broad write tools unless there is an explicit approval path. |
| **Admin controls** | Confirm the server is allowed in Microsoft 365 admin center under **Agents and Tools**. Admin allow/block policy wins over Copilot Studio configuration. |
| **Observability** | Use PowerClaw_Memory_Log for app-level actions and Microsoft Defender / source-system logs for tenant-level tool call auditing where available. |
| **Rollback** | Disable the tool in Copilot Studio first, then unpublish or delete the custom MCP server through MCP Management Server if it is no longer needed. |
| **Template portability** | Treat custom MCP servers as tenant-specific unless they are certified, published, and realistically importable by customers. Do not bake demo-only custom MCP servers into `PowerClaw_Solution.zip`. |

## Setup

### Step 1 - Define the scenario boundary

Create one server per job-to-be-done, not one server per entire business system.

Good examples:

- `PowerClaw-CrmPulse`
- `PowerClaw-ServiceDeskTriage`
- `PowerClaw-RenewalRisk`
- `PowerClaw-ProjectPortfolio`

For each proposed tool, define:

| Field | Guidance |
|---|---|
| **Tool name** | Verb-first and specific, such as `GetRenewalRisks` or `CreateServiceDeskDraft` |
| **Data touched** | Records, fields, files, or APIs the tool can read or write |
| **Operation type** | Read, draft, create, update, delete, approve, notify |
| **Approval rule** | Whether PowerClaw can execute directly or must move the item to Human Review |
| **Audit path** | PowerClaw_Memory_Log plus source-system or Defender trace location |

### Step 2 - Connect to the MCP Management Server

In Visual Studio Code:

1. Open the command palette.
2. Select **MCP: Add Server**.
3. Choose **http**.
4. Enter the server URL, replacing `{environment ID}` with your Power Platform environment ID:

```text
https://agent365.svc.cloud.microsoft/mcp/environments/{environment ID}/servers/MCPManagement
```

5. Name the server `MCPManagement`.
6. Choose **Global** or the current workspace, based on your admin policy.
7. Sign in with the tenant admin account that can publish custom MCP servers.

### Step 3 - Create and publish the scenario MCP server

Use the MCP Management Server tools:

| Tool | Use it for |
|---|---|
| `CreateMCPServer` | Create the scenario server shell |
| `CreateToolWithConnector` | Add connector, Graph API, Dataverse custom API, or REST-backed tools |
| `UpdateTool` | Refine names, descriptions, parameters, or behavior |
| `PublishMCPServer` | Publish the server so agents can use it |
| `DeleteMCPServer` | Remove a server that should no longer be available |

Keep descriptions explicit. PowerClaw's orchestration depends on tool names and descriptions to decide when a tool is safe and relevant.

### Step 4 - Add the server to PowerClaw

1. Open the PowerClaw agent in Copilot Studio.
2. Go to **Tools** -> **Add a tool** -> **Model Context Protocol**.
3. Select the custom server.
4. Create or select the connection.
5. Toggle on only the tools PowerClaw should use.
6. Publish the agent.

### Step 5 - Update `tools.md`

In the PowerClaw SharePoint workspace, update `tools.md` with a short, factual catalog entry:

```markdown
### CRM Pulse MCP
- Server: PowerClaw-CrmPulse
- Tools enabled: GetAccountSummary, GetRenewalRisks, DraftCustomerFollowUp
- Allowed operations: Read account/renewal data; draft follow-up emails; no direct contract changes
- Human review required for: external emails, discount recommendations, renewal status changes
- Audit path: PowerClaw_Memory_Log + CRM activity log + Defender tool trace where available
```

Do not list tools that are not enabled. Stale or aspirational tool catalogs make the agent attempt actions it cannot perform.

### Step 6 - Validate in the demo environment

Test in the real channel, not only the Copilot Studio test pane:

1. Ask PowerClaw to use the new capability interactively in Teams or Microsoft 365 Copilot.
2. Trigger a heartbeat routine if the skill is expected to run autonomously.
3. Confirm tool calls show up in the expected audit path.
4. Confirm the agent logs meaningful outcomes to PowerClaw_Memory_Log.
5. Confirm risky write operations route to Human Review unless explicitly approved.

## Maintainer Workflow for Template Publishing

PowerClaw's development flow uses a demo environment for validation and publishes a tenant-neutral sample solution for customers to import.

1. Build and validate custom MCP scenarios in the demo environment first.
2. Keep tenant-specific MCP servers, environment IDs, URLs, connection references, and secrets out of the generic repo artifacts.
3. If the custom MCP server is not customer-importable, ship it as a skill guide only.
4. If the custom MCP server is intended to ship broadly, validate it in a clean environment before adding it to `PowerClaw_Solution.zip`.
5. After any cloud pull, revert environment-specific workflow and settings files before reviewing diffs or committing.
6. Export, scrub, repack, and test-import the solution before publishing a new template zip.

## Example Interaction

> **You:** Build a custom MCP server plan for our renewal risk process.
>
> **PowerClaw:** I would create `PowerClaw-RenewalRisk` with three tools: `GetRenewalRiskSummary`, `ListAccountsRenewingSoon`, and `DraftRenewalFollowUp`. I would keep it read + draft only at first, require Human Review for external emails or opportunity updates, and log outcomes to PowerClaw_Memory_Log plus the CRM activity log.

## Tips

- Start read-only. Add write tools only after the scenario proves value.
- Prefer one focused MCP server per scenario over one broad server with dozens of tools.
- Use business-language tool names so PowerClaw can choose tools correctly.
- Document every enabled tool in `tools.md` after publishing.
- Test both interactive and heartbeat behavior if the skill can run autonomously.

## Limitations

- Microsoft MCP Management Server is a preview capability.
- Custom MCP server publishing currently requires tenant admin privileges.
- Tenant, region, licensing, and admin policy availability can vary.
- Custom MCP servers are usually not portable across customer environments without additional setup.
- PowerClaw should not use custom MCP tools for destructive or high-impact changes unless there is an explicit approval path.

## Extension Ideas

- CRM pulse skill for account briefs and renewal risk
- Service desk triage skill for ticket summarization and draft responses
- Customer success health monitor using Dataverse or REST APIs
- Project portfolio risk monitor from Planner, Azure DevOps, or internal systems
- Finance approval prep skill that drafts recommendations but leaves approvals to humans

## Related Skills

- [Agent Fleet Governor](agent-fleet-governor.md)
- [Workplace Intelligence Monitor](workplace-intelligence-monitor.md)
