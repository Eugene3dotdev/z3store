#!/usr/bin/env nu
# readiness.nu — canonical validator for the readiness/v1 change-control contract.
#
# Canonical source: Eugene3dotdev/dotfiles, readiness/readiness.nu. Every other
# repository carries a byte-identical vendored copy under .readiness/ plus a
# lock.yaml that pins this file's sha256; `readiness.nu audit` (run from
# dotfiles) reports any copy that drifts from the canonical file.
#
# The contract this file implements is described for humans in
# readiness/contract/readiness-contract.v1.yaml. The machine-readable parts
# (states, blast-radius classes, evidence kinds, staleness limits, execution
# path patterns) are the constants below; readiness/tests asserts that the two
# agree, so a contract change is one commit touching both.
#
# Untrusted-data boundary: Linear issue descriptions and comments are external
# text. This validator reads exactly one fenced ```readiness block and the
# fenced ```readiness-evidence blocks, parses them as YAML with a closed key
# set, and never interprets any other text. Nothing in an issue can change what
# this validator does; it can only make the verdict "not ready".

const SELF = (path self)
const CONTRACT = "readiness/v1"
const SUPPORTED_RECORD_CONTRACTS = ["readiness/v1"]
const ADAPTER_SCHEMA = "readiness-adapter/v1"
const LOCK_SCHEMA = "readiness-lock/v1"
const REGISTRY_SCHEMA = "readiness-registry/v1"
const LINEAR_URL = "https://api.linear.app/graphql"
const GITHUB_API = "https://api.github.com"
# The broker in the canonical repository is the enforcement point for every
# other repository: it evaluates open pull requests against Linear and posts
# this status context, which branch protection requires. Consuming
# repositories therefore hold no Linear credential at all.
const BROKER_KIND = "broker-status"
const BROKER_CONTEXT = "Readiness Gate"
const BROKER_WORKFLOW = "readiness-broker.yml"
const BROKER_MAX_AGE_MINUTES = 60
const MAX_VALIDITY_DAYS = 30
const DEFAULT_VALIDITY_DAYS = 14
const DEFAULT_ISSUE_PREFIX = "TEO"

const STATES = ["draft" "ready" "blocked" "done" "superseded"]

# Blast-radius classes, ordered. A record's declared class must rank at or
# above the class the changed paths require. Evidence kinds are what a change
# of that class must record back to its Linear issue before it is applied.
const CLASSES = [
  [name rank evidence];
  ["local" 1 ["source-validation"]]
  ["workstation" 2 ["source-validation" "dry-run-apply"]]
  ["release" 3 ["source-validation" "release-verification"]]
  ["service" 4 ["source-validation" "dry-run-apply" "rollback-plan"]]
  ["edge" 5 ["source-validation" "dry-run-apply" "signed-receipt" "backup-verified" "restore-drill" "rollback-plan"]]
  ["cluster" 6 ["source-validation" "rendered-manifests" "reconcile-dry-run" "live-cluster-validation" "secret-handling" "rollback-plan" "reapply-idempotency"]]
]

const EVIDENCE_KINDS = [
  "source-validation" "dry-run-apply" "release-verification" "rollback-plan"
  "signed-receipt" "backup-verified" "restore-drill" "rendered-manifests"
  "reconcile-dry-run" "live-cluster-validation" "secret-handling"
  "reapply-idempotency" "live-git-probe"
]
const EVIDENCE_STATUSES = ["pass" "fail" "degraded"]

const RECORD_KEYS = ["contract" "issue" "state" "blast_radius" "repos" "scope_digest" "approved_by" "approved_at" "expires_at" "exceptions" "notes"]
const RECORD_REQUIRED = ["contract" "issue" "state" "blast_radius" "repos"]
const READY_REQUIRED = ["scope_digest" "approved_by" "approved_at" "expires_at"]
const EXCEPTION_KEYS = ["id" "waives" "owner" "expires_at" "approval" "follow_up" "reason"]
const EXCEPTION_REQUIRED = ["id" "waives" "owner" "expires_at" "approval" "follow_up"]
const EVIDENCE_KEYS = ["contract" "repo" "kind" "status" "ref" "control_point" "run" "recorded_at" "fingerprint" "note"]
const EVIDENCE_REQUIRED = ["contract" "repo" "kind" "status" "ref" "control_point" "recorded_at" "fingerprint"]

# Execution paths a repository can have. Discovery lists every tracked file
# matching one of these and compares it with the adapter's control points; a
# match the adapter neither registers nor ignores is an enforcement gap.
const EXECUTION_PATHS = [
  [kind glob];
  ["github-workflow" ".github/workflows/*.yml"]
  ["github-workflow" ".github/workflows/*.yaml"]
  ["forgejo-workflow" ".forgejo/workflows/*.yml"]
  ["forgejo-workflow" ".forgejo/workflows/*.yaml"]
  ["gitea-workflow" ".gitea/workflows/*.yml"]
  ["gitea-workflow" ".gitea/workflows/*.yaml"]
  ["gitlab-ci" ".gitlab-ci.yml"]
  ["pre-commit" ".pre-commit-config.yaml"]
  ["agent-hooks" ".claude/settings.json"]
  ["agent-hook" ".claude/hooks/*"]
  ["agent-release-skill" ".claude/skills/release/SKILL.md"]
  ["verify-script" "scripts/verify-*"]
  ["release-script" "scripts/release*"]
  ["deploy-script" "**/deploy*.sh"]
  ["deploy-script" "**/deploy*.nu"]
  ["reconciler" "apply/Cargo.toml"]
  ["reconciler" "edge/*/reconcile.nu"]
  ["gitops-app" "**/argocd/applications.yaml"]
  ["homebrew-formula" "Formula/*.rb"]
  ["task-runner" "Makefile"]
  ["task-runner" "justfile"]
  ["task-runner" "Taskfile.yml"]
  ["build-script" "**/build.sh"]
]

# ---------------------------------------------------------------------------
# small helpers
# ---------------------------------------------------------------------------

def now-utc [] { date now | date to-timezone UTC }

def fmt-ts [d] { $d | date to-timezone UTC | format date "%Y-%m-%dT%H:%M:%SZ" }

def parse-ts [s] {
  if (($s | describe) != "string") { return null }
  if not ($s =~ '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$') { return null }
  try { $s | into datetime | date to-timezone UTC } catch { null }
}

def is-string [v] { ($v | describe) == "string" }
def is-list [v] { let d = ($v | describe); ($d starts-with "list") or ($d starts-with "table") }
def is-record [v] { ($v | describe) starts-with "record" }

def short-hash [s: string] { $s | hash sha256 | str substring 0..<16 }

def class-row [name] { $CLASSES | where name == $name | get -o 0 }
def class-rank [name] { let r = (class-row $name); if ($r == null) { 0 } else { $r.rank } }
def class-names [] { $CLASSES | get name }
def max-class [names: list<string>] {
  $names | reduce -f "local" {|it, acc| if (class-rank $it) > (class-rank $acc) { $it } else { $acc } }
}

# glob → anchored regex. `**` spans directories, `*` a single segment, `?` one char.
def glob-regex [g: string] {
  let escaped = ($g
    | str replace --all -r '([.+^$(){}|\[\]\\])' '\$1'
    | str replace --all '**/' "\u{1}"
    | str replace --all '**' "\u{2}"
    | str replace --all '*' '[^/]*'
    | str replace --all '?' '[^/]'
    | str replace --all "\u{1}" '(?:.*/)?'
    | str replace --all "\u{2}" '.*')
  $"^($escaped)$"
}
def glob-match [g: string, path: string] { $path =~ (glob-regex $g) }

def git-root [dir] {
  let r = (^git -C $dir rev-parse --show-toplevel | complete)
  if $r.exit_code != 0 { error make {msg: $"not a git repository: ($dir)"} }
  $r.stdout | str trim
}

def tracked-files [dir] {
  let r = (^git -C $dir ls-files | complete)
  if $r.exit_code != 0 { error make {msg: $"git ls-files failed in ($dir): ($r.stderr | str trim)"} }
  $r.stdout | lines | where {|l| ($l | str trim | is-not-empty) }
}

def changed-files [dir, base: string, head: string] {
  let r = (^git -C $dir diff --name-only $"($base)...($head)" | complete)
  if $r.exit_code != 0 {
    let r2 = (^git -C $dir diff --name-only $base $head | complete)
    if $r2.exit_code != 0 { error make {msg: $"git diff ($base)...($head) failed: ($r.stderr | str trim)"} }
    return ($r2.stdout | lines | where {|l| ($l | str trim | is-not-empty) })
  }
  $r.stdout | lines | where {|l| ($l | str trim | is-not-empty) }
}

def finding [code: string, message: string] { {code: $code, message: $message} }

# ---------------------------------------------------------------------------
# adapter / lock / registry
# ---------------------------------------------------------------------------

def adapter-path [root] {
  let candidates = [
    ([$root ".readiness" "adapter.yaml"] | path join)
    ([$root "readiness" "adapter.yaml"] | path join)
  ]
  let hit = ($candidates | where {|p| $p | path exists })
  if ($hit | is-empty) { null } else { $hit | first }
}

# Validate an adapter record. `src` only names the source in error messages,
# so the same rules apply to a file on disk and to a blob fetched from the
# GitHub API by the broker.
export def validate-adapter [a, src: string] {
  if (($a | get -o adapter) != $ADAPTER_SCHEMA) { error make {msg: $"($src): adapter schema must be ($ADAPTER_SCHEMA)"} }
  if (($a | get -o contract_version) not-in $SUPPORTED_RECORD_CONTRACTS) { error make {msg: $"($src): contract_version ($a | get -o contract_version) is not supported by this validator \(($CONTRACT)\)"} }
  for key in ["repo" "path_classes" "control_points"] {
    if (($a | get -o $key) == null) { error make {msg: $"($src): missing required key ($key)"} }
  }
  for pc in $a.path_classes {
    if (($pc | get -o glob) == null or ($pc | get -o class) == null) { error make {msg: $"($src): every path_classes entry needs glob and class"} }
    if ($pc.class not-in (class-names)) { error make {msg: $"($src): unknown class ($pc.class) in path_classes"} }
    for e in ($pc | get -o extra_evidence | default []) {
      if ($e not-in $EVIDENCE_KINDS) { error make {msg: $"($src): unknown extra_evidence kind ($e)"} }
    }
  }
  for cp in $a.control_points {
    for key in ["id" "kind" "enforces"] {
      if (($cp | get -o $key) == null) { error make {msg: $"($src): control point missing ($key)"} }
    }
    # A broker-status control point is enforced by the canonical repository's
    # broker, which posts a commit status; it owns no file in this repository,
    # so a path would be a lie the audit would then try to verify.
    if $cp.kind == $BROKER_KIND {
      if (($cp | get -o path) != null) { error make {msg: $"($src): control point ($cp.id) is a ($BROKER_KIND) and must not declare a path"} }
      if (($cp | get -o required_check) == null) { error make {msg: $"($src): control point ($cp.id) must declare the required_check the broker posts"} }
    } else if (($cp | get -o path) == null) {
      error make {msg: $"($src): control point ($cp.id) missing path"}
    }
    for e in ($cp | get -o evidence | default []) {
      if ($e not-in $EVIDENCE_KINDS) { error make {msg: $"($src): control point ($cp.id) names unknown evidence kind ($e)"} }
    }
  }
  $a
}

