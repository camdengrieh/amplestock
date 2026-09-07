# Audits

Phase 6 replaces an external audit with the Pashov Audit Group agent skills (user decision, 2026-09-05). Every report in this directory is produced by AI agents and is not a substitute for a human security review, a bug bounty or on-chain monitoring.

| Artifact | What it is |
|---|---|
| [`x-ray/x-ray.md`](x-ray/x-ray.md) | Pre-audit readiness report: protocol overview, threat and trust model, attack surfaces, test and documentation analysis, git history, verdict. |
| [`x-ray/entry-points.md`](x-ray/entry-points.md) | Every state-changing entry point with caller, parameters, call chain, state and value flow. |
| [`x-ray/invariants.md`](x-ray/invariants.md) | 53 enforced guards, 33 single-contract, 11 cross-contract and 7 economic invariants with on-chain / off-chain status. |
| [`x-ray/architecture.svg`](x-ray/architecture.svg) | Architecture diagram. |
| [`amplestock-pashov-ai-audit-report-20260907-045500.md`](amplestock-pashov-ai-audit-report-20260907-045500.md) | The twelve-agent `solidity-auditor` review of the pre-fix tree (`89e451d`): 20 findings, 34 leads. |
| [`fix-log.md`](fix-log.md) | Disposition of every finding and lead: fixed (commit, test), accepted with rationale, or deferred to a user decision. |

Re-running the skills: `/x-ray contracts/src`, `/solidity-auditor contracts/src`, `/fizz contracts` from the repository root with the skills vendored under `.claude/skills/`.
