# AGENTS.md

Kiosk-style cross-platform webcam edge client (Flutter; the codebase targets
Windows / macOS / Linux / Android / iOS) for the `smartclass-webcam-server`
device protocol. The device is subordinate: it pushes nothing until the server
commands it. Authoritative docs: `README.md`,
`docs/implementation-status.md`, and the server repo's `docs/protocol/`.

**Starting work on this repo? Read `docs/agents/handover.md` first.** It lists
what is *not* done, which of those an agent can actually do versus which need the
user's own terminal or real hardware, the repo's current git/CI state, and the
traps that are expensive to rediscover. Current gate:
`dart run tool/verify_pure.dart` → `failed: 0` (assertion counts drift; read the
live output, never a number quoted in a doc).

Decision conflicts resolve to `docs/adr/` (start with
`0001-dual-mode-capture-decisions.md`); the older plans under
`docs/superpowers/plans/` are superseded where they disagree. There is **one
open decision** waiting on the user — peak vs plateau fps aggregation, ADR
§4.1.1. Do not settle it yourself.

Project prose is mostly Chinese; code comments are English.

## Verification constraints

- `dart run tool/verify_pure.dart` — the gate, runs in an agent shell. Focused
  suites live in their own files (`verify_annexb.dart`, `verify_encode_budget.dart`,
  `verify_default_mode.dart`, `verify_sustained_rate.dart`,
  `verify_diagnostics.dart`, `verify_rate_calibration.dart`) and **must be
  imported and called from the main entry**; a suite that is written but never
  called is a suite that rots. This has happened.
- `python tool/check_compile.py` — type-checks `lib/` plus every file under
  `test/` and `tool/` with the real Flutter frontend server (~5 min). It catches
  a broken `test/` file, which the gate cannot — but it **compiles, it does not
  run**, so passing it is not the same as passing tests. Run it whenever you
  change a public shape (interface, field, constructor parameter) in `lib/`.
- `flutter test` / `flutter build` / `flutter analyze` — **cannot run in an
  agent shell.** Write the `test/` cases and hand them to the user.
- Keep `lib/src/backend`, `lib/src/capture` (non-plugin), `lib/src/config`,
  `lib/src/agent`, and `lib/src/app/capability_bootstrap.dart` free of
  `package:flutter` imports, or the gate can no longer run at all.
- Expectations about a default or declared constant exist in **two** places —
  `tool/verify_pure.dart` and `test/` — and only the first runs here. Change one,
  sweep both. Assert against the named constant (`kFpsWithoutEvidence`), never a
  literal. This has bitten twice.

## Landing your work (read this before saying "done")

**An edit that is not committed does not exist as far as CI and the remote are
concerned.** This has already cost a wasted release: `release.yml` was edited to
drop the Linux job, the change stayed in the working tree, and the user pushed a
tag that ran the *old* workflow and failed again. So:

- After changing CI, config, or code, **say explicitly whether it is committed**.
  If it is only in the working tree, say so and say it needs committing.
- **Check the trigger.** `ci.yml` runs on branch pushes and PRs; `release.yml`
  runs on **tag pushes only** (`v*`) plus manual dispatch. "I pushed" does not
  mean the workflow you expected ran.
- **Re-pushing an unchanged tag triggers nothing** (git says
  "Everything up-to-date" and GitHub sees no ref event). Releasing again needs a
  **new** tag, or deleting the remote tag first.
- **Verify, don't assume.** `git status`, `git log --oneline origin/<branch>..HEAD`,
  and `git show <commit>:<file>` answer "did my change actually get there" in one
  command. Do this before reporting a state change as complete.
- Memory/notes under `.workbuddy-ai/` are gitignored — they are not part of
  "the change is committed".

## Release matrix

Three platforms: **Windows, macOS, Android.** `iOS` is not built (needs an Apple
Developer certificate and provisioning profile) and **Linux was removed from the
release pipeline on 2026-10-10** — its native capture path is paused and has
never been compiled, so shipping a bundle would advertise a platform this
project does not claim to deliver. The `linux/` sources stay in the repo and
`flutter build linux` remains the local smoke test. Re-adding it takes a matrix
entry **plus** the two Linux-only steps and the asset assertion — see
`docs/release.md` ("为什么没有 Linux").

## Agent skills

### Issue tracker

Issues live in GitHub Issues (`crazy4chicken/smartclass-webcam-client`), managed with the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

The five canonical triage roles, label string equal to role name. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `docs/adr/` holds the decisions. A root `GLOSSARY.md` is created
lazily by the domain-modeling skill and **does not exist yet** — don't go looking
for it. See `docs/agents/domain.md`.