def load-adapter [root] {
  let p = (adapter-path $root)
  if ($p == null) {
    error make {msg: $"no readiness adapter in ($root): expected .readiness/adapter.yaml \(or readiness/adapter.yaml in the canonical repository\)"}
  }
  let a = (validate-adapter (open --raw $p | from yaml) $p)
  $a | insert _path $p | insert _dir ($p | path dirname)
}

def control-point-paths [adapter] {
  $adapter.control_points | each {|cp| $cp | get -o path } | compact
}

def lock-path [dir] { [$dir "lock.yaml"] | path join }

def validator-sha [file] { open --raw $file | hash sha256 }

# ---------------------------------------------------------------------------
# record extraction and validation
# ---------------------------------------------------------------------------

# Fenced blocks whose info string is exactly `lang`. Returns list of bodies.
def fenced-blocks [text: string, lang: string] {
  let ls = ($text | lines)
  let marks = ($ls | enumerate | where {|e| ($e.item | str trim) == $"```($lang)" } | get index)
  $marks | each {|start|
    let rest = ($ls | skip ($start + 1))
    let end = ($rest | enumerate | where {|e| ($e.item | str trim) starts-with "```" } | get -o 0.index)
    if ($end == null) { null } else { $rest | first $end | str join "\n" }
  } | compact
}

def strip-blocks [text: string, lang: string] {
  let ls = ($text | lines)
  # drop lines from each opening fence to its closing fence inclusive
  let out = ($ls | reduce -f {keep: [], inside: false} {|line, acc|
    let t = ($line | str trim)
    if $acc.inside {
      if ($t starts-with "```") { {keep: $acc.keep, inside: false} } else { $acc }
    } else if ($t == $"```($lang)") {
      {keep: $acc.keep, inside: true}
    } else {
      {keep: ($acc.keep | append $line), inside: false}
    }
  })
  $out.keep | str join "\n"
}

# Linear re-renders markdown on save (bullets become `*`), so list markers are
# canonicalized before hashing; otherwise a record stamped offline would read
# as stale once the description round-trips through Linear.
def normalize-text [text: string] {
  $text
    | lines
    | each {|l| $l | str trim --right }
    | each {|l| $l | str replace -r '^(\s*)[*+]\s+' '$1- ' }
    | str join "\n"
    | str replace --all -r '\n{3,}' "\n\n"
    | str trim
}

# The scope section is the `## Scope` heading (any case) up to the next `## `
# heading. Without one, the whole description minus the readiness block.
def scope-text [description: string] {
  let body = (strip-blocks $description "readiness")
  let ls = ($body | lines)
  let start = ($ls | enumerate | where {|e| ($e.item | str trim) =~ '(?i)^##\s+scope\s*$' } | get -o 0.index)
  if ($start == null) { return (normalize-text $body) }
  let rest = ($ls | skip ($start + 1))
  let end = ($rest | enumerate | where {|e| ($e.item | str trim) =~ '^##\s+' } | get -o 0.index)
  let section = if ($end == null) { $rest } else { $rest | first $end }
  normalize-text ($section | str join "\n")
}

export def scope-digest [description: string] { short-hash (scope-text $description) }

def parse-yaml-block [body: string] {
  let parsed = (try { $body | from yaml } catch { null })
  if not (is-record $parsed) { null } else { $parsed }
}

# Structural validation of a record. Returns list of findings (empty = valid).
def validate-record-shape [rec] {
  mut f = []
  let keys = ($rec | columns)
  for k in $keys { if ($k not-in $RECORD_KEYS) { $f = ($f | append (finding "invalid" $"unknown key `($k)` in readiness block")) } }
  for k in $RECORD_REQUIRED { if (($rec | get -o $k) == null) { $f = ($f | append (finding "invalid" $"missing required key `($k)`")) } }
  if ($f | is-not-empty) { return $f }
  if not (is-string $rec.contract) or ($rec.contract not-in $SUPPORTED_RECORD_CONTRACTS) {
    $f = ($f | append (finding "invalid" $"contract `($rec.contract)` is not supported by this validator \(supports ($SUPPORTED_RECORD_CONTRACTS | str join ', ')\)"))
  }
  if not (is-string $rec.issue) or not ($rec.issue =~ '^[A-Z][A-Z0-9]+-[0-9]+$') { $f = ($f | append (finding "invalid" "issue must be an identifier like TEO-1234")) }
  if not (is-string $rec.state) or ($rec.state not-in $STATES) { $f = ($f | append (finding "invalid" $"state must be one of ($STATES | str join ', ')")) }
  if not (is-string $rec.blast_radius) or ($rec.blast_radius not-in (class-names)) { $f = ($f | append (finding "invalid" $"blast_radius must be one of ((class-names) | str join ', ')")) }
  if not (is-list $rec.repos) or ($rec.repos | is-empty) or not ($rec.repos | all {|r| (is-string $r) and ($r =~ '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') }) {
    $f = ($f | append (finding "invalid" "repos must be a non-empty list of owner/name entries"))
  }
  if (($rec | get -o scope_digest) != null) and (not (is-string $rec.scope_digest) or not ($rec.scope_digest =~ '^[0-9a-f]{16}$')) {
    $f = ($f | append (finding "invalid" "scope_digest must be 16 lowercase hex characters"))
  }
  for k in ["approved_at" "expires_at"] {
    let v = ($rec | get -o $k)
    if ($v != null) and ((parse-ts $v) == null) { $f = ($f | append (finding "invalid" $"($k) must be an RFC 3339 timestamp")) }
  }
  if (($rec | get -o approved_by) != null) and (not (is-string $rec.approved_by) or ($rec.approved_by | str trim | is-empty)) {
    $f = ($f | append (finding "invalid" "approved_by must be a non-empty string"))
  }
  let exceptions = ($rec | get -o exceptions | default [])
  if not (is-list $exceptions) { $f = ($f | append (finding "invalid" "exceptions must be a list")) } else {
    for e in $exceptions {
      if not (is-record $e) { $f = ($f | append (finding "invalid" "each exception must be a mapping")); continue }
      for k in ($e | columns) { if ($k not-in $EXCEPTION_KEYS) { $f = ($f | append (finding "invalid" $"unknown exception key `($k)`")) } }
      for k in $EXCEPTION_REQUIRED { if (($e | get -o $k) == null) { $f = ($f | append (finding "invalid" $"exception missing `($k)`")) } }
      let w = ($e | get -o waives | default [])
      if not (is-list $w) or ($w | is-empty) or not ($w | all {|x| $x in $EVIDENCE_KINDS }) { $f = ($f | append (finding "invalid" "exception.waives must list known evidence kinds")) }
      if ((parse-ts ($e | get -o expires_at)) == null) { $f = ($f | append (finding "invalid" "exception.expires_at must be an RFC 3339 timestamp")) }
      let fu = ($e | get -o follow_up)
      if ($fu != null) and (not (is-string $fu) or not ($fu =~ '^[A-Z][A-Z0-9]+-[0-9]+$')) { $f = ($f | append (finding "invalid" "exception.follow_up must be a Linear issue identifier")) }
      let ap = ($e | get -o approval)
      if ($ap != null) and (not (is-string $ap) or ($ap | str trim | is-empty)) { $f = ($f | append (finding "invalid" "exception.approval must be a non-empty reference")) }
    }
  }
  $f
}

# Semantic validation against context. ctx: {now, description, repo, required_class, issue_state_type}
def validate-record-semantics [rec, ctx] {
  mut f = []
  let now = $ctx.now
  if $rec.state != "ready" {
    $f = ($f | append (finding "not-ready" $"record state is `($rec.state)`"))
  } else {
    for k in $READY_REQUIRED { if (($rec | get -o $k) == null) { $f = ($f | append (finding "invalid" $"state ready requires `($k)`")) } }
  }
  if ($f | where code == "invalid" | is-not-empty) { return $f }
  let ist = ($ctx | get -o issue_state_type)
  if ($ist != null) and ($ist in ["completed" "canceled" "cancelled"]) {
    $f = ($f | append (finding "not-ready" $"Linear issue state is ($ist)"))
  }
  if $rec.state == "ready" {
    let approved = (parse-ts $rec.approved_at)
    let expires = (parse-ts $rec.expires_at)
    if $expires <= $approved { $f = ($f | append (finding "invalid" "expires_at must be after approved_at")) }
    if ($expires - $approved) > ($MAX_VALIDITY_DAYS * 1day) { $f = ($f | append (finding "invalid" $"readiness may not be valid for more than ($MAX_VALIDITY_DAYS) days")) }
    if $approved > ($now + 5min) { $f = ($f | append (finding "invalid" "approved_at is in the future")) }
    if $expires <= $now { $f = ($f | append (finding "stale" $"readiness expired at ($rec.expires_at)")) }
    let digest = (scope-digest $ctx.description)
    if $digest != $rec.scope_digest {
      $f = ($f | append (finding "stale" $"scope changed since approval: record digest ($rec.scope_digest), current ($digest); re-run `readiness.nu stamp`"))
    }
  }
  let repo = ($ctx | get -o repo)
  if ($repo != null) and ($repo not-in $rec.repos) {
    $f = ($f | append (finding "out-of-scope" $"repository ($repo) is not listed in the record's repos"))
  }
  let required = ($ctx | get -o required_class)
  if ($required != null) and ((class-rank $rec.blast_radius) < (class-rank $required)) {
    $f = ($f | append (finding "insufficient" $"changed paths require blast_radius `($required)`; record declares `($rec.blast_radius)`"))
  }
  for e in ($rec | get -o exceptions | default []) {
    let ex = (parse-ts $e.expires_at)
    if $ex <= $now { $f = ($f | append (finding "invalid" $"exception ($e.id) expired at ($e.expires_at)")) }
    if (($ex - $now) > ($MAX_VALIDITY_DAYS * 1day)) { $f = ($f | append (finding "invalid" $"exception ($e.id) may not run more than ($MAX_VALIDITY_DAYS) days ahead")) }
  }
  $f
}

def active-waivers [rec, now] {
  $rec | get -o exceptions | default [] | where {|e| (parse-ts $e.expires_at) > $now } | get waives | flatten | uniq
}

