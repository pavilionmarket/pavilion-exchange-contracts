// Signatures: single and bulk layouts, wrong signer, wrong domain, tampering, replay across
// deployments, long signatures, account return values.

use openzeppelin_interfaces::erc1155::IERC1155DispatcherTrait;
use openzeppelin_interfaces::erc20::IERC20DispatcherTrait;
use openzeppelin_interfaces::erc721::IERC721DispatcherTrait;
use openzeppelin_utils::snip12::{StarknetDomain, StructHash};
use pavilion_exchange::market::interface::{
    BULK_SIGNATURE_PREFIX, IExchangeDispatcherTrait, IExchangeSafeDispatcherTrait,
    ORDER_TYPE_ERC1155_SELL_ORDER, ORDER_TYPE_ERC721_BUY_ORDER, ORDER_TYPE_ERC721_SELL_ORDER, Order,
};
use pavilion_exchange::market::signature_validator::{
    DOMAIN_NAME, DOMAIN_REVISION, DOMAIN_VERSION, domain_hash, hash_order_struct, message_hash,
};
use snforge_std::{
    start_cheat_caller_address, start_cheat_chain_id_global, stop_cheat_chain_id_global,
};
use starknet::ContractAddress;
use crate::mocks::IMintDispatcherTrait;
use crate::utils::{
    ALICE_KEY, Actor, BOB_KEY, CAROL_KEY, Env, OWNER, assert_fails_with, assert_fill_fails,
    balance_1155, bulk_leaves, bulk_message_hash, bulk_signature, chain_id, deploy, deploy_exchange,
    exchange_at, fill, merkle_proof, order, owner_of, params, public_key, setup, sign, sign_bulk,
    sign_for, sign_hash,
};

const INVALID_SIGNATURE: felt252 = 'Exchange: invalid signature';
const INVALID_SIGNATURE_LENGTH: felt252 = 'Exchange: invalid sig length';

fn listing(env: Env, id: u256) -> Order {
    order(env, ORDER_TYPE_ERC721_SELL_ORDER, env.alice.address, env.nft, id, 1, 100)
}

fn domain_with(name: felt252, version: felt252, chain: felt252, revision: felt252) -> felt252 {
    StarknetDomain { name, version, chain_id: chain, revision }.hash_struct()
}

#[feature("safe_dispatcher")]
fn try_validate(env: Env, o: Order, signature: Span<felt252>) -> Result<(), Array<felt252>> {
    env.safe.validate_signature(o, signature)
}

// ---------------------------------------------------------------------------------------------
// Single-order signatures

#[test]
fn valid_signature_is_accepted_by_view_and_fill() {
    let env = setup();
    let o = listing(env, 1);
    let sig = sign(env, env.alice, o);
    env.exchange.validate_signature(o, sig);
    // The independently built message hash equals the exchange's order hash.
    assert_eq!(
        env.exchange.get_order_hash(o),
        message_hash(domain_hash(chain_id()), o.maker, hash_order_struct(@o, env.address)),
    );
    fill(env, env.bob.address, o, params(1, 1, sig));
    assert_eq!(owner_of(env, 1), env.bob.address);
}

#[test]
fn wrong_signer_rejected() {
    let env = setup();
    let o = listing(env, 1);
    let sig = sign(env, env.bob, o);
    assert_fails_with(try_validate(env, o, sig), INVALID_SIGNATURE);
    assert_fill_fails(env, env.bob.address, o, params(1, 1, sig), INVALID_SIGNATURE);
}

