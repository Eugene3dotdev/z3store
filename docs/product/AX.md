# AX — Agent / automation experience (z3store / `zt`)

| Field | Value |
|-------|--------|
| **Status** | **DRAFT for PR** to `Eugene3dotdev/z3store` `dev` |
| **SoT** | Part 2 design memo (owner-confirmed) · **TEO-983** / **TEO-775** for Drive/sync safety |
| **Ticket** | TEO-914 |
| **Fence** | personal estate only — CK/Modicum FENCED · Phase B OFF |
| **Audience** | Agent authors · Nu-first estate automation · CoS · Evgenii |
| **Author** | Research (Eu3dotdev staff) |
| **Date** | 2026-09-21 Europe/Vienna |

---

## Purpose

This document defines how agents and automation may safely **observe** and (rarely) **mutate** the personal `zt` estate: which verbs are safe, which are forbidden, and what citation/stamp expectations apply.

It implements the Part 2 intended design narrative for the agent surface. It does **not** replace **TEO-983** or **TEO-775** as the binding Drive/sync safety SoT. Sync `plan` / `push` / `mirror` and filter v2 remain deferred implementation work — do not invent them as shipped CLI.

---

## Goals and non-goals

### What AX covers

- Calling conventions for agents on the personal z3store estate (Nu-first, JSON/exit expectations, observation stamps).
- A **safe verb set** for read-heavy automation and carefully gated mutate paths.
- **Forbidden / stop-rules** that prevent estate damage (estate-wide sync, Drive purge, blind adopt, new `gitstore.*` writes).
- Compat guidance so agents do not resurrect retired public identity residue or ignore Homebrew/PATH hygiene.
- Failure classes and when to stop and escalate to CoS / human (not “fix by re-adopt”).

### What AX defers

| Lane | Owns (not this AX doc) |
|------|-------------------------|
| **TEO-775** | Intended `sync plan` / non-destructive `push` / authorized `mirror`; keep legacy estate-wide sync **disabled** |
| **TEO-787** | Filter v2 + recovery-rename corpus + `zt filter explain` |
| **TEO-983** | Binding External-NVMe + Drive storage/sync safety architecture |
| **TEO-18** | Contract grilling of preserved surfaces (parked until Parts 2–3 drafts owner-confirmed in-repo) |
| **TEO-905 / 902** | Namespace / wiring cleanup levers for misfiled keys and org-folder lag |

---

## Calling conventions

### Nu-first / no Bash in product lanes

Estate automation that calls `zt` must follow the **Nu-first** estate policy: product lanes use Nushell (or equivalent structured callers), **not** Bash scripts. Shell `ghq` remains a thin forwarder story to `zt`; agents should call `zt` directly rather than wrapping legacy `ghq` in Bash.

Do not introduce new Bash product-lane wrappers around `zt status`, `zt verify`, adopt, or sync-related commands.

### JSON paths and exit-code expectations

Prefer machine-readable observation:

- Use `zt list --json` (and other JSON flags where available) for estate inventory.
- Treat **stdout EPIPE = exit 0** as Policy A (TEO-4 / TEO-977): broken pipes on JSON/list paths must not be mis-reported as store failure.
- **JSON-path WriteFailed** must not be silently erased — surface write failures distinctly from EPIPE.

Agents parsing CLI output should prefer JSON over scraping human tables. Do not invent exit-code contracts beyond what TEO-4 / TEO-977 and live `zt` already fix; TEO-18 will grill preserved surfaces later.

### Observation stamps and Linear citation on mutate

Any agent action that **mutates** store state (adopt, detach, create, rm, init, filter writes, or any future sync write) must:

1. Leave an **observation stamp** (who/what/when, host, `zt` version) in the operating trail the estate already uses (operations log / Linear comment / session note — follow CoS routing).
2. **Cite a Linear ticket** for the mutate intent (e.g. TEO-914 wiring research, TEO-905 cleanup, TEO-775 sync work). Unticketed estate mutation is forbidden for agents.

