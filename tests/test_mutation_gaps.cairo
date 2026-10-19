// Tests added by the tester to kill mutants that the engineer's suite let survive (see the
// mutation table in the tester's report). Each test names the guard it pins.

use core::num::traits::Zero;
use pavilion_exchange::market::interface::{
    BULK_SIGNATURE_PREFIX, ERC721SellOrder, Fee, IExchangeAdminDispatcherTrait,
    IExchangeDispatcherTrait, ORDER_TYPE_ERC1155_SELL_ORDER, ORDER_TYPE_ERC721_SELL_ORDER,
    SIGNATURE_VALID, VALIDATE_ORDER_MAGIC,
};
use snforge_std::{
    Event, EventSpyTrait, spy_events, start_cheat_caller_address, stop_cheat_caller_address,
};
use starknet::ContractAddress;
use crate::mocks::IMintDispatcherTrait;
use crate::mocks_extra::{IDivergentERC1155Dispatcher, IDivergentERC1155DispatcherTrait};
use crate::utils::{
    Env, OWNER, PLATFORM, assert_fill_fails, bulk_leaves, bulk_message_hash, deploy, fill,
    merkle_proof, order, owner_of, params, public_key, setup, sign, sign_hash, strk_balance,
};

const INVALID_SIGNATURE: felt252 = 'Exchange: invalid signature';

/// Events of the exchange itself (not of the NFT or the token) since the spy was created.
fn exchange_events(env: Env, ref spy: snforge_std::EventSpy) -> Array<Event> {
    let mut out: Array<Event> = array![];
    for (from, event) in spy.get_events().events {
        if from == env.address {
            out.append(event);
        }
    }
    out
}

fn cancel(
    env: Env, caller: ContractAddress, orders: Array<pavilion_exchange::market::interface::Order>,
) {
    start_cheat_caller_address(env.address, caller);
    env.exchange.cancel_orders(orders.span());
    stop_cheat_caller_address(env.address);
}

// ---------------------------------------------------------------------------------------------
// Event layouts the indexer decodes

/// Mutants: `#[key]` removed from OrderCancelled.account / .order_hash and from
/// CounterIncremented.account survived because the engineer's tests rebuild the expected event
/// with the same (mutated) struct.
#[test]
fn cancel_and_counter_events_raw_layout() {
    let env = setup();
    let o = order(env, ORDER_TYPE_ERC721_SELL_ORDER, env.alice.address, env.nft, 1, 1, 100);
    let hash = env.exchange.get_order_hash(o);
    let mut spy = spy_events();

    cancel(env, env.alice.address, array![o]);
    start_cheat_caller_address(env.address, env.alice.address);
    assert_eq!(env.exchange.increment_counter(), 1);
    stop_cheat_caller_address(env.address);

    let events = exchange_events(env, ref spy);
    assert_eq!(events.len(), 2);
    let cancelled = events.at(0);
    assert_eq!(
        cancelled.keys.span(),
        array![selector!("OrderCancelled"), env.alice.address.into(), hash].span(),
    );
    assert_eq!(cancelled.data.len(), 0);
    let bumped = events.at(1);
    assert_eq!(
        bumped.keys.span(),
        array![selector!("CounterIncremented"), env.alice.address.into()].span(),
    );
    assert_eq!(bumped.data.span(), array![1].span());
}

