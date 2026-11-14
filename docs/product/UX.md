# UX — Operator / human experience (z3store / `zt`)

| Field | Value |
|-------|--------|
| **Status** | **DRAFT for PR** to `Eugene3dotdev/z3store` `dev` |
| **SoT** | Part 2 design memo (owner-confirmed) · **TEO-983** / **TEO-775** for Drive/sync safety |
| **Ticket** | TEO-914 |
| **Fence** | personal estate only — CK/Modicum FENCED · Phase B OFF |
| **Audience** | Evgenii as primary operator · CoS · any human running the personal estate |
| **Author** | Research (Eu3dotdev staff) |
| **Date** | 2026-09-21 Europe/Vienna |

---

## Purpose

Describe, in plain language, what a **healthy personal `zt` estate** looks like, how Drive vs Crucial should feel day-to-day, common failure modes, and **operator stop-rules**.

This UX narrative follows the Part 2 owner-confirmed design memo. Binding Drive/sync safety detail remains **TEO-983** / **TEO-775** — do not re-litigate them here. Scaffold README/ARCHITECTURE are **not** the operator’s source of truth for product intent.

---

## What “healthy” looks like

### Status green (roots, adopted counts)

A healthy *status-level* picture:

- `zt status` exits **0**
- Working root resolves (e.g. `~/ghq` → `/Volumes/Crucial/ghq`)
- Backing root resolves (e.g. `/Volumes/Crucial/gitstore`)
- Adopted/repo counts look sane for your estate (Part 1 example: 55 repos / 34 adopted — illustrative, not a fixed SLA)

Post-TEO-980: default-shell `zt` should be Homebrew `z3store` (e.g. 0.3.1), with **no** stale `~/.local/bin/zt` shadow.

### Verify green (and what one fail means under fence)

`zt verify` should report checkouts, keys, and pointers in agreement. Restore-point confidence depends on this.

If verify shows a failure on a **CK-adjacent** path (Part 1 example: empty `index.lock` under a fenced checkout): treat as **report-only**. Do not chase CK / Modicum / zeal as product work from this UX. Phase B OFF.

### Backing root hygiene (keys only + audit — no Users/Volumes/cel* strays)

Fully healthy backing root means:

- Adopted keys in canonical `host/owner/repo` shape
- Audit / operations trail only as intentional estate logging
- **No** path-derived `Users/…` or `Volumes/…` keys
- **No** run/cache debris (`cel1021-*` class strays)

**Important:** `status` green ≠ backing hygiene clean. Part 1 still documented misfiled keys, a `z3store`→`gitstore-cli` pointer mismatch, strays, and org-folder lag. Those are residual debt (TEO-902/905), not proof that “Drive sync works.”

---

## Where things live

### Crucial NVMe = active work + gitstore backing

Keep on the always-attached **Crucial NVMe**:

- Active checkouts (`…/ghq`)
- z3store backing (`…/gitstore`)
- Build caches
- Bounded rclone cache (when sync tooling is eventually authorized)

### Google Drive for desktop = stream-only documents / selected replicas

Drive is a **Finder stream-only** document surface and, when sync eventually ships, a **one-way replica** of *explicitly selected* repositories. It is not an equal-authority working tree.

### What never lives where

| Never | Why |
|-------|-----|
| Active repo root under Drive File Provider or rclone mount | VCS DBs and active trees must not peer with DriveFS |
| Full ~828 GB Drive corpus mirrored onto internal system disk | TEO-983: never mirror corpus to internal disk |
| `.git` / `.jj` databases as Drive sync payload | Git remotes / JJ servers own VCS; Drive gets filtered tree replicas only |
| DVC cache relocated by casual “cleanup” | TEO-16: never move DVC cache |
| `.lore/` moved for convenience | Immovable / read-only |

Plain rule: **never “put the repo in Drive.”** Work on Crucial; optionally publish selected filtered snapshots later via the planned sync path (not yet daily UX).

---

## Day-to-day operator loop

### Check health (`status` / `verify`)

1. Confirm PATH: `which zt` → Homebrew Cellar `z3store`.
2. `zt status` — roots and counts.
3. `zt verify` — pointer/key proof before backup, travel, or major cleanup.

If either is wrong, fix PATH or report wiring issues before changing sync or Drive settings.

### Add / adopt work carefully

- Prefer `zt get` into the working root on Crucial.
- Adopt only when you intend detached VCS; avoid adopt under known binary skew (jjColocate / 0.3.1 pin story — see DX).
- Do not adopt in ways that bake absolute filesystem paths into backing key names.

### Sync: wait for planned path — do not “just rclone”

Default sync remains **disabled / unsafe** until TEO-775’s planned path ships. Production Drive write is **not** part of TEO-775 acceptance. LaunchAgent (TEO-780) stays **disabled-by-default** until explicit rollout auth.

Operator habit: **do not** run estate-wide `rclone sync` or legacy `zt sync` “to see if Drive is fine.” That is how estates get hurt.

---

## Failure modes (plain language)

### PATH shadow — wrong `zt` binary

**Feels like:** status/verify disagree with what you expect, or two machines “see” different estates.  
**Usually is:** a stale `~/.local/bin/zt` (or other shadow) ahead of Homebrew.  
**Do:** restore Homebrew-first PATH (TEO-980 class). Do not rewrite backing keys to chase a shadow binary.

