# HOLDINGS (HODL)

1,000 fully onchain generative ERC-721s about the difference between holding cryptocurrency and holding cash.
Each token shows a randomly generated balance as large black type on a white square.

- **ETH holdings** show `82,194,012 ETH`. The balance never changes.
- **IMD holdings** show `82,194,012 IMD`. The balance never changes.
- **CASH holdings** show `$82,194,012`. **Anyone** can call `outage(tokenId, newBalance)` to lower the balance, down to
  `$0`. It can never go up, reset or be restored.

The balances are artwork. They are not funds, they are not backed by anything, and they have nothing to do with what
the minter paid.

> **Core rule:** ETH and IMD holdings last forever. A CASH holding can only go down, through an outage.

## Contracts

| Contract | File | Purpose |
| --- | --- | --- |
| `Holdings` | `src/Holdings.sol` | The HOLDINGS / HODL collection: ERC-721, ERC-4906, Ownable2Step, ReentrancyGuard (OpenZeppelin v5.4.0) |
| `MockIMD` | `src/MockIMD.sol` | Worthless Sepolia test token standing in for IMD, with an open faucet |

The ABIs are in `abi/Holdings.json` and `abi/MockIMD.json`. To regenerate them, run
`forge inspect src/Holdings.sol:Holdings abi --json`.

### Is there an official IMD token on Sepolia? No.

The IMD token this brief names is `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7` on **Ethereum mainnet**. Read over
Ethereum mainnet JSON-RPC on 2026-11-19, it reports `name()` = "Identity.md",
`symbol()` = "IMD" and `decimals()` = 18. On Sepolia (chain 11155111) that address has **no code** (`eth_getCode`
returns `0x`). A web search found no published Sepolia deployment of IMD. So the launch deploys `MockIMD` (18 decimals,
symbol `IMD`, like mainnet) and passes its address to the `Holdings` constructor. After that, the address is
`immutable`.

### Deployment parameters (Sepolia, chain id 11155111)

The IMD launch deploys both contracts in this order, through its factory. Do not deploy them by hand for the launch.

| # | Contract | Constructor arguments |
| --- | --- | --- |
| 0 | `MockIMD` | none |
| 1 | `Holdings` | `owner_` = `$owner` (0xccf0a1307e5e5ad04e85d94d7f9d400390f0118a), `imdToken_` = `$contract:MockIMD` |

Neither constructor calls another contract, so both run on an empty chain. Neither is payable, and both deploy with 0
ETH. Nothing has to be configured after launch.

**Addresses:** the launch fills these in once it has deployed. This build does not broadcast transactions, and it
does not invent addresses.

- `MockIMD` (Sepolia): _assigned at launch_
- `Holdings` (Sepolia): _assigned at launch_

### Constants

| Name | Value | Notes |
| --- | --- | --- |
| `MAX_SUPPLY` | 1,000 | Shared by both payment methods. Token ids are `1..1000`. |
| `ETH_PRICE` | 0.00056 ETH (`560000000000000` wei) | `mint()` requires exactly this `msg.value` |
| `IMD_PRICE_HUNDREDTHS` | 35 → 0.35 IMD | `imdPrice()` = `35 * 10**(decimals - 2)` = `350000000000000000` for 18 decimals |
| `MIN_BALANCE` / `MAX_BALANCE` | 1 / 1,000,000,000 | Both inclusive |
| Canvas | 1000 × 1000 | White `#ffffff` background, black `#000000` text, bold monospace |
| Font size | `min(320, 1440 / characters)` | Every line is at most ~864 of the 1000 units wide (0.6em monospace glyphs) |
| `MockIMD.FAUCET_AMOUNT` | 10 IMD | `faucet()`, enough for 28 mints |
| `MockIMD.MAX_MINT_PER_CALL` | 1,000 IMD | Cap per call on `mint(to, amount)` |

## Interface

| Function | Who | What it does |
| --- | --- | --- |
| `mint()` payable | anyone | Requires exactly 0.00056 ETH. Gives a 50% ETH or 50% CASH holding and a balance from 1 to 1e9. |
| `mintWithIMD()` | anyone | Pulls exactly `imdPrice()` IMD with SafeERC20 after a prior `approve`. Always gives an IMD holding. |
| `outage(tokenId, newBalance)` | anyone | CASH only. Requires `newBalance < current`; the new balance may be 0. Emits `Outage(tokenId, previousBalance, newBalance, caller)` and ERC-4906 `MetadataUpdate(tokenId)`. |
| `getHolding(tokenId)` | view | `(holdingType, originalBalance, currentBalance, currency)`. `holdingType` is 0 = ETH, 1 = IMD, 2 = CASH. `currency` is "ETH", "IMD" or "USD". |
| `tokenURI(tokenId)` | view | `data:application/json;base64,…` with `image` = `data:image/svg+xml;base64,…`, rendered from storage on every call |
| `tokenSVG(tokenId)`, `displayText(tokenId)`, `outageCount(tokenId)` | view | Raw SVG, the displayed text, and the number of outages |
| `imdPrice()` | view | The IMD amount one mint costs, in base units |
| `withdrawETH()` / `withdrawIMD()` | owner | Sends the contract's whole ETH or IMD balance to `owner()` |
| `transferOwnership` / `acceptOwnership` | owner / pending owner | Two-step ownership handover. `renounceOwnership` is disabled so proceeds cannot be stranded. |

