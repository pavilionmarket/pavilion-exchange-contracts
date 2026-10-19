// SPDX-License-Identifier: MIT
//
// SNIP-12 revision 1 hashing of orders and verification of single and bulk signatures.
//
// Typed data (published with the test vectors in `test_vectors/`):
//
//   StarknetDomain { name: 'Pavilion Market', version: 1, chainId: <chain>, revision: 1 }
//
//   Single order, primary type `Order`:
//     "Order"("exchange":"ContractAddress","order_type":"u128","maker":"ContractAddress",
//     "taker":"ContractAddress","listing_time":"timestamp","expiry_time":"timestamp",
//     "salt":"u128","erc20_address":"ContractAddress","erc20_amount":"u128","fees":"Fee*",
//     "nft_address":"ContractAddress","nft_id":"u256","nft_amount":"u128",
//     "order_validator":"ContractAddress","counter":"u128")
//     "Fee"("recipient":"ContractAddress","amount":"u128")
//     "u256"("low":"u128","high":"u128")
//
//   Bulk, primary type `BulkOrder` (merkletree of `Order`):
//     "BulkOrder"("exchange":"ContractAddress","orders":"merkletree")
//
// `exchange` is always this contract's own address: callers never pass it, the contract inserts
// it, so a message signed for another deployment cannot verify here.
//
// Signature layouts (`FillParams.signature`):
//   single: the account signature as returned by the wallet, any length >= 1.
//   bulk:   [BULK_SIGNATURE_PREFIX, n, s_1..s_n (account signature, n >= 1), proof...]
//           where `proof` is the merkle path from the order's leaf to the signed root.

use core::hash::{HashStateExTrait, HashStateTrait};
use core::poseidon::{PoseidonTrait, hades_permutation, poseidon_hash_span};
use openzeppelin_utils::snip12::{StarknetDomain, StructHash};
use starknet::{ContractAddress, SyscallResultTrait};
use crate::market::interface::{BULK_SIGNATURE_PREFIX, Fee, Order, SIGNATURE_VALID};
use crate::utils::call::call_with_fallback;

pub const DOMAIN_NAME: felt252 = 'Pavilion Market';
pub const DOMAIN_VERSION: felt252 = 1;
pub const DOMAIN_REVISION: felt252 = 1;

pub const ORDER_TYPE_HASH: felt252 = selector!(
    "\"Order\"(\"exchange\":\"ContractAddress\",\"order_type\":\"u128\",\"maker\":\"ContractAddress\",\"taker\":\"ContractAddress\",\"listing_time\":\"timestamp\",\"expiry_time\":\"timestamp\",\"salt\":\"u128\",\"erc20_address\":\"ContractAddress\",\"erc20_amount\":\"u128\",\"fees\":\"Fee*\",\"nft_address\":\"ContractAddress\",\"nft_id\":\"u256\",\"nft_amount\":\"u128\",\"order_validator\":\"ContractAddress\",\"counter\":\"u128\")\"Fee\"(\"recipient\":\"ContractAddress\",\"amount\":\"u128\")\"u256\"(\"low\":\"u128\",\"high\":\"u128\")",
);
pub const FEE_TYPE_HASH: felt252 = selector!(
    "\"Fee\"(\"recipient\":\"ContractAddress\",\"amount\":\"u128\")",
);
pub const U256_TYPE_HASH: felt252 = selector!("\"u256\"(\"low\":\"u128\",\"high\":\"u128\")");
pub const BULK_ORDER_TYPE_HASH: felt252 = selector!(
    "\"BulkOrder\"(\"exchange\":\"ContractAddress\",\"orders\":\"merkletree\")",
);

pub mod Errors {
    pub const INVALID_SIGNATURE_LENGTH: felt252 = 'Exchange: invalid sig length';
    pub const INVALID_SIGNATURE: felt252 = 'Exchange: invalid signature';
}

/// Poseidon hash of the SNIP-12 `StarknetDomain` for this exchange on `chain_id`.
pub fn domain_hash(chain_id: felt252) -> felt252 {
    StarknetDomain {
        name: DOMAIN_NAME, version: DOMAIN_VERSION, chain_id, revision: DOMAIN_REVISION,
    }
        .hash_struct()
}

pub fn hash_u256(value: u256) -> felt252 {
    PoseidonTrait::new()
        .update_with(U256_TYPE_HASH)
        .update_with(value.low)
        .update_with(value.high)
        .finalize()
}

pub fn hash_fee(fee: @Fee) -> felt252 {
    PoseidonTrait::new()
        .update_with(FEE_TYPE_HASH)
        .update_with(*fee.recipient)
        .update_with(*fee.amount)
        .finalize()
}