# Evidence blocks from comments: list of {body, createdAt} → parsed evidence records.
def parse-evidence [comments] {
  $comments | each {|c|
    fenced-blocks ($c | get -o body | default "") "readiness-evidence" | each {|b|
      let r = (parse-yaml-block $b)
      if ($r == null) { null } else {
        let bad_keys = ($r | columns | where {|k| $k not-in $EVIDENCE_KEYS })
        let missing = ($EVIDENCE_REQUIRED | where {|k| ($r | get -o $k) == null })
        if ($bad_keys | is-not-empty) or ($missing | is-not-empty) { null } else { $r }
      }
    }
  } | flatten | compact
}

# The comment body an evidence record takes. Shared by `evidence` (a person or
# a repository's own workflow) and the broker, so both produce byte-comparable
# records with the same fingerprint.
def evidence-body [repo: string, kind: string, status: string, sha: string, control_point: string, run, note] {
  let fp = (evidence-fingerprint $repo $kind $sha $status)
  ([
    $"Readiness evidence for ($repo): **($kind)** = ($status) at `($sha)`."
    ""
    "```readiness-evidence"
    $"contract: ($CONTRACT)"
    $"repo: ($repo)"
    $"kind: ($kind)"
    $"status: ($status)"
    $"ref: ($sha)"
    $"control_point: ($control_point)"
    $"run: ($run | default '')"
    $"recorded_at: (fmt-ts (now-utc))"
    $"fingerprint: ($fp)"
  ] | append (if ($note == null) { [] } else { [$"note: ($note)"] }) | append ["```"] | str join "\n")
}

def load-registry [path: string] {
  let reg = (open --raw $path | from yaml)
  if (($reg | get -o registry) != $REGISTRY_SCHEMA) { error make {msg: $"($path): registry schema must be ($REGISTRY_SCHEMA)"} }
  if (($reg | get -o repositories) == null) { error make {msg: $"($path): registry has no repositories"} }
  $reg
}

def evidence-fingerprint [repo: string, kind: string, ref: string, status: string] {
  short-hash $"($repo)|($kind)|($ref)|($status)"
}

def check-evidence [evidence, repo: string, required: list<string>, ref, any_ref: bool] {
  $required | each {|kind|
    let hits = ($evidence | where {|e|
      let ident = (($e.repo == $repo) and ($e.kind == $kind) and ($e.status == "pass") and ($e.contract in $SUPPORTED_RECORD_CONTRACTS))
      let genuine = ($e.fingerprint == (evidence-fingerprint $e.repo $e.kind $e.ref $e.status))
      let ref_ok = ($any_ref or (($ref != null) and ($e.ref == $ref)))
      $ident and $genuine and $ref_ok
    })
    if ($hits | is-empty) {
      let scope = if $any_ref { "any ref" } else { $"ref ($ref | default 'unknown')" }
      finding "evidence-missing" $"no passing `($kind)` evidence recorded for ($repo) at ($scope)"
    } else { null }
  } | compact
}

# ---------------------------------------------------------------------------
# Linear
# ---------------------------------------------------------------------------

def linear-key [] {
  let k = ($env | get -o LINEAR_API_KEY | default "")
  if ($k | str trim | is-empty) {
    error make {msg: "LINEAR_API_KEY is not set; the readiness gate fails closed without Linear access (use --record <file> for an offline check)"}
  }
  $k
}

def linear-graphql [query: string, variables] {
  let resp = (http post --full --allow-errors --content-type application/json --headers ["Authorization" (linear-key)] $LINEAR_URL ({query: $query, variables: $variables} | to json))
  if $resp.status != 200 { error make {msg: $"Linear API returned HTTP ($resp.status): ($resp.body | to json --raw | str substring 0..<300)"} }
  let body = $resp.body
  let errs = ($body | get -o errors | default [])
  if ($errs | is-not-empty) { error make {msg: $"Linear API error: ($errs | get message | str join '; ')"} }
  $body.data
}

def linear-issue [identifier: string] {
  let q = "query($id: String!) { issue(id: $id) { id identifier title url description updatedAt state { name type } comments(first: 250) { nodes { id body createdAt } } } }"
  let d = (linear-graphql $q {id: $identifier})
  if (($d | get -o issue) == null) { error make {msg: $"Linear issue ($identifier) not found"} }
  $d.issue
}

def linear-comment-create [issue_id: string, body: string] {
  let m = "mutation($input: CommentCreateInput!) { commentCreate(input: $input) { success comment { id url } } }"
  linear-graphql $m {input: {issueId: $issue_id, body: $body}}
}

def linear-issue-update-description [issue_id: string, description: string] {
  let m = "mutation($id: String!, $input: IssueUpdateInput!) { issueUpdate(id: $id, input: $input) { success } }"
  linear-graphql $m {id: $issue_id, input: {description: $description}}
}

# ---------------------------------------------------------------------------
# issue reference resolution
# ---------------------------------------------------------------------------

def issue-ref-in [text, prefix: string] {
  if (not (is-string $text)) or ($text | is-empty) { return null }
  let re = ('\b(' + $prefix + '-[0-9]+)\b')
  let hits = ($text | parse -r $re | get -o capture0)
  if ($hits == null) or ($hits | is-empty) { null } else { $hits | first }
}

def github-event [] {
  let p = ($env | get -o GITHUB_EVENT_PATH | default "")
  if ($p | is-empty) or not ($p | path exists) { return null }
  try { open --raw $p | from json } catch { null }
}

# ---------------------------------------------------------------------------
# verdict rendering
# ---------------------------------------------------------------------------

def verdict-status [findings] {
  if ($findings | is-empty) { return "ready" }
  let order = ["unavailable" "not-onboarded" "missing" "invalid" "not-ready" "stale" "out-of-scope" "insufficient" "evidence-missing"]
  $order | where {|s| $findings | any {|f| $f.code == $s } } | first
}

def print-verdict [v, json: bool] {
  if $json { print ($v | to json); return }
  let mark = if $v.ok { "READY" } else { "NOT READY" }
  print $"readiness ($CONTRACT): ($mark) [($v.status)] issue=($v.issue | default '-') repo=($v.repo | default '-') required_class=($v.required_class | default '-') declared_class=($v.declared_class | default '-')"
  for f in $v.findings { print $"  - ($f.code): ($f.message)" }
  if ($v | get -o evidence_required | default [] | is-not-empty) { print $"  evidence required: ($v.evidence_required | str join ', ')" }
}

def make-verdict [status: string, findings, extra] {
  {
    contract: $CONTRACT
    status: $status
    ok: ($status == "ready")
    checked_at: (fmt-ts (now-utc))
    findings: $findings
  } | merge $extra
}

def exit-with [v, json: bool] {
  print-verdict $v $json
  if $v.ok { exit 0 } else { exit 1 }
}

# ---------------------------------------------------------------------------
# evaluation core
# ---------------------------------------------------------------------------

# The one place a verdict is decided. `check` gathers its context from a local
# checkout, `broker` gathers the same context from the GitHub API; neither
# holds policy of its own.
#
# ctx: {now, repo, adapter, issue_id, paths, description, unavailable,
#       state_type, comments, require_evidence, ref, any_ref, actor}
def evaluate-readiness [ctx] {
  let adapter = $ctx.adapter
  let repo_name = $ctx.repo
  let now = $ctx.now
  let issue_id = ($ctx | get -o issue_id)

  let actor = ($ctx | get -o actor)
  if ($actor != null) and ($actor in ($adapter | get -o exempt_actors | default [])) {
    return (make-verdict "ready" [] {issue: $issue_id, repo: $repo_name, required_class: null, declared_class: null, exempt_actor: $actor, evidence_required: []})
  }

  # Changed paths decide the class. No path information at all fails closed to
  # the strictest class the adapter declares.
  let paths = ($ctx | get -o paths | default [])
  let matched = if ($paths | is-empty) {
    $adapter.path_classes
  } else {
    $paths | each {|p| $adapter.path_classes | where {|pc| glob-match $pc.glob $p } | get -o 0 } | compact
  }
  # A branch head has no "changed paths"; the broker asks instead whether a
  # ready record covers this repository at the class the registry declares, so
  # it passes that class in rather than letting the empty path list fail closed
  # to the strictest one.
  let forced = ($ctx | get -o force_class)
  let required_class = if ($forced != null) { $forced } else { max-class ($matched | get class) }
  let evidence_required = if ($forced != null) {
    (class-row $required_class).evidence
  } else {
    ((class-row $required_class).evidence)
    | append ($matched | each {|m| $m | get -o extra_evidence | default [] } | flatten)
    | uniq
  }
  let base = {repo: $repo_name, required_class: $required_class, declared_class: null, evidence_required: $evidence_required, paths: $paths}

  if ($issue_id == null) {
    let prefix = ($adapter | get -o issue_prefix | default $DEFAULT_ISSUE_PREFIX)
    return (make-verdict "missing" [(finding "missing" $"no ($prefix)-<n> issue reference in the PR title, branch, body, or head commit message")] ($base | merge {issue: null}))
  }
  let unavailable = ($ctx | get -o unavailable)
  if ($unavailable != null) {
    return (make-verdict "unavailable" [(finding "unavailable" $unavailable)] ($base | merge {issue: $issue_id}))
  }

  let description = ($ctx | get -o description | default "")
  let blocks = (fenced-blocks $description "readiness")
  if ($blocks | is-empty) {
    return (make-verdict "missing" [(finding "missing" $"issue ($issue_id) has no ```readiness block; create it from `readiness.nu template`")] ($base | merge {issue: $issue_id}))
  }
  if ($blocks | length) > 1 {
    return (make-verdict "invalid" [(finding "invalid" "issue has more than one readiness block")] ($base | merge {issue: $issue_id}))
  }
  let rec = (parse-yaml-block ($blocks | first))
  if ($rec == null) {
    return (make-verdict "invalid" [(finding "invalid" "readiness block is not a YAML mapping")] ($base | merge {issue: $issue_id}))
  }
  let shape = (validate-record-shape $rec)
  if ($shape | is-not-empty) {
    return (make-verdict "invalid" $shape ($base | merge {issue: $issue_id, declared_class: ($rec | get -o blast_radius)}))
  }
  if $rec.issue != $issue_id {
    return (make-verdict "invalid" [(finding "invalid" $"record issue ($rec.issue) does not match the referenced issue ($issue_id)")] ($base | merge {issue: $issue_id, declared_class: $rec.blast_radius}))
  }

  let findings = (validate-record-semantics $rec {now: $now, description: $description, repo: $repo_name, required_class: $required_class, issue_state_type: ($ctx | get -o state_type)})
  let waived = (active-waivers $rec $now)
  let effective_required = ($evidence_required | where {|k| $k not-in $waived })
  let ev_findings = if (($ctx | get -o require_evidence | default false)) and ($findings | is-empty) {
    check-evidence (parse-evidence ($ctx | get -o comments | default [])) $repo_name $effective_required ($ctx | get -o ref) (($ctx | get -o any_ref | default false))
  } else { [] }

  let all = ($findings | append $ev_findings)
  make-verdict (verdict-status $all) $all ($base | merge {
    issue: $issue_id, declared_class: $rec.blast_radius, evidence_required: $effective_required,
    waived: $waived, record: $rec
  })
}

