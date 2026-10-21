# YOLO support launch adaptation

This deliverable describes the second of four moneycanbuy.fun launches: `custom_token` on Ethereum mainnet (chain ID 1), paired with IMD. It deploys YoloToken and exactly the eight support contracts in the requested order. The existing NftGate and YoloSplitter are the fixed dependencies from launch #2292. The core and module launches remain separate.

## Changes and scope

| File | Change | Reason |
| --- | --- | --- |
| `launch.json` | Added the custom-token manifest, fixed constructor arguments, eight ordered support contracts, IMD pool, exact economics and launch notes. | The assignment explicitly calls for this launch adaptation and names this file; its instructions override the background reference that normally defers manifest creation. |
| `ADAPTATION.md` | Added this review, the disposition of all seven imported audit entries, launch prerequisites and verification evidence. | Required audit and change record. |

No production Solidity or deployment script is changed. All constructor values, token properties, addresses, recipients, supply, shares, prices, bounds, timelocks, opening time and reviewed `slither-disable-next-line` comments are preserved. Existing build configuration, dependencies and tests are unchanged. Additional local checks live only in `test/scratch/`, which the assignment removes before submission.

The assignment specifically requires audit findings to be recorded **without code changes**. That restriction governs the imported audit's generic request to fix reproductions. Accordingly, reproduced observations below are notes and do not authorize changes to `src/` or `script/`.

## Launch configuration and constructor compatibility

- Token: `YoloToken`, name/symbol `YOLO`, 18 decimals, `1000000000000000000000000000` minor units. Its constructor mints the entire supply once to its caller, the factory. It exposes no owner, mint, burn, pause or mutable trading list.
- Constructor: `$poolManager`, `0x97C8Fe82527F1a65A147bB0b425C717E4EC547C2`, `0x3c587Eff6c96eAcF7E3dcC2CFf6416161386E48C`, `1792584000`.
- Economics: `poolBps = 1500`, `initialMarketCapWei = "15000000000000000000000"`, `remainderTo = "0xf165884070b1a1e571f4a3b50fd727fe8380bee4"`. The allocation is 100 million YOLO to the factory's swarm distributor, 150 million to seed the pool, and 750 million to the splitter, subject only to the factory's existing seed rounding. No swarm address or extra token allocation is introduced.
- Pool: IMD `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`, fee `12500`, tick spacing `60`, manifest initial price `"79228162514264337593543950336"`. That price is the required provenance value; the actual opening price is derived by the deployer from supply, token sorting and the 15,000 IMD market cap.

| Order | Contract | Constructor ABI | Initial authority |
| --- | --- | --- | --- |
| Token | YoloToken | address, address, address, uint256 | No owner; launcher exemption is the deploying factory |
| 1 | DevPrices | four addresses, three uint256 | `0x8Ad18E99F4C8d8406f9Ba8899CF308000518A981` |
| 2 | UniswapV3SwapAdapter | two addresses | None |
| 3 | ParamsRegistry | eight addresses | `0x3c587Eff6c96eAcF7E3dcC2CFf6416161386E48C` |
| 4 | TextRules | none | None |
| 5 | SwarmQuestionBuilder | none | None |
| 6 | VotePower | two addresses | None |
| 7 | AttestationChecker | one address | None; reads ParamsRegistry |
| 8 | BuybackBurner | five addresses | DevPrices owner can change only its buyback-wallet setting |

All nine constructors are nonpayable and fully configure their contracts without an external call or initialization transaction. `gate.code.length` is a code-existence inspection, not a call; the gate's absence permanently selects the plain ERC-20 behavior required by the empty-chain floor. Names are unique Solidity identifiers of at most 32 characters; argument counts are at most 16. `$contract:` references point only to earlier entries. Library calls are internal and require no deployed or linked library.

## Opening deadline and current dependency state