/// Mutants: an extra or duplicated event in a state-changing call (survived because
/// `assert_emitted` only checks presence).
#[test]
fn every_call_emits_exactly_its_events() {
    let env = setup();
    let o1 = order(env, ORDER_TYPE_ERC721_SELL_ORDER, env.alice.address, env.nft, 1, 1, 100);
    let o2 = order(env, ORDER_TYPE_ERC721_SELL_ORDER, env.alice.address, env.nft, 2, 1, 100);
    let sig1 = sign(env, env.alice, o1);
    let sig2 = sign(env, env.alice, o2);

    // fill_order: one OrderFilled.
    let mut spy = spy_events();
    fill(env, env.bob.address, o1, params(1, 1, sig1));
    let events = exchange_events(env, ref spy);
    assert_eq!(events.len(), 1);
    assert_eq!(*events.at(0).keys.at(0), selector!("OrderFilled"));

    // buy_erc721: one OrderFilled.
    let short = ERC721SellOrder {
        maker: env.alice.address,
        listing_time: o2.listing_time,
        expiry_time: o2.expiry_time,
        salt: o2.salt,
        erc20_address: env.strk,
        erc20_amount: 100,
        fee0_recipient: Zero::zero(),
        fee0_amount: 0,
        fee1_recipient: Zero::zero(),
        fee1_amount: 0,
        nft_address: env.nft,
        nft_id: 2,
    };
    let mut spy = spy_events();
    start_cheat_caller_address(env.address, env.bob.address);
    env.exchange.buy_erc721(short, sig2);
    stop_cheat_caller_address(env.address);
    let events = exchange_events(env, ref spy);
    assert_eq!(events.len(), 1);
    assert_eq!(*events.at(0).keys.at(0), selector!("OrderFilled"));

    // cancel_orders: one OrderCancelled per order.
    let o3 = order(env, ORDER_TYPE_ERC721_SELL_ORDER, env.alice.address, env.nft, 3, 1, 100);
    let o4 = order(env, ORDER_TYPE_ERC721_SELL_ORDER, env.alice.address, env.nft, 4, 1, 100);
    let mut spy = spy_events();
    cancel(env, env.alice.address, array![o3, o4]);
    let events = exchange_events(env, ref spy);
    assert_eq!(events.len(), 2);
    assert_eq!(*events.at(0).keys.at(0), selector!("OrderCancelled"));
    assert_eq!(*events.at(1).keys.at(0), selector!("OrderCancelled"));
    assert_eq!(*events.at(0).keys.at(2), env.exchange.get_order_hash(o3));
    assert_eq!(*events.at(1).keys.at(2), env.exchange.get_order_hash(o4));

    // increment_counter: one CounterIncremented.
    let mut spy = spy_events();
    start_cheat_caller_address(env.address, env.bob.address);
    env.exchange.increment_counter();
    stop_cheat_caller_address(env.address);
    let events = exchange_events(env, ref spy);
    assert_eq!(events.len(), 1);
    assert_eq!(*events.at(0).keys.at(0), selector!("CounterIncremented"));

    // pause / unpause: only OpenZeppelin's Paused / Unpaused.
    let mut spy = spy_events();
    start_cheat_caller_address(env.address, OWNER());
    env.admin.pause();
    let events = exchange_events(env, ref spy);
    assert_eq!(events.len(), 1);
    assert_eq!(*events.at(0).keys.at(0), selector!("Paused"));
    let mut spy = spy_events();
    env.admin.unpause();
    stop_cheat_caller_address(env.address);
    let events = exchange_events(env, ref spy);
    assert_eq!(events.len(), 1);
    assert_eq!(*events.at(0).keys.at(0), selector!("Unpaused"));
}

// ---------------------------------------------------------------------------------------------
// Constants the tests of the engineer take from the contract itself

/// Mutants: VALIDATE_ORDER_MAGIC / BULK_SIGNATURE_PREFIX / SIGNATURE_VALID changed. The mocks and
/// helpers import the constants, so a changed value was invisible. These are the values external
/// validators, wallets-side signing code and accounts rely on.
#[test]
fn wire_constants_are_pinned() {
    assert_eq!(VALIDATE_ORDER_MAGIC, selector!("validate_pavilion_order"));
    // starknet_keccak("validate_pavilion_order"), computed independently with starknet.go.
    assert_eq!(
        VALIDATE_ORDER_MAGIC, 0x18d0327d89bca46769e4df5ed22f169175d7c5efed2c3b6f50c9e67dcdf0d71,
    );
    assert_eq!(BULK_SIGNATURE_PREFIX, 0xfefefef0);
    assert_eq!(SIGNATURE_VALID, 'VALID');
    assert_eq!(SIGNATURE_VALID, 0x56414c4944);
}

/// A bulk signature built only from literals (not the exported constant) is accepted.
#[test]
fn bulk_signature_with_literal_prefix_is_accepted() {
    let env = setup();
    let o1 = order(env, ORDER_TYPE_ERC721_SELL_ORDER, env.alice.address, env.nft, 1, 1, 100);
    let o2 = order(env, ORDER_TYPE_ERC721_SELL_ORDER, env.alice.address, env.nft, 2, 1, 100);
    let orders = array![o1, o2].span();
    let account_sig = sign_hash(
        crate::utils::ALICE_KEY, bulk_message_hash(env.address, env.alice.address, orders),
    );
    let proof = merkle_proof(bulk_leaves(env.address, orders), 1);
    let mut signature = array![0xfefefef0, 2, *account_sig[0], *account_sig[1]];
    for x in proof {
        signature.append(x);
    }
    fill(env, env.bob.address, o2, params(2, 1, signature.span()));
    assert_eq!(owner_of(env, 2), env.bob.address);
}

