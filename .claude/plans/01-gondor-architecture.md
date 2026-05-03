# 01 · gondor · Architecture

**Status:** stub
**Date:** 2026-05-03

## Purpose

`gondor` is a host-ops application composed from
[`assay-hostops`](https://github.com/developerinlondon/assay-hostops) with
application-specific branding, services, and pages. It is one of two known consumer
applications of `assay-hostops` at this stage; `knowhere` is the other. They share no
code at the application level — the shared layer is upstream — and are maintained
under separate ownership.

This stub fixes the architectural shape. A detailed v0.1 spec lands when implementation
starts.

## Architectural shape

Same as the consumer-app pattern locked in
[`assay-hostops`'s architecture plan](https://github.com/developerinlondon/assay-hostops/blob/main/.claude/plans/01-assay-hostops-architecture.md):

- Repo holds application-specific pieces only: `brand/`, `services/`, `pages/`,
  `templates/`, `static/`, `scripts/main.lua`, `deploy/<app>.service.example`.
- The shared host-ops surface (containers, services, logs, tunnels, audit, metrics,
  read-only backups) lives upstream in `assay-hostops`.
- Runs as a systemd unit on a managed host alongside an `assay-engine` sidecar.
- Mutations dispatch through `assay-engine` workflows scheduling `assay-ops.converge`
  activities (see
  [`assay-infra`'s ops-layer plan](https://github.com/developerinlondon/assay-infra/blob/main/.claude/plans/01-ops-layer-evaluation.md)).
- Application pages beyond host-ops are this repo's domain; concrete page surface
  defined in v0.1 spec.

## v0.1 spec — to be written

When implementation starts, a v0.1 spec covers:

- `pages/` — application-specific page surface and HTMX fragments.
- `services/state.lua`, `audit.lua`, `jobs.lua`, `secret_store.lua` — schemas + storage
  choices.
- `services/engine_client.lua` — HTTP wrapper to the engine sidecar.
- `services/brand.lua` — brand pack reader.
- `brand/` — brand metadata + CSS overrides + favicon.
- `scripts/main.lua` — composition entry point.
- `deploy/<app>.service.example` — systemd unit template.
- Authentication / authorization model.
- Secrets storage choice (engine vault, file, both).
- Audit retention policy.
