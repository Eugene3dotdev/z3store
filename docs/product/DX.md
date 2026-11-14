# DX — Developer experience (z3store / `zt`)

| Field | Value |
|-------|--------|
| **Status** | **DRAFT for PR** to `Eugene3dotdev/z3store` `dev` |
| **SoT** | Part 2 design memo (owner-confirmed) · **TEO-983** / **TEO-775** for Drive/sync safety |
| **Ticket** | TEO-914 |
| **Fence** | personal estate only — CK/Modicum FENCED · Phase B OFF |
| **Audience** | Developers of / on the personal `zt` estate · Evgenii · CoS |
| **Author** | Research (Eu3dotdev staff) |
| **Date** | 2026-09-21 Europe/Vienna |

---

## Purpose

Give developers a lean mental model and daily loop for personal `zt`: **two roots**, adopt/detach, verify-as-health-gate, known gaps, and release/trunk notes.

This document aligns to the Part 2 owner-confirmed design narrative. It does **not** re-litigate Drive/sync safety — cite **TEO-983** / **TEO-775**. In-repo scaffold `README.md` / `doc/ARCHITECTURE.md` still describe the zig-qm-toolkit scaffold era; **docs ≠ product SoT**. Prefer this DX (plus Part 2 + Linear) for product intent.

---

## Mental model

### Workspace control plane (absorb ghq + detach VCS)

**z3store** (`zt`) is the personal **workspace control plane** for Evgenii’s developer estate.

It exists because working trees and VCS databases want different homes:

- Trees may sit on large/local NVMe (and, later, cloud-visible document surfaces for *selected* replicas).
- Git and JJ databases must stay on reliable local storage — **never** as equal peers inside Google Drive File Provider.

In one sentence: **absorb ghq** (one CLI for get / list / root / rm / create, plus adopt, detach, verify, status, sync, filter, hook, lore) and **detach VCS** from the tree so the tree can move or sync without dragging `.git` / `.jj` onto Drive.

### Two roots and config/env precedence

| Root | Typical live path | Role |
|------|-------------------|------|
| Working-tree root | `~/ghq` → `/Volumes/Crucial/ghq` | Checkouts you edit |
| Backing-store root | `/Volumes/Crucial/gitstore` | Detached Git/JJ databases (adopted keys) |

Roots are **independently** configured. Changing the backing root does **not** rewrite existing absolute `.git` / `gitdir:` pointers. Legacy `gitstore.*` / `GITSTORE_*` remain readable (ADR 0005 Keep) until estate-wide pointer proof; prefer current z3store/`zt` config for new writes.

### Adopt / detach / verify as core verbs

- **Adopt** — absolute `gitdir:` pointer into the backing store + gitignored `.jj` symlink (TEO-16). Tree can relocate; VCS DB stays local.
- **Detach** — reverse / related semantics for leaving the adopted model cleanly (hazards around jjColocate noted on TEO-982/983).
- **Verify / status** — estate health. Backup and restore-point tooling depend on `zt verify` / `zt status` staying trustworthy.

Git and JJ may disagree after adopt; `.lore/` is immovable; never move DVC cache as part of adopt/detach.

---

## Daily developer loop

### `get` → edit → `status` / `verify`

Recommended loop:

1. `zt get <repo>` (use `--no-adopt` when adopt is unsafe or you only need a tree).
2. Work in the checkout under the working root on Crucial.
3. Before trusting the estate (or after structural changes): `zt status` then `zt verify`.
4. Shell `ghq` may forward to `zt`; prefer calling `zt` directly.

`zt create`, `rm`, `list`, `root`, `hook`, and `lore` (read) round out ghq-parity / estate tooling. Treat `zt init` as thin bootstrap.

### When **not** to sync (legacy path disabled)

**Do not** use legacy estate-wide `zt sync` / `rclone sync` as a daily developer habit. It is **unsafe** and must remain **disabled** for production Drive write (TEO-775). Estate-wide sync was never the intended end state.

Do not “put the repo in Drive.” Do not use Google Drive for desktop / File Provider as an active checkout root. Do not mirror the Drive corpus onto the internal system disk.

### Planned future: `sync plan` / `push` / authorized `mirror` (deferred)

When TEO-775 ships, the intended developer-facing sync UX is:

1. **plan** — explicit selection, manifest-aware
2. **non-destructive copy / push** — default path; no delete
3. **mirror** — separately named, reviewed, manifest-backed (not the default)

Until those verbs exist and are authorized, developers wait. Native Drive API (TEO-837) may later replace rclone **without** changing manifest/policy semantics — still not a DX “enable sync now” instruction.

---

## Migration from ghq

### Pointer to migration doc (historical)

See in-repo `docs/MIGRATION-ghq-to-gitstore.md` for historical migration steps and two-root layout notes. Useful as **history and how-we-got-here**, not as living product SoT.

### Docs ≠ SoT disclaimer

| Document class | Trust for product intent |
|----------------|---------------------------|
| Part 2 design memo (owner-confirmed) | **Product narrative SoT** |
| TEO-983 / TEO-775 | **Drive/sync safety SoT** |
| This DX / AX / UX draft set | Product experience narrative (confirm-in-PR) |
| `README.md`, `doc/ARCHITECTURE.md` | Scaffold / historical — **≠ product SoT** |
| ADR 0005 | Binding for rename residue / compat Keep vs Remove |