`openAt` stays **1792584000, 21 October 2026 at 12:00:00 UTC**. The observed mainnet block 26,239,071 has timestamp **1792562819, 06:06:59 UTC**, so the fixed input was still deployable, about 5 hours 53 minutes before opening. There is no demonstrated need to exercise the brief's exception.

With gate code present, the constructor accepts deployment at `openAt` itself and reverts `BadOpenAt(openAt)` at any later timestamp. Operationally the launch should land before noon. If that becomes impossible, the brief allows only moving this manifest argument later, no later than **1792594800, 15:00:00 UTC**; after that ceiling the job must fail. This review neither promises a mining time nor changes the immutable schedule.

At block **26,239,071**, hash `0x49e1ed1a43614f63c914669fbeb91e1f29c55b951bda32753b6bfe33e9854acd`, the fixed gate returned:

| Read | Value |
| --- | --- |
| `writer()` | `0x3c587eff6c96eacf7e3dcc2cff6416161386e48c` |
| `nft()` | `0x0000ec93127baa929e58e97dd0095a2bfb38ec1d` |
| `sealedAt()` | `1792560251` (05:24:11 UTC), strictly before `openAt` |
| `walletCount()` | `794` |
| `totalNfts()` | `2000` |
| `snapshotBlock()` | `26234580` |

The gate has 1,916 runtime bytes; the imported report's 3,835-byte statement appears to count hexadecimal text rather than decoded bytes. The fixed splitter, Intake v2, NFT, delegate.xyz v2 registry, SwapRouter02, WETH, USDC, IMD and PoolManager all had code at that block. The token `symbol()` reads returned WETH, USDC and IMD respectively. These are dated chain observations, not changes to any address. The snapshot's complete wallet-by-wallet accuracy was not independently reconstructed.

## Disposition of the imported audit

### 1. Medium — fixed opening deadline

ID: `00298ce586953504f0263759584a998fe1f383a2354ea62600a45c97219332e4`

Location: `src/token/YoloToken.sol:77`, constructor, especially the deployment-window check at line 80.

**Reproduced as an input deadline, not a code defect.** With code at the fixed gate address, deployment using `1792584000` succeeds at timestamp `1792584000` and reverts `BadOpenAt(1792584000)` at `1792584001`. The factory cannot finish a launch whose token constructor reverts. The snapshot deadline is stricter: its seal must precede `openAt`, rather than merely equal it.

Evidence: the existing `test_OpenAtBounds` and `test_GateCode_ScheduleAsBefore`; local reproduction `test_ImportedOpeningDeadlineExactAndOneSecondLate` uses the fixed manifest timestamp. The live chain observation above establishes that the deadline had not elapsed. Disposition: preserve the fixed argument and record the mining deadline; no token change or unconditional postponement.

### 2. Medium — unsealed gate prevents first-window buys

ID: `df7a4cab38219be52eda9fc1099b703689f1ce26c0b7502be80c7eae9353bb37`

Location: `src/token/YoloToken.sol:158`, `_update`; `src/token/NftGate.sol:86`, `seal`.

**Historical state reproduced; current operational condition resolved.** Archive reads at the reported block 26,238,804 (timestamp `1792559603`) reproduce `sealedAt = walletCount = totalNfts = snapshotBlock = 0`. Newer reads show the irreversible seal at `1792560251`, 794 wallets and 2,000 NFTs. This is strictly before noon; the imported statement that the live gate remains unsealed is stale.

The underlying behavior remains intentional: an unsealed gate, or one sealed at `openAt` or later, causes every nonexempt nonzero buy during the first 1,800 seconds to revert `SnapshotNotSealed`. An empty snapshot cannot be sealed. At `openAt + 1800`, a 100 YOLO buy succeeds with 70 to the buyer and 30 to the treasury regardless of that seal. Existing tests `test_UnsealedSnapshot_WindowClosedToAll` and `test_SealAtOpenAtDoesNotCount` cover this; `test_ImportedUnsealedAndLateSnapshot` reproduces it using the fixed addresses and timestamp. Disposition: note the resolved live precondition and keep the gate and schedule unchanged. No snapshot transactions were sent.