The metadata JSON has `name` ("HOLDINGS #id"), `description`, `holding_type`, `currency`, `initial_balance`,
`current_balance`, `display`, `image`, and `attributes`: Holding Type, Currency, Initial Balance, Current Balance and
Outages.

Errors: `IncorrectETHPayment`, `IMDAllowanceTooLow`, `IMDBalanceTooLow`, `IMDPaymentShort` (fee-on-transfer and other
short payments), `UnsupportedIMDDecimals` (fewer than 2 or more than 36), `SoldOut`, `NotCashHolding`,
`BalanceMustDecrease`, `NothingToWithdraw`, `ETHTransferFailed`, `RenounceDisabled`, `ZeroIMDToken`, plus
OpenZeppelin's `OwnableUnauthorizedAccount` and `ERC721NonexistentToken`.

## Security model and trust assumptions

- **No admin power over the art.** There is no setter for balances, types, currencies, URIs or the IMD token. There is
  no proxy, no `delegatecall`, no `selfdestruct` and no baseURI. `originalBalance` is written once, at mint. For
  ETH/IMD, `currentBalance` is never written again. For CASH, the only write is in `outage`, which enforces a strict
  decrease.
- **Owner powers:** the owner can withdraw the ETH and IMD that mints have paid into the contract, and can hand
  ownership over in two steps. Nothing else. The owner is `$owner`, never the factory or the deployer.
- **Payments:** ETH must be exact, and plain ETH transfers to the contract are rejected (it has no `receive`). IMD is
  pulled only from `msg.sender`, only from the immutable IMD address, and only after allowance and balance checks. The
  amount that arrives is measured, so a short payment reverts. No other ERC-20 is accepted.
- **Reentrancy:** `mint`, `mintWithIMD`, `withdrawETH` and `withdrawIMD` are `nonReentrant`. Holdings are recorded
  before the external IMD pull and the `_safeMint` receiver hook.
- **Supply:** `_nextTokenId` reverts with `SoldOut` once `totalSupply` reaches 1,000, whichever payment path is used.
- **Outage griefing is the artwork:** anyone can wipe any CASH token to `$0` at any time, and this is by design.
  Holders should understand that before they mint.

### Randomness and its manipulation risks

The brief asks for documented pseudo-randomness for Sepolia testing. The seed is
`keccak256(abi.encode(block.prevrandao, blockhash(block.number - 1), block.timestamp, msg.sender, tokenId, address(this), block.chainid))`.
The balance is `1 + seed % 1e9`. For an ETH mint, bit 128 of the seed picks ETH (0) or CASH (1).

The seed is **not secure randomness**:

1. **Simulate and revert.** A contract can call `mint()`, read `getHolding` in the same transaction, and revert when
   it does not like the result. For example, it could keep only ETH holdings or only large balances. Each retry costs
   only gas.
2. **Proposers and builders.** The proposer controls `block.timestamp` within protocol limits. It can also withhold a
   block to pick between two `prevrandao` values, and it can choose the order of transactions in its block.
3. **Public inputs.** Every input is public before inclusion, so anyone can predict the outcome for a pending mint.

On Sepolia the stakes are nil. For a mainnet launch where outcomes matter, replace `_random` with Chainlink VRF or a
commit-reveal scheme. That changes the mint flow to two steps.

### What has not been done

- No independent security audit. Before this holds real value, an independent reviewer should audit it adversarially.
- Slither and Mythril were not run in this build. Forge's built-in lints were reviewed. The remaining warnings are
  `weak-prng`, which is the documented pseudo-randomness, and `block-timestamp`, which is part of the same seed.

## Build and test

```bash
forge build
forge test                      # 70 tests: unit, fuzz, supply cap, metadata decode, script rehearsal
forge fmt --check
```

Foundry config: `solc = "0.8.26"`, optimizer at 200 runs, `bytecode_hash = "none"`, EVM `cancun`. OpenZeppelin
Contracts v5.4.0 and forge-std v1.11.0 are vendored as plain files in `lib/`. There are no submodules, and the build
needs no network.

