/**
 * Readiness gate bridge (readiness/v1). The canonical contract and validator
 * live in Eugene3dotdev/dotfiles readiness/; .readiness/readiness.nu is the
 * vendored copy pinned by .readiness/lock.yaml. This module only resolves a
 * Nushell runtime and runs that validator — no policy lives here.
 *
 * This repository holds no Linear credential. Enforcement for pull requests
 * is the canonical broker, which validates the record and posts the
 * `Readiness Gate` commit status that branch protection requires. The tiers
 * therefore run in one of three modes, and say which one they are in:
 *
 *   enforce    LINEAR_API_KEY or Z3_READINESS_RECORD is configured: run the
 *              full record check here (operators and agents, locally).
 *   delegated  Z3_READINESS_MODE=delegated: read the broker's verdict back
 *              from the commit status with a GitHub token. Unspoofable by an
 *              environment variable, because the status is fetched from the
 *              API rather than trusted from the environment.
 *   advisory   Neither is available. The per-PR tier says so and continues —
 *              the required status still blocks the merge. The release tier
 *              refuses, because a release must not proceed on an unverified
 *              record.
 */
import { existsSync } from "node:fs";
import { join } from "node:path";
import { repoRoot, type SpawnResult, spawnSync } from "./runtime.ts";

const NU_PIN = "0.109.1";
const VALIDATOR = ".readiness/readiness.nu";

export type ReadinessMode = "enforce" | "delegated" | "advisory";

function nuCommand(): string[] | null {
	if (Bun.which("mise") !== null) {
		return ["mise", "x", `aqua:nushell/nushell@${NU_PIN}`, "--", "nu"];
	}
	if (Bun.which("nu") !== null) return ["nu"];
	return null;
}

function hasEnv(name: string): boolean {
	const v = process.env[name];
	return typeof v === "string" && v.length > 0;
}

export function readinessMode(): ReadinessMode {
	if (process.env.Z3_READINESS_MODE === "delegated") return "delegated";
	if (hasEnv("LINEAR_API_KEY") || hasEnv("Z3_READINESS_RECORD")) return "enforce";
	return "advisory";
}

export type ReadinessOptions = {
	tier: "pr" | "release";
	requireEvidence?: boolean;
};

/**
 * Run the readiness gate for the current change. Returns the spawn result the
 * caller fails the tier on; `code: 0` with a message on stdout is a pass.
 */
export function runReadinessCheck(opts: ReadinessOptions): SpawnResult {
	const root = repoRoot();
	const validator = join(root, VALIDATOR);
	if (!existsSync(validator)) {
		return {
			code: 1,
			stdout: "",
			stderr: `readiness: ${VALIDATOR} is missing; re-vendor it from Eugene3dotdev/dotfiles readiness/readiness.nu`,
		};
	}
	const nu = nuCommand();
	if (nu === null) {
		return {
			code: 127,
			stdout: "",
			stderr: `readiness: no Nushell runtime (install mise, or nu ${NU_PIN}); the gate fails closed`,
		};
	}
	const lock = spawnSync([...nu, "--no-config-file", validator, "lock"], {
		cwd: root,
	});
	if (lock.code !== 0) return lock;

	const mode = readinessMode();
	if (mode === "delegated") {
		return spawnSync([...nu, "--no-config-file", validator, "assert-status"], {
			cwd: root,
		});
	}
	if (mode === "advisory") {
		if (opts.tier === "release") {
			return {
				code: 1,
				stdout: "",
				stderr:
					"readiness: a release needs a verified record. Set LINEAR_API_KEY (or Z3_READINESS_RECORD for an offline check), or run under CI where Z3_READINESS_MODE=delegated reads the broker's `Readiness Gate` status.",
			};
		}
		return {
			code: 0,
			stdout:
				"readiness: advisory here (no LINEAR_API_KEY, no offline record). The canonical broker validates the record and posts the `Readiness Gate` status this pull request must pass; see .readiness/adapter.yaml.\n",
			stderr: "",
		};
	}

	const args = [...nu, "--no-config-file", validator, "check"];
	const issue = process.env.Z3_READINESS_ISSUE;
	if (issue && issue.length > 0) args.push("--issue", issue);
	const record = process.env.Z3_READINESS_RECORD;
	if (record && record.length > 0) args.push("--record", record);
	const base = process.env.Z3_READINESS_BASE;
	if (base && base.length > 0) args.push("--base", base);
	if (opts.requireEvidence) {
		args.push("--require-evidence");
		const ref = process.env.Z3_READINESS_REF;
		if (ref && ref.length > 0) args.push("--ref", ref);
	}
	return spawnSync(args, { cwd: root });
}