#[test]
fn signature_for_other_chain_rejected() {
    let env = setup();
    let o = listing(env, 1);
    let other_chain = domain_with(DOMAIN_NAME, DOMAIN_VERSION, 'SN_MAIN', DOMAIN_REVISION);
    assert!(chain_id() != 'SN_MAIN');
    let sig = sign_for(env.alice, o, env.address, other_chain);
    assert_fill_fails(env, env.bob.address, o, params(1, 1, sig), INVALID_SIGNATURE);
    // Same construction with the right chain id is accepted.
    let right = domain_with(DOMAIN_NAME, DOMAIN_VERSION, chain_id(), DOMAIN_REVISION);
    fill(env, env.bob.address, o, params(1, 1, sign_for(env.alice, o, env.address, right)));
}

#[test]
fn signature_for_other_version_name_or_revision_rejected() {
    let env = setup();
    let o = listing(env, 1);
    let domains = array![
        domain_with(DOMAIN_NAME, 2, chain_id(), DOMAIN_REVISION),
        domain_with(DOMAIN_NAME, '1', chain_id(), DOMAIN_REVISION),
        domain_with('Other Market', DOMAIN_VERSION, chain_id(), DOMAIN_REVISION),
        domain_with(DOMAIN_NAME, DOMAIN_VERSION, chain_id(), 0),
    ];
    for domain in domains {
        let sig = sign_for(env.alice, o, env.address, domain);
        assert_fill_fails(env, env.bob.address, o, params(1, 1, sig), INVALID_SIGNATURE);
    }
}

#[test]
fn modified_order_fields_rejected() {
    let env = setup();
    let o = listing(env, 1);
    let sig = sign(env, env.alice, o);
    let mut cheaper = o;
    cheaper.erc20_amount = 1;
    assert_fill_fails(env, env.bob.address, cheaper, params(1, 1, sig), INVALID_SIGNATURE);
    let mut other_id = o;
    other_id.nft_id = 2;
    assert_fill_fails(env, env.bob.address, other_id, params(2, 1, sig), INVALID_SIGNATURE);
    let mut longer = o;
    longer.expiry_time += 1;
    assert_fill_fails(env, env.bob.address, longer, params(1, 1, sig), INVALID_SIGNATURE);
    let mut no_taker = o;
    no_taker.salt += 1;
    assert_fill_fails(env, env.bob.address, no_taker, params(1, 1, sig), INVALID_SIGNATURE);
}

#[test]
fn tampered_signature_rejected() {
    let env = setup();
    let o = listing(env, 1);
    let sig = sign(env, env.alice, o);
    let tampered = array![*sig[0], *sig[1] + 1].span();
    assert_fill_fails(env, env.bob.address, o, params(1, 1, tampered), INVALID_SIGNATURE);
}

#[test]
fn empty_signature_rejected() {
    let env = setup();
    let o = listing(env, 1);
    assert_fill_fails(
        env, env.bob.address, o, params(1, 1, array![].span()), INVALID_SIGNATURE_LENGTH,
    );
    assert_fails_with(try_validate(env, o, array![].span()), INVALID_SIGNATURE_LENGTH);
}

#[test]
fn counter_mismatch_rejected() {
    let env = setup();
    let mut o = listing(env, 1);
    o.counter = 1;
    assert_fill_fails(
        env,
        env.bob.address,
        o,
        params(1, 1, sign(env, env.alice, o)),
        'Exchange: unmatched counter',
    );
}

// ---------------------------------------------------------------------------------------------
// Replay across deployments and chains