### Compat: `gitstore.*` / `GITSTORE_*` read until estate clear

Keep reading legacy keys for diagnosis. Do not teach new config as `gitstore.*`. Public identity `gitstore-cli` / EugOT product URLs are **retired** (PRs #24/#25/#47 + ADR 0005 Remove class). Trunk policy: FF `main` ← `dev` when TEO-978 lands (still backlog).

---

## Known gaps (honest table)

### Sync / filter / migrate unimplemented or replace-class

| Gap | Status | Owner lane |
|-----|--------|------------|
| Legacy estate-wide `zt sync` | **Replace-class** — unsafe; stay disabled | TEO-775 |
| `sync plan` / `push` / `mirror` | **Deferred** — not shipped | TEO-775 |
| Live `zt filter` (canonical names only) | **Incomplete** vs recovery-renamed DriveFS forms | TEO-787 |
| `zt filter explain` | **Deferred** | TEO-787 |
| `zt migrate` real-mode | **Deferred** — dry-run only; waits WAL/replay | TEO-20 / sync journal reuse |

Identity rename PRs (#24/#25/#47) did **not** fix Drive folder-rename / recovery-rename handling (Part 1b). Do not treat them as closing the sync/filter gap.

### On-disk residuals (Part 1 census, 2026-09-18)

| Kind | Example / note |
|------|----------------|
| Path-derived misfiled keys | `…/gitstore/Users/…`, `…/gitstore/Volumes/…` — prefer refuse/remap going forward |
| Checkout→key mismatch | `EugOT/z3store` checkout `.git` → `gitstore-cli` key |
| Backing strays | `cel1021-*`, oversized run/cache debris; `operations.log` under backing |
| Namespace lag | Many `EugOT/*` checkouts with `Eugene3dotdev/*` remotes; dual backing namespaces — TEO-905 lever incomplete on disk |

`zt status` green does **not** mean backing hygiene is clean. Re-probe before treating any residual row as current after cleanup tickets land.

### jjColocate / linked-worktree / version skew notes

- **jjColocate=false** honor on adopt is contractual **intent**; source fixed (TEO-982); Homebrew **0.3.1** may still skew — version convergence is a release gate.
- Linked-worktree / primary identity repair: TEO-981.
- PATH hygiene: TEO-980 class — Homebrew `zt` must win; no stale `~/.local/bin/zt`.

---

## Release and trunk

### `dev` as integration branch; TEO-978 FF backlog

Develop against **`dev`**. Fast-forward `main` ← `dev` remains TEO-978 backlog. Do not assume `main` is the daily integration tip.

### Homebrew `z3store` pin / PATH hygiene

Live baseline (Part 1): `z3store 0.3.1` via Homebrew; default-shell PATH green post-980. After local builds, confirm `which zt` before trusting verify/status output. Shadow binaries are a DX failure mode, not a store failure mode.

### What lands under 914 vs sibling lanes

| Lane | Developer expectation |
|------|------------------------|
| **TEO-914** | Design narrative + AX/DX/UX drafts (this pack) — **not** sync/filter code |
| **TEO-775 / 787** | Implement planned sync + filter v2 |
| **TEO-905 / 902** | Namespace / wiring cleanup (misfiles, pointer mismatch) |
| **TEO-18 → TEO-21** | Contract grill then Rust/vNext authority — **after** Part 3 confirm |

---

## Drive posture for developers

### Crucial = active work; Drive = selected replica surface

- **Always-attached Crucial NVMe:** active checkouts, z3store backing, build caches, bounded rclone cache.
- **Google Drive for desktop:** stream-only Finder/document surface for selected, filtered, versioned snapshots/documents — **not** an equal-authority working tree.

Git remotes remain authoritative for source; DVC/object storage for large scientific data.

### Never active repo root under File Provider

No active repository root inside File Provider or an rclone mount. No bisync. No estate-root unattended sync. Default sync non-destructive; mirror/delete only as separately named, reviewed, manifest-backed operations (when shipped).

### Cite TEO-983 / TEO-775; no parallel sync design

DX must not invent a second sync policy. If guidance conflicts with Linear TEO-983/775 bodies, **Linear wins**.

---

## Links and ownership

| Source | Role |
|--------|------|
| Part 2 §1, §3, §4, §6 | Product job, reality vs intent, truth table, DX bullets |
| Part 1 / 1b | Residuals + identity-vs-Drive-rename gap |
| TEO-983 / TEO-775 | Binding Drive/sync SoT |
| TEO-905, TEO-978, TEO-980, TEO-16, ADR 0005 | Namespace, trunk, PATH, adopt, compat |

**Exit:** Owner confirms in-repo AX/DX/UX on `dev` → unpark **TEO-18** using Part 2 §4 as starting preserved-surface table → TEO-21 after that. TEO-905 may consume wiring findings in parallel; it does not replace 914.

---

## What this draft does **not** authorize

- Presenting legacy `zt sync` as supported daily DX
- Promising filter v2 / WAL migrate / plan-push as shipped
- Enabling Drive write or LaunchAgent
- Grilling TEO-18 or expanding TEO-11 in this PR
- Phase B / CK / Modicum product work

---

*DRAFT for PR · TEO-914 · personal estate · CK fenced · Phase B OFF*
