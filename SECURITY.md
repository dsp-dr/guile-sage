# Security Policy

guile-sage takes security seriously. This document describes how to report
vulnerabilities, which versions receive fixes, and the threat model we
consider in scope.

## Supported Versions

guile-sage is pre-1.0 software. Security fixes land on the current minor
release line. Older minors receive fixes only at maintainer discretion.

| Version | Supported        |
| ------- | ---------------- |
| 0.7.x   | Yes (current)    |
| 0.6.x   | Best-effort      |
| < 0.6   | No               |

Once 1.0 ships, this table will shift to "current major + previous minor."

## Reporting a Vulnerability

**Please do NOT file public GitHub issues for security vulnerabilities.**
Public issues tip off attackers before a fix is available.

Email reports to: **security@defrecord.com**

Include, if possible:

- A description of the issue and its impact
- Steps to reproduce (a minimal repro case is ideal)
- Affected version(s) and configuration (provider, YOLO mode, MCP servers in use)
- Any suggested mitigations or patches
- Whether you plan to request a CVE

PGP / age keys are optional. If you want encrypted communication, request a
key in your first message and we will reply out of band.

## Response SLA

| Stage              | Target                                     |
| ------------------ | ------------------------------------------ |
| Acknowledgement    | Within **72 hours** of report              |
| Initial triage     | Within **7 days** (severity + reproducibility) |
| Remediation target | Based on severity (see below)              |

Severity targets (from initial triage, not from report):

- **Critical** (RCE, sandbox escape, credential exfiltration): patch within 14 days
- **High** (privilege escalation, unintended tool execution): patch within 30 days
- **Medium** (info disclosure, DoS): patch within 60 days
- **Low** (hardening, defense-in-depth): next release

## Disclosure Timeline

We follow coordinated disclosure. Default timeline:

- **Day 0**: Report received, acknowledged within 72 hours
- **Day 7**: Triage complete, severity assigned, fix plan shared with reporter
- **Day ≤ 90**: Fix released; reporter credited (unless anonymity requested)
- **Day 90+**: Public disclosure and CVE (if applicable) after fix ships

If the issue is being actively exploited, we may disclose and patch sooner.
Extensions past 90 days require reporter agreement.

## Scope

### In scope

- Code in this repository (`src/sage/**`, tests, scripts, Makefile)
- The tool sandbox and safe/unsafe permission model (`src/sage/tools.scm`)
- The YOLO-mode threat model: what happens when unsafe tools run with user consent
- Session, config, and credential handling (`.env` loading, XDG paths)
- MCP client behavior (`src/sage/mcp.scm`) — SSE/JSON-RPC parsing and tool dispatch
- Provider clients (`ollama.scm`, `openai.scm`, `gemini.scm`) — request construction, auth header handling
- Telemetry emission (no secrets in OTLP payloads)

### Out of scope — report upstream

- **Ollama**, **LiteLLM**, **vLLM**, or any external LLM runtime — report to that project
- **Google Gemini API**, **OpenAI API**, or other hosted provider issues — report to the provider
- **GNU Guile** itself, **curl**, or OS-level libraries — report upstream
- **skills-hub** or other external MCP servers — report to that server's maintainer

### Not considered vulnerabilities

- User misconfiguration (e.g., pointing sage at an untrusted Ollama host, committing `.env` with secrets)
- Running sage in YOLO mode on untrusted input — YOLO is documented as opt-in and unrestricted by design
- Prompt injection via model output when the user has explicitly granted tool access (mitigation is the safe/unsafe split, not content filtering)
- Rate limits or cost overruns from LLM providers

## Credit

Reporters who follow this policy are credited in the release notes and
(optionally) in a `SECURITY-ACKNOWLEDGEMENTS` section of future releases.
Let us know how you want to be credited.

## Questions

For non-security questions, use the normal GitHub issue tracker or see
[CONTRIBUTING.org](CONTRIBUTING.org).
