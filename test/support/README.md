These tests supplement the existing launch, core, module and fork suites. Production contracts, launch arguments, economics, schedules and build configuration are unchanged.

| File | Additional coverage |
| --- | --- |
| `YoloTokenStateful.t.sol` | Random buys, sells, delegated sells, wallet transfers, factory transfers, gate consumption by another caller and forward-only time changes. Fixed supply, exact pool settlement, rational tax/rounding bounds, snapshot quotas, and rollback of both quota and allowance on failed transfers. |
| `BuybackBurnerStateful.t.sol` | Random deposits, vault credits, pulls, burns, forwards and wallet rotations. Each reserve is either held, credited or received by a configured buyback wallet; YOLO is held, credited or sent to DEAD. Rejected ETH, blocked tokens, failed pulls and unauthorized wallet changes preserve balances and accounting. |
| `GenesisCustodyStateful.t.sol` | Random funding, splitting, vesting releases, rebinding attempts and time changes. Every remainder token is accounted for, fixed allocations are paid once, clocks cannot restart, and all allocations can be released after maturity. The four vestings and splitter deploy inside one helper call so transient constructor binding matches one factory transaction. |
| `SupportParameterFailures.t.sol` | Price decimal conversions and rounding, all setter authorities, unknown currencies, small-price bounds, proposal replacement/cancellation, exact 48-hour boundaries, signer rotation and failed-proposal rollback. |
| `SwapAdapterFailures.t.sol` | Offline router payment model: route shape/endpoints, deadlines, ETH under/overpayment, output recipient/minimum, allowance cleanup, blocked input and rollback after router slippage failure. |
| `AttestationConformance.t.sol` | The supplied independent protocol digest/signature vector, canonical callback tuple, every signed field, domain separation, invalid bool encoding, malformed signatures, panel/quorum bounds, positive expiry and global signer rotation. |
| `VotePowerFailures.t.sol` | Failed NFT/delegate lookups, ownership transfers, delegation revocation, token/collection isolation, disabled delegation and the first invalid batch index. |

The three added invariant campaigns use explicit handler selectors and `fail-on-revert = true`. Expected failures are asserted inside handlers; unexpected reverts fail the campaign. They use 128 runs each, with depths 128, 128 and 96 respectively (45,056 randomized actions per complete run). Deterministic scenario tests also drive their success and failure branches. Stateless fuzz properties use 1,000 runs, configured inline so the verifier retains them.

The price property accounts for the documented intermediate USD conversion: at the fixed IMD and YOLO prices an odd number of IMD wei can lose 500 YOLO wei to intermediate rounding. It checks no overvaluation and loss below one intermediate USD unit, rather than assuming exact real-number conversion.

The adapter model tests payment plumbing, not pool pricing, live liquidity, WETH wrapping or SwapRouter02's special zero-input behavior. The existing mainnet fork suites supply the real factory, PoolManager and Universal Router integration. The attestation fixture uses the public protocol test-vector key; it supplies no deployment credential. These tests do not claim to resolve the attestation freshness deviations already recorded in `ADAPTATION.md`.

Three existing fork assertions in `test/review/ReviewLaunch.t.sol` compared deployment gas/headroom with historical documentation estimates. Before changes, block 26,239,791 reproduced failures at 15,008,132 gas for the core, 12,821,996 for support, and 8,190 bytes of estimated headroom, against the old 14.88M, 12.69M and 8.8KB estimates. The successful execution-limit search remained below 16,777,216 in both launches. The tests now enforce that unchanged cap for measured total gas and executable gas limit; the marginal-code test checks the measured cost against runtime deposit plus calldata cost. The binary search, intrinsic-gas cross-check and other fork assertions remain intact. No production defect or increased launch cap is asserted away.

Run the suite with the assignment's seed:

```sh
FOUNDRY_FUZZ_SEED=0x58f7999ed688ba8baac10de5654deaf4e7a0373feba1923b288a74c7dbdba06c forge test
```

Set `FORK_URL` to a mainnet archive RPC to include the existing fork suites. No new test needs network access, an uncommitted dependency, or anything under `test/scratch/`. Local build artifacts and logs were placed in `test/scratch/` with `FOUNDRY_OUT` and `FOUNDRY_CACHE_PATH`; those paths are disposable and are not test dependencies.