What the tests cover (`test/Holdings.t.sol`, `test/Deploy.t.sol`):

- 1,000 ETH mints split about 50/50 between ETH and CASH (each side must be ≥ 450). Every balance falls in [1, 1e9].
- 300 IMD mints are all IMD.
- The price is exact in both directions: a fuzzed wrong ETH amount, too little or too much ETH, zero ETH, ETH sent to
  `mintWithIMD`, missing or insufficient allowance or balance, a fee-on-transfer token, a token that returns false,
  another ERC-20, and price scaling at 6 and 2 decimals.
- The supply cap holds at 600 ETH + 400 IMD mints and at 1,000 IMD-only mints.
- Outages: anyone can call one. A fuzzed sequence of outages never raises the balance. A balance can reach `$0`, and
  no outage works after that. Equal or higher values revert. The owner and the holder cannot restore a balance. Outages
  on ETH/IMD tokens and on nonexistent tokens revert. Events are checked.
- The tokenURI is base64-decoded and its JSON parsed. The current/initial balances, type, currency and embedded SVG
  change after each outage, and the original balance is preserved.
- ETH/IMD holdings and their tokenURIs stay identical through outage attempts, transfers, new mints, withdrawals and
  an ownership change.
- Rendering: thousands separators, the three display formats, and font scaling that fits the canvas.
- Withdrawals are owner-only (fuzzed callers). A pending owner can withdraw only after accepting. Renounce is
  disabled. An owner that rejects ETH, and an owner that re-enters, are both handled. Funds are conserved.
- A receiver that re-enters `mint` is blocked.
- The deploy script's `deploy(Config)` is tested, and so is the demonstration scenario (an ETH mint, an IMD mint, and
  an outage that changes the SVG).

## Scripts

`script/Deploy.s.sol:DeployHoldings` is for manual or rehearsal deployments outside the IMD launch. `run()` reads
`HOLDINGS_OWNER`, and optionally `IMD_TOKEN`. Without `IMD_TOKEN` it deploys a `MockIMD`. The logic is in
`deploy(Config)`.

```bash
HOLDINGS_OWNER=0x... forge script script/Deploy.s.sol:DeployHoldings \
  --rpc-url https://ethereum-sepolia-rpc.publicnode.com --account <keystore> --broadcast \
  --verify --etherscan-api-key $ETHERSCAN_API_KEY
```

To verify the launch's contracts on Etherscan by hand:

```bash
forge verify-contract <MockIMD address> src/MockIMD.sol:MockIMD --chain sepolia --watch
forge verify-contract <Holdings address> src/Holdings.sol:Holdings --chain sepolia --watch \
  --constructor-args $(cast abi-encode "constructor(address,address)" 0xccf0a1307e5e5ad04e85d94d7f9d400390f0118a <MockIMD address>)
```

### Demonstration (after launch)

1. **ETH mint + IMD mint.** Run
   `HOLDINGS=<Holdings address> forge script script/Demo.s.sol:DemoMint --rpc-url <sepolia> --account <keystore> --broadcast`.
   It mints once with 0.00056 ETH, takes 10 test IMD from the MockIMD faucet, approves 0.35 IMD and mints with IMD.
   The holding is drawn when the transaction is mined, so read the result from the `HoldingMinted` event or from
   `getHolding(id)`. Repeat the ETH mint until you get a CASH holding (50% each time).
2. **Outage.** Run
   `HOLDINGS=<addr> TOKEN_ID=<cash id> NEW_BALANCE=<lower value> forge script script/Demo.s.sol:DemoOutage --rpc-url <sepolia> --account <keystore> --broadcast`.
   It logs the SVG before and after. You can also check it with `cast call <addr> "tokenSVG(uint256)(string)" <id>`.

Record the transaction hashes here once they exist:

- ETH mint: _pending_
- IMD mint: _pending_
- Outage: _pending_

## After launch

The contracts need no configuration after deployment. They have no setters to call. The owner's ongoing
responsibilities are:

- **Withdraw proceeds.** `withdrawETH()` and `withdrawIMD()` from the owner wallet
  (0xccf0a1307e5e5ad04e85d94d7f9d400390f0118a) send the whole ETH or IMD balance to the owner.
- **Ownership.** Transfer ownership with `transferOwnership(newOwner)`, then call `acceptOwnership()` from the new
  owner. Renouncing is disabled.
- **Demonstration and verification.** Run the demonstration steps and the Etherscan verification above, and record
  the addresses and transaction hashes in this README.
- **Mainnet.** If this ever moves to mainnet, pass the real IMD (`0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`) as
  `imdToken_`, do not deploy `MockIMD`, and replace the pseudo-randomness (see above).
