# Cost Estimate

Model: **the subagent tier used for this run** ($15.00/M input, $75.00/M output list price)
Mode: **automatic**
Selected contracts: **9**
Selected functions: **40** — scale 1x (medium)

| Stage                              | Count | Input    | Output  | Cost     |
|------------------------------------|-------|----------|---------|----------|
| Protocol Analyzer (conditional)    |     1 |      50k |      8k |    $1.35 |
| Discovery agents                   |     5 |     400k |     60k |   $10.50 |
| Synthesizer                        |     1 |      50k |     12k |    $1.65 |
| Implementers                       |     2 |     120k |     30k |    $4.05 |
| Report Writer                      |     1 |      30k |      8k |    $1.05 |
| Orchestrator overhead              |     1 |     250k |     40k |    $6.75 |
| TOTAL                              |       |     900k |    158k |   $25.35 |

**Estimated total: $25.35** — expected range $17.75 – $38.03

These numbers are list-price estimates for the subagents and a rough orchestrator overhead share. Actual cost varies with: coverage-iteration cycles (Step 8), re-runs after compile errors, handler complexity, whether x-ray skipped the Protocol Analyzer, and prompt-cache hit rate. Treat this as a ballpark, not a commitment.