### 3. Low — protocol price differs from the pool's opening valuation

ID: `0e9eb5d5782fbaefc843f79d5b177f5825531de276de626a1ea7591f4f5fa6b2`

Locations: `script/LaunchPlan.sol:74`, `YOLO_PRICE_USD`; `src/DevPrices.sol:123`, `yoloValue`; `src/desks/CaseDesk.sol:519`, `_stakeBps`.

**Arithmetic reproduced; fixed economics retained.** The implied initial dollar price is `15,000 IMD * $5.5 / 1,000,000,000 YOLO = $0.0000825`, whereas DevPrices starts at `$0.001`: a ratio of about 12.1212. DevPrices values a 100 USDC reward at 100,000 YOLO. A 100,000 YOLO lock for 52 weeks, established before submission and with no add-on, therefore earns the maximum 400-bps bonus; at the pool-implied price its value is $8.25 and the same ratio would yield 33 bps. The lock term matters: a shorter lock has less power.

Evidence: `test_ImportedStartingPriceMismatchAndTenfoldGuard` and `test_ImportedPriceDifferenceSizesActualStakeBonus`. A direct setter move from `1e15` to `82500000000000` reverts `PriceSanity`; the owner could make that hypothetical change through `100000000000000` in two calls. These are reproduction values, not proposed launch arguments or authorized live changes. The manual-price trust assumption is accepted by the brief. This changes bonus sizing, not the winner, reward principal or refund entitlement. Disposition: note only; preserve all initial prices and market-cap inputs.

### 4. Low — attestation freshness differs from the supplied verifier

ID: `c3895e1717dc52293c716b8e3056a8a89232ff6f85d891b9ee0d5a562399f1cd`

Location: `src/helpers/AttestationChecker.sol:43`, `check`, especially line 54.

**Reproduced, conditional on a trusted attester signing the message.** A correctly signed bool attestation with panel/quorum/agreed `7/5/5`, `issuedAt = 1792559603` and `expiresAt = 0` returns code 0 at timestamp `1900000000`. Giving it an already elapsed nonzero expiry returns code 6. A correctly signed message issued one day in the future is also accepted. The supplied `OracleAttestationConsumer._verifyAttestation` rejects both zero expiry at positive timestamps and issue times more than five minutes ahead.

Evidence: `test_ImportedZeroExpiryAcceptedButPositiveExpiredRejected` and `test_ImportedFutureIssuedAtAccepted`. The protocol's fixed EIP-712 vector also checks the project's digest independently of a self-generated signature (`test_ProtocolDigestConformance`). The launch's requested `validForSeconds = 2592000` normally gives a nonzero expiry; an untrusted caller cannot forge the signature.

Scope correction: the TaskVault callback accepts only its recorded Intake and an unanswered Intake request. It marks that request answered; it does not globally consume the attestation's separate oracle UUID. Answer-to-question pairing is the documented Intake trust assumption. Later core state-machine deadlines further constrain whether a delivered answer can affect settlement; checker acceptance alone is not proof of an indefinitely delayed payout exploit.

Disposition: retain as a note under the explicit no-source-change instruction. If separately authorized, parity would require removing the zero-expiry exemption and checking future `issuedAt`, with callback regression tests. No such change is made here.

### 5. Low — zero-input adapter uses the router's own balance

ID: `57ad838102c0f63bc8b8d0b6651a937b37f2aefc17848740c1e21fa0edff897f`

Locations: `src/adapters/UniswapV3SwapAdapter.sol:43`, `swapExactIn`; `src/TaskVault.sol:774`, `_collectImd`.