# Fetch the issue from Linear and shape it for evaluate-readiness. Never
# throws: a failure becomes an `unavailable` context, which is fail-closed.
def load-issue-context [issue_id: string] {
  let r = (try { {ok: true, issue: (linear-issue $issue_id)} } catch {|e| {ok: false, msg: $e.msg} })
  if not $r.ok { return {unavailable: $r.msg, description: "", state_type: null, comments: [], id: null} }
  {
    unavailable: null
    description: ($r.issue | get -o description | default "")
    state_type: ($r.issue | get -o state.type)
    comments: ($r.issue | get -o comments.nodes | default [])
    id: $r.issue.id
  }
}

# ---------------------------------------------------------------------------
# main commands
# ---------------------------------------------------------------------------

def main [] {
  print $"readiness.nu ($CONTRACT) — canonical readiness validator"
  print "subcommands: check, broker, parse, digest, stamp, template, evidence, comment, issue, discover, audit, lock, version"
  print "run `nu readiness.nu <subcommand> --help` for flags"
}

def "main version" [] { print $CONTRACT }

# Validate the readiness record for a change in this repository.
def "main check" [
  --issue: string          # Linear identifier (TEO-1234); resolved from --title/--branch/--body/GITHUB_EVENT_PATH/HEAD message when omitted
  --record: path           # offline: file holding the Linear issue description (with its ```readiness block)
  --comments: path         # offline: JSON list of {body, createdAt} comments used for --require-evidence
  --issue-state: string    # offline: Linear workflow state type (started, completed, canceled ...)
  --repo-dir: path         # repository root (default: current directory's git root)
  --repo: string           # owner/name override (default: adapter.repo)
  --base: string           # base ref for changed-path classification
  --head: string = "HEAD"  # head ref for changed-path classification
  --files: string          # explicit changed paths, comma-separated (overrides --base/--head)
  --title: string          # PR title (issue reference source)
  --branch: string         # branch name (issue reference source)
  --body: string           # PR body (issue reference source)
  --require-evidence       # also require passing evidence comments for every evidence kind of the required class
  --ref: string            # evidence must be recorded for this git ref (default: resolved head sha)
  --any-ref                # accept evidence recorded for any ref
  --actor: string          # actor login; adapter.exempt_actors may skip the gate (audited)
  --now: string            # override current time (tests)
  --json                   # machine-readable verdict on stdout
] {
  let now = if ($now == null) { now-utc } else { let t = (parse-ts $now); if ($t == null) { error make {msg: "--now must be RFC 3339"} }; $t }
  let root = (git-root ($repo_dir | default (pwd)))
  let adapter = (load-adapter $root)
  let repo_name = ($repo | default $adapter.repo)
  let prefix = ($adapter | get -o issue_prefix | default $DEFAULT_ISSUE_PREFIX)

  # 1. issue reference
  let event = (github-event)
  let pr = if ($event == null) { null } else { $event | get -o pull_request }
  let head_msg = (^git -C $root log -1 --format=%B $head | complete | get stdout)
  let sources = [
    $issue
    (issue-ref-in $title $prefix)
    (issue-ref-in $branch $prefix)
    (issue-ref-in $body $prefix)
    (if ($pr == null) { null } else { issue-ref-in ($pr | get -o title) $prefix })
    (if ($pr == null) { null } else { issue-ref-in ($pr | get -o head.ref) $prefix })
    (if ($pr == null) { null } else { issue-ref-in ($pr | get -o body) $prefix })
    (issue-ref-in $head_msg $prefix)
  ] | compact
  let issue_id = ($sources | get -o 0)

  # 2. changed paths
  let paths = if ($files != null) { $files | split row "," | each {|p| $p | str trim } | where {|p| $p | is-not-empty } } else if ($base != null) { changed-files $root $base $head } else if ($pr != null) {
    let base_sha = ($pr | get -o base.sha)
    let head_sha = ($pr | get -o head.sha)
    if ($base_sha == null or $head_sha == null) { [] } else { try { changed-files $root $base_sha $head_sha } catch { [] } }
  } else { [] }

  # 3. issue content: an offline --record, or Linear
  let loaded = if ($issue_id == null) {
    {description: "", state_type: null, comments: [], unavailable: null}
  } else if ($record != null) {
    {description: (open --raw $record), state_type: $issue_state, comments: (if ($comments == null) { [] } else { open --raw $comments | from json }), unavailable: null}
  } else {
    load-issue-context $issue_id
  }

  let ref_sha = if ($ref != null) { $ref } else { ^git -C $root rev-parse $head | complete | get stdout | str trim }
  let v = (evaluate-readiness {
    now: $now, repo: $repo_name, adapter: $adapter, issue_id: $issue_id, paths: $paths,
    description: $loaded.description, unavailable: ($loaded | get -o unavailable),
    state_type: ($loaded | get -o state_type), comments: $loaded.comments,
    require_evidence: $require_evidence, ref: $ref_sha, any_ref: $any_ref, actor: $actor
  })
  exit-with $v $json
}

# Print the parsed readiness record of an issue description as JSON.
def "main parse" [--file: path, --issue: string] {
  let text = if ($file != null) { open --raw $file } else if ($issue != null) { (linear-issue $issue).description | default "" } else { error make {msg: "give --file or --issue"} }
  let blocks = (fenced-blocks $text "readiness")
  if ($blocks | length) != 1 { error make {msg: $"expected exactly one readiness block, found ($blocks | length)"} }
  let rec = (parse-yaml-block ($blocks | first))
  if ($rec == null) { error make {msg: "readiness block is not a YAML mapping"} }
  let f = (validate-record-shape $rec)
  {record: $rec, findings: $f, scope_digest: (scope-digest $text)} | to json
}

# Print the scope digest of an issue description.
def "main digest" [--file: path, --issue: string] {
  let text = if ($file != null) { open --raw $file } else if ($issue != null) { (linear-issue $issue).description | default "" } else { error make {msg: "give --file or --issue"} }
  print (scope-digest $text)
}

def render-block [rec] {
  let ex = ($rec | get -o exceptions | default [])
  let lines = [
    "```readiness"
    $"contract: ($rec.contract)"
    $"issue: ($rec.issue)"
    $"state: ($rec.state)"
    $"blast_radius: ($rec.blast_radius)"
    "repos:"
  ] | append ($rec.repos | each {|r| $"  - ($r)" })
    | append [
      $"scope_digest: ($rec | get -o scope_digest | default '')"
      $"approved_by: ($rec | get -o approved_by | default '')"
      $"approved_at: ($rec | get -o approved_at | default '')"
      $"expires_at: ($rec | get -o expires_at | default '')"
    ]
    | append (if ($ex | is-empty) { ["exceptions: []"] } else { ["exceptions:"] | append ($ex | each {|e|
        [
          $"  - id: ($e.id)"
          $"    waives: [($e.waives | str join ', ')]"
          $"    owner: ($e.owner)"
          $"    expires_at: ($e.expires_at)"
          $"    approval: ($e.approval)"
          $"    follow_up: ($e.follow_up)"
        ] | append (if (($e | get -o reason) == null) { [] } else { [$"    reason: ($e.reason)"] })
      } | flatten) })
    | append (if (($rec | get -o notes) == null) { [] } else { [$"notes: ($rec.notes)"] })
    | append ["```"]
  $lines | str join "\n"
}

# Print a readiness block skeleton for a new issue.
def "main template" [--issue: string = "TEO-0000", --class: string = "local", --repos: string = ""] {
  if ($class not-in (class-names)) { error make {msg: $"unknown class ($class)"} }
  render-block {contract: $CONTRACT, issue: $issue, state: "draft", blast_radius: $class, repos: (if ($repos | str trim | is-empty) { ["Eugene3dotdev/<repo>"] } else { $repos | split row "," | each {|r| $r | str trim } }), exceptions: []}
}

# Approve: recompute the scope digest, set state ready, approved_at now and
# expires_at now + days, and print (or --write back to Linear) the description.
def "main stamp" [
  --issue: string
  --record: path           # offline: description file; result printed, never written to Linear
  --approved-by: string
  --days: int = 14
  --write                  # update the Linear issue description in place
  --now: string
] {
  if ($approved_by == null) { error make {msg: "--approved-by is required"} }
  if $days < 1 or $days > $MAX_VALIDITY_DAYS { error make {msg: $"--days must be 1..($MAX_VALIDITY_DAYS)"} }
  let now = if ($now == null) { now-utc } else { parse-ts $now }
  let loaded = if ($record != null) { {description: (open --raw $record), id: null} } else {
    if ($issue == null) { error make {msg: "give --issue or --record"} }
    let i = (linear-issue $issue); {description: ($i.description | default ""), id: $i.id}
  }
  let blocks = (fenced-blocks $loaded.description "readiness")
  if ($blocks | length) != 1 { error make {msg: $"expected exactly one readiness block, found ($blocks | length)"} }
  let rec = (parse-yaml-block ($blocks | first))
  if ($rec == null) { error make {msg: "readiness block is not a YAML mapping"} }
  let shape = (validate-record-shape $rec)
  if ($shape | is-not-empty) { error make {msg: $"record is invalid: ($shape | get message | str join '; ')"} }
  if ($issue != null) and ($rec.issue != $issue) { error make {msg: $"record issue ($rec.issue) does not match ($issue)"} }
  let stamped = ($rec
    | upsert state "ready"
    | upsert scope_digest (scope-digest $loaded.description)
    | upsert approved_by $approved_by
    | upsert approved_at (fmt-ts $now)
    | upsert expires_at (fmt-ts ($now + ($days * 1day))))
  let ls = ($loaded.description | lines)
  let start = ($ls | enumerate | where {|e| ($e.item | str trim) == "```readiness" } | get 0.index)
  let rest = ($ls | skip ($start + 1))
  let len = ($rest | enumerate | where {|e| ($e.item | str trim) starts-with "```" } | get 0.index)
  let new_desc = (($ls | first $start) | append (render-block $stamped | lines) | append ($rest | skip ($len + 1)) | str join "\n")
  if $write {
    if ($loaded.id == null) { error make {msg: "--write needs --issue (a Linear issue), not --record"} }
    let r = (linear-issue-update-description $loaded.id $new_desc)
    if not ($r | get -o issueUpdate.success | default false) { error make {msg: "Linear issueUpdate did not report success"} }
    print $"stamped ($stamped.issue): ready until ($stamped.expires_at), scope_digest ($stamped.scope_digest)"
  } else {
    print $new_desc
  }
}

