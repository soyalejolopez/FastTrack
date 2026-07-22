# Catalog build

This package generates the static FastTrack catalog from YAML front matter in resource Markdown files.

## Commands

From this directory:

```powershell
npm ci
npm run check
npm run build
```

- `npm run check` scans and validates metadata without writing files. It exits non-zero and lists every file and invalid field when validation fails.
- `npm run build` validates, then writes `catalog.json` at the repository root and mirrors the same file to `design-concepts/catalog.json`. The mirror lets the catalog page fetch `catalog.json` when `design-concepts` is served as the web root.

The scanner covers `scripts`, the supported Copilot agent roots, `copilot-agent-strategy`, `copilot-analytics-samples`, and top-level prompt Markdown files. It excludes `archive`, `_SAMPLE_Templates`, and `samples` paths. Known metadata-less resources are explicitly listed in `legacy-exclusions.json`; any new eligible resource without front matter fails validation.

Front matter is validated against `resource.schema.json` and additional cross-field rules. Validation rejects unknown fields, duplicate normalized slugs, duplicate or non-lowercase tags, invalid destinations, future dates, and an `updated` date earlier than `published`.

See [`docs/CATALOG-METADATA.md`](../../docs/CATALOG-METADATA.md) for the schema and contribution guidance.
