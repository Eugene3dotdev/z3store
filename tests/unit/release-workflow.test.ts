import { describe, expect, test } from "bun:test";
import { join } from "node:path";
import { RELEASE_WORKFLOW_PATH } from "../../scripts/lib/release-manifest.ts";

type Step = {
	name?: string;
	if?: string;
	uses?: string;
	run?: string;
	with?: { install_args?: string };
};
type Workflow = { jobs: Record<string, { steps: Step[] }> };

const workflow = Bun.YAML.parse(
	await Bun.file(
		join(import.meta.dir, "..", "..", RELEASE_WORKFLOW_PATH),
	).text(),
) as Workflow;

function installsNu(step: Step): boolean {
	if (!step.uses?.startsWith("jdx/mise-action@")) return false;
	if (step.if !== undefined) return false;
	const args = step.with?.install_args;
	return args === undefined || args.split(/\s+/).includes("nu");
}

describe("release workflow", () => {
	// Every `run:` step is Nu, and Nu comes only from the mise install, which
	// reads its pin from the checked-out `.mise.toml`. A step that runs before
	// an unconditional install fails with a missing shell.
	test("no job runs a step before mise has installed Nu", () => {
		const early: string[] = [];
		for (const [id, job] of Object.entries(workflow.jobs)) {
			const installed = job.steps.findIndex(installsNu);
			const checkout = job.steps.findIndex((step) =>
				step.uses?.startsWith("actions/checkout@"),
			);
			if (installed !== -1 && (checkout === -1 || checkout > installed)) {
				early.push(`${id}: mise install without a checkout before it`);
			}
			job.steps.forEach((step, i) => {
				if (step.run === undefined) return;
				if (installed === -1 || i < installed) {
					early.push(`${id}: ${step.name}`);
				}
			});
		}
		expect(early).toEqual([]);
	});
});
