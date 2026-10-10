# AGENTS.md

Kiosk-style cross-platform webcam edge client (Flutter, 5 platforms) for the
`smartclass-webcam-server` device protocol. The device is subordinate: it pushes
nothing until the server commands it. Authoritative docs: `README.md`,
`docs/implementation-status.md`, and the server repo's `docs/protocol/`.

**Starting work on this repo? Read `docs/agents/handover.md` first.** It lists
what is *not* done, which of those an agent can actually do versus which need the
user's own terminal or real hardware, and the traps that are expensive to
rediscover. Current gate: `dart run tool/verify_pure.dart`, `failed: 0`.

Decision conflicts resolve to `docs/adr/` (start with
`0001-dual-mode-capture-decisions.md`); the older plans under
`docs/superpowers/plans/` are superseded where they disagree.

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
