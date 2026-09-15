# Changelog

All notable changes to the M365 Copilot Agents Cost Calculator are documented here.
This project follows [Semantic Versioning](https://semver.org/).

## [1.7.0] - 2026-09-15

### Changed

- Reasoning is now modeled as a per-conversation **Text and generative AI tools
  (premium)** meter — **10 Copilot Credits per 1,000 reasoning tokens** — instead
  of a fixed +10 credit per-response surcharge. Enable "Uses reasoning model" and
  enter the average reasoning tokens per conversation (default 1000). The premium
  meter is estimated once per conversation as `tokens / 1000 * 10`, on top of the
  normal feature rates. Templates, reset, config, example trace, results table,
  CSV export, tooltips, labels, and docs were updated for consistency, and the
  language clarifies that reasoning-token counts are planning estimates.
- Enterprise connectors cost label now follows the tenant graph grounding toggle
  (12 cr/query with graph, 2 cr/query without), matching the computed rate.
- M365 Copilot licensed-user language now describes **no charge for the eligible
  modeled features in employee-facing authenticated scenarios, subject to fair
  use**, rather than a blanket "zero credits for all features." Agent-flow
  inclusion is scoped to runs triggered by "When an agent calls the flow," and
  Computer-Using Agents are noted as excluded and not modeled.
- Refreshed the footer verification date to September 2026 and the source
  verification notes to reflect Microsoft Learn as of 2026-09-15.

Source: [Reasoning model billing rates](https://learn.microsoft.com/en-us/microsoft-copilot-studio/requirements-messages-management#reasoning-model-billing-rates)
· [Tenant graph grounding](https://learn.microsoft.com/en-us/microsoft-copilot-studio/knowledge-copilot-studio#tenant-graph-grounding-with-semantic-search)
· [Copilot Credits billing rates](https://learn.microsoft.com/en-us/microsoft-copilot-studio/requirements-messages-management#copilot-credits-billing-rates)