// ---------------------------------------------------------------------------------------------
// Zero-value fee transfers

/// Mutant: `if amount != 0` before a fee transfer replaced by `true`. A fee that rounds down to
/// zero for a partial fill must not produce a zero-value `transfer_from` (a token that rejects
/// zero transfers, or an event consumer counting transfers, would otherwise break).
#[test]
fn fee_that_prorates_to_zero_makes_no_token_transfer() {
    let env = setup();
    let mut o = order(
        env, ORDER_TYPE_ERC1155_SELL_ORDER, env.alice.address, env.nft1155, 7, 10, 1000,
    );
    o.fees = array![Fee { recipient: PLATFORM(), amount: 1 }].span(); // 3 * 1 / 10 = 0
    let sig = sign(env, env.alice, o);
    let mut spy = spy_events();
    fill(env, env.bob.address, o, params(7, 3, sig));

    let mut token_transfers = 0_u32;
    for (from, event) in spy.get_events().events {
        if from == env.strk && *event.keys.at(0) == selector!("Transfer") {
            token_transfers += 1;
            // The only transfer is the payment to the seller.
            assert_eq!(*event.keys.at(2), env.alice.address.into());
        }
    }
    assert_eq!(token_transfers, 1);
    assert_eq!(strk_balance(env, PLATFORM()), 0);
    assert_eq!(crate::utils::balance_1155(env, env.bob.address, 7), 103);
}

// ---------------------------------------------------------------------------------------------
// Entry point priority

/// Mutant: ERC1155 `safe_transfer_from` tried before `safeTransferFrom`. The documented order is
/// camelCase first (it exists on OpenZeppelin and on Cairo 0 collections alike).
#[test]
fn erc1155_camel_case_entry_point_is_called_first() {
    let env = setup();
    let coll = deploy("DivergentERC1155", array![]);
    IMintDispatcherTrait::mint(
        crate::mocks::IMintDispatcher { contract_address: coll }, env.alice.address, 5, 10,
    );
    let o = order(env, ORDER_TYPE_ERC1155_SELL_ORDER, env.alice.address, coll, 5, 10, 1000);
    fill(env, env.bob.address, o, params(5, 4, sign(env, env.alice, o)));
    let nft = IDivergentERC1155Dispatcher { contract_address: coll };
    assert_eq!(nft.balanceOf(env.bob.address, 5), 4);
    assert_eq!(nft.balanceOf(env.alice.address, 5), 6);
}

/// Mutant: the maker account's `isValidSignature` tried before `is_valid_signature`. Here the
/// two disagree: only the snake_case answer counts.
#[test]
fn account_snake_case_entry_point_has_priority() {
    let env = setup();
    let maker = deploy("DivergentAccount", array![]);
    let o = order(env, ORDER_TYPE_ERC721_SELL_ORDER, maker, env.nft, 1, 1, 0);
    // [1, 2] is accepted by is_valid_signature; anything else is rejected by it, although
    // isValidSignature would say yes.
    assert_fill_fails(
        env, env.bob.address, o, params(1, 1, array![3, 4].span()), INVALID_SIGNATURE,
    );
    env.exchange.validate_signature(o, array![1, 2].span());
    let _ = public_key(1);
}

/// Mutant: the account's own panic replaced by the generic invalid-signature error. The account's
/// error reaches the caller unchanged (the fill reverts either way).
#[test]
fn error_of_the_maker_account_propagates() {
    let env = setup();
    let maker = deploy("PanicAccount", array![]);
    let o = order(env, ORDER_TYPE_ERC721_SELL_ORDER, maker, env.nft, 1, 1, 0);
    assert_fill_fails(
        env, env.bob.address, o, params(1, 1, array![1, 2].span()), 'account exploded',
    );
}

/// A collection that panics with no data: the failure is not mistaken for a missing entry point.
#[test]
fn collection_panicking_without_data_fails_the_fill() {
    let env = setup();
    let coll = deploy("EmptyPanicERC721", array![]);
    let o = order(env, ORDER_TYPE_ERC721_SELL_ORDER, env.alice.address, coll, 1, 1, 100);
    let result = crate::utils::try_fill(
        env, env.bob.address, o, params(1, 1, sign(env, env.alice, o)),
    );
    match result {
        Result::Ok(_) => panic!("fill with a failing collection succeeded"),
        Result::Err(error) => { assert!(error.len() > 0); },
    }
}