#[test]
fn order_signed_for_one_deployment_rejected_by_another() {
    let env = setup();
    let second = deploy_exchange(OWNER(), env.strk);
    let (second_exchange, second_safe) = exchange_at(second);
    let env2 = Env { address: second, exchange: second_exchange, safe: second_safe, ..env };
    // alice approves the second exchange too, so only the signature can stop the fill.
    start_cheat_caller_address(env.nft, env.alice.address);
    openzeppelin_interfaces::erc721::IERC721Dispatcher { contract_address: env.nft }
        .set_approval_for_all(second, true);
    start_cheat_caller_address(env.strk, env.bob.address);
    openzeppelin_interfaces::erc20::IERC20Dispatcher { contract_address: env.strk }
        .approve(second, core::num::traits::Bounded::MAX);
    snforge_std::stop_cheat_caller_address(env.nft);
    snforge_std::stop_cheat_caller_address(env.strk);

    let o = listing(env, 1);
    let sig = sign(env, env.alice, o);
    // Same chain, same domain, same order: different hash because `exchange` differs.
    assert!(env.exchange.get_order_hash(o) != env2.exchange.get_order_hash(o));
    assert_fill_fails(env2, env.bob.address, o, params(1, 1, sig), INVALID_SIGNATURE);
    // Bulk signatures are bound the same way.
    let orders = array![listing(env, 2), listing(env, 3)].span();
    let bulk = sign_bulk(env, env.alice, orders);
    assert_fill_fails(env2, env.bob.address, *orders[0], params(2, 1, *bulk[0]), INVALID_SIGNATURE);
    // The original deployment accepts both.
    fill(env, env.bob.address, o, params(1, 1, sig));
    fill(env, env.bob.address, *orders[0], params(2, 1, *bulk[0]));
    assert_eq!(owner_of(env, 1), env.bob.address);
    assert_eq!(owner_of(env, 2), env.bob.address);
}

#[test]
fn chain_id_is_captured_at_deployment() {
    let env = setup();
    let o = listing(env, 1);
    let hash = env.exchange.get_order_hash(o);
    // Later calls see another chain id: hashes keep using the deployment's.
    start_cheat_chain_id_global('SN_OTHER');
    assert_eq!(env.exchange.get_order_hash(o), hash);
    fill(env, env.bob.address, o, params(1, 1, sign(env, env.alice, o)));
    // A deployment on another chain computes another hash for the same order and address set.
    let other = deploy_exchange(OWNER(), env.strk);
    stop_cheat_chain_id_global();
    let (other_exchange, _) = exchange_at(other);
    let expected = message_hash(
        domain_with(DOMAIN_NAME, DOMAIN_VERSION, 'SN_OTHER', DOMAIN_REVISION),
        o.maker,
        hash_order_struct(@o, other),
    );
    assert_eq!(other_exchange.get_order_hash(o), expected);
}

// ---------------------------------------------------------------------------------------------
// Bulk signatures

#[test]
fn bulk_signature_fills_every_order_with_single_order_identity() {
    let env = setup();
    let orders = array![
        listing(env, 1), listing(env, 2), listing(env, 3),
        order(env, ORDER_TYPE_ERC1155_SELL_ORDER, env.alice.address, env.nft1155, 7, 10, 1000),
        order(env, ORDER_TYPE_ERC721_BUY_ORDER, env.alice.address, env.nft, 11, 1, 50),
    ]
        .span();
    let sigs = sign_bulk(env, env.alice, orders);
    for i in 0..3_u32 {
        let id: u256 = (i + 1).into();
        env.exchange.validate_signature(*orders[i], *sigs[i]);
        fill(env, env.bob.address, *orders[i], params(id, 1, *sigs[i]));
        assert_eq!(owner_of(env, id), env.bob.address);
        // Status lives under the single-order hash.
        let hash = env.exchange.get_order_hash(*orders[i]);
        assert_eq!(env.exchange.get_order_status(hash).filled_amount, 1);
    }
    fill(env, env.carol.address, *orders[3], params(7, 4, *sigs[3]));
    assert_eq!(balance_1155(env, env.carol.address, 7), 104);
    fill(env, env.bob.address, *orders[4], params(11, 1, *sigs[4]));
    assert_eq!(owner_of(env, 11), env.alice.address);
}

#[test]
fn bulk_with_a_single_order() {
    let env = setup();
    let orders = array![listing(env, 1)].span();
    let sigs = sign_bulk(env, env.alice, orders);
    assert_eq!((*sigs[0]).len(), 4); // prefix, 2, r, s and an empty proof
    fill(env, env.bob.address, *orders[0], params(1, 1, *sigs[0]));
    assert_eq!(owner_of(env, 1), env.bob.address);
}