# Record validation evidence on the Linear issue as a ```readiness-evidence comment.
def "main evidence" [
  --issue: string
  --kind: string
  --status: string = "pass"
  --ref: string            # git sha the evidence is for (default: HEAD of --repo-dir)
  --control-point: string
  --run: string            # URL of the CI run or log
  --note: string
  --repo-dir: path
  --repo: string
  --dry-run                # print the comment instead of posting
] {
  if ($issue == null or $kind == null or $control_point == null) { error make {msg: "--issue, --kind and --control-point are required"} }
  if ($kind not-in $EVIDENCE_KINDS) { error make {msg: $"unknown evidence kind ($kind); known: ($EVIDENCE_KINDS | str join ', ')"} }
  if ($status not-in $EVIDENCE_STATUSES) { error make {msg: $"status must be one of ($EVIDENCE_STATUSES | str join ', ')"} }
  let root = (git-root ($repo_dir | default (pwd)))
  let repo_name = ($repo | default (load-adapter $root).repo)
  let sha = if ($ref != null) { $ref } else { ^git -C $root rev-parse HEAD | complete | get stdout | str trim }
  let fp = (evidence-fingerprint $repo_name $kind $sha $status)
  let body = (evidence-body $repo_name $kind $status $sha $control_point $run $note)
  if $dry_run { print $body; return }
  let i = (linear-issue $issue)
  let existing = (parse-evidence ($i | get -o comments.nodes | default []) | where fingerprint == $fp)
  if ($existing | is-not-empty) { print $"evidence already recorded on ($issue) \(fingerprint ($fp)\)"; return }
  let r = (linear-comment-create $i.id $body)
  if not ($r | get -o commentCreate.success | default false) { error make {msg: "Linear commentCreate did not report success"} }
  print $"recorded ($kind)=($status) for ($repo_name)@($sha) on ($issue): ($r | get -o commentCreate.comment.url | default '')"
}

# Post a file as a comment on a Linear issue (program notes, audit reports).
def "main comment" [--issue: string, --file: path, --dry-run] {
  if ($issue == null or $file == null) { error make {msg: "--issue and --file are required"} }
  let body = (open --raw $file)
  if $dry_run { print $body; return }
  let i = (linear-issue $issue)
  let r = (linear-comment-create $i.id $body)
  if not ($r | get -o commentCreate.success | default false) { error make {msg: "Linear commentCreate did not report success"} }
  print $"commented on ($issue): ($r | get -o commentCreate.comment.url | default '')"
}

# ---------------------------------------------------------------------------
# discovery and audit
# ---------------------------------------------------------------------------

def discover-paths [root] {
  let files = (tracked-files $root)
  $EXECUTION_PATHS | each {|pat|
    $files | where {|f| glob-match $pat.glob $f } | each {|f| {kind: $pat.kind, path: $f} }
  } | flatten | uniq-by path | sort-by path
}

def discover-report [root, adapter] {
  let found = (discover-paths $root)
  let registered = (control-point-paths $adapter)
  let ignored = ($adapter | get -o ignore_paths | default [])
  let rows = ($found | each {|d|
    let status = if ($d.path in $registered) { "registered" } else if ($ignored | any {|g| glob-match $g $d.path }) { "ignored" } else { "unregistered" }
    $d | insert status $status
  })
  let missing_cp = ($adapter.control_points | where {|cp| ($cp | get -o path) != null } | where {|cp| not ([$root $cp.path] | path join | path exists) })
  {paths: $rows, unregistered: ($rows | where status == "unregistered"), missing_control_points: $missing_cp}
}

# List execution paths of a repository and compare with its adapter.
def "main discover" [--repo-dir: path, --json] {
  let root = (git-root ($repo_dir | default (pwd)))
  let adapter = (load-adapter $root)
  let rep = (discover-report $root $adapter)
  if $json { print ($rep | to json); } else {
    print $"execution paths in ($adapter.repo):"
    for r in $rep.paths { print $"  [($r.status)] ($r.kind) ($r.path)" }
    for m in $rep.missing_control_points { print $"  [missing] control point ($m.id) → ($m.path) does not exist" }
  }
  if ($rep.unregistered | is-not-empty) or ($rep.missing_control_points | is-not-empty) { exit 1 }
}

def gate-marker-ok [root, cp] {
  let file = ([$root $cp.path] | path join)
  if not ($file | path exists) { return false }
  let marker = ($cp | get -o marker | default "readiness.nu check")
  open --raw $file | str contains $marker
}

def github-required-checks [repo: string, branch: string, token: string] {
  let headers = ["Authorization" $"Bearer ($token)" "Accept" "application/vnd.github+json" "X-GitHub-Api-Version" "2022-11-28"]
  let rules = (try { http get --full --allow-errors --headers $headers $"($GITHUB_API)/repos/($repo)/rules/branches/($branch)" } catch {|e| {status: 0, body: $e.msg} })
  let from_rules = if $rules.status == 200 {
    $rules.body | where type == "required_status_checks" | each {|r| $r | get -o parameters.required_status_checks | default [] | get context } | flatten
  } else { [] }
  let classic = (try { http get --full --allow-errors --headers $headers $"($GITHUB_API)/repos/($repo)/branches/($branch)/protection/required_status_checks" } catch {|e| {status: 0, body: $e.msg} })
  let from_classic = if $classic.status == 200 { $classic.body | get -o contexts | default [] } else { [] }
  let prot = (try { http get --full --allow-errors --headers $headers $"($GITHUB_API)/repos/($repo)/branches/($branch)/protection" } catch {|e| {status: 0, body: $e.msg} })
  let protected = ($prot.status == 200) or (($rules.status == 200) and ($rules.body | is-not-empty))
  {protected: $protected, required: ($from_rules | append $from_classic | uniq), rules_status: $rules.status, protection_status: $prot.status}
}

def locate-repo [root_dir, entry] {
  let short = ($entry.repo | split row "/" | last)
  let owner = ($entry.repo | split row "/" | first)
  let candidates = [
    ($entry | get -o local_path | default "")
    ([$root_dir $short] | path join)
    ([$root_dir "github.com" $owner $short] | path join)
    ([$root_dir $owner $short] | path join)
  ] | where {|p| ($p | is-not-empty) and ($p | path exists) }
  if ($candidates | is-empty) { null } else { $candidates | first }
}

def audit-repo [entry, root_dir, canonical_sha: string, github: bool, token: string] {
  let dir = (locate-repo $root_dir $entry)
  if ($dir == null) {
    return {repo: $entry.repo, located: false, gaps: [$"clone not found under ($root_dir)"], adapter_ok: false, lock_ok: false, canonical_ok: false, missing_control_points: [], unregistered: [], protection: null}
  }
  let root = (try { git-root $dir } catch { null })
  if ($root == null) { return {repo: $entry.repo, located: true, gaps: [$"($dir) is not a git repository"], adapter_ok: false, lock_ok: false, canonical_ok: false, missing_control_points: [], unregistered: [], protection: null} }
  let head = (^git -C $root rev-parse --short HEAD | complete | get stdout | str trim)
  let adapter = (try { {ok: true, a: (load-adapter $root)} } catch {|e| {ok: false, msg: $e.msg} })
  if not $adapter.ok {
    return {repo: $entry.repo, located: true, head: $head, gaps: [$"adapter: ($adapter.msg)"], adapter_ok: false, lock_ok: false, canonical_ok: false, missing_control_points: [], unregistered: [], protection: null}
  }
  let a = $adapter.a
  mut gaps = []
  if $a.repo != $entry.repo { $gaps = ($gaps | append $"adapter declares repo ($a.repo), registry expects ($entry.repo)") }
  if $a.contract_version != $entry.contract_version { $gaps = ($gaps | append $"adapter contract ($a.contract_version) differs from registry expectation ($entry.contract_version)") }
  # lock and validator drift
  let vfile = ([$a._dir "readiness.nu"] | path join)
  let lfile = (lock-path $a._dir)
  let is_canonical = (($entry | get -o canonical | default false) == true)
  let lock = if ($lfile | path exists) { try { open --raw $lfile | from yaml } catch { null } } else { null }
  let lock_ok = if $is_canonical { true } else if ($lock == null) { false } else {
    ($lock | get -o lock) == $LOCK_SCHEMA and ($vfile | path exists) and (($lock | get -o validator_sha256) == (validator-sha $vfile))
  }
  let canonical_ok = if $is_canonical { (validator-sha $vfile) == $canonical_sha } else { ($vfile | path exists) and ((validator-sha $vfile) == $canonical_sha) }
  if not $lock_ok { $gaps = ($gaps | append "lock.yaml missing or its validator_sha256 does not match the vendored readiness.nu") }
  if not $canonical_ok { $gaps = ($gaps | append "vendored readiness.nu differs from the canonical validator (re-vendor from dotfiles)") }
  # control points
  let expected_ids = ($entry | get -o control_points | default [])
  let adapter_ids = ($a.control_points | get id)
  for id in $expected_ids { if ($id not-in $adapter_ids) { $gaps = ($gaps | append $"registry control point ($id) is not declared by the adapter") } }
  for id in $adapter_ids { if ($id not-in $expected_ids) { $gaps = ($gaps | append $"adapter control point ($id) is not registered in the registry") } }
  let rep = (discover-report $root $a)
  for m in $rep.missing_control_points { $gaps = ($gaps | append $"control point ($m.id) path ($m.path) does not exist") }
  for cp in ($a.control_points | where enforces == true) {
    if $cp.kind == $BROKER_KIND {
      # Enforced from the canonical repository: the broker posts this status
      # and branch protection requires it. What the audit can check here is
      # that the repository asks for the context the broker actually posts and
      # that the registry expects it as a required check.
      if $cp.required_check != $BROKER_CONTEXT {
        $gaps = ($gaps | append $"control point ($cp.id) expects the status `($cp.required_check)`, but the broker posts `($BROKER_CONTEXT)`")
      }
      if ($cp.required_check not-in ($entry | get -o required_checks | default [])) {
        $gaps = ($gaps | append $"registry entry does not list `($cp.required_check)` among required_checks")
      }
    } else if not (gate-marker-ok $root $cp) {
      $gaps = ($gaps | append $"enforcing control point ($cp.id) \(($cp.path)\) does not invoke the readiness gate")
    }
  }
  # Every consuming repository must be enforced by the broker; a repository
  # whose only enforcement is a local workflow would need its own Linear
  # credential, which is the arrangement the broker replaced.
  if not $is_canonical {
    if (($a.control_points | where {|cp| ($cp.kind == $BROKER_KIND) and ($cp.enforces == true) } | is-empty)) {
      $gaps = ($gaps | append $"no enforcing ($BROKER_KIND) control point: this repository is not gated by the canonical broker")
    }
  }
  for u in $rep.unregistered { $gaps = ($gaps | append $"unregistered execution path: ($u.kind) ($u.path)") }
  let enforcing = ($a.control_points | where enforces == true)
  if ($enforcing | is-empty) { $gaps = ($gaps | append "adapter declares no enforcing control point") }
  # branch protection
  let protection = if $github {
    let branches = ($entry | get -o protected_branches | default [($entry | get -o default_branch | default "main")])
    $branches | each {|b|
      let p = (github-required-checks $entry.repo $b $token)
      let wanted = ($a.control_points | where enforces == true | each {|cp| $cp | get -o required_check } | compact)
      let missing = ($wanted | where {|w| $w not-in $p.required })
      {branch: $b, protected: $p.protected, required: $p.required, missing_required_checks: $missing, rules_status: $p.rules_status, protection_status: $p.protection_status}
    }
  } else { null }
  if $github {
    for p in $protection {
      if not $p.protected { $gaps = ($gaps | append $"branch ($p.branch) is not protected \(rules HTTP ($p.rules_status), protection HTTP ($p.protection_status)\)") }
      for m in $p.missing_required_checks { $gaps = ($gaps | append $"branch ($p.branch) does not require status check `($m)`") }
    }
  }
  {
    repo: $entry.repo, located: true, head: $head, adapter_ok: true, lock_ok: $lock_ok, canonical_ok: $canonical_ok,
    class: ($entry | get -o class), contract: $a.contract_version,
    control_points: ($a.control_points | each {|cp| {id: $cp.id, kind: $cp.kind, enforces: $cp.enforces, path: ($cp | get -o path)} }),
    missing_control_points: ($rep.missing_control_points | get id), unregistered: ($rep.unregistered | get path),
    exempt_actors: ($a | get -o exempt_actors | default []), protection: $protection, gaps: $gaps
  }
}

