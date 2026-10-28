# STEPS v2 — contracts-only deployment package

Deploy one new `StepsBranch` on Ethereum mainnet through IMD's official `launch.open` / `evm_contracts` flow. This does not migrate an existing ledger or publish a website.

## Constructor and authority

`StepsBranch(IIntake intake, address asset, uint256 price, address initialOwner)`

- Intake: `0xa43e6f75ee006411f79ac1c84120606c2330de82`
- Existing IMD token: `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`
- Price: `500000000000000000` atomic units (0.5 IMD)
- Initial owner: `$owner`, explicitly `0x0bced6bf6f6db1d7ac5bc0b540482d170a027352` in the request.

The owner may set a nonzero future price and transfer ownership in two steps. It cannot rewrite lineage, force a callback, seize balances, upgrade, or pause a branch. Factory deployment must not make the factory the owner. No post-deployment call or ETH value is required.

This package derives from the locally repaired v2 source (SHA-256 c8ecbc82b47b2ddf77989112997608e31e0ee37a1ebb016b527df21e7700ec39). Deployment-only differences are the explicit nonzero initial-owner argument, nonzero static address checks instead of constructor code-size probes (for empty-chain launch rehearsal), and IMD-required `bytecode_hash = "none"`. Public-chain code and address bindings must be verified before payment and after delivery. All runtime product behavior is preserved. This work includes local repairs; do not claim it was authored exclusively by IMD.

## Behavior to preserve

Only the configured same-chain Intake can settle a known request. The SDK rejects cross-chain `deliver` routing. Proposals commit the exact body and parent. Funding pulls exactly the current price under the funder's cap, uses the official tuple-shaped `requestWithFailure`, and clears temporary approval. Each logical branch permits one pending request. Forks create independent logical branch IDs, not successful checkpoints.

Proposal states: Draft=0, Pending=1, Succeeded=2, Refused=3, Failed=4, Expired=5. A valid success while Pending appends one immutable checkpoint. Authenticated refusal/no-result releases only its branch and invents no checkpoint or refund.

After seven days anyone may call `expirePending`; elapsed time alone does not change state. Expiry is local waiting policy, not IMD failure or cancellation. The first later authenticated outcome is recorded separately in `lateReceiptOf` and a late-outcome event. An expired proposal stays Expired; a late result never advances a head, adds a checkpoint, or unlocks a newer request. Check `received` before reading a late receipt's default status 0. Duplicate or conflicting outcomes cannot overwrite it.

Callbacks must fit a 200,000-gas stipend. URI bytes are emitted up to 2,048 bytes; longer locators remain hash-committed with `UriOmitted`. No manual result-binding authority exists. A failed/missing callback remains a separate monitoring concern from upstream completion.

Reference forks inherit exact recorded provenance. Snapshot forks also store at most 4 KiB of exact hash-verified result JSON, retrievable by `snapshotOf`. They do not copy referenced files. Fully nonzero 4 KiB storage costs about 3.02 million gas; larger results use reference forks. Result JSON is checked by keccak256; manifest-listed file bytes require SHA-256 and size checks. Lineage does not prove AI use of input sources.

## Reproducible checks

Build: Solidity 0.8.26, optimizer 200, Cancun, bytecode hash none, no via-IR or linked libraries. See `foundry.toml` and `launch.json`. `src/MockToken.sol` and test contracts are never deployment entries.

Run `forge test` and SDK tests with `node --test sdk/steps-branch-v2.test.mjs` after installing the SDK's declared dependencies. `sdk/local-integration.mjs` only targets an isolated Anvil at 127.0.0.1:18765 / chain 31337 and uses unlocked disposable accounts; it does not load wallet files. It runs separate cold transactions to verify callback gas, independent branch ordering, late outcome isolation and snapshot storage.

The committed ABI and compiler artifact are in `deployment/` (moved out of `artifacts/`, which can be the forge output directory and is wiped by a clean build). Reproduction results and the import-audit notes are in `evidence/LOCAL-REPRODUCTION.json` and `ADAPTATION.md`. Known property: branches are shared and permissionless, so any payer can occupy a branch's single pending slot. Contributors who need an uncontested line of work should `forkFromOrigin` or `fork` their own branch.

See `evidence/LOCAL-VALIDATION.json` for this exact source. Local evidence is not an external audit, a live paid-product acceptance, or deployment proof. IMD must audit imported code, perform only necessary packaging, rerun tests and independently review final source before its service deploys. Any substantive defect must block deployment and be reported rather than silently expanding scope.

Deliver the final immutable source, complete diff from input, constructor args, compiler settings, ABI/runtime hashes and immutable bindings, launch ID, contract address, deployment transaction/receipt, actual deployer/factory identity and official handoff. Keep unperformed checks NOT_RUN. All delivery documents must be English.