#[test]
fn bulk_and_single_signatures_share_order_status() {
    let env = setup();
    let o = order(env, ORDER_TYPE_ERC1155_SELL_ORDER, env.alice.address, env.nft1155, 7, 3, 300);
    let orders = array![o, listing(env, 2)].span();
    let bulk = sign_bulk(env, env.alice, orders);
    let single = sign(env, env.alice, o);
    fill(env, env.bob.address, o, params(7, 2, *bulk[0]));
    // Signed both ways, it is one order: only 1 unit is left.
    assert_fill_fails(
        env, env.bob.address, o, params(7, 2, single), 'Exchange: exceeds nft amount',
    );
    fill(env, env.bob.address, o, params(7, 1, single));
    // Cancelling by the single-order identity blocks the bulk signature.
    start_cheat_caller_address(env.address, env.alice.address);
    env.exchange.cancel_orders(array![*orders[1]].span());
    snforge_std::stop_cheat_caller_address(env.address);
    assert_fill_fails(
        env, env.bob.address, *orders[1], params(2, 1, *bulk[1]), 'Exchange: order cancelled',
    );
}

#[test]
fn bulk_proof_tampering_rejected() {
    let env = setup();
    let orders = array![listing(env, 1), listing(env, 2), listing(env, 3)].span();
    let sigs = sign_bulk(env, env.alice, orders);
    let sig = *sigs[0];
    assert_eq!(sig.len(), 6); // prefix, 2, r, s, two proof nodes

    // Flip a proof node.
    let mut bad = array![];
    for i in 0..sig.len() {
        bad.append(if i == 4 {
            *sig[i] + 1
        } else {
            *sig[i]
        });
    }
    assert_fill_fails(
        env, env.bob.address, *orders[0], params(1, 1, bad.span()), INVALID_SIGNATURE,
    );
    // Drop the last proof node.
    assert_fill_fails(
        env, env.bob.address, *orders[0], params(1, 1, sig.slice(0, 5)), INVALID_SIGNATURE,
    );
    // Extra proof node.
    let mut longer: Array<felt252> = sig.into();
    longer.append(0);
    assert_fill_fails(
        env, env.bob.address, *orders[0], params(1, 1, longer.span()), INVALID_SIGNATURE,
    );
    // Another order's proof.
    assert_fill_fails(env, env.bob.address, *orders[0], params(1, 1, *sigs[1]), INVALID_SIGNATURE);
    // An order that is not in the tree, with a valid proof of a sibling.
    let outsider = listing(env, 4);
    assert_fill_fails(env, env.bob.address, outsider, params(4, 1, sig), INVALID_SIGNATURE);
    // The untouched signature still works.
    fill(env, env.bob.address, *orders[0], params(1, 1, sig));
}

#[test]
fn bulk_signature_not_usable_as_single_and_vice_versa() {
    let env = setup();
    let orders = array![listing(env, 1), listing(env, 2)].span();
    let bulk_hash = bulk_message_hash(env.address, env.alice.address, orders);
    let account_sig = sign_hash(env.alice.secret, bulk_hash);
    // The bulk account signature without the bulk layout is a single signature over the wrong hash.
    assert_fill_fails(
        env, env.bob.address, *orders[0], params(1, 1, account_sig.span()), INVALID_SIGNATURE,
    );
    // A single-order signature wrapped in the bulk layout (empty proof) is not a bulk signature.
    let single = sign(env, env.alice, *orders[0]);
    assert_fill_fails(
        env,
        env.bob.address,
        *orders[0],
        params(1, 1, bulk_signature(single, array![].span())),
        INVALID_SIGNATURE,
    );
}