# The broker is the single enforcement point, so its health is part of
# coverage: a broker that stopped running leaves every pull request without a
# status, which blocks merges (fail-closed) but must never go unnoticed.
def audit-broker [reg, canonical_entry, root_dir, github: bool] {
  let dir = (locate-repo $root_dir $canonical_entry)
  let workflow = if ($dir == null) { null } else { [$dir ".github" "workflows" $BROKER_WORKFLOW] | path join }
  let present = ($workflow != null) and ($workflow | path exists)
  let max_age = ($reg | get -o broker_max_age_minutes | default $BROKER_MAX_AGE_MINUTES)
  let base_gaps = if $present { [] } else { [$"the canonical repository has no .github/workflows/($BROKER_WORKFLOW)"] }
  let freshness = if not $github {
    {last: null, age: null, gaps: []}
  } else {
    let r = (gh-get $"/repos/($canonical_entry.repo)/actions/workflows/($BROKER_WORKFLOW)/runs?status=success&per_page=1")
    if $r.status != 200 {
      {last: null, age: null, gaps: [$"cannot read broker workflow runs \(HTTP ($r.status)\)"]}
    } else {
      let run = ($r.body | get -o workflow_runs | default [] | get -o 0)
      if ($run == null) {
        {last: null, age: null, gaps: ["the broker workflow has never completed successfully"]}
      } else {
        let last = ($run | get -o updated_at)
        let t = (parse-ts $last)
        if ($t == null) {
          {last: $last, age: null, gaps: [$"the last successful broker run has an unreadable timestamp \(($last)\)"]}
        } else {
          let age = (((now-utc) - $t) / 1min | math round)
          {last: $last, age: $age, gaps: (if $age > $max_age { [$"the last successful broker run is ($age) minutes old \(limit ($max_age)\); pull requests are unattended"] } else { [] })}
        }
      }
    }
  }
  {
    workflow: $BROKER_WORKFLOW, present: $present, context: $BROKER_CONTEXT,
    last_success: $freshness.last, age_minutes: $freshness.age, max_age_minutes: $max_age,
    checked: $github, gaps: ($base_gaps | append $freshness.gaps)
  }
}

def broker-markdown [b] {
  let freshness = if $b.checked {
    $"last success ($b.last_success | default 'never') \(($b.age_minutes | default '?') min, limit ($b.max_age_minutes) min\)"
  } else {
    "freshness not checked (no --github)"
  }
  $"**Broker**: `($b.workflow)` present ($b.present), posts `($b.context)`; ($freshness)."
}

def audit-markdown [report] {
  let rows = ($report.repositories | each {|r|
    let status = if ($r.gaps | is-empty) { "covered" } else { "GAP" }
    $"| ($r.repo) | ($r | get -o head | default '-') | ($r | get -o class | default '-') | ($r | get -o contract | default '-') | ($status) | ($r.gaps | length) |"
  })
  let details = ($report.repositories | where {|r| $r.gaps | is-not-empty } | each {|r|
    ([$"### ($r.repo)"] | append ($r.gaps | each {|g| $"- ($g)" })) | str join "\n"
  })
  ([
    $"## Readiness coverage audit \(($CONTRACT)\)"
    ""
    $"Generated ($report.generated_at) from registry `($report.registry)`; canonical validator sha256 `($report.canonical_sha256 | str substring 0..<12)…`."
    ""
    "| repository | head | class | contract | status | gaps |"
    "|---|---|---|---|---|---|"
  ] | append $rows | append [""] | append [(broker-markdown $report.broker)] | append ($report.broker.gaps | each {|g| $"- ($g)" }) | append [""] | append $details | append [
    ""
    $"Total gaps: ($report.total_gaps). Repositories covered: ($report.covered)/($report.repositories | length)."
  ]) | str join "\n"
}

# Compare the registry with live repository configuration.
def "main audit" [
  --registry: path         # registry.yaml (default: next to this validator)
  --root: path             # directory holding the clones (flat <name>/ or ghq github.com/<owner>/<name>/ layout)
  --github                 # also verify branch protection and required checks through the GitHub API (needs GITHUB_TOKEN or READINESS_GITHUB_TOKEN)
  --json                   # machine-readable report
  --out: path              # write the markdown report here
  --post-issue: string     # post the markdown report as a Linear comment on this issue
] {
  let reg_path = ($registry | default ([($SELF | path dirname) "registry.yaml"] | path join))
  let reg = (load-registry $reg_path)
  let root_dir = ($root | default ($SELF | path dirname | path dirname | path dirname))
  let canonical_entry = ($reg.repositories | where {|r| ($r | get -o canonical | default false) == true } | get -o 0)
  if ($canonical_entry == null) { error make {msg: "registry has no canonical repository entry"} }
  let canonical_sha = (validator-sha $SELF)
  let token = ($env | get -o READINESS_GITHUB_TOKEN | default ($env | get -o GITHUB_TOKEN | default ""))
  if $github and ($token | is-empty) { error make {msg: "--github needs READINESS_GITHUB_TOKEN or GITHUB_TOKEN"} }
  let repos = ($reg.repositories | each {|e| audit-repo ($e | upsert contract_version ($e | get -o contract_version | default $reg.contract_version)) $root_dir $canonical_sha $github $token })
  let broker = (audit-broker $reg $canonical_entry $root_dir $github)
  let total = (($repos | each {|r| $r.gaps | length } | math sum) + ($broker.gaps | length))
  let report = {
    contract: $CONTRACT, registry: ($reg_path | path basename), generated_at: (fmt-ts (now-utc)), canonical_sha256: $canonical_sha,
    github_checked: $github, repositories: $repos, broker: $broker, total_gaps: $total, covered: ($repos | where {|r| $r.gaps | is-empty } | length)
  }
  let md = (audit-markdown $report)
  if ($out != null) { $md | save --force $out }
  if $json { print ($report | to json) } else { print $md }
  if ($post_issue != null) {
    let i = (linear-issue $post_issue)
    let r = (linear-comment-create $i.id $md)
    if not ($r | get -o commentCreate.success | default false) { error make {msg: "Linear commentCreate did not report success"} }
    print $"posted audit to ($post_issue)"
  }
  if $total > 0 { exit 1 }
}

# Verify or refresh the lock that pins the vendored validator.
def "main lock" [
  --dir: path              # directory holding readiness.nu and lock.yaml (default: this file's directory)
  --update                 # rewrite lock.yaml from the current file
  --source-commit: string  # canonical dotfiles commit the copy was taken from (recorded with --update)
] {
  let d = ($dir | default ($SELF | path dirname))
  let vfile = ([$d "readiness.nu"] | path join)
  if not ($vfile | path exists) { error make {msg: $"no readiness.nu in ($d)"} }
  let sha = (validator-sha $vfile)
  let lfile = (lock-path $d)
  if $update {
    let existing = if ($lfile | path exists) { try { open --raw $lfile | from yaml } catch { {} } } else { {} }
    let text = ([
      "# Pins the vendored copy of the canonical readiness validator. Regenerate"
      "# with `nu .readiness/readiness.nu lock --update` after re-vendoring;"
      "# `readiness.nu audit` in dotfiles reports any copy whose sha differs from"
      "# the canonical file."
      $"lock: ($LOCK_SCHEMA)"
      $"contract_version: ($CONTRACT)"
      $"validator_sha256: ($sha)"
      $"source: ($existing | get -o source | default 'Eugene3dotdev/dotfiles')"
      $"source_path: ($existing | get -o source_path | default 'readiness/readiness.nu')"
      $"source_commit: ($source_commit | default ($existing | get -o source_commit | default 'unknown'))"
      $"vendored_at: (fmt-ts (now-utc))"
    ] | str join "\n") + "\n"
    $text | save --force $lfile
    print $"wrote ($lfile) \(sha256 ($sha | str substring 0..<12)…\)"
    return
  }
  if not ($lfile | path exists) { print $"lock: no lock.yaml in ($d)"; exit 1 }
  let lock = (open --raw $lfile | from yaml)
  if (($lock | get -o lock) != $LOCK_SCHEMA) { print $"lock: schema must be ($LOCK_SCHEMA)"; exit 1 }
  if (($lock | get -o contract_version) != $CONTRACT) { print $"lock: contract_version ($lock | get -o contract_version) differs from validator ($CONTRACT)"; exit 1 }
  if (($lock | get -o validator_sha256) != $sha) { print $"lock: readiness.nu sha256 ($sha) does not match lock ($lock | get -o validator_sha256)"; exit 1 }
  print $"lock ok: ($CONTRACT) ($sha | str substring 0..<12)… from ($lock | get -o source | default '?')@($lock | get -o source_commit | default '?')"
}

# Contract constants, for the tests that keep the YAML contract and this file in step.
def "main contract" [] {
  {
    contract: $CONTRACT, supported_record_contracts: $SUPPORTED_RECORD_CONTRACTS, states: $STATES, classes: $CLASSES,
    evidence_kinds: $EVIDENCE_KINDS, evidence_statuses: $EVIDENCE_STATUSES, record_keys: $RECORD_KEYS, record_required: $RECORD_REQUIRED,
    ready_required: $READY_REQUIRED, exception_keys: $EXCEPTION_KEYS, max_validity_days: $MAX_VALIDITY_DAYS,
    default_validity_days: $DEFAULT_VALIDITY_DAYS, execution_paths: $EXECUTION_PATHS
  } | to json
}

