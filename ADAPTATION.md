# ADAPTATION — STEPS v2 StepsBranch, contracts-only launch on Ethereum (chainId 1)

Imported commit: `3962d42` ("Prepare STEPS v2 same-chain contracts for IMD deployment").
That commit already carried the requester's local user/assistant repairs (explicit `initialOwner`,
nonzero static address checks instead of code-size probes, `bytecode_hash = "none"`). That
provenance is kept as it was; this adaptation does not claim the source as IMD-authored.

## Summary

The contract source is **unchanged** (`src/StepsBranch.sol` SHA-256
`6451f1c4b42fdee696f10383caa411e1e3017438d43047607ce4b124ad5ec1a7`, the same value as
`evidence/LOCAL-VALIDATION.json`). It already met the `evm_contracts` launch rules: one contract,
a nonpayable constructor with four static arguments, no external calls or code checks in the
constructor, an explicit owner (never `msg.sender` or `tx.origin`), no proxy, initializer,
DELEGATECALL, CALLCODE, SELFDESTRUCT, mint, pause or seizure. `foundry.toml` and `launch.json` are
unchanged.

## Changes

| # | Change | Files | Why it was needed |
|---|--------|-------|-------------------|
| 1 | Moved the tracked, committed build outputs out of `artifacts/` (contents unchanged, byte-identical) | `artifacts/StepsBranch.abi.json` → `deployment/StepsBranch.abi.json`, `artifacts/StepsBranch.artifact.json` → `deployment/StepsBranch.artifact.json` | The previous attempt was rejected with "the build modified tracked files". In the verifying environment forge's output directory resolves to `artifacts/`, and a forced or clean build (`forge build --force`, `forge clean`) wipes that directory, deleting these two tracked files. Reproduced: before the move, `forge build --force` left `D artifacts/StepsBranch.abi.json` and `D artifacts/StepsBranch.artifact.json`; after it, the tree stays clean. |
| 2 | Added two tests reproducing the import audit's findings | `test/AuditFindings.t.sol` | The audit rules say every finding that reproduces gets a test. Both findings describe the supplied design, so the tests pin that behaviour rather than change it (see below). The 57 supplied tests are untouched. |
| 3 | Added reproduction evidence | `evidence/LOCAL-REPRODUCTION.json`, `evidence/LOCAL-INTEGRATION-REPRODUCED.json` | The brief asks for build settings, hashes, ABI and reproduced test, fuzz, SDK and cold-callback results. Deployment fields stay `NOT_AVAILABLE`, and paid live tests stay `NOT_RUN`. |
| 4 | Documentation | `ADAPTATION.md` (this file), `README.md` (artifact paths, audit notes) | Required by the task. |

The deployed bytecode is unchanged, since no Solidity under `src/` changed.

## Import audit findings

### 2ba0657b (low): anyone can take a shared branch's single pending slot. Reproduces; not fixed.

`propose` and `fundWithPayment` are permissionless, and branches have no creator. A payer can hold a
branch's single pending slot and, on success, append their own checkpoint, which leaves other
Drafts on that branch `StaleAnchor` for good. Reproduced by
`testAuditFindingSharedBranchCanBeTakenWithoutVictimLoss`. The victim is never charged:
`BranchBusy` and `StaleAnchor` revert before any token moves. The victim can still fund the same
body on its own `forkFromOrigin` branch. This is the supplied shared, append-only ledger design.
The brief says to "preserve existing price-only management … add no other authority", so adding
branch ownership would be a product change. **It was not fixed.** It is recorded as a known
griefing and liveness property for the requester to accept, or to change in a later product
revision.

### 561bdcd1 (info): the callback depends on the Intake's owner-settable `callbackGas` staying ≥ ~195k. Reproduces as a dependency; not a defect.

A read-only mainnet check on 2026-10-28 gave `callbackGas()` = 200000 on Intake
`0xa43e…de82`. The heaviest cold success path (first checkpoint, nonzero proposal id, 2048-byte
URI) used 192,259 gas, including mock overhead, on an isolated Anvil. That matches the supplied
evidence exactly. `testAuditFindingHeaviestFirstCheckpointFitsStipend` checks that path under the
200,000 stipend. `ACTION`, `intake` and `asset` are immutable by design: the brief allows
price-only management. **Nothing was changed.** It is a dependency to monitor: if the Intake
lowered `callbackGas` below ~195k, heavy first checkpoints would not be delivered, and the branch
would wait for `expirePending` (no funds at risk).

## Independent review of the final source (no new findings)

- Authority: only `setPrice` (nonzero) and the two-step `transferOwner`/`acceptOwner`. The owner
  cannot settle, rewrite lineage, move funds or pause.
- Payment: the exact `price` must be ≤ `maxPayment`. `transferFrom` pulls only from `msg.sender`,
  and the balance delta is checked. Approvals go 0 → amount → 0. After the request, the ledger's
  balance must return to its value before the pull. Everything is under a reentrancy guard. There
  is no ETH entry point.
- Callbacks: they require `msg.sender == intake`, a locally admitted request id that matches the
  proposal, Pending status with a consistent branch, or Expired status with no late receipt yet.
  Zero result hashes and failure statuses other than 1 or 2 are rejected. Late outcomes write only
  `lateReceiptOf` and the late events.
- Expiry needs an explicit transaction after 7 days. It releases only the local pending slot, with
  no refund, failure claim or checkpoint.
- Snapshots: at most 4096 bytes, and keccak256 must match the parent checkpoint's `resultHash`.
- The constructor has nonzero checks only and makes no external call, so it succeeds on an empty
  chain.

## Reproduced locally (evidence, not an external audit or mainnet acceptance)

- `forge build` and `forge test` with the project's configuration: 59/59 pass (57 supplied plus 2
  audit tests). Fuzzing ran 256 runs with
  `FOUNDRY_FUZZ_SEED=0x5a23f447b929a78f45b403ca4173b345b3f4fb4c8374df970311bf3091a512d2`.
- `forge build --force` leaves the git tree clean.
- SDK: `node --test sdk/steps-branch-v2.test.mjs` passes 16/16, with viem 2.57.7 installed outside
  the repository.
- `sdk/local-integration.mjs` on an isolated Anvil (chain 31337, disposable unlocked accounts) ran
  17 separate cold callback transactions under the real 200,000-gas stipend. All were delivered,
  with a maximum of 192,259. The 4 KiB snapshot copy used 3,021,993 gas. The run covered late
  success, refusal and failure while newer work was pending, and 2048-byte and 16384-byte URIs.
- Floor rehearsal: a CREATE2 deployment of the init code plus the manifest arguments on chainId 1,
  with no code at the intake or asset, succeeds. The owner is
  `0x0bced6bf6f6db1d7ac5bc0b540482d170a027352`, which is neither the factory nor `tx.origin`. The
  runtime is 11,460 bytes, and no DELEGATECALL, CALLCODE or SELFDESTRUCT is reachable.
- Read-only mainnet bindings: the Intake has code and exposes `requestWithFailure` (`0x9a78c321`),
  and `priceOf("job.open@job-1", IMD)` returns 500000000000000000. The asset reads `IMD` with 18
  decimals.

## Deployment evidence

This step does not deploy. The launch ID, contract address, deployment transaction, receipt and
block, outer sender, contract-creation caller, live readbacks and the official handoff are **not
available**. They come from IMD's launch after acceptance. Paid live product tests are `NOT_RUN`,
and `productionReady` is `false`.