#[test]
fn bulk_layout_length_checks() {
    let env = setup();
    let orders = array![listing(env, 1), listing(env, 2)].span();
    let sig = *sign_bulk(env, env.alice, orders)[0];
    let o = *orders[0];
    // Prefix alone.
    assert_fill_fails(
        env,
        env.bob.address,
        o,
        params(1, 1, array![BULK_SIGNATURE_PREFIX].span()),
        INVALID_SIGNATURE_LENGTH,
    );
    // Zero-length account signature.
    assert_fill_fails(
        env,
        env.bob.address,
        o,
        params(1, 1, array![BULK_SIGNATURE_PREFIX, 0, *sig[2], *sig[3]].span()),
        INVALID_SIGNATURE_LENGTH,
    );
    // Declared length longer than what follows.
    assert_fill_fails(
        env,
        env.bob.address,
        o,
        params(1, 1, array![BULK_SIGNATURE_PREFIX, 3, *sig[2], *sig[3]].span()),
        INVALID_SIGNATURE_LENGTH,
    );
    // Declared length that is not a u32.
    assert_fill_fails(
        env,
        env.bob.address,
        o,
        params(1, 1, array![BULK_SIGNATURE_PREFIX, 0x100000000, *sig[2], *sig[3]].span()),
        INVALID_SIGNATURE_LENGTH,
    );
    // Declared length 1 shifts the proof: the account gets a 1-felt signature.
    assert_fill_fails(
        env,
        env.bob.address,
        o,
        params(1, 1, array![BULK_SIGNATURE_PREFIX, 1, *sig[2], *sig[3], *sig[4]].span()),
        INVALID_SIGNATURE,
    );
    // Declared length equal to everything that follows (no proof) is well-formed but wrong here.
    assert_fill_fails(
        env,
        env.bob.address,
        o,
        params(1, 1, array![BULK_SIGNATURE_PREFIX, 3, *sig[2], *sig[3], *sig[4]].span()),
        INVALID_SIGNATURE,
    );
    fill(env, env.bob.address, o, params(1, 1, sig));
}

#[test]
fn bulk_proof_for_odd_tree_uses_zero_sibling() {
    let env = setup();
    let orders = array![listing(env, 1), listing(env, 2), listing(env, 3)].span();
    let leaves = bulk_leaves(env.address, orders);
    // The third leaf has no sibling on the first level.
    let proof = merkle_proof(leaves, 2);
    assert_eq!(*proof[0], 0);
    let sigs = sign_bulk(env, env.alice, orders);
    fill(env, env.bob.address, *orders[2], params(3, 1, *sigs[2]));
    assert_eq!(owner_of(env, 3), env.bob.address);
}

// ---------------------------------------------------------------------------------------------
// Accounts: long signatures, camelCase-only, return values

fn multisig_maker(env: Env) -> ContractAddress {
    let account = deploy("MultisigAccount", array![public_key(CAROL_KEY), public_key(BOB_KEY)]);
    // Give the multisig ERC1155 units and approve the exchange.
    crate::mocks::IMintDispatcher { contract_address: env.nft1155 }.mint(account, 7, 10);
    start_cheat_caller_address(env.nft1155, account);
    openzeppelin_interfaces::erc1155::IERC1155Dispatcher { contract_address: env.nft1155 }
        .set_approval_for_all(env.address, true);
    snforge_std::stop_cheat_caller_address(env.nft1155);
    account
}

fn multisig_sign(hash: felt252) -> Span<felt252> {
    let a = sign_hash(CAROL_KEY, hash);
    let b = sign_hash(BOB_KEY, hash);
    array![*a[0], *a[1], *b[0], *b[1]].span()
}