# Print the Linear issue identifier a change references (same resolution as check).
def "main issue" [--title: string, --branch: string, --body: string, --repo-dir: path, --head: string = "HEAD"] {
  let root = (git-root ($repo_dir | default (pwd)))
  let adapter = (load-adapter $root)
  let prefix = ($adapter | get -o issue_prefix | default $DEFAULT_ISSUE_PREFIX)
  let event = (github-event)
  let pr = if ($event == null) { null } else { $event | get -o pull_request }
  let head_msg = (^git -C $root log -1 --format=%B $head | complete | get stdout)
  let sources = [
    (issue-ref-in $title $prefix)
    (issue-ref-in $branch $prefix)
    (issue-ref-in $body $prefix)
    (if ($pr == null) { null } else { issue-ref-in ($pr | get -o title) $prefix })
    (if ($pr == null) { null } else { issue-ref-in ($pr | get -o head.ref) $prefix })
    (if ($pr == null) { null } else { issue-ref-in ($pr | get -o body) $prefix })
    (issue-ref-in $head_msg $prefix)
  ] | compact
  if ($sources | is-empty) { print -e $"no ($prefix)-<n> issue reference found"; exit 1 }
  print ($sources | first)
}

# ---------------------------------------------------------------------------
# GitHub API (broker and audit)
# ---------------------------------------------------------------------------

def github-token [] {
  let t = ($env | get -o READINESS_GITHUB_TOKEN | default ($env | get -o GITHUB_TOKEN | default ""))
  if ($t | str trim | is-empty) {
    error make {msg: "no GitHub token: set READINESS_GITHUB_TOKEN (the broker credential) or GITHUB_TOKEN"}
  }
  $t
}

def gh-headers [accept: string] {
  let tok = (github-token)
  ["Authorization" $"Bearer ($tok)" "Accept" $accept "X-GitHub-Api-Version" "2022-11-28" "User-Agent" "readiness-broker"]
}

def gh-get [path: string, --accept: string = "application/vnd.github+json"] {
  let r = (http get --full --allow-errors --headers (gh-headers $accept) $"($GITHUB_API)($path)")
  {status: $r.status, body: $r.body}
}

def gh-post [path: string, payload] {
  let r = (http post --full --allow-errors --content-type application/json --headers (gh-headers "application/vnd.github+json") $"($GITHUB_API)($path)" ($payload | to json))
  {status: $r.status, body: $r.body}
}

# ---------------------------------------------------------------------------
# broker — the enforcement point for every consuming repository
# ---------------------------------------------------------------------------
#
# Consuming repositories hold no Linear credential. This command runs in the
# canonical repository, evaluates every open pull request in the registry
# against its Linear record, and posts the `Readiness Gate` commit status that
# their branch protection requires. A status that is absent (the broker has
# not seen a push yet) blocks the merge exactly like a failing one, so the
# default is closed.

def broker-status-state [status: string] {
  if $status == "ready" { "success" } else if $status == "unavailable" { "error" } else { "failure" }
}

# A base branch with no adapter is a repository that carries no readiness
# policy there yet. That blocks its pull requests — fail-closed — but it is a
# verdict about the change, not a fault in the broker, so it must not make the
# run fail and the freshness check go stale.
def broker-not-onboarded [repo: string, msg: string] {
  make-verdict "not-onboarded" [(finding "not-onboarded" $msg)] {
    issue: null, repo: $repo, required_class: null, declared_class: null, evidence_required: [], paths: []
  }
}

def broker-description [v] {
  let first = ($v.findings | get -o 0.message | default $"record ready for ($v.required_class | default 'this change')")
  let text = $"($v.status): ($first)"
  # GitHub rejects a status description over 140 characters.
  if ($text | str length) > 138 { ($text | str substring 0..<137) + "…" } else { $text }
}

# The adapter is read from the pull request's BASE ref, never its head. The
# head is author-controlled: an adapter fetched from it could reclassify the
# change as `local` or add its own author to exempt_actors. A pull request that
# edits the adapter is judged by the adapter already on the base branch, which
# is what review is for.
def broker-adapter [repo: string, ref: string] {
  # Same two locations as a local checkout: .readiness/ everywhere, and
  # readiness/ in the canonical repository, which owns the contract itself.
  let candidates = [".readiness/adapter.yaml" "readiness/adapter.yaml"]
  let found = ($candidates | each {|path|
    let r = (gh-get $"/repos/($repo)/contents/($path)?ref=($ref)" --accept "application/vnd.github.raw")
    if $r.status == 200 { {path: $path, body: $r.body} } else { null }
  } | compact | get -o 0)
  if ($found == null) {
    return {ok: false, msg: $"no readable adapter on ($repo)@($ref): tried ($candidates | str join ', ')"}
  }
  let parsed = (try { validate-adapter ($found.body | from yaml) $"($repo)@($ref):($found.path)" } catch {|e| {__err: $e.msg} })
  if (($parsed | get -o __err) != null) { return {ok: false, msg: $"adapter on ($repo)@($ref) is invalid: ($parsed.__err)"} }
  {ok: true, adapter: $parsed}
}

# Changed paths of a pull request. GitHub truncates this listing at 3000
# files; a truncated answer returns an empty list, which makes
# evaluate-readiness fall back to the strictest class the adapter declares.
def broker-pr-files [repo: string, number: int] {
  mut all = []
  mut page = 1
  mut truncated = false
  loop {
    let r = (gh-get $"/repos/($repo)/pulls/($number)/files?per_page=100&page=($page)")
    if $r.status != 200 { return {ok: false, msg: $"cannot list files of ($repo)#($number) \(HTTP ($r.status)\)", files: []} }
    let batch = ($r.body | each {|f| $f.filename })
    $all = ($all | append $batch)
    if (($batch | length) < 100) { break }
    if $page >= 30 { $truncated = true; break }
    $page = $page + 1
  }
  if $truncated { {ok: true, files: [], truncated: true} } else { {ok: true, files: $all, truncated: false} }
}

# Check runs and commit statuses on a sha, flattened to {name, ok} plus the
# raw statuses so an unchanged readiness status is not reposted every tick.
def broker-signals [repo: string, sha: string] {
  let cr = (gh-get $"/repos/($repo)/commits/($sha)/check-runs?per_page=100")
  let runs = if $cr.status == 200 {
    $cr.body | get -o check_runs | default [] | each {|c| {name: $c.name, ok: ((($c | get -o conclusion) | default "") == "success")} }
  } else { [] }
  let st = (gh-get $"/repos/($repo)/commits/($sha)/status")
  let statuses = if $st.status == 200 { $st.body | get -o statuses | default [] } else { [] }
  let from_status = ($statuses | each {|s| {name: $s.context, ok: ($s.state == "success")} })
  {checks: ($runs | append $from_status), statuses: $statuses}
}

# Read the commit's signals, then post the verdict unless it is already the
# status standing on that commit.
def broker-post-row [repo: string, target, v, dry_run: bool] {
  let signals = (broker-signals $repo $target.sha)
  let existing = ($signals.statuses | where {|s| ($s | get -o context) == $BROKER_CONTEXT } | get -o 0)
  let posted = (broker-post-status $repo $target.sha $v $target.url $existing $dry_run)
  {signals: $signals, posted: $posted}
}

def broker-row [repo: string, target, v, posted, evidence] {
  {
    repo: $repo, kind: $target.kind, ref: ($target | get -o number | default $target.branch), sha: ($target.sha | str substring 0..<8),
    url: $target.url, issue: ($v | get -o issue), status: $v.status, state: $posted.state, action: $posted.action,
    required_class: ($v | get -o required_class), findings: ($v.findings | each {|f| $f.message }), evidence: $evidence
  }
}

def broker-post-status [repo: string, sha: string, v, target: string, existing, dry_run: bool] {
  let state = (broker-status-state $v.status)
  let desc = (broker-description $v)
  if ($existing != null) and ((($existing | get -o state) == $state) and (($existing | get -o description) == $desc)) {
    return {state: $state, action: "unchanged"}
  }
  if $dry_run { return {state: $state, action: "dry-run"} }
  let r = (gh-post $"/repos/($repo)/statuses/($sha)" {state: $state, context: $BROKER_CONTEXT, description: $desc, target_url: $target})
  if $r.status >= 300 { error make {msg: $"cannot post the readiness status to ($repo)@($sha): HTTP ($r.status)"} }
  {state: $state, action: "posted"}
}

# Evidence the repository's own checks have already proven. A control point
# that declares `evidence` and the `check_name` producing it gets those kinds
# recorded on the issue once that check is green on this exact sha.
def broker-record-evidence [repo: string, adapter, issue_uuid, sha: string, checks, comments, run_url: string, dry_run: bool] {
  if ($issue_uuid == null) { return [] }
  let existing = (parse-evidence $comments)
  let producers = ($adapter.control_points | where {|cp|
    ((($cp | get -o evidence | default []) | is-not-empty)) and ((($cp | get -o check_name) | default "") != "")
  })
  $producers | each {|cp|
    let hit = ($checks | where {|c| $c.name == $cp.check_name } | get -o 0)
    if ($hit == null) or (not $hit.ok) { [] } else {
      $cp.evidence | each {|kind|
        let fp = (evidence-fingerprint $repo $kind $sha "pass")
        if ($existing | any {|e| ($e | get -o fingerprint) == $fp }) { null } else {
          if $dry_run { {kind: $kind, control_point: $cp.id, action: "dry-run"} } else {
            linear-comment-create $issue_uuid (evidence-body $repo $kind "pass" $sha $cp.id $run_url $"($cp.check_name) succeeded on this commit")
            {kind: $kind, control_point: $cp.id, action: "recorded"}
          }
        }
      } | compact
    }
  } | flatten
}

def broker-issue-ref [adapter, title, branch, body] {
  let prefix = ($adapter | get -o issue_prefix | default $DEFAULT_ISSUE_PREFIX)
  [
    (issue-ref-in $title $prefix)
    (issue-ref-in $branch $prefix)
    (issue-ref-in $body $prefix)
  ] | compact | get -o 0
}

