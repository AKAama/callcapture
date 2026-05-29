# Security Policy

## Reporting a vulnerability

Please **do not** open a public issue for security vulnerabilities.

Instead, report privately via GitHub's [private vulnerability reporting](https://github.com/bodharma/callcapture/security/advisories/new)
("Report a vulnerability" under the repository's **Security** tab). This opens a
private channel between you and the maintainers.

When reporting, include:

- A description of the vulnerability and its impact
- Steps to reproduce (proof-of-concept if possible)
- Affected version / commit
- Any suggested remediation

You can expect an initial acknowledgement within a few days. Please allow
reasonable time for a fix before any public disclosure.

## Scope & data handling

CallCapture is local-first: recordings, transcripts, notes, and the session
database stay on the user's machine. API keys are stored in the macOS Keychain
and are never written to the repository or logs. Audio/transcript data leaves
the machine only when a user explicitly selects a cloud transcription engine
(AssemblyAI / Deepgram) or a cloud LLM provider (OpenRouter).

Reports about accidental secret exposure, audio/transcript leakage, or
insecure handling of credentials are especially appreciated.