Read-only verbs (`status`, `verify`, `list --json`, `root`, `lore` read path) do not require a mutate stamp, but probes that feed tickets should still cite TEO-914 (or the owning ticket) when filing findings.

---

## Safe verb set

### `status` / `verify` / `list --json`

These are the default agent toolkit:

| Verb | Role |
|------|------|
| `zt status` | Daily estate summary: working root, backing root, repo/adopted counts, rough size. Exit 0 with sane roots = baseline healthy *at status level*. |
| `zt verify` | Deeper checkout ↔ key ↔ pointer proof. Restore-point and backup tooling depend on this. Report failures; do not auto-repair. |
| `zt list --json` | Structured inventory for agents. Prefer over human `list` for automation. |

**Fence note:** A verify fail on a CK-adjacent checkout (e.g. empty `index.lock` under a fenced path) is **report-only**. Do not deepen CK / Modicum / zeal-as-product. Phase B OFF.

### `get --no-adopt` and when adopt is forbidden

- Prefer `zt get … --no-adopt` when the agent only needs a working tree and adopt is unsafe or version-skewed.
- **Do not adopt** under known **0.3.1 jjColocate skew** without an explicit pin / version that honors `jjColocate=false` (TEO-982 source-fixed; installed 0.3.1 may still skew — treat as release gate, not agent improvisation).
- Do not adopt in a way that creates **path-derived absolute keys** (`Users/…`, `Volumes/…`). Prefer refuse or remap; those shapes are Part 1 residuals from absolute-path adopt (PR #3 era), not intended key layout. Canonical keys are `host/owner/repo` under the backing root.
- Do not blindly re-adopt to “fix” pointer mismatch (e.g. `z3store` checkout → `gitstore-cli` key). Report; hand to human / TEO-905 lane.

### Read-only lore / root / hook forwarder notes

- `zt lore` — **read path** is contractual; `.lore/` is immovable / read-only (TEO-16). Agents must not move or rewrite lore as part of adopt/sync.
- `zt root` — observe configured roots; changing backing root must **not** be used by agents to rewrite existing absolute `.git` pointers.
- `zt hook` — shell/ghq forwarder compat. Agents should not depend on hook side effects as a mutate API.
- `zt init` — thin bootstrap; only with ticket + stamp if mutating config.

---

## Forbidden / stop-rules

### Estate-wide sync and unattended Drive write

**Forbidden for agents:**

- Estate-wide `zt sync` / `rclone sync` against Drive or any remote “to test” rename, filter, or Drive health.
- Unattended estate-root sync; bisync; treating DriveFS / File Provider paths as active repository roots.
- Enabling LaunchAgent (TEO-780) or production Drive write paths. Production Drive write is **not** part of TEO-775 acceptance; LaunchAgent stays disabled-by-default until explicit rollout auth.

Default sync posture: **plan → non-destructive copy → one-way check → completion marker** — but that CLI is **not shipped**. Until TEO-775 lands, agents treat sync as **disabled**. Do not document intended `plan` / `push` / `mirror` as callable today.

### Purge / delete-excluded / Lost-and-Found wildcards

**Forbidden:**

- Broad DriveFS Lost-and-Found cleanup (`purge`, `--delete-excluded`, wildcards).
- Reconciling historical DriveFS shells by anything other than **exact identity** (TEO-731 / 732 / 727).

DriveFS Lost-and-Found historical shells ≠ current z3store transfers.

### Adopt skew and misfiled-key creation

**Forbidden:**

- Adopt without version pin when jjColocate skew is known on the installed binary.
- Creating new path-derived keys under backing (`Users/`, `Volumes/`).
- Moving DVC cache or relocating `.lore/` as part of adopt/detach automation (TEO-16).

### Writing new `gitstore.*` config keys

Legacy `gitstore.*` / `GITSTORE_*` remain a **read** compat path (ADR 0005 Keep) until estate-wide pointer proof. Agents must **not** write new `gitstore.*` keys. Teach and emit only current `z3store` / `zt` config identity. Public `gitstore-cli` / EugOT URL residue is already retired — do not resurrect in help text, docs, or agent prompts.

---

## Compat for agents

### Legacy env read path (keep)

Agents may **read** legacy env/config for diagnosis (`GITSTORE_*`, `gitstore.*`) when explaining pointer or config drift. Do not treat legacy names as the preferred write path. Changing backing root in config does not rewrite existing absolute `gitdir:` pointers — agents must not assume it does.

### Public identity residue (already retired)

Do not teach agents to clone, advertise, or prefer `gitstore-cli` / old EugOT product URLs. Canonical product repo: `Eugene3dotdev/z3store`. Identity rename PRs (#24 / #25 / #47) fixed **product naming**, not Drive folder-rename — agents must not conflate the two (Part 1b).

### Version pin / Homebrew baseline awareness

Baseline post-TEO-980: default-shell `zt` from Homebrew `z3store/0.3.1`; stale `~/.local/bin/zt` should be **absent**. Agents that discover PATH shadow (wrong binary ahead of Homebrew) must **stop and report** (TEO-980 class) — do not silently prefer `~/.local/bin/zt`.

---

## Failure and escalation

### PATH shadow class (TEO-980 pattern)

Symptom: `which zt` is not Homebrew Cellar `z3store`, or a shadow binary disagrees with `brew` pin.  
Agent action: report host stamp (`which`, realpath, brew version); do not mutate store until PATH is clean.

### Pointer mismatch / misfiled key

Symptoms (Part 1 census patterns):

- Backing keys under `Users/…` or `Volumes/…`
- Checkout `.git` pointing at a retired key name (e.g. `gitstore-cli` while checkout is `z3store`)
- `cel1021-*` / run-cache debris under backing root
- Org-folder lag (`EugOT/*` checkouts vs `Eugene3dotdev/*` remotes)

Agent action: **report with paths and sizes**; do not “fix” by blind re-adopt, delete, or estate-wide sync. Wiring cleanup is TEO-902/905 (or a dedicated cleanup ticket) — not agent improvisation under AX.

### When to stop and hand to CoS / human

Stop and escalate when:

- Any Drive write or sync enablement is suggested by a task prompt without TEO-775 rollout auth.
- Verify failures invite CK/Modicum/zeal product work (fence).
- Mutate is requested without Linear citation.
- Proposed fix is purge / `--delete-excluded` / mirror Drive onto internal disk / place active repo under File Provider.
- TEO-18 grilling or TEO-11 vNext expansion is requested before in-repo AX/DX/UX confirm (CoS routes).

---

## Links and ownership

| Source | Role |
|--------|------|
| Part 2 design memo §1–2, §4, §6, §8 | Owner-confirmed product narrative; locked contracts; truth table; what-not-to-do |
| **TEO-983** | Binding Drive / NVMe / File Provider / filter safety SoT |
| **TEO-775** | SYNC parent: Drive = one-way selected replica; estate-wide sync disabled |
| **TEO-787** | Filter explain / recovery-rename (deferred) |
| TEO-16 | Adopt model: absolute `gitdir:` + gitignored `.jj` symlink; lore/DVC rules |
| TEO-4 / TEO-977 | EPIPE Policy A; JSON WriteFailed |
| ADR 0005 | Compat Keep vs identity Remove |
| TEO-18 | Parked until Part 3 drafts land and are confirmed in-repo |

**Exit path:** After AX/DX/UX drafts are PR’d and owner-confirmed on `dev`, CoS may unpark **TEO-18** grilling using Part 2 §4 as the starting preserved-surface table. This AX doc does not authorize that grilling by itself.

---

## What this draft does **not** authorize

- Enabling sync, LaunchAgent, or production Drive write
- Code changes, filter/sync implementation, or TEO-18 expansion
- Phase B / CK / Modicum product work
- Agents messaging other agents (CoS routes)

---

*DRAFT for PR · TEO-914 · personal estate · CK fenced · Phase B OFF*
