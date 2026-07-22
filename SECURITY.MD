# Security

Microsoft takes the security of our software products and services seriously, including source code repositories managed through our GitHub organizations.

## Reporting security issues

**Do not report security vulnerabilities through public GitHub issues.**

Report potential vulnerabilities to the Microsoft Security Response Center (MSRC) using the [secure reporting portal](https://msrc.microsoft.com/create-report). If you cannot use the portal, email [security@microsoft.com](mailto:security@microsoft.com). Encrypt sensitive email with the [MSRC PGP key](https://www.microsoft.com/msrc/pgp-key-msrc).

Include as much of the following information as possible:

- The issue type and potential impact.
- Full paths and the affected branch, tag, or commit.
- Required configuration and step-by-step reproduction instructions.
- Proof-of-concept or exploit code, when available.

MSRC will acknowledge and triage the report. Microsoft follows [Coordinated Vulnerability Disclosure](https://www.microsoft.com/msrc/cvd).

## Preferred language

Security reports are preferred in English.

## Workflow credentials

Repository automation should prefer a GitHub App installation token or a fine-grained personal access token over a classic, long-lived PAT. The traffic collection workflow needs only repository traffic read access plus contents and pull-request write access. Scope the credential to this repository, store it as an Actions secret, rotate it regularly and immediately after suspected exposure, and document an owner and expiry date outside the repository.