**Adapter behavior reproduced conditionally; claimed TaskVault path rejected.** SwapRouter02 treats zero `amountIn` as its entire input-token balance and makes itself the payer. This is explicit in Uniswap's [V3SwapRouter.exactInput](https://github.com/Uniswap/swap-router-contracts/blob/main/contracts/V3SwapRouter.sol) and [Constants.CONTRACT_BALANCE](https://github.com/Uniswap/swap-router-contracts/blob/main/contracts/libraries/Constants.sol). The adapter forwards zero unchanged. With 100 USDC placed in the router on a local mainnet fork, a caller with no USDC balance or adapter allowance can receive IMD through the USDC/IMD 0.3% path. The real router, tokens and pool are used; the 100 USDC precondition is supplied locally. At the recorded live block the router's actual USDC balance was **zero**, so the imported assertion about existing dust was not reproduced.

The report's suggested bond-payment path is interrupted at `_collectImd`: `payIn.amountIn == 0` directly pulls the required IMD from the payer and returns before the adapter branch. `test_ImportedZeroInputCannotFundBondFromRouterDust` makes any adapter call revert, confirms the 0.5 IMD bond is still collected from the payer, and confirms missing IMD approval causes failure. Thus zero-input adapter semantics do not bypass the vault's bond collection through that claimed route.

Evidence: `test_ImportedZeroInputRouterDustConditionalReproduction` and the vault test above. Router dust is already permissionlessly accessible through the router itself; no protocol-held router balance was identified. Disposition: note the conditional adapter behavior and reject the vault impact. A separately authorized zero-input guard would remove the adapter quirk; the adapter is unchanged here.

### 6. Informational — burner pull can call a foreign withdraw implementation

ID: `c04cf54b770168fd3c59bc19e494b238e3d1edcaaa1e9661756b8e448a644efe`

Location: `src/BuybackBurner.sol:123`, `pull`.

**Call-context observation reproduced; no loss demonstrated.** Any caller can supply a contract implementing `withdraw(address)`; that contract sees the burner as `msg.sender` and receives the supplied token argument. `test_ImportedPullCallsForeignCodeAsBurner` records both. The call sends no ETH, has a fixed selector and one address argument, is an ordinary CALL, and the burner grants no token approvals. Its own `forward` and `burnYolo` still select only their defined destinations.

Disposition: informational note only. Future integrations must not grant privileges merely because the caller is this burner. A vault restriction would need a different deployment/interface design because the vault is deployed later; it is not added.

### 7. Informational — coverage, trust and launch-rule record

ID: `5223bb34f287538f661ab537438ff9f4fae191a33cc94e9aa5764f0f961e9df2`

**Revalidated as coverage metadata, not a defect.** Reviewed in full: YoloToken, the eight support contracts, NftGate, YoloSplitter, VaultParams, OracleAttestation, their relevant interfaces, and the launch plan. Followed the later core's stake-bonus, IMD-collection and attestation-callback paths to validate reported cross-contract consequences, with the lock-power implementation as supporting context. Read the supplied protected custom-token tests, audit references, README, tokenomics and relevant mechanics/tests. Checked the inherited OpenZeppelin ERC-20, two-step ownership and SafeERC20 behavior.

The review covered applicable arithmetic/precision, access control, economics, execution trace, invariants, periphery, first principles, symmetry, boundary, numerical-gap, trust-gap and flow-gap checks in one review. No independent-agent review is claimed. Lending, share-vault, bridge and proxy-specific mechanisms are absent from this launch. Slither/Mythril were not run. The complete core, later modules, vestings, frontend and off-chain oracle operator are not newly audited here. Running their existing tests is not a claim of complete manual coverage.

No additional critical or high defect was reproduced in the support-launch scope. Known limitations in the brief/docs remain accepted design rules, including ERC-6909 claim bypasses, taxed liquidity deposits, pools outside v4, router minimum-output timing, whole-balance sells during the tax window and router-first buys during the snapshot window.

## Entry points, authorities and invariants checked

