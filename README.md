# Pavilion exchange (v1)

Pavilion Market's on-chain order book settlement contract (`PavilionExchange`).

| Network | Address |
|---|---|
| Starknet mainnet | `0x0278b46e96fd5adae06f8675e49b2f07f9e660c889f4b633b2c9869ce1e39678` |

```bash
scarb build      # Scarb 2.20.1 / Cairo 2.20, OpenZeppelin Contracts for Cairo 4.0.1
snforge test     # Starknet Foundry 0.64.1
```

## Deployment

Constructor: `(owner: ContractAddress, payment_token: ContractAddress)`. Both must be non-zero.
Use STRK (`0x04718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d`, same on Sepolia
and mainnet). The chain id is read from the deploy transaction and stored; every hash uses it.
The contract is immutable: no upgrade, no setters. A new version is a new deployment.

## Interface

`IExchange`

| Function | Notes |
|---|---|
| `fill_order(order: Order, params: FillParams)` | Every order type. Blocked while paused. |
| `buy_erc721(order: ERC721SellOrder, signature: Span<felt252>)` | Short form of an ERC721 listing; expands to the equivalent `Order` (taker 0, validator 0, nft_amount 1, current counter, fee slots with a zero recipient omitted) and runs the same path as `fill_order`, so it has the same order hash. A zero fee recipient with a non-zero amount is rejected. Blocked while paused. |
| `cancel_orders(orders: Span<Order>)` | Caller must be the maker of every order. Works while paused. |
| `increment_counter() -> u128` | Invalidates every order signed with the previous counter. Works while paused. |
| `get_counter(account) -> u128` | |
| `get_order_status(order_hash) -> OrderStatus { is_cancelled, filled_amount }` | |
| `get_order_hash(order) -> felt252` | The order's identity (single-order SNIP-12 message hash). |
| `validate_signature(order, signature)` | Panics unless valid (single or bulk layout). |
| `payment_token() -> ContractAddress` | |

`IExchangeAdmin`: `owner()`, `transfer_ownership(new_owner)` (owner only, non-zero), `pause()`,
`unpause()` (owner only). `is_paused() -> bool` (OpenZeppelin Pausable). There is no
`renounce_ownership`.

`Order` (calldata order): `order_type: u128, maker, taker, listing_time: u64, expiry_time: u64,
salt: u128, erc20_address, erc20_amount: u128, fees: Span<Fee{recipient, amount: u128}>,
nft_address, nft_id: u256, nft_amount: u128, order_validator, counter: u128`.

`FillParams`: `fill_id: u256, fill_amount: u128, recipient (0 = caller), signature: Span<felt252>,
extra_data: Span<felt252>`.

Order types: 0 ERC721 item offer, 1 ERC721 listing, 2 ERC1155 item offer, 3 ERC1155 listing,
4 ERC721 collection offer, 6 ERC1155 collection offer. Sell orders (1, 3): the maker gives the
NFT, the caller pays, `recipient` gets the NFT. Buy orders (0, 2, 4, 6): the caller gives the NFT,
the maker pays, `recipient` gets the payment. `taker` (if non-zero) must equal `recipient`.
Collection offers accept any `fill_id`; with an `order_validator`, `nft_id` carries a merkle root
that is passed to the validator. ERC721 fills are always 1 unit; ERC721 collection offers may
have `nft_amount > 1` (filled one token at a time). Partial fills pay
`floor(amount * fill_amount / nft_amount)` for the price and for each fee; the payee receives the
price minus the fees.

Order validator interface: `validate_pavilion_order(nft_address, nft_id: u256, merkle_root,
order_hash, extra_data: Span<felt252>) -> felt252` must return
`selector!("validate_pavilion_order")`.

### Events

| Event | keys | data |
|---|---|---|
| `OrderFilled` | `selector("OrderFilled"), order_hash, order_type, maker` | `taker, erc20_address, erc20_amount, fees_len, (recipient, amount)*, nft_address, nft_id.low, nft_id.high, nft_amount, caller` |
| `OrderCancelled` | `selector("OrderCancelled"), account, order_hash` | — |
| `CounterIncremented` | `selector("CounterIncremented"), account` | `new_counter` |
| `OwnershipTransferred` (OZ) | `selector, previous_owner, new_owner` | — |
| `Paused` / `Unpaused` (OZ) | `selector` | `account` |

In `OrderFilled`, `taker` is the fill's recipient (buyer for listings, payment recipient for
offers), `caller` the account that sent the transaction (for offers: the account that gave the
NFT), `erc20_amount`/fees are the amounts actually paid for this fill, `nft_id` is the filled id and
`nft_amount` the filled quantity. `order_hash` is always the single-order hash, also for orders
signed in a bulk.

### Errors

`Exchange: unmatched counter`, `Exchange: invalid maker`, `Exchange: invalid erc20 address`
(not the payment token), `Exchange: invalid nft address` (zero or the payment token),
`Exchange: not started`, `Exchange: is expired`, `Exchange: invalid recipient` (private taker),
`Exchange: invalid order type`, `Exchange: invalid nft amount`, `Exchange: invalid fill amount`,
`Exchange: invalid nft id`, `Exchange: invalid fill id`, `Exchange: invalid fee recipient`,
`Exchange: invalid fees` (sum above price), `Exchange: invalid sig length`,
`Exchange: invalid signature`, `Exchange: validate order error`, `Exchange: order cancelled`,
`Exchange: exceeds nft amount`, `Exchange: erc20 transfer failed`, `Exchange: invalid caller`
(cancel), `Exchange: invalid fee` (short form), `Exchange: zero owner`,
`Exchange: zero payment token`; from OpenZeppelin: `Pausable: paused`, `Pausable: not paused`,
`Caller is not the owner`, `ReentrancyGuard: reentrant call`.

