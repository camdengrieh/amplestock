#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# The Amplestocks deployment pipeline, run for real against a local anvil with `forge script --broadcast`, and
# then run again to prove nothing moves.
#
# WHY THIS EXISTS
# ---------------
# `contracts/test/script/Phase3Scripts.t.sol` runs the same scripts inside `forge test`, which never broadcasts.
# That is exactly the blind spot that hid the nonce bug: under Foundry 1.8.1 a `vm.startBroadcast` window opened
# by a *helper contract* writes every transaction into `broadcast/…/run-latest.json` with the same nonce, and the
# run dies with "EOA nonce changed unexpectedly while sending transactions". Simulation is unaffected, so a
# Foundry-only harness cannot see it. This can: every transaction below is signed, sent and mined.
#
# It also exercises the two things a simulation cannot: the timelock relay (the bootstrap runs through a real
# `TimelockController` at zero delay, because the timelock address is an immutable constructor argument of the
# vault, the registry and the hook and cannot be an EOA on mainnet), and the chain's clock (the hub pool needs
# thirty minutes of observations before the gate goes GREEN, and the two genesis placement phases are sixty
# seconds apart).
#
# WHAT IT ASSERTS, with `cast`, against the chain the scripts left behind:
#   * 32 pools registered, 30 active constituents, 30 bond markets
#   * every vault pointer, the hook's fee policy, the hook's router pointer and the bonds' policy
#   * `OracleGate.state(0) == GREEN`
#   * `S0` = 5,000 AMPS, 250 to the team vesting wallet, NAV/share = $1.00 within 1%
#   * 328 live ladder cells (32 x 10 asks + 2 x 4 seed bids) and the §3.3 layout, via the script's own
#     `assertLayout`
#   * a second full pass registers nothing, deploys nothing (the AmpsRouter included) and moves no number
#   * `09_Phase3Wire` refuses to re-run after genesis (`AlreadyGenesis`), which is the wiring latch working
#   * `03_Core CORE_STAGE=finalize` raises the timelock to 48 h and drops the deployer's proposer role
#
# It is localhost-only: anvil, `forge`, `cast`. No RPC leaves the machine and it runs with the network down.
#
# USAGE
#   pnpm --filter @amplestocks/contracts broadcast-test
#   contracts/test/script/broadcast.sh              # same thing
#   BROADCAST_KEEP=1 contracts/test/script/broadcast.sh   # leave anvil up and the config files rewritten
set -euo pipefail

# ---------------------------------------------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------------------------------------------

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTRACTS="$(cd "$HERE/../.." && pwd)"
cd "$CONTRACTS"

export PATH="${FOUNDRY_BIN:-/root/.foundry/bin}:$PATH"
export FOUNDRY_OUT="${FOUNDRY_OUT:-out-broadcast}"
export FOUNDRY_CACHE_PATH="${FOUNDRY_CACHE_PATH:-cache-broadcast}"
export FOUNDRY_PROFILE=default

PORT="${BROADCAST_PORT:-8545}"
RPC="http://127.0.0.1:${PORT}"

# anvil's deterministic accounts. Account 0 is the deployer (and, until `finalize`, a timelock proposer);
# account 1 stands in for the 3/5 proposer Safe, account 2 for the 2/4 guardian Safe, account 3 for the creator.
DEPLOYER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
DEPLOYER_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
PROPOSER_SAFE=0x70997970C51812dc3A010C7d01b50e0d17dc79C8
GUARDIAN_SAFE=0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC
CREATOR=0x90F79bf6EB2c4f870365E785982E1f101E93b906

# 2026-09-09 14:00:00 UTC — a Wednesday, 10:00 ET on daylight time, squarely inside the REGULAR session. Every
# gated vault path refuses when the session is CLOSED, so the whole run happens on a live trading clock.
GENESIS_TIME=1788962400

# The launch seed: 1 WETH at the fixture's $2,500 plus 2,500 USDG, against S0 = 5,000 AMPS => NAV/share $1.00.
SEED_WETH=1000000000000000000
SEED_USDG=2500000000