| Surface | Caller/guard | Effect and invariant |
| --- | --- | --- |
| YoloToken `transfer`, `transferFrom`, `approve` | Holder or approved spender under inherited ERC-20 checks | Fixed supply; exact launch transfers; wallet transfers untaxed; only PoolManager boundaries invoke the fixed schedule |
| DevPrices three setters | `onlyOwner` | Nonzero manual price, at most 10x per call, event; no fund transfer |
| DevPrices/ParamsRegistry ownership functions | Owner initiates/renounces; pending owner accepts | Two-step handover; no factory/IMD ownership assigned by constructors |
| ParamsRegistry propose/cancel parameters or attesters | `onlyOwner` | Compiled bounds for parameters; pending changes cannot activate before 48 hours |
| ParamsRegistry activate/execute | Anyone after the recorded ETA | Append-only parameter versions; attester set is global; removal of the last listed attester reverts |
| ParamsRegistry `setNewTasksPaused` | `onlyOwner`, immediate by design | Controls new tasks only; no token pause or deposited-balance control |
| Adapter `swapExactIn` | Anyone; deadline, value and path endpoint checks | Caller funds input, router receives exact approval then allowance is cleared; recipient/minimum are caller-supplied |
| Burner `receive`, `burnYolo`, `forward`, `pull` | Anyone | YOLO only to DEAD; supported reserves only to configured buyback wallet; no caller reward; foreign-call caveat above |
| Burner `setBuybackWallet` | Caller equals live DevPrices owner; nonzero wallet | Emits event; initial wallet remains `0x027e55f01e8cf808e5d2a2ad68e5e7f67fd6df6e` |
| TextRules, SwarmQuestionBuilder, VotePower, AttestationChecker | Public pure/view methods | No mutable admin or user-fund custody; external reads and signature checks are scoped to supplied inputs |
| Existing NftGate `record`, `seal`, `consume` | Immutable writer before seal; `consume` books by calling token | Immutable sealed list; one token cannot consume another's allowance |

Tax math matches the brief: for elapsed seconds `e` in `[1800,3600)`, buy tax is `amount * 3000 * (3600-e) / 18000000`, rounded down. Sell tax on the amount delivered to the pool is `amount * num / (18000000-num)`, where `num = 5400000` before minute 30 and `3000*(3600-e)` until minute 60. Thus 70 YOLO delivered to the pool costs 30 more at 30%; the pool's settlement is not shorted. From minute 60 the tax numerator is zero. Supply-sized amounts cannot overflow these products. Gate consumption is reverted atomically if the later transfer fails.

The dev wallet's manual prices, cancellation authority in the later core, buyback-wallet setting, the treasury's bounded/timelocked registry control, its immediate new-task pause, global signer rotation and the Intake's answer-pairing role are trust assumptions required by the project, not permission-bypass findings.

## Verification

All Foundry runs used the requested fuzz seed:

```text
0x58f7999ed688ba8baac10de5654deaf4e7a0373feba1923b288a74c7dbdba06c
```

The existing compiler, optimizer, EVM target, dependency tree and test settings were used unchanged. The initial `forge build` passed. With no fork URL, `forge test` passed **698 tests, zero failures, four skips**: the original 688 passing tests plus ten passing scratch checks; the fork-only suites skip in their setup. These checks include empty-chain deployment of the manifest, byte-for-byte comparison of its resolved constructor arguments with LaunchPlan, fixed opening-time boundaries, the imported audit reproductions, and the independent oracle digest vector.

With `FORK_URL` set to a mainnet archive RPC, the complete suite ran **711 tests: 708 passed, three failed, zero skipped**. Both original `LaunchRehearsalForkTest` tests passed. They exercise all four launches, their gas caps, first-hour Universal Router trades and exact tax boundaries, task lifecycles, factory fee collection, swarm claims/sells, and the burner's ETH/USDC/IMD forwarding. The two additional fork checks passed: deployment from this manifest's fixed addresses and noon opening time against the already sealed gate, followed by first-hour buys; and the conditional zero-input router-dust reproduction. The scratch subclass also runs the two inherited rehearsal tests.

A focused repeat pinned to block **26,239,145** reproduced the same three estimate failures and passed all six rehearsal/manifest fork tests. Measured totals include execution and intrinsic calldata gas, with the calldata floor applied by the existing harness:

| Fork deployment | Total gas | Below 16,777,216 |
| --- | ---: | ---: |
| Original rehearsal: genesis | 3,560,707 | Yes |
| Original rehearsal: YOLO and support | 12,821,449 | Yes |
| Original rehearsal: core | 15,008,483 | Yes |
| Original rehearsal: modules | 9,333,393 | Yes |
| Additional check: this fixed manifest's YOLO and support | 12,752,226 | Yes |

The fixed-manifest measurement uses the existing gate/splitter, actual constructor wallets, and an empty optional source-repository metadata field. Transaction metadata, address sorting, state warmth and seed rounding can change the final gas; this is a fork measurement, not a mined receipt. The original rehearsal uses its own test wallets and deploys a fresh gate/splitter. In the router-dust reproduction, 100 USDC supplied only on the fork produced `16610719118840218453` minor units of IMD; observed preexisting router USDC was zero.

Commands used (the public archive endpoint was `https://mainnet.gateway.tenderly.co`; each command had the seed above set as `FOUNDRY_FUZZ_SEED`):

```sh
forge build
forge test
FORK_URL=https://mainnet.gateway.tenderly.co forge test --no-storage-caching
forge test --match-contract '^(ReviewLaunchFork|LaunchRehearsalForkTest|ManifestForkEvidence)$' \
  --fork-url https://mainnet.gateway.tenderly.co --fork-block-number 26239145 \
  --no-storage-caching -vv
```

### Additional validation note — existing gas-estimate assertions fail

The full fork run is **not an all-pass result**. At block 26,239,145, three unchanged tests in `test/review/ReviewLaunch.t.sol` failed their comparisons with historical documentation estimates:

| Test and assertion | Expected | Observed |
| --- | --- | --- |
| `test_F1_core_realGas_vs_rehearsal`, line 505 | 14,880,000 gas, within 0.5% | 15,008,168; deviation 0.8613% |
| `test_F1b_support_realGas_vs_rehearsal`, line 521 | 12,690,000 gas, within 0.5% | 12,816,842; deviation 0.9995% |
| `test_F2_marginalGasPerRuntimeByte`, line 560 | 8,800 additional bytes, within 300 | 8,190; difference 610 |

These are gas-estimate regression failures, not a reproduced failure to fit the 16,777,216 transaction gas cap. The first two tests successfully deploy and search for a working gas limit below that cap before reaching the failing estimate assertion. The third fails a derived estimate of room for hypothetical additional code. This review does not establish the historical cause of the estimate drift. The tests construct launches directly from the unchanged Solidity plan; they do not read either deliverable file. No estimate, threshold, source or test was changed to obtain a pass. Updating these existing tests or their documentation is outside the explicit two-file adaptation scope; the failures are recorded for the final reviewer.

### Manifest and preservation checks

The manifest was parsed and checked against the brief, compiled constructor ABIs and the ordered LaunchPlan support deployment. Every constructor is static/nonpayable, every reference resolves to an earlier deployment, and every creation/runtime artifact has no unresolved library reference. Runtime sizes in bytes are: YoloToken 4,526; DevPrices 2,467; UniswapV3SwapAdapter 1,673; ParamsRegistry 13,552; TextRules 5,249; SwarmQuestionBuilder 5,506; VotePower 942; AttestationChecker 2,125; BuybackBurner 2,614. All are below 24,576 bytes.

SHA-256 comparisons confirmed all 1,864 original files captured under source, scripts, tests, vendored libraries and protected build/dependency files remain unchanged. The supplied protected floor tests were read for their requirements; their separate protocol harness was not executed here. Empty-chain scratch deployment and the live-factory fork tests provide the local compatibility evidence, without claiming to replace the verifier's protected checks. Scratch tests and generated helpers are local verification scaffolding and are removed by the assignment before submission. No live deployment, transaction signing or contract configuration was performed.