### Misfiled backing key (`Users/…`, `Volumes/…`)

**Feels like:** disk use under weird prefixes inside `gitstore`.  
**Usually is:** absolute-path adopt (historical) baked home or volume paths into key names.  
**Do:** report; schedule cleanup under TEO-902/905. Do not delete blindly.

### Pointer mismatch (checkout name ≠ backing key / gitstore-cli residue)

**Feels like:** you renamed the product to z3store but a checkout still points at `gitstore-cli`.  
**Usually is:** identity rename shipped; on-disk pointer not fully migrated.  
**Do:** report exact `gitdir:` target; do not equate this with a Drive folder-rename fix (Part 1b).

### DriveFS recovery-renamed cache shells ≠ zt sync job

**Feels like:** Finder/Drive shows oddly renamed `.zig-cache…` / `zig-out…` shells; sync “rename PRs” were supposed to help.  
**Usually is:** filter still matches **canonical** cache names only; recovery-renamed forms are an unbuilt TEO-787 gap. Historical Lost-and-Found shells are **not** the same as current `zt` transfers.  
**Do:** exact-identity reconcile only (TEO-731/732/727). No broad purge.

### Namespace lag (EugOT folders vs Eugene3dotdev remotes)

**Feels like:** folders say `EugOT`, remotes say `Eugene3dotdev`.  
**Usually is:** incomplete on-disk namespace migration (TEO-905 owns the lever).  
**Do:** do not mass-rename via Drive sync to “fix” GitHub org moves.

---

## Operator stop-rules

### From TEO-983 immediate safety (cite; do not rewrite policy)

1. **Never mirror** the large Drive corpus onto the internal system disk.
2. Active checkouts + z3store backing + build caches + bounded rclone cache stay on **Crucial NVMe**.
3. Google Drive for desktop / File Provider = **stream-only**; **no** active repository root there.
4. Git remotes authoritative for source; Drive receives only selected, filtered, versioned snapshots/documents.
5. **Default sync is non-destructive.** Mirror/delete is separately named, reviewed, manifest-backed — when it exists.
6. Filter must eventually exclude build/cache/VCS/secrets **and** DriveFS recovery-renamed forms; until then, do not rely on live filter as complete.
7. Lost-and-Found: **exact identity only** — no broad purge / `--delete-excluded`.
8. Protected layout: trees under Crucial `ghq`; backing under Crucial `gitstore`.

### From TEO-775

1. Drive is a **one-way replica** of explicitly selected repos — not equal authority.
2. **No bisync**, no DriveFS active root, **no estate-root unattended sync**, **no delete** in default/unattended path.
3. Estate-wide `rclone sync` is **unsafe and must remain disabled**.
4. Local events are hints; periodic full reconciliation is truth — when built.
5. Production Drive write and LaunchAgent enablement are **not** casual operator toggles.

### When to stop and escalate to CoS / Research / Engineering

Stop and call CoS (who routes Research / Eng) when:

- You feel tempted to re-enable estate-wide sync “just once.”
- Verify noise pulls you into CK/Modicum/zeal product debugging (fence).
- Cleanup wants wildcards on Lost-and-Found.
- Someone proposes treating scaffold ARCHITECTURE or identity-rename PRs as having fixed Drive.
- TEO-18 grilling or sync/filter implementation is proposed under the wrong ticket (914 is narrative; 775/787 own code).

---

## Confirm and next gates

### Part 2 as design SoT; these drafts as experience SoT candidates

Part 2 memo is the owner-confirmed **design** SoT for personal z3store product narrative. TEO-983/775 remain SoT for Drive/sync safety. This UX (with AX/DX) is the experience layer to land on `Eugene3dotdev/z3store` `dev` for confirm-in-PR.

### After UX+AX+DX confirm → TEO-18 grilling allowed

Once the three experience markdowns are merged/confirmed on `dev`, CoS may unpark **TEO-18** using Part 2 §4 truth table as the starting preserved-surface list. TEO-21 follows TEO-18. TEO-905 may clean wiring in parallel.

### What UX does **not** authorize

- Code PRs that enable sync, filter v2, WAL, daemon, or LaunchAgent
- Claiming “Drive sync works as intended” for daily use (contract written; runtime legacy must stay off)
- Equating identity rename PRs with Drive folder-rename fixes
- Phase B / CK / Modicum product expansion
- Messaging other agents from this document (CoS routes)

---

## Links and ownership

| Source | Role |
|--------|------|
| Part 2 §2, §3, §5–§8 | Locked contracts, reality vs intent, open questions history, UX bullets, what-not-to-do |
| Part 1 | Live residuals that define “not yet fully healthy” |
| Part 1b | Why “rename PRs” disappointment ≠ operator fix landed |
| **TEO-983** / **TEO-775** | Binding operator safety + sync rules |
| TEO-980, TEO-907, TEO-731/732/727, TEO-780 | PATH, orphan cleanup done, DriveFS exact identity, LaunchAgent default-off |

---

*DRAFT for PR · TEO-914 · personal estate · CK fenced · Phase B OFF*
