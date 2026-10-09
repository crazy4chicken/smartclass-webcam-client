# AGENTS.md

Kiosk-style cross-platform webcam edge client (Flutter, 5 platforms) for the
`smartclass-webcam-server` device protocol. The device is subordinate: it pushes
nothing until the server commands it. Authoritative docs: `README.md`,
`docs/implementation-status.md`, and the server repo's `docs/protocol/`.
Project prose is mostly Chinese; code comments are English.

Verification constraints: `dart run tool/verify_pure.dart` is the runnable
gate in an agent shell; `flutter test` needs the user's own terminal.
Keep `lib/src/backend`, `lib/src/capture` (non-plugin), `lib/src/config`, and
`lib/src/app/capability_bootstrap.dart` free of `package:flutter` imports.

## Agent skills

### Issue tracker

Issues live in GitHub Issues (`crazy4chicken/smartclass-webcam-client`), managed with the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

The five canonical triage roles, label string equal to role name. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `GLOSSARY.md` at the repo root plus `docs/adr/`. See `docs/agents/domain.md`.
