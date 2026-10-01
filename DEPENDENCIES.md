# Vendored dependencies

The files in `lib/` are ordinary source files. No installation, submodule checkout,
network access, or package manager is needed to build and test this project once
Foundry and the pinned Solidity compiler are available.

| Directory | Upstream revision | Included files |
| --- | --- | --- |
| `lib/v4-core` | [Uniswap/v4-core `46c6834698c48bc4a463a86d8420f4eb1d7f3b75`](https://github.com/Uniswap/v4-core/tree/46c6834698c48bc4a463a86d8420f4eb1d7f3b75) | `src/`, `test/utils/{Constants,CurrencySettler,LiquidityAmounts}.sol`, licenses |
| `lib/v4-periphery` | [Uniswap/v4-periphery `444c526b77d804590f0d7bc5a481af5a3277c952`](https://github.com/Uniswap/v4-periphery/tree/444c526b77d804590f0d7bc5a481af5a3277c952) | `BaseHook`, `HookMiner`, `ImmutableState`, `IImmutableState`, license |
| `lib/forge-std` | [foundry-rs/forge-std v1.9.7, `77041d2ce690e692d6e03cc812b57d1ddaa4d505`](https://github.com/foundry-rs/forge-std/tree/77041d2ce690e692d6e03cc812b57d1ddaa4d505) | `src/`, licenses |
| `lib/openzeppelin-contracts` | [OpenZeppelin/openzeppelin-contracts v5.1.0, `69c8def5f222ff96f2b5beff05dfba996368aa79`](https://github.com/OpenZeppelin/openzeppelin-contracts/tree/69c8def5f222ff96f2b5beff05dfba996368aa79) | ERC-20 and its import closure, `Proxy.sol` used by upstream test helpers, license |
| `lib/solmate` | [transmissions11/solmate `4b47a19038b798b4a33d9749d25e570443520647`](https://github.com/transmissions11/solmate/tree/4b47a19038b798b4a33d9749d25e570443520647) | `Owned`, `ERC20`, `MockERC20`, license |

Sources were downloaded from the official GitHub repositories at the immutable
revisions above. Files are unmodified. `lib/SHA256SUMS` records their contents.
The Solmate revision is the submodule revision used by this v4-core revision;
it is copied here as ordinary files, without submodule metadata.

The periphery snapshot is selected because its `BaseHook` uses the standalone
`ModifyLiquidityParams` and `SwapParams` definitions in `PoolOperation.sol`,
matching the vendored v4-core API. `BaseHook` and `HookMiner` have subsequently
moved out of the periphery repository; this project deliberately pins the
compatible snapshot. The vendored `PoolManager` requires Solidity 0.8.26.

Remappings used by this project:

```text
forge-std/=lib/forge-std/src/
v4-core/=lib/v4-core/
@uniswap/v4-core/=lib/v4-core/
v4-periphery/=lib/v4-periphery/
@openzeppelin/contracts/=lib/openzeppelin-contracts/contracts/
solmate/=lib/solmate/
```

Both v4-core import prefixes resolve to the same files and Solidity types. There
are no nested dependency configurations or package manager hooks.

Each upstream file retains its SPDX identifier and copyright notice. The
dependency license texts are included alongside the corresponding sources:
v4-core includes BUSL-1.1 and MIT texts, periphery and OpenZeppelin use MIT,
forge-std provides Apache-2.0/MIT, and the copied Solmate files use AGPL-3.0-only.
Upstream v4-core test helpers retain their original `UNLICENSED` identifiers.
