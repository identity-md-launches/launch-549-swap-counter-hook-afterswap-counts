# Swap Counter

An immutable Uniswap v4 hook that counts `afterSwap` callbacks per sender and in
total, and emits one `SwapCounted` event per callback. It never transfers tokens,
returns a nonzero delta, overrides fees, or calls back into PoolManager.

## Build and test

Install Foundry and Solidity **0.8.26**, then run:

```sh
forge build
forge test
forge fmt --check
```

All Solidity dependencies are ordinary files in `lib/`; no dependency download is
needed. The compiler is pinned by version in `foundry.toml`, with Cancun EVM,
optimizer enabled at 200 runs, and metadata disabled. Tests require no RPC, keys,
environment variables, FFI, or filesystem cheatcode permissions. See
[DEPENDENCIES.md](DEPENDENCIES.md) for revisions and licenses.

## Contracts and semantics

`src/SwapCounterHook.sol:SwapCounterHook` takes one constructor argument,
`IPoolManager manager`. `poolManager()` exposes that immutable reference.

| Interface | Meaning |
| --- | --- |
| `swapCount(address sender)` | Number of callbacks attributed to this sender |
| `totalSwaps()` | Number of callbacks across all senders and pools using this instance |
| `SwapCounted(address indexed sender, bytes32 indexed poolId, uint256 senderCount, uint256 totalCount)` | Updated counts, with the v4 pool ID; the Solidity pool ID type is `PoolId` |
| `getHookPermissions()` | Only `beforeInitialize` and `afterSwap` enabled |

Counts start at zero. Every successful `afterSwap` adds exactly one to both
counters and returns `(IHooks.afterSwap.selector, 0)`. Exact input, exact output,
direction, trade size, and `hookData` do not affect counting. Counts represent
callbacks, not volume, unique traders, or economic activity: tiny swaps and a
successful callback with no token movement still count. If the surrounding
transaction later reverts (including failed settlement), increments and logs
revert with it. Checked `uint256` arithmetic rejects overflow instead of wrapping.

The `sender` is the direct caller of **PoolManager.swap**, usually a router.
Several users of one router share a counter. `msg.sender` in a hook callback is
PoolManager; neither `tx.origin` nor an address encoded in `hookData` is used.
Counts are global to a hook instance, including all pools that select it. There
is no pool allowlist, router allowlist, reset, enumeration, owner, pause, upgrade,
or withdrawal function. Pool IDs in events allow off-chain per-pool analysis.

The inherited BaseHook authenticates **every** callback against the immutable
manager. The initialization callback returns its selector without changing
counts. Disabled callbacks revert. Permission validation runs in the production
constructor and is never bypassed. All four return-delta permissions are false;
ordinary pool LP and protocol fees still apply. The only extra swap cost is gas
for counting and logging.

`src/SwapCounterToken.sol:SwapCounterToken` is the accompanying launch token:
**Swap Counter / SWAPC**, 18 decimals, exactly **1,000,000,000 tokens** (`10^27`
minor units), all minted to its immediate deployer. Its constructor has no
arguments. It uses OpenZeppelin ERC20 without mint, burn, ownership, fee, pause,
blocklist, or upgrade extensions. It does not interact with the hook.

## Design decisions

| Decision | Configuration |
| --- | --- |
| Hook type | General-purpose `BaseHook` |
| Permissions | `beforeInitialize = true`, `afterSwap = true`; all other 12 flags false |
| Utilities | No currency settler, safe casts, or transient hook state |
| Shares | None; the launch token is not a share token |
| Access | Immutable PoolManager-only callbacks; no administrator |
| Hook inputs | Only `IPoolManager`; no tunable parameters |

The launch initialization callback is deliberately enabled even though counting
does not need initialization state. A PoolManager expecting its selector cannot
initialize the predicted hook pool while that hook has no code. After deployment,
initialization is permissionless; this callback does not reserve a pool for any
particular creator.

## Deployment parameters and procedure

No transaction is broadcast by this project. The network's deployer is responsible
for chain selection, manager authentication, factory integration, and funding.

1. Select a chain supporting Cancun and its trusted Uniswap v4 PoolManager. Pass
   that address as the sole hook constructor argument. The constructor rejects
   addresses without code; this is a sanity check, **not** proof of authenticity.
   No manager or factory address is hardcoded. A downstream IMD manifest should
   represent this argument as `"$poolManager"`.
2. Use the exact compiled hook creation code followed by `abi.encode(manager)`.
   Mine a CREATE2 salt for the **actual deploying factory**, requiring
   `uint160(predictedAddress) & 0x3fff == 0x2040` (**8256**). This enables
   `BEFORE_INITIALIZE_FLAG | AFTER_SWAP_FLAG` only. Source, compiler settings,
   constructor arguments, and the deploying address all affect the result.
3. `script/FindHookSalt.s.sol` provides a read-only
   `run(address deployer, IPoolManager manager)` function returning the predicted
   address and salt, using the vendored HookMiner. Call it directly or simulate:

   ```sh
   forge script script/FindHookSalt.s.sol:FindHookSalt \
     --sig 'run(address,address)' <CREATE2_FACTORY> <POOL_MANAGER>
   ```

   Simulate against the target chain with `--rpc-url <RPC_URL>` to check code
   occupancy there. This helper never broadcasts or reads environment variables.
   HookMiner has a bounded search; failure means a new search range or deployer
   is needed, never relaxed permission bits. Independently recheck the computed
   address is unused before deployment.
4. Have the launch factory deploy the token and hook and initialize the pool
   atomically. The token's full supply belongs to that factory, which handles
   the launch allocation and liquidity. Choose sorted currencies, a valid static
   pool fee, tick spacing, initial `sqrtPriceX96`, liquidity amounts, and price
   limits. These are PoolManager/factory parameters, not hook constructor inputs.
   Local tests use a 0.3% fee, spacing 60, and initial price 1:1 solely as fixtures.
5. Verify deployed source, constructor arguments, manager, address bits,
   permissions, token supply, and initialized pool on the target chain. Perform
   the network's independent review and fork rehearsal before release.

The factory must implement compatible CREATE2 deployment; the salt finder is not
a launch factory. No chain, quote currency, initial price, liquidity allocation,
or funded wallet has been chosen by this assignment.

## Operations and security review

There are no keeper or administrator duties. Index `SwapCounted` logs with normal
chain reorganization handling and reconcile them with the views at the same
block. Routers remain responsible for swap limits and settlement. Do not use these
counts as authenticated human identities or as a Sybil-resistant reward measure.
Do not send assets to the hook: it has no recovery mechanism.

The local suite uses production bytecode deployed by CREATE2 and a real, locally
deployed PoolManager. It checks callback authentication, exact flags, selectors,
events, sender attribution, fuzzed callback inputs, fixed token supply and ERC20
failure paths. Integration tests exercise initialization, liquidity, both swap
directions and amount modes, multiple pools, failed settlement rollback, and
compare amounts and fees against an otherwise identical hookless pool.

Review against the supplied security checklist found no hook token handling,
external calls, unbounded callback loops, signatures, oracle dependence,
delegatecall, or administrative powers. Reentrancy guards and router trust lists
are unnecessary for this observational state update. Gas consumption includes
two persistent counters, so first-use swaps cost more than repeat swaps.

Local verification is not an external audit. Live-chain fork rehearsal, deployed
source verification, Slither/Mythril, and an independent production security
review are not claimed here and remain deployment responsibilities.
