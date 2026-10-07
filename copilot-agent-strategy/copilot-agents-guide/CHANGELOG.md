# Changelog

All notable changes to the Copilot Agents Guide are documented here.

## 4.0.2 - 2026-10-06

- Fixed the Labs tab empty state so it recovers correctly: when the selected approach has no mapped labs (for example the Microsoft-built first-party approach), it now explains that and offers a "View Copilot Studio labs" action that switches to the custom-engine approach and resets lab filters; when an approach has labs but the current journey/difficulty filters exclude them, it offers a working "Clear lab filters" action. The previous single "Clear all filters" button was a no-op for the default approach.
- Clarified Cowork access control: access is granted through a spending policy that selects Cowork (a low credit limit still grants access), and the legacy Cowork entry under All agents no longer controls access. Added this as a Cowork limitation and a required deployment-checklist item.
- Updated the core guidance review date to October 6, 2026.

## 4.0.1 - 2026-09-09

- Added `interactiveKind: guide` catalog metadata so the catalog labels this resource an "Interactive guide". Guide content is unchanged.

Earlier version history is available in the repository Git log.