/// SNIP-12 revision 1 `Fee*`: Poseidon of the fees' struct hashes.
pub fn hash_fees(fees: Span<Fee>) -> felt252 {
    let mut hashes: Array<felt252> = array![];
    for fee in fees {
        hashes.append(hash_fee(fee));
    }
    poseidon_hash_span(hashes.span())
}

/// Struct hash of `Order` with `exchange` inserted as the first field. Also the merkle leaf of
/// the order in a bulk signature.
pub fn hash_order_struct(order: @Order, exchange: ContractAddress) -> felt252 {
    PoseidonTrait::new()
        .update_with(ORDER_TYPE_HASH)
        .update_with(exchange)
        .update_with(*order.order_type)
        .update_with(*order.maker)
        .update_with(*order.taker)
        .update_with(*order.listing_time)
        .update_with(*order.expiry_time)
        .update_with(*order.salt)
        .update_with(*order.erc20_address)
        .update_with(*order.erc20_amount)
        .update_with(hash_fees(*order.fees))
        .update_with(*order.nft_address)
        .update_with(hash_u256(*order.nft_id))
        .update_with(*order.nft_amount)
        .update_with(*order.order_validator)
        .update_with(*order.counter)
        .finalize()
}

pub fn hash_bulk_order_struct(exchange: ContractAddress, root: felt252) -> felt252 {
    PoseidonTrait::new()
        .update_with(BULK_ORDER_TYPE_HASH)
        .update_with(exchange)
        .update_with(root)
        .finalize()
}

/// SNIP-12 message hash: Poseidon('StarkNet Message', domain hash, signer, struct hash).
pub fn message_hash(
    domain_hash: felt252, signer: ContractAddress, struct_hash: felt252,
) -> felt252 {
    PoseidonTrait::new()
        .update_with('StarkNet Message')
        .update_with(domain_hash)
        .update_with(signer)
        .update_with(struct_hash)
        .finalize()
}

/// Root of the SNIP-12 revision 1 `merkletree` (starknet.js `MerkleTree`): each step hashes the
/// pair in ascending order with two-input Poseidon.
pub fn merkle_root(leaf: felt252, proof: Span<felt252>) -> felt252 {
    let mut node = leaf;
    for sibling in proof {
        node = hash_pair(node, *sibling);
    }
    node
}

fn hash_pair(a: felt252, b: felt252) -> felt252 {
    let a_u256: u256 = a.into();
    let b_u256: u256 = b.into();
    let (x, y) = if a_u256 < b_u256 {
        (a, b)
    } else {
        (b, a)
    };
    let (hash, _, _) = hades_permutation(x, y, 2);
    hash
}

/// Verifies `signature` for the order whose single-order hash is `order_hash` and whose merkle
/// leaf is `leaf`. Panics if it is not the maker's valid signature.
pub fn validate_signature(
    maker: ContractAddress,
    exchange: ContractAddress,
    domain_hash: felt252,
    order_hash: felt252,
    leaf: felt252,
    signature: Span<felt252>,
) {
    let len = signature.len();
    assert(len != 0, Errors::INVALID_SIGNATURE_LENGTH);

    let (signed_hash, account_signature) = if *signature.at(0) == BULK_SIGNATURE_PREFIX {
        assert(len >= 2, Errors::INVALID_SIGNATURE_LENGTH);
        let sig_len: u32 = match (*signature.at(1)).try_into() {
            Option::Some(n) => n,
            Option::None => core::panic_with_felt252(Errors::INVALID_SIGNATURE_LENGTH),
        };
        assert(sig_len != 0 && sig_len <= len - 2, Errors::INVALID_SIGNATURE_LENGTH);
        let proof_start = 2 + sig_len;
        let root = merkle_root(leaf, signature.slice(proof_start, len - proof_start));
        let bulk_hash = message_hash(domain_hash, maker, hash_bulk_order_struct(exchange, root));
        (bulk_hash, signature.slice(2, sig_len))
    } else {
        (order_hash, signature)
    };

    let mut calldata: Array<felt252> = array![signed_hash];
    account_signature.serialize(ref calldata);
    let result = call_with_fallback(
        maker, selector!("is_valid_signature"), selector!("isValidSignature"), calldata.span(),
    )
        .unwrap_syscall();
    assert(result.len() != 0, Errors::INVALID_SIGNATURE);
    let is_valid = *result.at(0);
    // SNIP-6 accounts return 'VALID'; Cairo 0 accounts return 1 (TRUE). Anything else is invalid.
    assert(is_valid == SIGNATURE_VALID || is_valid == 1, Errors::INVALID_SIGNATURE);
}
