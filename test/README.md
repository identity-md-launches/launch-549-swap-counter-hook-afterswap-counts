The additional suites extend the existing hook, integration, and token tests. They use the production contracts and the repository's existing dependencies; no network, fork, environment mutation, or extra installation is required.

| Suite | Properties exercised |
| --- | --- |
| `SwapCounterHookEdgeCases.t.sol` | Exactly one event with the complete pool ID and updated counts; zero and maximum callback inputs; read-only count getters; caller and origin spoofing after existing activity; malformed and payable callback rejection; checked counter overflow and atomic rollback. |
| `SwapCounterBatch.t.sol` | Several swaps across hooked and hookless pools in one PoolManager unlock; counts and events per hooked swap; net token settlement; rollback of earlier swaps when the final swap or settlement fails; successful retry preserving previously committed counts. |
| `SwapCounterSequenceInvariant.t.sol` | Random real swaps through three routers, exact input/output and both directions, liquidity changes, and rejected swaps. Independent successful-call counts must match each sender and the total. A hookless pool receives the same successful operations and must match deltas, prices, ticks, liquidity, fees, fee growth, and LP proceeds. Token balances must conserve the initial supply. |
| `SwapCounterTokenInvariant.t.sol` | Four actors exchange the fixed supply through transfers and delegated transfers, change approvals, and attempt invalid operations. Independent balance and allowance models check conservation, exact movements, finite/infinite approvals, revocation, and failure atomicity. |

The sequence handler bounds swaps to 1 wei through 10 tokens and retains at least 100,000 units of liquidity, keeping generated successful operations executable. Its two invariants run over 128 sequences of up to 64 actions. The token handler runs 256 sequences of up to 32 actions. Both explicitly target only handler actions and fail on unexpected reverts. Deterministic sequences pin dust, full-supply transfers, self-transfers, and approval boundaries alongside random coverage.

Direct callback tests impersonate the trusted manager to isolate the observer from PoolManager's input validation. Their arbitrary keys and extreme swap values are callback ABI tests, not claims that such swaps are executable in a pool. The overflow tests seed otherwise impractical counter values through discovered storage slots; the real-swap suites do not alter hook storage or bypass constructor permission validation. `sender` is the router that calls PoolManager, not the payer encoded in hook data.

Run the complete checks while keeping generated artifacts in the disposable scratch directory:

```sh
forge build --out test/scratch/out --cache-path test/scratch/cache
forge test --out test/scratch/out --cache-path test/scratch/cache
```

The delivered tests have no dependency on anything in `test/scratch/` or `.imd/reads/`.
