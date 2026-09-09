# Audits

Phase 6 replaces an external audit with the Pashov Audit Group agent skills (user decision, 2026-09-05). Every report in this directory is produced by AI agents and is not a substitute for a human security review, a bug bounty or on-chain monitoring.

| Artifact | What it is |
|---|---|
| [`x-ray/x-ray.md`](x-ray/x-ray.md) | Pre-audit readiness report over the revision-7 tree (`ccffe6c`, after both remediation waves): protocol overview, threat and trust model, attack surfaces, test and documentation analysis, git history, verdict. |
| [`x-ray/entry-points.md`](x-ray/entry-points.md) | Every state-changing entry point with caller, parameters, call chain, state and value flow. |
| [`x-ray/invariants.md`](x-ray/invariants.md) | 45 enforced guards, 22 single-contract, 9 cross-contract and 6 economic invariants with on-chain / off-chain status; the seed list for the fizz fuzz suite's properties. |
| [`x-ray/architecture.svg`](x-ray/architecture.svg), [`x-ray/architecture.json`](x-ray/architecture.json) | Architecture diagram and the contract graph it is drawn from. |
| [`amplestock-pashov-ai-audit-report-20260907-045500.md`](amplestock-pashov-ai-audit-report-20260907-045500.md) | The twelve-agent `solidity-auditor` review of the pre-fix tree (`89e451d`): 20 findings, 34 leads. |
| [`amplestock-pashov-ai-audit-report-20260907-133000.md`](amplestock-pashov-ai-audit-report-20260907-133000.md) | The re-audit: the same twelve agents over the ten files the first remediation changed (`bc0e6bb`), each verifying the fix it re-checked before hunting residuals: 13 findings (6 at or above the threshold), 23 leads. |
| [`fix-log.md`](fix-log.md) | Disposition of every finding and lead: fixed (commit, test), accepted with rationale, or deferred to a user decision. |

Re-running the skills: `/x-ray contracts/src`, `/solidity-auditor contracts/src`, `/fizz contracts` from the repository root with the skills vendored under `.claude/skills/`.