TWAP_WINDOW=1800
PLACEMENT_COOLDOWN=60

STARTED_AT=$(date +%s)
STAGE_LOG=$(mktemp -d)/stages
: >"$STAGE_LOG"

CONFIG_DIR="$CONTRACTS/script/config"
BACKUP_DIR=$(mktemp -d)
LOG_DIR=$(mktemp -d)
LOG="$LOG_DIR/last.log"
ANVIL_PID=""

cleanup() {
  local status=$?
  if [ -n "$ANVIL_PID" ] && [ -z "${BROADCAST_KEEP:-}" ]; then kill -9 "$ANVIL_PID" 2>/dev/null || true; fi
  if [ -z "${BROADCAST_KEEP:-}" ]; then
    # The scripts rewrite committed artefacts under script/config by design, and 12_Verify writes a new
    # verify.sh. Put the originals back and delete anything that was not there before, so a run — passing or
    # failing — never leaves the working tree dirty.
    for f in "$CONFIG_DIR"/*; do
      [ -e "$BACKUP_DIR/$(basename "$f")" ] || rm -f "$f"
    done
    cp -a "$BACKUP_DIR"/. "$CONFIG_DIR"/ 2>/dev/null || true
  fi
  rm -rf "$BACKUP_DIR" "$LOG_DIR"
  if [ "$status" -eq 0 ]; then
    echo ""
    echo "=== broadcast test PASSED in $(( $(date +%s) - STARTED_AT ))s ==="
    cat "$STAGE_LOG"
  else
    echo ""
    echo "=== broadcast test FAILED (exit $status) after $(( $(date +%s) - STARTED_AT ))s ==="
    cat "$STAGE_LOG" 2>/dev/null || true
  fi
}
trap cleanup EXIT

say() { printf '\n\033[1m>>> %s\033[0m\n' "$*"; }
fail() { printf '\033[31mFAIL: %s\033[0m\n' "$*" >&2; exit 1; }

# `expect <what> <actual> <expected>`
expect() {
  if [ "$2" != "$3" ]; then fail "$1: expected '$3', got '$2'"; fi
  printf '  ok  %-46s %s\n' "$1" "$2"
}

json() { python3 -c "import json,sys;print(json.load(open(sys.argv[1]))$2)" "$1"; }

rpc() { cast rpc --rpc-url "$RPC" "$@" >/dev/null; }

# Advances the chain by `$1` seconds and mines a block, so the gate's layer-A watchdog sees a chain that kept
# running rather than a stalled sequencer.
advance() {
  rpc evm_increaseTime "$1"
  rpc evm_mine
}

# `stage <name> -- <forge script args...>`
stage() {
  local name="$1"; shift; shift
  local t0; t0=$(date +%s)
  say "$name"
  if ! forge script "$@" --rpc-url "$RPC" --broadcast --slow --private-key "$DEPLOYER_KEY" >"$LOG" 2>&1; then
    tail -80 "$LOG" >&2
    fail "$name"
  fi
  printf '  %-44s %ss\n' "$name" "$(( $(date +%s) - t0 ))" >>"$STAGE_LOG"
}

# `stage_readonly <name> -- <forge script args...>` — no key, no broadcast.
stage_readonly() {
  local name="$1"; shift; shift
  local t0; t0=$(date +%s)
  say "$name"
  if ! forge script "$@" --rpc-url "$RPC" >"$LOG" 2>&1; then
    tail -80 "$LOG" >&2
    fail "$name"
  fi
  printf '  %-44s %ss\n' "$name" "$(( $(date +%s) - t0 ))" >>"$STAGE_LOG"
}

# `expect_revert <name> <substring> -- <forge script args...>`
expect_revert() {
  local name="$1" needle="$2"; shift; shift; shift
  say "$name (must refuse)"
  if forge script "$@" --rpc-url "$RPC" --broadcast --slow --private-key "$DEPLOYER_KEY" >"$LOG" 2>&1; then
    fail "$name: expected a revert, the run succeeded"
  fi
  grep -Eq "$needle" "$LOG" || {
    tail -40 "$LOG" >&2
    fail "$name: expected '$needle' in the output"
  }
  printf '  ok  %-46s reverted with %s\n' "$name" "$needle"
}

# ---------------------------------------------------------------------------------------------------------------
# The environment every stage runs under
# ---------------------------------------------------------------------------------------------------------------

# Relay mode: the bootstrap goes through a real TimelockController at zero delay, signed by the deployer, which is
# the only shape a mainnet deployment can have (the timelock address is an immutable constructor argument).
export AMPS_GOV_RELAY=true
export AMPS_DEPLOYER="$DEPLOYER"
export AMPS_NETWORK=anvil
export CORE_PROPOSER_SAFE="$PROPOSER_SAFE"
export AMPS_GUARDIAN="$GUARDIAN_SAFE"
export AMPS_CREATOR="$CREATOR"
export AMPS_TEAM_BENEFICIARY="$CREATOR"
export AMPS_TEAM_VEST_START="$GENESIS_TIME"
export AMPS_SEED_WETH="$SEED_WETH"
export AMPS_SEED_USDG="$SEED_USDG"
# Two leading zero bytes, not three: 65k CREATE2 attempts instead of 16.7 million. Every counter asset here is an
# ordinary CREATE address, so two is more than enough for AMPS to be currency0, and `_assertOrdering` checks it
# rather than assuming it. Production mines three, off-chain, with script/mine-amps.py.
export AMPS_ZERO_BYTES=2
export TESTNET_DEPLOY_POOL_MANAGER=true
export PREFLIGHT_CHAIN_ID=46630
export PREFLIGHT_STRICT=false

# ---------------------------------------------------------------------------------------------------------------
# 0. Build once, back the config up, start anvil
# ---------------------------------------------------------------------------------------------------------------

command -v anvil >/dev/null || fail "anvil not on PATH (set FOUNDRY_BIN)"
cp -a "$CONFIG_DIR"/. "$BACKUP_DIR"/

say "forge build"
forge build >/dev/null

say "anvil on ${RPC} (chain 46630, t0 = ${GENESIS_TIME})"
anvil --port "$PORT" --host 127.0.0.1 --chain-id 46630 --timestamp "$GENESIS_TIME" --silent &
ANVIL_PID=$!
for _ in $(seq 1 60); do
  if cast block-number --rpc-url "$RPC" >/dev/null 2>&1; then break; fi
  sleep 0.5
done
cast block-number --rpc-url "$RPC" >/dev/null || fail "anvil did not come up"

# ---------------------------------------------------------------------------------------------------------------
# The pipeline
# ---------------------------------------------------------------------------------------------------------------

run_pipeline() {
  local pass="$1"

  # 00 — the read-only pre-flight. No key and no --broadcast: it has nothing to broadcast. Not strict here
  # either — the 4663 infrastructure addresses have no code on anvil, and that is the finding, not a failure.
  stage_readonly "pass ${pass}: 00_Preflight" -- script/00_Preflight.s.sol --tc Preflight

  # 02 — the four linked vault libraries, in the two passes the rollout library's own link reference forces.
  stage "pass ${pass}: 02_Libraries (pass 1)" -- script/02_Libraries.s.sol --tc Libraries
  PLACEMENT=$(json "$CONFIG_DIR/libraries.json" "['libraries']['VaultPlacementLib']['address']")
  export LIB_ROLLOUT_ONLY=true
  stage "pass ${pass}: 02_Libraries (pass 2)" -- script/02_Libraries.s.sol --tc Libraries \
    --libraries "src/vault/VaultPlacementLib.sol:VaultPlacementLib:${PLACEMENT}"
  unset LIB_ROLLOUT_ONLY
  read_library_flags

  # 10 assets-only — the mock counter assets and, on a bare chain, the v4 PoolManager. First, because
  # `PoolRegistry` takes WETH9 and USDG in its constructor.
  export TESTNET_ASSETS_ONLY=true
  stage "pass ${pass}: 10_TestnetPools (assets)" -- script/10_TestnetPools.s.sol --tc TestnetPools
  unset TESTNET_ASSETS_ONLY

  # 03 — the timelock, the token, the vault, the hook, the registry and the whole periphery.
  stage "pass ${pass}: 03_Core" -- script/03_Core.s.sol --tc Core $LIBRARY_FLAGS
  read_addresses

  # 05 through 10 — the 32 pools, with the vault's gate pointer still unset (phase2-state-model §9.1 step 2).
  stage "pass ${pass}: 10_TestnetPools (register)" -- script/10_TestnetPools.s.sol --tc TestnetPools $LIBRARY_FLAGS
}

read_library_flags() {
  LIBRARY_FLAGS=$(json "$CONFIG_DIR/libraries.json" "['librariesFlag']")
  [ -n "$LIBRARY_FLAGS" ] || fail "libraries.json carries no librariesFlag"
}

read_addresses() {
  TIMELOCK=$(json "$CONFIG_DIR/deployments.json" "['core']['timelock']")
  AMPS=$(json "$CONFIG_DIR/deployments.json" "['core']['amps']")
  VAULT=$(json "$CONFIG_DIR/deployments.json" "['core']['vault']")
  HOOK=$(json "$CONFIG_DIR/deployments.json" "['core']['hook']")
  REGISTRY=$(json "$CONFIG_DIR/deployments.json" "['core']['registry']")
  BONDS=$(json "$CONFIG_DIR/deployments.json" "['core']['bonds']")
  POT=$(json "$CONFIG_DIR/deployments.json" "['core']['bountyPot']")
  FEEDS=$(json "$CONFIG_DIR/deployments.json" "['core']['feedRegistry']")
  GATE=$(json "$CONFIG_DIR/deployments.json" "['core']['oracleGate']")
  VALUER=$(json "$CONFIG_DIR/deployments.json" "['core']['positionValuer']")
  LADDER_POLICY=$(json "$CONFIG_DIR/deployments.json" "['core']['ladderPolicy']")
  ROLLOUT_POLICY=$(json "$CONFIG_DIR/deployments.json" "['core']['rolloutPolicy']")
  FEE_POLICY=$(json "$CONFIG_DIR/deployments.json" "['core']['feePolicy']")
  BOND_POLICY=$(json "$CONFIG_DIR/deployments.json" "['core']['bondPolicy']")
  QUOTER=$(json "$CONFIG_DIR/deployments.json" "['core']['quoter']")
  ROUTER=$(json "$CONFIG_DIR/deployments.json" "['core']['router']")
  TEAM_VESTING=$(json "$CONFIG_DIR/deployments.json" "['core']['teamVestingWallet']")
  WETH9=$(json "$CONFIG_DIR/deployments.json" "['core']['weth9']")
  USDG=$(json "$CONFIG_DIR/deployments.json" "['core']['usdg']")
}

# `cast call` annotates large integers ("5000000000000000000000 [5e21]"), so keep the first field only. Every
# read below returns exactly one value.
call() { cast call --rpc-url "$RPC" "$@" | awk 'NR==1{print $1}'; }

# The whole chain state the idempotence check compares, as one string.
fingerprint() {
  printf '%s|%s|%s|%s|%s|%s|%s|%s|%s' \
    "$(call "$REGISTRY" 'poolCount()(uint16)')" \
    "$(call "$REGISTRY" 'activeConstituentCount()(uint16)')" \
    "$(call "$BONDS" 'marketCount()(uint16)')" \
    "$(call "$AMPS" 'totalSupply()(uint256)')" \
    "$(call "$VAULT" 'liveCells()(uint32)')" \
    "$(call "$VAULT" 'navPerShareX18()(uint256)')" \
    "$(call "$VAULT" 'oracleGate()(address)')" \
    "$(call "$HOOK" 'router()(address)')" \
    "$(cast to-check-sum-address "$VAULT")"
}

# ---------------------------------------------------------------------------------------------------------------
# Pass 1
# ---------------------------------------------------------------------------------------------------------------

run_pipeline 1

say "assert: 32 pools, 30 constituents, 30 bond markets, gate still unset"
expect "registry.poolCount" "$(call "$REGISTRY" 'poolCount()(uint16)')" "32"
expect "registry.activeConstituentCount" "$(call "$REGISTRY" 'activeConstituentCount()(uint16)')" "30"
expect "bonds.marketCount" "$(call "$BONDS" 'marketCount()(uint16)')" "30"
expect "vault.oracleGate (unset)" "$(call "$VAULT" 'oracleGate()(address)')" "0x0000000000000000000000000000000000000000"
expect "vault.registry" "$(call "$VAULT" 'registry()(address)')" "$(cast to-check-sum-address "$REGISTRY")"
expect "vault.bonds" "$(call "$VAULT" 'bonds()(address)')" "$(cast to-check-sum-address "$BONDS")"
expect "vault.bountyPot" "$(call "$VAULT" 'bountyPot()(address)')" "$(cast to-check-sum-address "$POT")"
expect "vault.feedRegistry" "$(call "$VAULT" 'feedRegistry()(address)')" "$(cast to-check-sum-address "$FEEDS")"
expect "vault.marketReference" "$(call "$VAULT" 'marketReference()(address)')" "$(cast to-check-sum-address "$HOOK")"
expect "vault.positionValuer" "$(call "$VAULT" 'positionValuer()(address)')" "$(cast to-check-sum-address "$VALUER")"
expect "amps.vault" "$(call "$AMPS" 'vault()(address)')" "$(cast to-check-sum-address "$VAULT")"
expect "hook.timelock" "$(call "$HOOK" 'timelock()(address)')" "$(cast to-check-sum-address "$TIMELOCK")"
[ "$(printf '%s' "$AMPS" | tr 'A-F' 'a-f')" \< "$(printf '%s' "$USDG" | tr 'A-F' 'a-f')" ] \
  || fail "AMPS does not sort below USDG"
[ "$(printf '%s' "$AMPS" | tr 'A-F' 'a-f')" \< "$(printf '%s' "$WETH9" | tr 'A-F' 'a-f')" ] \
  || fail "AMPS does not sort below WETH9"
printf '  ok  %-46s %s\n' "amps sorts below both entry counters" "$AMPS"

# §9.1 step 3: the hub's observation ring has to cover `twapWindow` before the gate can be pointed at.
say "advance the chain past twapWindow (${TWAP_WINDOW}s)"
HUB=$(call "$REGISTRY" 'hubPoolId()(bytes32)')
printf '  --  %-46s %s\n' "hub coverage before" "$(call "$HOOK" "observationCoverage(bytes32)(uint32)" "$HUB")"
advance $(( TWAP_WINDOW + 1 ))
COVERED=$(call "$HOOK" "observationCoverage(bytes32)(uint32)" "$HUB")
[ "$COVERED" -ge "$TWAP_WINDOW" ] || fail "hub coverage $COVERED < $TWAP_WINDOW"
printf '  ok  %-46s %s\n' "hub coverage after" "$COVERED"

# 09 — the Phase 3 pointer moves and the gate, in the §9.1 order. The gate was already deployed by 03_Core with
# the hook as its marketReference, so this run repoints rather than redeploys.
export WIRE_DIRECT=true WIRE_REDEPLOY_GATE=false
stage "pass 1: 09_Phase3Wire" -- script/09_Phase3Wire.s.sol --tc Phase3Wire $LIBRARY_FLAGS
read_addresses

say "assert: the seven pointer moves and a GREEN gate"
expect "vault.ladderPolicy" "$(call "$VAULT" 'ladderPolicy()(address)')" "$(cast to-check-sum-address "$LADDER_POLICY")"
expect "vault.rolloutPolicy" "$(call "$VAULT" 'rolloutPolicy()(address)')" "$(cast to-check-sum-address "$ROLLOUT_POLICY")"
expect "hook.feePolicy" "$(call "$HOOK" 'feePolicy()(address)')" "$(cast to-check-sum-address "$FEE_POLICY")"
expect "hook.router" "$(call "$HOOK" 'router()(address)')" "$(cast to-check-sum-address "$ROUTER")"
expect "bonds.policy" "$(call "$BONDS" 'policy()(address)')" "$(cast to-check-sum-address "$BOND_POLICY")"
expect "vault.oracleGate" "$(call "$VAULT" 'oracleGate()(address)')" "$(cast to-check-sum-address "$GATE")"
expect "feedRegistry.oracleGate" "$(call "$FEEDS" 'oracleGate()(address)')" "$(cast to-check-sum-address "$GATE")"
expect "gate.marketReference" "$(call "$GATE" 'marketReference()(address)')" "$(cast to-check-sum-address "$HOOK")"
expect "gate.state(0) == GREEN" "$(call "$GATE" 'state(uint16)(uint8)' 0)" "0"

# The founders' seed lives in the timelock, because `genesis()` pulls it from `msg.sender` and `msg.sender` is
# the timelock. On 4663 that is a transfer the Safe signs; here the mocks have an open mint.
say "fund the timelock with the launch seed"
cast send --rpc-url "$RPC" --private-key "$DEPLOYER_KEY" "$WETH9" "mint(address,uint256)" "$TIMELOCK" "$SEED_WETH" >/dev/null
cast send --rpc-url "$RPC" --private-key "$DEPLOYER_KEY" "$USDG" "mint(address,uint256)" "$TIMELOCK" "$SEED_USDG" >/dev/null

stage "pass 1: 11_GenesisPlacement (phase 1)" -- script/11_GenesisPlacement.s.sol --tc GenesisPlacement $LIBRARY_FLAGS

say "assert: S0 minted and an ask ladder in every pool"
expect "amps.totalSupply" "$(call "$AMPS" 'totalSupply()(uint256)')" "5000000000000000000000"
expect "team vesting balance" "$(call "$AMPS" 'balanceOf(address)(uint256)' "$TEAM_VESTING")" "250000000000000000000"
expect "vault.creator" "$(call "$VAULT" 'creator()(address)')" "$(cast to-check-sum-address "$CREATOR")"
expect "vault.liveCells (asks only)" "$(call "$VAULT" 'liveCells()(uint32)')" "320"
NAV=$(call "$VAULT" 'navPerShareX18()(uint256)')
[ "$NAV" -ge 990000000000000000 ] && [ "$NAV" -le 1010000000000000000 ] || fail "navPerShare $NAV is not \$1.00 +/- 1%"
printf '  ok  %-46s %s\n' "navPerShareX18 within 1% of \$1.00" "$NAV"

say "advance past the ${PLACEMENT_COOLDOWN}s per-pool placement cooldown"
advance $(( PLACEMENT_COOLDOWN + 1 ))
stage "pass 1: 11_GenesisPlacement (phase 2)" -- script/11_GenesisPlacement.s.sol --tc GenesisPlacement $LIBRARY_FLAGS

say "assert: the entry-pool seed bids and the section 3.3 layout"
expect "vault.liveCells (asks + seed bids)" "$(call "$VAULT" 'liveCells()(uint32)')" "328"

# 12 — the verification commands. Read-only: no key, no broadcast, no chain writes.
stage_readonly "pass 1: 12_Verify" -- script/12_Verify.s.sol --tc Verify
[ -s "$CONFIG_DIR/verify.sh" ] || fail "12_Verify wrote no verify.sh"
grep -q -- "--verifier blockscout" "$CONFIG_DIR/verify.sh" || fail "verify.sh has no blockscout commands"
grep -q -- "VaultNavLib.sol:VaultNavLib:" "$CONFIG_DIR/verify.sh" || fail "verify.sh does not pass --libraries"
VERIFY_COUNT=$(grep -c '^forge verify-contract' "$CONFIG_DIR/verify.sh")
[ "$VERIFY_COUNT" -ge 18 ] || fail "verify.sh names only $VERIFY_COUNT contracts"
printf '  ok  %-46s %s contracts\n' "verify.sh" "$VERIFY_COUNT"

BEFORE=$(fingerprint)
ROUTER_BEFORE="$ROUTER"

# ---------------------------------------------------------------------------------------------------------------
# Pass 2 — the same pipeline again, which must change nothing
# ---------------------------------------------------------------------------------------------------------------

run_pipeline 2

# 09 is the one step that is deliberately not repeatable: `genesis()` closed the wiring latch, and re-running the
# batch against a live vault would be a governance action, not a deployment step.
expect_revert "pass 2: 09_Phase3Wire" "AlreadyGenesis|0x035e4b00" -- script/09_Phase3Wire.s.sol --tc Phase3Wire \
  $LIBRARY_FLAGS
unset WIRE_DIRECT WIRE_REDEPLOY_GATE

# 11 with both phases complete walks every pool and re-asserts the §3.3 cell layout.
stage "pass 2: 11_GenesisPlacement (layout re-check)" -- script/11_GenesisPlacement.s.sol --tc GenesisPlacement \
  $LIBRARY_FLAGS

say "assert: the second pass moved nothing"
read_addresses
AFTER=$(fingerprint)
expect "chain fingerprint" "$AFTER" "$BEFORE"
expect "core.router (pass 2 deployed no new router)" "$ROUTER" "$ROUTER_BEFORE"
expect "registry.poolCount" "$(call "$REGISTRY" 'poolCount()(uint16)')" "32"
expect "vault.liveCells" "$(call "$VAULT" 'liveCells()(uint32)')" "328"
expect "amps.totalSupply" "$(call "$AMPS" 'totalSupply()(uint256)')" "5000000000000000000000"
expect "gate.state(0) == GREEN" "$(call "$GATE" 'state(uint16)(uint8)' 0)" "0"

# ---------------------------------------------------------------------------------------------------------------
# Hand-over
# ---------------------------------------------------------------------------------------------------------------

expect "timelock.minDelay before finalize" "$(call "$TIMELOCK" 'getMinDelay()(uint256)')" "0"
export CORE_STAGE=finalize
stage "03_Core (finalize)" -- script/03_Core.s.sol --tc Core $LIBRARY_FLAGS
unset CORE_STAGE
expect "timelock.minDelay after finalize" "$(call "$TIMELOCK" 'getMinDelay()(uint256)')" "172800"
PROPOSER_ROLE=0xb09aa5aeb3702cfd50b6b62bc4532604938f21248a27a1d5ca736082b6819cc1
CANCELLER_ROLE=0xfd643c72710c63c0180259aba6b2d05451e3591a24e58b62239378085726f783
expect "deployer is no longer a proposer" \
  "$(call "$TIMELOCK" 'hasRole(bytes32,address)(bool)' "$PROPOSER_ROLE" "$DEPLOYER")" "false"
expect "the Safe is still a proposer" \
  "$(call "$TIMELOCK" 'hasRole(bytes32,address)(bool)' "$PROPOSER_ROLE" "$PROPOSER_SAFE")" "true"
expect "the guardian is a canceller" \
  "$(call "$TIMELOCK" 'hasRole(bytes32,address)(bool)' "$CANCELLER_ROLE" "$GUARDIAN_SAFE")" "true"

# And the bootstrap relay is now closed: a script that tries to run through it says so instead of half-running.
# `TimelockNotBootstrappable` is declared in script/lib/Gov.sol; accept the decoded name or the raw selector,
# because whether solc lifts a library's errors into the using contract's ABI is a compiler detail, not a
# statement about the deployment.
expect_revert "post-finalize 10_TestnetPools" "TimelockNotBootstrappable|0xbbb95b56" -- \
  script/10_TestnetPools.s.sol --tc TestnetPools $LIBRARY_FLAGS
