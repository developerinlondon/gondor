# AGENTS.md

## App boundary

This repo is one consumer application of `assay-sysops`. It holds only
application-specific pieces — composition entry point, application pages, brand pack,
deploy unit. The shared host-ops dashboard surface lives upstream in `assay-sysops`;
do not duplicate it here.

When writing or modifying code, do not bake operator / customer / company names into
identifiers, comments, docs, or commit messages. Use generic terms (`the app`, `the
host`, `the operator`).

## Plan and spec writing

- Concise. No verbose framing.
- No human-time estimates. Quantify in concrete units (file count, LOC, MB).
- No "for our N hosts" reasoning. Architecture evaluates properties at production scale.

## Markdown formatting

`dprint fmt` is the formatter; config is `dprint.json` at repo root. Run after every
markdown write or edit.

## Failing tests: never silently rewrite

If a test is failing, fix the code under test, not the test. Modifying a failing test
requires explicit approval. Report the failure, propose a fix, wait for confirmation.