def broker-evaluate-target [entry, target, adapter, now, run_url: string, dry_run: bool] {
  # target: {kind: "pull-request"|"branch", sha, base_ref, number, title, branch, body, actor, url, force_class}
  let repo = $entry.repo
  if $adapter.repo != $repo {
    error make {msg: $"adapter on ($repo)@($target.base_ref) declares repo ($adapter.repo)"}
  }
  let paths = if $target.kind == "pull-request" {
    let f = (broker-pr-files $repo $target.number)
    if not $f.ok { error make {msg: $f.msg} }
    $f.files
  } else { [] }
  let issue_id = (broker-issue-ref $adapter ($target | get -o title) ($target | get -o branch) ($target | get -o body))
  let issue = if ($issue_id == null) { {description: "", state_type: null, comments: [], unavailable: null, id: null} } else { load-issue-context $issue_id }
  let require_evidence = (($entry | get -o require_evidence | default false) == true)
  let v = (evaluate-readiness {
    now: $now, repo: $repo, adapter: $adapter, issue_id: $issue_id, paths: $paths,
    description: $issue.description, unavailable: ($issue | get -o unavailable),
    state_type: ($issue | get -o state_type), comments: $issue.comments,
    require_evidence: $require_evidence, ref: $target.sha, any_ref: false,
    actor: ($target | get -o actor), force_class: ($target | get -o force_class)
  })
  let out = (broker-post-row $repo $target $v $dry_run)
  let evidence = (try {
    broker-record-evidence $repo $adapter ($issue | get -o id) $target.sha $out.signals.checks $issue.comments $run_url $dry_run
  } catch {|e| [{action: "failed", error: $e.msg}] })
  broker-row $repo $target $v $out.posted $evidence
}

def broker-open-prs [repo: string, number] {
  if ($number != null) {
    let r = (gh-get $"/repos/($repo)/pulls/($number)")
    if $r.status != 200 { error make {msg: $"cannot read ($repo)#($number) \(HTTP ($r.status)\)"} }
    [$r.body]
  } else {
    let r = (gh-get $"/repos/($repo)/pulls?state=open&per_page=100")
    if $r.status != 200 { error make {msg: $"cannot list open pull requests of ($repo) \(HTTP ($r.status)\)"} }
    $r.body
  }
}

# Evaluate open pull requests (and, where the registry asks for it, the
# default-branch head) and post the readiness status GitHub branch protection
# requires. Exits non-zero only on an operational failure: a pull request that
# is not ready is a posted verdict, not a broker error.
def "main broker" [
  --registry: path         # registry.yaml (default: next to this validator)
  --repo: string           # limit to one registered repository
  --pr: int                # limit to one pull request (requires --repo)
  --run-url: string = ""   # URL of the broker run, recorded on evidence comments
  --dry-run                # evaluate and report; post nothing
  --now: string            # override current time (tests)
  --json
] {
  let now = if ($now == null) { now-utc } else { let t = (parse-ts $now); if ($t == null) { error make {msg: "--now must be RFC 3339"} }; $t }
  let reg = (load-registry ($registry | default ([($SELF | path dirname) "registry.yaml"] | path join)))
  let entries = ($reg.repositories | where {|r| ($repo == null) or ($r.repo == $repo) })
  if ($entries | is-empty) { error make {msg: $"no registry entry for ($repo | default '<all>')"} }
  if ($pr != null) and ($repo == null) { error make {msg: "--pr requires --repo"} }

  mut rows = []
  mut errors = []
  for e in $entries {
    let prs = (try { {ok: true, list: (broker-open-prs $e.repo $pr)} } catch {|err| {ok: false, msg: $err.msg} })
    if not $prs.ok {
      $errors = ($errors | append {repo: $e.repo, error: $prs.msg})
      continue
    }
    # Pull requests share base branches, and the adapter is read from the
    # base; fetch it once per base ref instead of once per pull request.
    let base_refs = ($prs.list | each {|p| $p.base.ref } | uniq)
    let adapters = ($base_refs | each {|ref| {ref: $ref, loaded: (broker-adapter $e.repo $ref)} })
    for p in $prs.list {
      let loaded = ($adapters | where ref == $p.base.ref | get 0.loaded)
      let target = {
        kind: "pull-request", sha: $p.head.sha, base_ref: $p.base.ref, number: $p.number,
        title: ($p | get -o title), branch: ($p | get -o head.ref), body: ($p | get -o body),
        actor: ($p | get -o user.login), url: ($p | get -o html_url), force_class: null
      }
      let r = (try {
        if $loaded.ok {
          {ok: true, row: (broker-evaluate-target $e $target $loaded.adapter $now $run_url $dry_run)}
        } else {
          let v = (broker-not-onboarded $e.repo $loaded.msg)
          {ok: true, row: (broker-row $e.repo $target $v (broker-post-row $e.repo $target $v $dry_run).posted [])}
        }
      } catch {|err| {ok: false, msg: $err.msg} })
      if $r.ok { $rows = ($rows | append $r.row) } else { $errors = ($errors | append {repo: $e.repo, pr: $p.number, error: $r.msg}) }
    }
    # Release-class repositories also carry the status on their default-branch
    # head, so a tag or dispatch build can require it with nothing but the
    # workflow token.
    if (($e | get -o gate_default_branch | default false) == true) and ($pr == null) {
      let branch = ($e | get -o default_branch | default "main")
      let hr = (gh-get $"/repos/($e.repo)/commits/($branch)")
      if $hr.status != 200 {
        $errors = ($errors | append {repo: $e.repo, error: $"cannot read ($branch) head \(HTTP ($hr.status)\)"})
      } else {
        let target = {
          kind: "branch", sha: $hr.body.sha, base_ref: $branch, number: null,
          title: null, branch: $branch, body: ($e | get -o release_issue),
          actor: null, url: $"https://github.com/($e.repo)/commits/($branch)",
          force_class: ($e | get -o class)
        }
        let loaded = (broker-adapter $e.repo $branch)
        if not $loaded.ok {
          # A default branch with no adapter is an onboarding gap the audit
          # reports; do not paint a status on a branch head over it.
          $rows = ($rows | append {
            repo: $e.repo, kind: "branch", ref: $branch, sha: (($hr.body.sha) | str substring 0..<8), url: $target.url,
            issue: null, status: "not-onboarded", state: "skipped", action: "skipped",
            required_class: null, findings: [$loaded.msg], evidence: []
          })
        } else {
          let r = (try { {ok: true, row: (broker-evaluate-target $e $target $loaded.adapter $now $run_url $dry_run)} } catch {|err| {ok: false, msg: $err.msg} })
          if $r.ok { $rows = ($rows | append $r.row) } else { $errors = ($errors | append {repo: $e.repo, branch: $branch, error: $r.msg}) }
        }
      }
    }
  }

  # A verdict of `unavailable` means Linear could not be read. The status is
  # posted (fail-closed for the pull request), and the run fails so the audit's
  # freshness check sees a stale broker instead of a silent one.
  let unavailable = ($rows | where status == "unavailable")
  let not_onboarded = ($rows | where status == "not-onboarded")
  let report = {
    contract: $CONTRACT, ran_at: (fmt-ts $now), dry_run: $dry_run,
    evaluated: ($rows | length), ready: ($rows | where status == "ready" | length),
    blocked: ($rows | where {|r| $r.status != "ready" } | length),
    unavailable: ($unavailable | length), not_onboarded: ($not_onboarded | length),
    targets: $rows, errors: $errors
  }
  if $json { print ($report | to json) } else {
    print $"readiness broker ($CONTRACT): evaluated ($report.evaluated), ready ($report.ready), blocked ($report.blocked)"
    for r in $rows {
      print $"  [($r.state)] ($r.repo) ($r.kind) ($r.ref) ($r.sha) issue=($r.issue | default '-') ($r.status) \(($r.action)\)"
      for f in $r.findings { print $"      ($f)" }
      for ev in $r.evidence { print $"      evidence ($ev | get -o kind | default '?') ($ev.action)" }
    }
    for e in $errors { print $"  [error] ($e | to json --raw)" }
  }
  if ($errors | is-not-empty) or (($unavailable | length) > 0) { exit 1 }
}

# Assert that the broker's status is green on a commit, using nothing but a
# GitHub token. This is how a consuming repository proves the readiness record
# was validated without ever holding a Linear credential: the broker writes the
# verdict as a commit status, and release or deploy paths read it back here.
def "main assert-status" [
  --repo: string           # owner/name (default: the adapter's repo)
  --sha: string            # commit (default: HEAD of --repo-dir)
  --context: string        # status context (default: the broker's)
  --repo-dir: path
  --json
] {
  let root = (git-root ($repo_dir | default (pwd)))
  let repo_name = ($repo | default (load-adapter $root).repo)
  let commit = if ($sha != null) { $sha } else { ^git -C $root rev-parse HEAD | complete | get stdout | str trim }
  let ctx = ($context | default $BROKER_CONTEXT)
  let r = (gh-get $"/repos/($repo_name)/commits/($commit)/status")
  if $r.status != 200 {
    let out = {ok: false, repo: $repo_name, sha: $commit, context: $ctx, state: null, reason: $"cannot read commit status \(HTTP ($r.status)\)"}
    if $json { print ($out | to json) } else { print -e $"assert-status: ($out.reason)" }
    exit 1
  }
  let hit = ($r.body | get -o statuses | default [] | where {|s| ($s | get -o context) == $ctx } | get -o 0)
  let state = ($hit | get -o state)
  let ok = ($state == "success")
  let reason = if $ok { "" } else if ($hit == null) {
    $"no `($ctx)` status on ($repo_name)@($commit); the broker has not evaluated this commit yet"
  } else {
    $"`($ctx)` is ($state) on ($repo_name)@($commit): ($hit | get -o description | default '')"
  }
  let out = {ok: $ok, repo: $repo_name, sha: $commit, context: $ctx, state: $state, reason: $reason, url: ($hit | get -o target_url)}
  if $json { print ($out | to json) } else if $ok {
    print $"assert-status: `($ctx)` is success on ($repo_name)@($commit | str substring 0..<8)"
  } else {
    print -e $"assert-status: ($reason)"
  }
  if $ok { exit 0 } else { exit 1 }
}

# Publish a fact this repository proved as a commit status. The broker turns
# such a status into Linear evidence when the adapter names it as the
# `check_name` of an evidence-producing control point, which is how a
# repository contributes evidence without holding a Linear credential.
def "main publish-status" [
  --context: string        # status context, e.g. "z3store/verify-release"
  --state: string = "success"  # success | failure | error | pending
  --description: string = ""
  --url: string = ""
  --sha: string
  --repo: string
  --repo-dir: path
] {
  if ($context == null) { error make {msg: "--context is required"} }
  if ($state not-in ["success" "failure" "error" "pending"]) { error make {msg: $"--state must be success, failure, error or pending"} }
  let root = (git-root ($repo_dir | default (pwd)))
  let repo_name = ($repo | default (load-adapter $root).repo)
  let commit = if ($sha != null) { $sha } else { ^git -C $root rev-parse HEAD | complete | get stdout | str trim }
  let desc = if (($description | str length) > 138) { ($description | str substring 0..<137) + "…" } else { $description }
  let r = (gh-post $"/repos/($repo_name)/statuses/($commit)" {state: $state, context: $context, description: $desc, target_url: $url})
  if $r.status >= 300 { error make {msg: $"cannot publish `($context)` to ($repo_name)@($commit): HTTP ($r.status)"} }
  print $"published `($context)` = ($state) on ($repo_name)@($commit | str substring 0..<8)"
}
