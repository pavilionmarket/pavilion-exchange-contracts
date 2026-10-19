// Anchors the SNIP-12 revision 1 building blocks to values computed by independent
// implementations (starknet.go v0.17.1 / starknet.js test fixtures), so the exchange's hashing is
// not only self-consistent.

use core::hash::{HashStateExTrait, HashStateTrait};
use core::poseidon::PoseidonTrait;
use openzeppelin_utils::snip12::{STARKNET_DOMAIN_TYPE_HASH, StarknetDomain, StructHash};
use pavilion_exchange::market::signature_validator::{
    U256_TYPE_HASH, hash_u256, merkle_root, message_hash,
};
use crate::utils::{addr, merkle_hash, merkle_proof, merkle_tree_root};

const TOKEN_AMOUNT_TYPE_HASH: felt252 =
    0x14648649d4413eb385eea9ac7e6f2b9769671f5d9d7ad40f7b4aadd67839d4;
const NFT_ID_TYPE_HASH: felt252 = 0xaf7d0f5e34446178d80fadf5ddaaed52347121d2fac19ff184ff508d4776f2;

#[test]
fn preset_u256_type_hash_matches_starknet_go() {
    // typeddata/revision.go, preset "u256".
    assert_eq!(U256_TYPE_HASH, 0x3b143be38b811560b45593fb2a071ec4ddd0a020e10782be62ffe6f39e0e82c);
    // Same string encoding style (quoted names, preset dependencies appended) for other presets.
    assert_eq!(
        selector!(
            "\"TokenAmount\"(\"token_address\":\"ContractAddress\",\"amount\":\"u256\")\"u256\"(\"low\":\"u128\",\"high\":\"u128\")",
        ),
        TOKEN_AMOUNT_TYPE_HASH,
    );
    assert_eq!(
        STARKNET_DOMAIN_TYPE_HASH,
        0x1ff2f602e42168014d405a94f75e8a93d640751d71d16311266e140d8b0a210,
    );
}

/// starknet.go typeddata/testData/example_presetTypes.json (also a starknet.js fixture): revision
/// 1, domain {name "StarkNet Mail", version "1", chainId "1", revision "1"}, u256 inside presets.
#[test]
fn example_preset_types_fixture() {
    let type_hash = selector!(
        "\"Example\"(\"n0\":\"TokenAmount\",\"n1\":\"NftId\")\"NftId\"(\"collection_address\":\"ContractAddress\",\"token_id\":\"u256\")\"TokenAmount\"(\"token_address\":\"ContractAddress\",\"amount\":\"u256\")\"u256\"(\"low\":\"u128\",\"high\":\"u128\")",
    );
    assert_eq!(type_hash, 0x1a25a8bb84b761090b1fadaebe762c4b679b0d8883d2bedda695ea340839a55);

    let token = 0x049d36570d4e46f48e99674bd3fcc84644ddd6b96f7c741b1562b82f9e004dc7;
    let n0 = PoseidonTrait::new()
        .update_with(TOKEN_AMOUNT_TYPE_HASH)
        .update_with(token)
        .update_with(hash_u256(0x3e8))
        .finalize();
    let n1 = PoseidonTrait::new()
        .update_with(NFT_ID_TYPE_HASH)
        .update_with(token)
        .update_with(hash_u256(0x3e8))
        .finalize();
    let struct_hash = PoseidonTrait::new()
        .update_with(type_hash)
        .update_with(n0)
        .update_with(n1)
        .finalize();
    assert_eq!(struct_hash, 0x74fba3f77f8a6111a9315bac313bf75ecfa46d1234e0fda60312fb6a6517667);

    // "1" strings encode as the number 1 (not the short string '1').
    let domain = StarknetDomain { name: 'StarkNet Mail', version: 1, chain_id: 1, revision: 1 }
        .hash_struct();
    let hash = message_hash(domain, addr(0xCD2a3d9F938E13CD947Ec05AbC7FE734Df8DD826), struct_hash);
    assert_eq!(hash, 0x185b339d5c566a883561a88fb36da301051e2c0225deb325c91bb7aa2f3473a);
}

#[test]
fn merkle_root_is_order_independent_per_pair_and_matches_tree_builder() {
    let leaves = array![0x11, 0x5, 0x33, 0x2, 0x7].span();
    let root = merkle_tree_root(leaves);
    for i in 0..leaves.len() {
        assert_eq!(merkle_root(*leaves[i], merkle_proof(leaves, i).span()), root);
    }
    // Pair hashing sorts its inputs.
    assert_eq!(merkle_hash(1, 2), merkle_hash(2, 1));
    assert_eq!(merkle_root(2, array![1].span()), merkle_root(1, array![2].span()));
    assert!(merkle_root(1, array![2].span()) != 1);
    // An empty proof means the leaf is the root.
    assert_eq!(merkle_root(0x42, array![].span()), 0x42);
}

/// Pair hashing is two-input Poseidon (hades(x, y, 2)[0]), not Poseidon of a 2-element span.
#[test]
fn merkle_pair_hash_is_two_input_poseidon() {
    let (expected, _, _) = core::poseidon::hades_permutation(1, 2, 2);
    assert_eq!(merkle_root(1, array![2].span()), expected);
    assert!(expected != core::poseidon::poseidon_hash_span(array![1, 2].span()));
}