## Signing (SNIP-12 revision 1)

Domain: `{ name: "Pavilion Market", version: "1", chainId: "SN_SEPOLIA" | "SN_MAIN", revision: "1" }`
(`version` `"1"` encodes as the number 1, as starknet.js and starknet.go do).

The contract inserts its own address as `exchange`; a message signed for another deployment,
chain or domain does not verify.

Single order, `primaryType: "Order"`:

```
"Order"("exchange":"ContractAddress","order_type":"u128","maker":"ContractAddress",
"taker":"ContractAddress","listing_time":"timestamp","expiry_time":"timestamp","salt":"u128",
"erc20_address":"ContractAddress","erc20_amount":"u128","fees":"Fee*",
"nft_address":"ContractAddress","nft_id":"u256","nft_amount":"u128",
"order_validator":"ContractAddress","counter":"u128")
"Fee"("recipient":"ContractAddress","amount":"u128")
"u256"("low":"u128","high":"u128")            (preset type, not listed in `types`)
```

Bulk, `primaryType: "BulkOrder"`: `"BulkOrder"("exchange":"ContractAddress","orders":"merkletree")`
with `{"name": "orders", "type": "merkletree", "contains": "Order"}`. Leaves are the `Order`
struct hashes in the order given; the tree is starknet.js's `MerkleTree` (pairs hashed sorted with
two-input Poseidon, an odd last node paired with `0x0`).

An order's identity (`order_hash`) is always the message hash of the order signed alone, whether
it was signed alone or in a bulk.

Signature layouts (`FillParams.signature`):

- Single: the account signature exactly as the wallet returns it (any length ≥ 1).
- Bulk: `[0xfefefef0, n, s_1 … s_n, proof_1 … proof_k]` — `n ≥ 1` account signature felts over the
  `BulkOrder` message, then the merkle proof of the order's leaf (starknet.js `getProof`).

The maker's account is called with `is_valid_signature(hash, signature)` (falling back to
`isValidSignature` only if the entry point does not exist). Only `'VALID'` (SNIP-6) or `1`
(Cairo 0 accounts) count as valid.

Cairo 0 (deprecated) maker accounts are not supported. The `isValidSignature` fallback and the
`1` result were tested only with Cairo 1 mocks that imitate Cairo 0 accounts, not with a real
Cairo 0 account class. On a real one, the failed `is_valid_signature` call may not be catchable,
so the fill reverts (fails closed; no funds at risk). Cairo 0 *collections* are unaffected:
camelCase is tried first for NFT calls.

## Test vectors

`test_vectors/vectors.json` holds sample orders of every type with the exact typed data a wallet
receives and the expected hashes; `tests/test_vectors.cairo` asserts the contract computes the same
values, so the file cannot drift from the contract. Schema (`schema_version` 1):

| Field | Meaning |
|---|---|
| `chain_id`, `chain_id_felt`, `exchange` | Environment of every vector (exchange address is fictitious). |
| `constants` | `domain`, `domain_hash`, `order_type_hash`, `fee_type_hash`, `u256_type_hash`, `bulk_order_type_hash`, `bulk_signature_prefix`, accepted `is_valid_signature` results. |
| `orders[]` | `name`, `description`, `signer` (maker), `typed_data` (full SNIP-12 JSON), `struct_hash` (Order struct hash = merkle leaf), `message_hash` (what the account signs), `order_hash` (identity, equal to `message_hash`), `order_calldata` (Cairo serialization of `Order` for `fill_order`). |
| `bulk[]` | `name`, `description`, `signer`, `typed_data` (`BulkOrder` JSON), `root`, `message_hash` (what the account signs), `orders[]`: `index`, `struct_hash` (leaf), `order_hash` (identity), `proof`, `order_calldata`, `signature_layout`. |
| `short_forms[]` | `buy_erc721` short form (`erc721_sell_order`) and the `orders[]` entry it equals. |

All numbers are strings: addresses and u256 halves in hex, other integers in decimal.

## NFT and payment-token calls

- NFTs: `transferFrom` (ERC721) / `safeTransferFrom` (ERC1155, empty data) first, then the
  snake_case name if the collection has no camelCase entry point. Works for OpenZeppelin Cairo 1
  collections, Cairo 0-style camelCase-only collections (e.g. PVL) and snake_case-only
  collections. Errors that do not start with `ENTRYPOINT_NOT_FOUND` are returned unchanged (no
  retry). The check looks only at the first felt of the error, so an `ENTRYPOINT_NOT_FOUND`
  bubbling up from a nested call also triggers the snake_case retry; for example, an OpenZeppelin
  ERC1155 `safeTransferFrom` to a recipient contract without SRC5. The retry then fails the same
  way, so the only effects are one extra call and a revert reason from the second attempt. The
  collection is chosen by the maker, so a third party gains nothing from this.
- Evidence (starknet-devnet 0.9.0, `starknet_version` 0.14.3, RPC 0.10.2): a call to a missing
  entry point returns `['ENTRYPOINT_NOT_FOUND', 'ENTRYPOINT_FAILED']` to the calling contract,
  which can catch it; a transaction that falls back from `transferFrom` to `transfer_from` on a
  snake_case-only contract succeeds, and the trace shows the failed inner call followed by the
  successful one. A call to an address with no contract is not catchable (the transaction reverts).
- Payment token: `transfer_from` (snake_case; STRK exposes both) and the call must return `true`.
