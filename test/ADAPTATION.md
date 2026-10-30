# Profiles testing additions

This assignment changes only `test/`. Production contracts, constructor arguments, build configuration, and dependencies are unchanged. This file records the testing changes within the permitted paths; the earlier root `ADAPTATION.md` is unchanged.

- `ProfilesRules.t.sol`: all 256 input-byte classes for names and URL tails; name and skeleton length boundaries; all 17 reserved skeletons and their aliases; allowed prefixes/suffixes around reserved words; invalid lookups; full-width name round trips; host confusion; URL length and short/long storage boundaries. Name fuzzing runs 1,000 cases.
- `ProfilesBehavior.t.sol` and `mocks/ProfilesTestTokens.sol`: all 16 picture transitions; idempotent and caller-scoped clearing; zero/max token IDs; burns, remints, partial ERC-1155 transfers and approvals; failed-update rollback; exact event/tuple/error encodings; nonpayable entry points; every short return length; noncanonical booleans; zero/dirty owners; disappearing token code; successful responses with trailing data. Each new fuzz property runs 1,000 cases. The earlier gas-bomb/static-call tests remain in place.
- `ProfilesInvariant.t.sol`: four actors, eight known skeletons and alternate spellings, with independent records and token-holding models. Random actions include setting, clearing, invalid updates, transfers, delegation/revocation and time advancement. After every action, individual and batched reads must match the model, name reservations must agree with live records, and token holdings must remain external to Profiles. At the end of every sequence, every actor can clear and released names can be reclaimed. Inline configuration sets 256 runs of 100 calls with unexpected reverts failing the run. A deterministic scenario also exercises the handler's success and rejection paths.
- `fork/ProfilesFork.t.sol`: preserves the original integrations and changes their setup to `vm.envOr("MAINNET_RPC_URL", string(""))` and block `26305652`. Skipping occurs only when that variable is empty. Adds assertions for deployed dependency code and exact TextRules runtime equality; exercises wallet, collection and token delegation, revocation, scope/rights mismatch, NFT approval rejection, sale to a new owner and URL errors against mainnet state. Registry writes and token transfers occur only within the local fork.

Review covered `Profiles.sol`, its delegate-registry interface, and the `TextRules.checkScreenshotUrl` path and associated constants/errors. The supplied Pashov, x-ray, entry-point, invariant-discovery and property-testing guides informed a single-reviewer pass. Financial conservation, interest, oracle, governance, signature and upgrade properties do not apply to this contract; unrelated TextRules functions and the rest of the vault declarations were not audited. Profiles has no custody accounting, so the invariant suite targets identity state and ownership freshness. Accepted limitations, including first-come names and arbitrary conforming NFT contracts, remain accepted. No contract defect was reproduced; passing tests are not a proof of absence of defects.

All tests use the dependencies already present in `lib/`. No installation, downloaded dependency, submodule, FFI or RPC address is needed in this change. Fork configuration is supplied externally and is never changed by a test.

Validation commands (build products stay in disposable scratch space):

```sh
forge build --out test/scratch/out --cache-path test/scratch/cache
FOUNDRY_FUZZ_SEED=0xb5e6457a7b2bdc9c8bf4bc127c05a9c501b8ab2507684cc3ff36794560986624 forge test --out test/scratch/out --cache-path test/scratch/cache --no-storage-caching
env -u MAINNET_RPC_URL -u FORK_URL FOUNDRY_FUZZ_SEED=0xb5e6457a7b2bdc9c8bf4bc127c05a9c501b8ab2507684cc3ff36794560986624 forge test --out test/scratch/out --cache-path test/scratch/cache --no-storage-caching
```

The output/cache flags only redirect generated artifacts; fuzz and invariant run counts travel with the test sources. The suite also runs with the repository's ordinary `forge test` command. The pinned fork must be run with `MAINNET_RPC_URL` set before submission.

Local results with Foundry 1.8.3 and the required fuzz seed:

- `forge build`: successful, without compiler warnings.
- Whole suite with `MAINNET_RPC_URL` set: 84 passed, 0 failed, 0 skipped. All 10 fork tests reached Ethereum mainnet at block 26305652.
- Whole suite with both RPC variables absent: 74 passed, 0 failed; the fork suite skips in `setUp` (reported as one skipped test).
- Invariant campaign: 256 sequences, 25,600 random handler calls, zero unexpected reverts or discarded calls. All seven actions were exercised.
- Scope check: all six delivered files are under `test/`; no delivered source imports scratch files or changes shared environment variables.