#[test]
fn four_felt_signature_single_and_bulk() {
    let env = setup();
    let maker = multisig_maker(env);
    let o1 = order(env, ORDER_TYPE_ERC1155_SELL_ORDER, maker, env.nft1155, 7, 5, 500);
    let mut o2 = o1;
    o2.salt = 43;
    let sig = multisig_sign(env.exchange.get_order_hash(o1));
    assert_eq!(sig.len(), 4);
    fill(env, env.bob.address, o1, params(7, 5, sig));

    let orders = array![o2, o1].span();
    let account_sig = multisig_sign(bulk_message_hash(env.address, maker, orders));
    let bulk = bulk_signature(
        account_sig, merkle_proof(bulk_leaves(env.address, orders), 0).span(),
    );
    fill(env, env.carol.address, o2, params(7, 5, bulk));
    assert_eq!(balance_1155(env, env.bob.address, 7), 105);
    assert_eq!(balance_1155(env, env.carol.address, 7), 105);
    // Only half of the multisig is not enough.
    let mut o3 = o1;
    o3.salt = 44;
    let half = sign_hash(CAROL_KEY, env.exchange.get_order_hash(o3));
    assert_fill_fails(env, env.bob.address, o3, params(7, 1, half.span()), INVALID_SIGNATURE);
}

#[test]
fn camel_case_only_account_returning_true_is_accepted() {
    let env = setup();
    let maker = deploy("CamelOnlyAccount", array![public_key(ALICE_KEY)]);
    let o = order(env, ORDER_TYPE_ERC721_BUY_ORDER, maker, env.nft, 11, 1, 100);
    crate::mocks::IMintDispatcher { contract_address: env.strk }.mint(maker, 0, 1000);
    start_cheat_caller_address(env.strk, maker);
    openzeppelin_interfaces::erc20::IERC20Dispatcher { contract_address: env.strk }
        .approve(env.address, 1000);
    snforge_std::stop_cheat_caller_address(env.strk);
    let signer = Actor { address: maker, secret: ALICE_KEY };
    let sig = sign(env, signer, o);
    fill(env, env.bob.address, o, params(11, 1, sig));
    assert_eq!(owner_of(env, 11), maker);
    // And a wrong signature (returns 0) is rejected.
    let mut o2 = o;
    o2.nft_id = 12;
    assert_fill_fails(env, env.bob.address, o2, params(12, 1, sig), INVALID_SIGNATURE);
}

#[test]
fn account_return_value_must_be_valid_or_true() {
    let env = setup();
    for value in array![0, 2, 'INVALID', 'VALID' + 1] {
        let maker = deploy("FixedReturnAccount", array![value]);
        let o = order(env, ORDER_TYPE_ERC721_BUY_ORDER, maker, env.nft, 11, 1, 100);
        assert_fill_fails(
            env, env.bob.address, o, params(11, 1, array![1, 2].span()), INVALID_SIGNATURE,
        );
    }
    // 'VALID' and 1 are accepted (the fill then fails later, at payment, for lack of funds).
    for value in array!['VALID', 1] {
        let maker = deploy("FixedReturnAccount", array![value]);
        let o = order(env, ORDER_TYPE_ERC721_BUY_ORDER, maker, env.nft, 11, 1, 0);
        env.exchange.validate_signature(o, array![1, 2].span());
        fill(env, env.bob.address, o, params(11, 1, array![1, 2].span()));
        assert_eq!(owner_of(env, 11), maker);
        start_cheat_caller_address(env.nft, maker);
        openzeppelin_interfaces::erc721::IERC721Dispatcher { contract_address: env.nft }
            .transfer_from(maker, env.bob.address, 11);
        snforge_std::stop_cheat_caller_address(env.nft);
    }
}

#[test]
fn account_returning_nothing_is_rejected() {
    let env = setup();
    let maker = deploy("EmptyReturnAccount", array![]);
    let o = order(env, ORDER_TYPE_ERC721_BUY_ORDER, maker, env.nft, 11, 1, 0);
    assert_fill_fails(
        env, env.bob.address, o, params(11, 1, array![1, 2].span()), INVALID_SIGNATURE,
    );
}
