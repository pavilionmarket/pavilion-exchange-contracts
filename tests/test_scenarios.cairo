// Scenario matrix: collection types x order types, plus cancel / counter / pause interplay and
// multi-felt (multisig-style) and Cairo 0-style accounts. Written by the tester; all assertions are
// on observable balances, owners and order status, never on the contract's internals.
//
// ERC721 collection types:  Oz (snake_case + camelCase), Camel (camelCase only, like PVL),
//                           Snake (snake_case only).
// ERC1155 collection types: Oz (snake_case + camelCase), Snake (snake only), Camel (camel only).

use core::num::traits::Zero;
use openzeppelin_interfaces::erc1155::{IERC1155Dispatcher, IERC1155DispatcherTrait};
use openzeppelin_interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
use openzeppelin_interfaces::erc721::{IERC721Dispatcher, IERC721DispatcherTrait};
use pavilion_exchange::market::interface::{
    ERC721SellOrder, Fee, IExchangeAdminDispatcherTrait, IExchangeDispatcherTrait,
    IExchangeSafeDispatcherTrait, ORDER_TYPE_ERC1155_BUY_ORDER, ORDER_TYPE_ERC1155_CONTRACT_OFFER,
    ORDER_TYPE_ERC1155_SELL_ORDER, ORDER_TYPE_ERC721_BUY_ORDER, ORDER_TYPE_ERC721_CONTRACT_OFFER,
    ORDER_TYPE_ERC721_SELL_ORDER, Order, OrderStatus, VALIDATE_ORDER_MAGIC,
};
use snforge_std::{start_cheat_caller_address, stop_cheat_caller_address};
use starknet::ContractAddress;
use crate::mocks::{
    ICamelOnlyERC1155Dispatcher, ICamelOnlyERC1155DispatcherTrait, ICamelOnlyERC721Dispatcher,
    ICamelOnlyERC721DispatcherTrait, IMintDispatcher, IMintDispatcherTrait,
    IMockValidatorDispatcher, IMockValidatorDispatcherTrait, ISnakeOnlyERC1155Dispatcher,
    ISnakeOnlyERC1155DispatcherTrait, ISnakeOnlyERC721Dispatcher, ISnakeOnlyERC721DispatcherTrait,
};
use crate::utils::{
    ALICE_KEY, BOB_KEY, CAROL_KEY, Env, OWNER, PLATFORM, ROYALTY, assert_fill_fails, deploy, fill,
    order, params, public_key, setup, sign, sign_bulk, sign_hash, strk_balance,
};

const EXCEEDS: felt252 = 'Exchange: exceeds nft amount';
const CANCELLED: felt252 = 'Exchange: order cancelled';
const COUNTER: felt252 = 'Exchange: unmatched counter';
const PAUSED: felt252 = 'Pausable: paused';
const BAD_TAKER: felt252 = 'Exchange: invalid recipient';
const BAD_VALIDATOR: felt252 = 'Exchange: validate order error';
const BAD_SIGNATURE: felt252 = 'Exchange: invalid signature';
const BAD_FILL_AMOUNT: felt252 = 'Exchange: invalid fill amount';

// ---------------------------------------------------------------------------------------------
// Collection adapters

#[derive(Copy, Drop)]
enum Kind {
    Oz,
    Camel,
    Snake,
}

fn nft721(env: Env, kind: Kind) -> ContractAddress {
    match kind {
        Kind::Oz => env.nft,
        Kind::Camel => env.camel_nft,
        Kind::Snake => env.snake_nft,
    }
}

fn owner721(env: Env, kind: Kind, id: u256) -> ContractAddress {
    match kind {
        Kind::Oz => IERC721Dispatcher { contract_address: env.nft }.owner_of(id),
        Kind::Camel => ICamelOnlyERC721Dispatcher { contract_address: env.camel_nft }.ownerOf(id),
        Kind::Snake => ISnakeOnlyERC721Dispatcher { contract_address: env.snake_nft }.owner_of(id),
    }
}

/// An ERC1155 collection for `kind`, with 100 units of id 7 for alice, bob and carol, of id 9 for
/// bob and carol, and of id 1 for alice and bob. (Snake/Camel collections do not model approvals.)
fn nft1155(env: Env, kind: Kind) -> ContractAddress {
    let coll = match kind {
        Kind::Oz => env.nft1155,
        Kind::Camel => deploy("CamelOnlyERC1155", array![]),
        Kind::Snake => deploy("SnakeOnlyERC1155", array![]),
    };
    match kind {
        Kind::Oz => {},
        _ => {
            let mint = IMintDispatcher { contract_address: coll };
            mint.mint(env.alice.address, 7, 100);
            mint.mint(env.alice.address, 1, 100);
            mint.mint(env.bob.address, 7, 100);
            mint.mint(env.bob.address, 9, 100);
            mint.mint(env.bob.address, 1, 100);
            mint.mint(env.carol.address, 7, 100);
            mint.mint(env.carol.address, 9, 100);
        },
    }
    coll
}

fn bal1155(kind: Kind, coll: ContractAddress, who: ContractAddress, id: u256) -> u256 {
    match kind {
        Kind::Oz => IERC1155Dispatcher { contract_address: coll }.balance_of(who, id),
        Kind::Camel => ICamelOnlyERC1155Dispatcher { contract_address: coll }.balanceOf(who, id),
        Kind::Snake => ISnakeOnlyERC1155Dispatcher { contract_address: coll }.balance_of(who, id),
    }
}

// ---------------------------------------------------------------------------------------------
// Helpers

fn fees2(platform: u128, royalty: u128) -> Span<Fee> {
    array![
        Fee { recipient: PLATFORM(), amount: platform },
        Fee { recipient: ROYALTY(), amount: royalty },
    ]
        .span()
}

fn status(env: Env, o: Order) -> OrderStatus {
    env.exchange.get_order_status(env.exchange.get_order_hash(o))
}

fn filled(env: Env, o: Order) -> u128 {
    status(env, o).filled_amount
}

fn cancel(env: Env, caller: ContractAddress, orders: Array<Order>) {
    start_cheat_caller_address(env.address, caller);
    env.exchange.cancel_orders(orders.span());
    stop_cheat_caller_address(env.address);
}

fn bump_counter(env: Env, caller: ContractAddress) {
    start_cheat_caller_address(env.address, caller);
    env.exchange.increment_counter();
    stop_cheat_caller_address(env.address);
}

fn pause(env: Env) {
    start_cheat_caller_address(env.address, OWNER());
    env.admin.pause();
    stop_cheat_caller_address(env.address);
}

fn unpause(env: Env) {
    start_cheat_caller_address(env.address, OWNER());
    env.admin.unpause();
    stop_cheat_caller_address(env.address);
}

/// The `buy_erc721` short form of a listing with at most two fees.
fn short_of(o: Order) -> ERC721SellOrder {
    let mut fee0 = Fee { recipient: Zero::zero(), amount: 0 };
    let mut fee1 = Fee { recipient: Zero::zero(), amount: 0 };
    if o.fees.len() > 0 {
        fee0 = *o.fees.at(0);
    }
    if o.fees.len() > 1 {
        fee1 = *o.fees.at(1);
    }
    ERC721SellOrder {
        maker: o.maker,
        listing_time: o.listing_time,
        expiry_time: o.expiry_time,
        salt: o.salt,
        erc20_address: o.erc20_address,
        erc20_amount: o.erc20_amount,
        fee0_recipient: fee0.recipient,
        fee0_amount: fee0.amount,
        fee1_recipient: fee1.recipient,
        fee1_amount: fee1.amount,
        nft_address: o.nft_address,
        nft_id: o.nft_id,
    }
}

fn buy(env: Env, caller: ContractAddress, o: Order, signature: Span<felt252>) {
    start_cheat_caller_address(env.address, caller);
    env.exchange.buy_erc721(short_of(o), signature);
    stop_cheat_caller_address(env.address);
}

#[feature("safe_dispatcher")]
fn try_buy(
    env: Env, caller: ContractAddress, o: Order, signature: Span<felt252>,
) -> Result<(), Array<felt252>> {
    start_cheat_caller_address(env.address, caller);
    let result = env.safe.buy_erc721(short_of(o), signature);
    stop_cheat_caller_address(env.address);
    result
}

fn assert_failed(result: Result<(), Array<felt252>>, expected: felt252) {
    crate::utils::assert_fails_with(result, expected);
}

// ---------------------------------------------------------------------------------------------
// ERC721 x order types

fn erc721_listing_fill_order(kind: Kind) {
    let env = setup();
    let nft = nft721(env, kind);
    let mut o = order(env, ORDER_TYPE_ERC721_SELL_ORDER, env.alice.address, nft, 1, 1, 1000);
    o.fees = fees2(25, 50);
    let sig = sign(env, env.alice, o);
    let (a0, b0) = (strk_balance(env, env.alice.address), strk_balance(env, env.bob.address));

    fill(env, env.bob.address, o, params(1, 1, sig));

    assert_eq!(owner721(env, kind, 1), env.bob.address);
    assert_eq!(strk_balance(env, env.alice.address), a0 + 925);
    assert_eq!(strk_balance(env, env.bob.address), b0 - 1000);
    assert_eq!(strk_balance(env, PLATFORM()), 25);
    assert_eq!(strk_balance(env, ROYALTY()), 50);
    assert_eq!(status(env, o), OrderStatus { is_cancelled: false, filled_amount: 1 });
    // A second buyer cannot fill it again.
    assert_fill_fails(env, env.carol.address, o, params(1, 1, sig), EXCEEDS);
}

fn erc721_listing_buy_erc721(kind: Kind) {
    let env = setup();
    let nft = nft721(env, kind);
    let mut o = order(env, ORDER_TYPE_ERC721_SELL_ORDER, env.alice.address, nft, 2, 1, 1000);
    o.fees = fees2(25, 50);
    let sig = sign(env, env.alice, o);
    let b0 = strk_balance(env, env.bob.address);

    buy(env, env.bob.address, o, sig);

    assert_eq!(owner721(env, kind, 2), env.bob.address);
    assert_eq!(b0 - strk_balance(env, env.bob.address), 1000);
    assert_eq!(strk_balance(env, PLATFORM()), 25);
    assert_eq!(strk_balance(env, ROYALTY()), 50);
    // The status is kept under the full order's hash, shared with fill_order.
    assert_eq!(filled(env, o), 1);
    assert_fill_fails(env, env.carol.address, o, params(2, 1, sig), EXCEEDS);
    assert_failed(try_buy(env, env.carol.address, o, sig), EXCEEDS);
}

fn erc721_listing_to_another_recipient(kind: Kind) {
    let env = setup();
    let nft = nft721(env, kind);
    let o = order(env, ORDER_TYPE_ERC721_SELL_ORDER, env.alice.address, nft, 3, 1, 1000);
    let mut p = params(3, 1, sign(env, env.alice, o));
    p.recipient = env.carol.address;
    let (b0, c0) = (strk_balance(env, env.bob.address), strk_balance(env, env.carol.address));

    fill(env, env.bob.address, o, p);

    assert_eq!(owner721(env, kind, 3), env.carol.address);
    assert_eq!(b0 - strk_balance(env, env.bob.address), 1000);
    assert_eq!(strk_balance(env, env.carol.address), c0);
}

fn erc721_item_offer(kind: Kind) {
    let env = setup();
    let nft = nft721(env, kind);
    // carol offers 500 for bob's token 11; 2% platform fee.
    let mut o = order(env, ORDER_TYPE_ERC721_BUY_ORDER, env.carol.address, nft, 11, 1, 500);
    o.fees = array![Fee { recipient: PLATFORM(), amount: 10 }].span();
    let sig = sign(env, env.carol, o);
    let (b0, c0) = (strk_balance(env, env.bob.address), strk_balance(env, env.carol.address));

    fill(env, env.bob.address, o, params(11, 1, sig));

    assert_eq!(owner721(env, kind, 11), env.carol.address);
    assert_eq!(strk_balance(env, env.bob.address), b0 + 490);
    assert_eq!(c0 - strk_balance(env, env.carol.address), 500);
    assert_eq!(strk_balance(env, PLATFORM()), 10);
    // Only the offered token can be sold into an item offer.
    assert_fill_fails(env, env.bob.address, o, params(12, 1, sig), 'Exchange: invalid fill id');
    // The payment can go to a different recipient than the seller.
    let mut o2 = o;
    o2.nft_id = 21;
    o2.salt = 99;
    let mut p = params(21, 1, sign(env, env.carol, o2));
    p.recipient = env.alice.address;
    let a0 = strk_balance(env, env.alice.address);
    let bob_before = strk_balance(env, env.bob.address);
    // carol gives token 21 herself and the payment (minus fee) goes to alice.
    fill(env, env.carol.address, o2, p);
    assert_eq!(strk_balance(env, env.alice.address), a0 + 490);
    assert_eq!(strk_balance(env, env.bob.address), bob_before);
}

fn erc721_collection_offer_two_sellers(kind: Kind) {
    let env = setup();
    let nft = nft721(env, kind);
    // alice offers 200 for any 2 tokens; the fee is 20 for the whole offer.
    let mut o = order(env, ORDER_TYPE_ERC721_CONTRACT_OFFER, env.alice.address, nft, 0, 2, 200);
    o.fees = array![Fee { recipient: PLATFORM(), amount: 20 }].span();
    let sig = sign(env, env.alice, o);
    let (a0, b0, c0) = (
        strk_balance(env, env.alice.address),
        strk_balance(env, env.bob.address),
        strk_balance(env, env.carol.address),
    );

    fill(env, env.bob.address, o, params(11, 1, sig));
    assert_eq!(owner721(env, kind, 11), env.alice.address);
    assert_eq!(strk_balance(env, env.bob.address), b0 + 90);
    assert_eq!(filled(env, o), 1);

    fill(env, env.carol.address, o, params(21, 1, sig));
    assert_eq!(owner721(env, kind, 21), env.alice.address);
    assert_eq!(strk_balance(env, env.carol.address), c0 + 90);
    assert_eq!(filled(env, o), 2);

    assert_eq!(a0 - strk_balance(env, env.alice.address), 200);
    assert_eq!(strk_balance(env, PLATFORM()), 20);
    // Third sale: the offer is exhausted.
    assert_fill_fails(env, env.bob.address, o, params(12, 1, sig), EXCEEDS);
    // A token the seller does not own cannot be sold (the collection refuses).
    let mut o2 = o;
    o2.salt = 5;
    let result = crate::utils::try_fill(
        env, env.bob.address, o2, params(1, 1, sign(env, env.alice, o2)),
    );
    assert!(result.is_err(), "sold a token bob does not own");
    assert_eq!(owner721(env, kind, 1), env.alice.address);
}

fn erc721_bulk_listings(kind: Kind) {
    let env = setup();
    let nft = nft721(env, kind);
    let mut orders: Array<Order> = array![];
    for i in 0..5_u32 {
        let id: u256 = 1 + i.into();
        let mut o = order(
            env, ORDER_TYPE_ERC721_SELL_ORDER, env.alice.address, nft, id, 1, 100 * (1 + i.into()),
        );
        o.salt = 1000 + i.into();
        orders.append(o);
    }
    let orders = orders.span();
    let sigs = sign_bulk(env, env.alice, orders);

    // Fill #1 (bob), the odd last leaf #4 (carol) and #0 (bob), each with its own proof.
    fill(env, env.bob.address, *orders.at(1), params(2, 1, *sigs.at(1)));
    fill(env, env.carol.address, *orders.at(4), params(5, 1, *sigs.at(4)));
    fill(env, env.bob.address, *orders.at(0), params(1, 1, *sigs.at(0)));
    assert_eq!(owner721(env, kind, 2), env.bob.address);
    assert_eq!(owner721(env, kind, 5), env.carol.address);
    assert_eq!(owner721(env, kind, 1), env.bob.address);
    // Status is per single-order hash: the untouched ones are untouched.
    assert_eq!(filled(env, *orders.at(2)), 0);
    assert_eq!(filled(env, *orders.at(3)), 0);
    assert_eq!(filled(env, *orders.at(1)), 1);
    // A proof for another order does not fit.
    assert_fill_fails(
        env, env.bob.address, *orders.at(3), params(4, 1, *sigs.at(2)), BAD_SIGNATURE,
    );
    // Cancelling one bulk member leaves the others fillable.
    cancel(env, env.alice.address, array![*orders.at(2)]);
    assert_fill_fails(env, env.bob.address, *orders.at(2), params(3, 1, *sigs.at(2)), CANCELLED);
    // The same bulk signature still fills the sibling.
    fill(env, env.carol.address, *orders.at(3), params(4, 1, *sigs.at(3)));
    assert_eq!(owner721(env, kind, 4), env.carol.address);
    // Exact payments: alice received 200 + 500 + 100 + 400.
    assert_eq!(strk_balance(env, env.alice.address) - 1_000_000_000_000_000_000_000_000, 1200);
}

fn erc721_bulk_invalidated_by_counter(kind: Kind) {
    let env = setup();
    let nft = nft721(env, kind);
    let o1 = order(env, ORDER_TYPE_ERC721_SELL_ORDER, env.alice.address, nft, 1, 1, 100);
    let mut o2 = o1;
    o2.nft_id = 2;
    let orders = array![o1, o2].span();
    let sigs = sign_bulk(env, env.alice, orders);
    bump_counter(env, env.alice.address);
    assert_fill_fails(env, env.bob.address, o1, params(1, 1, *sigs.at(0)), COUNTER);
    assert_fill_fails(env, env.bob.address, o2, params(2, 1, *sigs.at(1)), COUNTER);
}

fn erc721_private_taker(kind: Kind) {
    let env = setup();
    let nft = nft721(env, kind);
    let mut o = order(env, ORDER_TYPE_ERC721_SELL_ORDER, env.alice.address, nft, 4, 1, 1000);
    o.taker = env.carol.address;
    let sig = sign(env, env.alice, o);
    // bob is not the taker...
    assert_fill_fails(env, env.bob.address, o, params(4, 1, sig), BAD_TAKER);
    // ...also not through buy_erc721's short form, which has no taker (so signs differently).
    // carol is.
    fill(env, env.carol.address, o, params(4, 1, sig));
    assert_eq!(owner721(env, kind, 4), env.carol.address);

    // The restriction is on the recipient: bob may pay for carol (the NFT goes to carol).
    let mut o2 = order(env, ORDER_TYPE_ERC721_SELL_ORDER, env.alice.address, nft, 5, 1, 1000);
    o2.taker = env.carol.address;
    let mut p = params(5, 1, sign(env, env.alice, o2));
    p.recipient = env.carol.address;
    fill(env, env.bob.address, o2, p);
    assert_eq!(owner721(env, kind, 5), env.carol.address);

    // A private item offer: alice offers for carol's token 21 but only to bob.
    let mut offer = order(env, ORDER_TYPE_ERC721_BUY_ORDER, env.alice.address, nft, 21, 1, 300);
    offer.taker = env.bob.address;
    let offer_sig = sign(env, env.alice, offer);
    assert_fill_fails(env, env.carol.address, offer, params(21, 1, offer_sig), BAD_TAKER);
}

fn erc721_validator(kind: Kind) {
    let env = setup();
    let nft = nft721(env, kind);
    let validator = deploy("MockOrderValidator", array![VALIDATE_ORDER_MAGIC]);
    let mock = IMockValidatorDispatcher { contract_address: validator };
    let root_felt: felt252 = 0xabc123;
    let root: u256 = root_felt.into();
    let mut o = order(env, ORDER_TYPE_ERC721_CONTRACT_OFFER, env.alice.address, nft, root, 3, 300);
    o.order_validator = validator;
    let sig = sign(env, env.alice, o);
    let mut p = params(11, 1, sig);
    p.extra_data = array![4, 5].span();

    fill(env, env.bob.address, o, p);
    assert_eq!(owner721(env, kind, 11), env.alice.address);
    let (seen_nft, seen_id, seen_root, seen_hash, seen_extra) = mock.last_call();
    assert_eq!(seen_nft, nft);
    assert_eq!(seen_id, 11);
    assert_eq!(seen_root, root_felt);
    assert_eq!(seen_hash, env.exchange.get_order_hash(o));
    assert_eq!(seen_extra, array![4, 5].span());

    // The validator rejects: nothing moves, the status is unchanged.
    mock.set_result('nope');
    assert_fill_fails(env, env.carol.address, o, params(21, 1, sig), BAD_VALIDATOR);
    assert_eq!(owner721(env, kind, 21), env.carol.address);
    assert_eq!(filled(env, o), 1);
    mock.set_result(VALIDATE_ORDER_MAGIC);
    fill(env, env.carol.address, o, params(21, 1, sig));
    assert_eq!(filled(env, o), 2);

    // A listing with a validator: the validator sees merkle root 0.
    let mut l = order(env, ORDER_TYPE_ERC721_SELL_ORDER, env.bob.address, nft, 12, 1, 100);
    l.order_validator = validator;
    fill(env, env.alice.address, l, params(12, 1, sign(env, env.bob, l)));
    let (_, seen_id, seen_root, _, _) = mock.last_call();
    assert_eq!(seen_id, 12);
    assert_eq!(seen_root, 0);
    assert_eq!(owner721(env, kind, 12), env.alice.address);
}

fn erc721_cancel_counter_pause(kind: Kind) {
    let env = setup();
    let nft = nft721(env, kind);
    let mk = |id: u256, salt: u128| {
        let mut o = order(env, ORDER_TYPE_ERC721_SELL_ORDER, env.alice.address, nft, id, 1, 100);
        o.salt = salt;
        o
    };
    let (o1, o2, o3) = (mk(1, 1), mk(2, 2), mk(3, 3));
    let (s1, s2, s3) = (
        sign(env, env.alice, o1), sign(env, env.alice, o2), sign(env, env.alice, o3),
    );

    cancel(env, env.alice.address, array![o1]);
    assert_fill_fails(env, env.bob.address, o1, params(1, 1, s1), CANCELLED);

    pause(env);
    assert_fill_fails(env, env.bob.address, o2, params(2, 1, s2), PAUSED);
    assert_failed(try_buy(env, env.bob.address, o3, s3), PAUSED);
    // While paused the maker can still protect herself.
    cancel(env, env.alice.address, array![o2]);
    bump_counter(env, env.alice.address);
    unpause(env);

    // o2 is both cancelled and from an old counter: either way it cannot be filled.
    assert!(status(env, o2).is_cancelled && status(env, o1).is_cancelled);
    assert_fill_fails(env, env.bob.address, o2, params(2, 1, s2), COUNTER);
    assert_fill_fails(env, env.bob.address, o3, params(3, 1, s3), COUNTER);
    // buy_erc721 re-reads the counter, so the old signature no longer matches the order it expands
    // to.
    assert_failed(try_buy(env, env.bob.address, o3, s3), BAD_SIGNATURE);
    // Everything was protected: no token moved.
    assert_eq!(owner721(env, kind, 1), env.alice.address);
    assert_eq!(owner721(env, kind, 2), env.alice.address);
    assert_eq!(owner721(env, kind, 3), env.alice.address);

    // A new order with the new counter works.
    let mut fresh = order(env, ORDER_TYPE_ERC721_SELL_ORDER, env.alice.address, nft, 3, 1, 100);
    fresh.counter = env.exchange.get_counter(env.alice.address);
    assert_eq!(fresh.counter, 1);
    fill(env, env.bob.address, fresh, params(3, 1, sign(env, env.alice, fresh)));
    assert_eq!(owner721(env, kind, 3), env.bob.address);
}

#[test]
fn oz_erc721_listing_fill_order() {
    erc721_listing_fill_order(Kind::Oz);
}
#[test]
fn camel_erc721_listing_fill_order() {
    erc721_listing_fill_order(Kind::Camel);
}
#[test]
fn snake_erc721_listing_fill_order() {
    erc721_listing_fill_order(Kind::Snake);
}
#[test]
fn oz_erc721_listing_buy_erc721() {
    erc721_listing_buy_erc721(Kind::Oz);
}
#[test]
fn camel_erc721_listing_buy_erc721() {
    erc721_listing_buy_erc721(Kind::Camel);
}
#[test]
fn snake_erc721_listing_buy_erc721() {
    erc721_listing_buy_erc721(Kind::Snake);
}
#[test]
fn oz_erc721_listing_to_another_recipient() {
    erc721_listing_to_another_recipient(Kind::Oz);
}
#[test]
fn camel_erc721_listing_to_another_recipient() {
    erc721_listing_to_another_recipient(Kind::Camel);
}
#[test]
fn snake_erc721_listing_to_another_recipient() {
    erc721_listing_to_another_recipient(Kind::Snake);
}
#[test]
fn oz_erc721_item_offer() {
    erc721_item_offer(Kind::Oz);
}
#[test]
fn camel_erc721_item_offer() {
    erc721_item_offer(Kind::Camel);
}
#[test]
fn snake_erc721_item_offer() {
    erc721_item_offer(Kind::Snake);
}
#[test]
fn oz_erc721_collection_offer_two_sellers() {
    erc721_collection_offer_two_sellers(Kind::Oz);
}
#[test]
fn camel_erc721_collection_offer_two_sellers() {
    erc721_collection_offer_two_sellers(Kind::Camel);
}
#[test]
fn snake_erc721_collection_offer_two_sellers() {
    erc721_collection_offer_two_sellers(Kind::Snake);
}
#[test]
fn oz_erc721_bulk_listings() {
    erc721_bulk_listings(Kind::Oz);
}
#[test]
fn camel_erc721_bulk_listings() {
    erc721_bulk_listings(Kind::Camel);
}
#[test]
fn snake_erc721_bulk_listings() {
    erc721_bulk_listings(Kind::Snake);
}
#[test]
fn oz_erc721_bulk_invalidated_by_counter() {
    erc721_bulk_invalidated_by_counter(Kind::Oz);
}
#[test]
fn camel_erc721_bulk_invalidated_by_counter() {
    erc721_bulk_invalidated_by_counter(Kind::Camel);
}
#[test]
fn snake_erc721_bulk_invalidated_by_counter() {
    erc721_bulk_invalidated_by_counter(Kind::Snake);
}
#[test]
fn oz_erc721_private_taker() {
    erc721_private_taker(Kind::Oz);
}
#[test]
fn camel_erc721_private_taker() {
    erc721_private_taker(Kind::Camel);
}
#[test]
fn snake_erc721_private_taker() {
    erc721_private_taker(Kind::Snake);
}
#[test]
fn oz_erc721_validator() {
    erc721_validator(Kind::Oz);
}
#[test]
fn camel_erc721_validator() {
    erc721_validator(Kind::Camel);
}
#[test]
fn snake_erc721_validator() {
    erc721_validator(Kind::Snake);
}
#[test]
fn oz_erc721_cancel_counter_pause() {
    erc721_cancel_counter_pause(Kind::Oz);
}
#[test]
fn camel_erc721_cancel_counter_pause() {
    erc721_cancel_counter_pause(Kind::Camel);
}
#[test]
fn snake_erc721_cancel_counter_pause() {
    erc721_cancel_counter_pause(Kind::Snake);
}

// ---------------------------------------------------------------------------------------------
// ERC1155 x order types

fn erc1155_listing_partial_fills(kind: Kind) {
    let env = setup();
    let coll = nft1155(env, kind);
    // 10 units for 1007, platform fee 33: neither divides evenly, so every fill rounds down.
    let mut o = order(env, ORDER_TYPE_ERC1155_SELL_ORDER, env.alice.address, coll, 7, 10, 1007);
    o.fees = array![Fee { recipient: PLATFORM(), amount: 33 }].span();
    let sig = sign(env, env.alice, o);
    let (a0, b0, c0) = (
        strk_balance(env, env.alice.address),
        strk_balance(env, env.bob.address),
        strk_balance(env, env.carol.address),
    );

    fill(env, env.bob.address, o, params(7, 3, sig));
    // pays floor(1007 * 3 / 10) = 302, fee floor(33 * 3 / 10) = 9
    assert_eq!(bal1155(kind, coll, env.alice.address, 7), 97);
    assert_eq!(bal1155(kind, coll, env.bob.address, 7), 103);
    assert_eq!(b0 - strk_balance(env, env.bob.address), 302);
    assert_eq!(strk_balance(env, env.alice.address), a0 + 293);
    assert_eq!(strk_balance(env, PLATFORM()), 9);
    assert_eq!(filled(env, o), 3);

    fill(env, env.carol.address, o, params(7, 7, sig));
    // pays floor(1007 * 7 / 10) = 704, fee floor(33 * 7 / 10) = 23
    assert_eq!(bal1155(kind, coll, env.alice.address, 7), 90);
    assert_eq!(bal1155(kind, coll, env.carol.address, 7), 107);
    assert_eq!(c0 - strk_balance(env, env.carol.address), 704);
    assert_eq!(strk_balance(env, env.alice.address), a0 + 293 + 681);
    assert_eq!(strk_balance(env, PLATFORM()), 32);
    assert_eq!(filled(env, o), 10);

    // Sold out; bad amounts and ids are rejected even before.
    assert_fill_fails(env, env.bob.address, o, params(7, 1, sig), EXCEEDS);
    assert_fill_fails(env, env.bob.address, o, params(7, 0, sig), BAD_FILL_AMOUNT);
    assert_fill_fails(env, env.bob.address, o, params(7, 11, sig), BAD_FILL_AMOUNT);
    assert_fill_fails(env, env.bob.address, o, params(9, 1, sig), 'Exchange: invalid fill id');
}

fn erc1155_item_offer_partial_fills(kind: Kind) {
    let env = setup();
    let coll = nft1155(env, kind);
    // bob wants 6 units of id 7 for 600, platform fee 12.
    let mut o = order(env, ORDER_TYPE_ERC1155_BUY_ORDER, env.bob.address, coll, 7, 6, 600);
    o.fees = array![Fee { recipient: PLATFORM(), amount: 12 }].span();
    let sig = sign(env, env.bob, o);
    let (a0, b0, c0) = (
        strk_balance(env, env.alice.address),
        strk_balance(env, env.bob.address),
        strk_balance(env, env.carol.address),
    );

    fill(env, env.alice.address, o, params(7, 4, sig));
    assert_eq!(bal1155(kind, coll, env.alice.address, 7), 96);
    assert_eq!(bal1155(kind, coll, env.bob.address, 7), 104);
    assert_eq!(strk_balance(env, env.alice.address), a0 + 392);
    assert_eq!(b0 - strk_balance(env, env.bob.address), 400);

    fill(env, env.carol.address, o, params(7, 2, sig));
    assert_eq!(bal1155(kind, coll, env.carol.address, 7), 98);
    assert_eq!(bal1155(kind, coll, env.bob.address, 7), 106);
    assert_eq!(strk_balance(env, env.carol.address), c0 + 196);
    assert_eq!(b0 - strk_balance(env, env.bob.address), 600);
    assert_eq!(strk_balance(env, PLATFORM()), 12);
    assert_eq!(filled(env, o), 6);

    assert_fill_fails(env, env.alice.address, o, params(7, 1, sig), EXCEEDS);
    assert_fill_fails(env, env.alice.address, o, params(9, 1, sig), 'Exchange: invalid fill id');
}

fn erc1155_collection_offer_multiple_sellers(kind: Kind) {
    let env = setup();
    let coll = nft1155(env, kind);
    // alice wants any 5 units for 503 (platform fee 26): rounding on each partial fill.
    let mut o = order(env, ORDER_TYPE_ERC1155_CONTRACT_OFFER, env.alice.address, coll, 0, 5, 503);
    o.fees = array![Fee { recipient: PLATFORM(), amount: 26 }].span();
    let sig = sign(env, env.alice, o);
    let (a0, b0, c0) = (
        strk_balance(env, env.alice.address),
        strk_balance(env, env.bob.address),
        strk_balance(env, env.carol.address),
    );

    fill(env, env.bob.address, o, params(9, 2, sig)); // pays floor(503*2/5) = 201, fee 10
    assert_eq!(bal1155(kind, coll, env.alice.address, 9), 2);
    assert_eq!(bal1155(kind, coll, env.bob.address, 9), 98);
    assert_eq!(strk_balance(env, env.bob.address), b0 + 191);

    fill(env, env.carol.address, o, params(7, 3, sig)); // pays floor(503*3/5) = 301, fee 15
    assert_eq!(bal1155(kind, coll, env.alice.address, 7), 103);
    assert_eq!(bal1155(kind, coll, env.carol.address, 7), 97);
    assert_eq!(strk_balance(env, env.carol.address), c0 + 286);

    assert_eq!(a0 - strk_balance(env, env.alice.address), 502);
    assert_eq!(strk_balance(env, PLATFORM()), 25);
    assert_eq!(filled(env, o), 5);
    assert_fill_fails(env, env.bob.address, o, params(9, 1, sig), EXCEEDS);
}

fn erc1155_bulk_listings(kind: Kind) {
    let env = setup();
    let coll = nft1155(env, kind);
    let o0 = order(env, ORDER_TYPE_ERC1155_SELL_ORDER, env.alice.address, coll, 1, 10, 100);
    let mut o1 = order(env, ORDER_TYPE_ERC1155_SELL_ORDER, env.alice.address, coll, 7, 20, 200);
    o1.salt = 2;
    let mut o2 = order(env, ORDER_TYPE_ERC1155_SELL_ORDER, env.alice.address, coll, 1, 30, 300);
    o2.salt = 3;
    let orders = array![o0, o1, o2].span();
    let sigs = sign_bulk(env, env.alice, orders);

    fill(env, env.bob.address, o1, params(7, 5, *sigs.at(1)));
    fill(env, env.carol.address, o1, params(7, 15, *sigs.at(1)));
    fill(env, env.carol.address, o0, params(1, 10, *sigs.at(0)));
    assert_eq!(bal1155(kind, coll, env.alice.address, 7), 80);
    assert_eq!(bal1155(kind, coll, env.bob.address, 7), 105);
    assert_eq!(bal1155(kind, coll, env.carol.address, 7), 115);
    assert_eq!(bal1155(kind, coll, env.alice.address, 1), 90);
    assert_eq!(filled(env, o1), 20);
    assert_eq!(filled(env, o0), 10);
    assert_eq!(filled(env, o2), 0);

    cancel(env, env.alice.address, array![o2]);
    assert_fill_fails(env, env.bob.address, o2, params(1, 5, *sigs.at(2)), CANCELLED);
    // alice received 50 + 150 + 100.
    assert_eq!(strk_balance(env, env.alice.address) - 1_000_000_000_000_000_000_000_000, 300);
}

fn erc1155_private_taker(kind: Kind) {
    let env = setup();
    let coll = nft1155(env, kind);
    let mut o = order(env, ORDER_TYPE_ERC1155_SELL_ORDER, env.alice.address, coll, 7, 10, 100);
    o.taker = env.carol.address;
    let sig = sign(env, env.alice, o);
    assert_fill_fails(env, env.bob.address, o, params(7, 1, sig), BAD_TAKER);
    fill(env, env.carol.address, o, params(7, 4, sig));
    fill(env, env.carol.address, o, params(7, 6, sig));
    assert_eq!(bal1155(kind, coll, env.carol.address, 7), 110);
    assert_eq!(filled(env, o), 10);
}

fn erc1155_validator(kind: Kind) {
    let env = setup();
    let coll = nft1155(env, kind);
    let validator = deploy("MockOrderValidator", array![VALIDATE_ORDER_MAGIC]);
    let mock = IMockValidatorDispatcher { contract_address: validator };
    let root_felt: felt252 = 0x5eed;
    let mut o = order(
        env, ORDER_TYPE_ERC1155_CONTRACT_OFFER, env.alice.address, coll, root_felt.into(), 4, 400,
    );
    o.order_validator = validator;
    let sig = sign(env, env.alice, o);

    fill(env, env.bob.address, o, params(9, 2, sig));
    let (seen_nft, seen_id, seen_root, seen_hash, _) = mock.last_call();
    assert_eq!((seen_nft, seen_id, seen_root), (coll, 9, root_felt));
    assert_eq!(seen_hash, env.exchange.get_order_hash(o));
    assert_eq!(bal1155(kind, coll, env.alice.address, 9), 2);

    mock.set_result(0);
    assert_fill_fails(env, env.carol.address, o, params(9, 2, sig), BAD_VALIDATOR);
    assert_eq!(bal1155(kind, coll, env.carol.address, 9), 100);
    assert_eq!(filled(env, o), 2);
}

fn erc1155_cancel_and_pause_after_partial_fill(kind: Kind) {
    let env = setup();
    let coll = nft1155(env, kind);
    let o = order(env, ORDER_TYPE_ERC1155_SELL_ORDER, env.alice.address, coll, 7, 10, 1000);
    let sig = sign(env, env.alice, o);
    fill(env, env.bob.address, o, params(7, 3, sig));

    pause(env);
    assert_fill_fails(env, env.carol.address, o, params(7, 7, sig), PAUSED);
    cancel(env, env.alice.address, array![o]);
    unpause(env);

    assert_fill_fails(env, env.carol.address, o, params(7, 7, sig), CANCELLED);
    assert_eq!(status(env, o), OrderStatus { is_cancelled: true, filled_amount: 3 });
    assert_eq!(bal1155(kind, coll, env.alice.address, 7), 97);
    assert_eq!(bal1155(kind, coll, env.carol.address, 7), 100);
}

#[test]
fn oz_erc1155_listing_partial_fills() {
    erc1155_listing_partial_fills(Kind::Oz);
}
#[test]
fn snake_erc1155_listing_partial_fills() {
    erc1155_listing_partial_fills(Kind::Snake);
}
#[test]
fn camel_erc1155_listing_partial_fills() {
    erc1155_listing_partial_fills(Kind::Camel);
}
#[test]
fn oz_erc1155_item_offer_partial_fills() {
    erc1155_item_offer_partial_fills(Kind::Oz);
}
#[test]
fn snake_erc1155_item_offer_partial_fills() {
    erc1155_item_offer_partial_fills(Kind::Snake);
}
#[test]
fn camel_erc1155_item_offer_partial_fills() {
    erc1155_item_offer_partial_fills(Kind::Camel);
}
#[test]
fn oz_erc1155_collection_offer_multiple_sellers() {
    erc1155_collection_offer_multiple_sellers(Kind::Oz);
}
#[test]
fn snake_erc1155_collection_offer_multiple_sellers() {
    erc1155_collection_offer_multiple_sellers(Kind::Snake);
}
#[test]
fn camel_erc1155_collection_offer_multiple_sellers() {
    erc1155_collection_offer_multiple_sellers(Kind::Camel);
}
#[test]
fn oz_erc1155_bulk_listings() {
    erc1155_bulk_listings(Kind::Oz);
}
#[test]
fn snake_erc1155_bulk_listings() {
    erc1155_bulk_listings(Kind::Snake);
}
#[test]
fn camel_erc1155_bulk_listings() {
    erc1155_bulk_listings(Kind::Camel);
}
#[test]
fn oz_erc1155_private_taker() {
    erc1155_private_taker(Kind::Oz);
}
#[test]
fn snake_erc1155_private_taker() {
    erc1155_private_taker(Kind::Snake);
}
#[test]
fn camel_erc1155_private_taker() {
    erc1155_private_taker(Kind::Camel);
}
#[test]
fn oz_erc1155_validator() {
    erc1155_validator(Kind::Oz);
}
#[test]
fn snake_erc1155_validator() {
    erc1155_validator(Kind::Snake);
}
#[test]
fn camel_erc1155_validator() {
    erc1155_validator(Kind::Camel);
}
#[test]
fn oz_erc1155_cancel_and_pause_after_partial_fill() {
    erc1155_cancel_and_pause_after_partial_fill(Kind::Oz);
}
#[test]
fn snake_erc1155_cancel_and_pause_after_partial_fill() {
    erc1155_cancel_and_pause_after_partial_fill(Kind::Snake);
}
#[test]
fn camel_erc1155_cancel_and_pause_after_partial_fill() {
    erc1155_cancel_and_pause_after_partial_fill(Kind::Camel);
}

// ---------------------------------------------------------------------------------------------
// Accounts with long signatures and Cairo 0-style accounts

/// 2-of-2 multisig maker (signature = 4 felts) holding STRK, ERC721 ids 101..=104 and ERC1155
/// units, all approved for the exchange.
fn multisig_maker(env: Env) -> ContractAddress {
    let maker = deploy("MultisigAccount", array![public_key(CAROL_KEY), public_key(BOB_KEY)]);
    give_assets(env, maker);
    maker
}

fn give_assets(env: Env, maker: ContractAddress) {
    IMintDispatcher { contract_address: env.strk }.mint(maker, 0, 1_000_000);
    start_cheat_caller_address(env.strk, maker);
    IERC20Dispatcher { contract_address: env.strk }.approve(env.address, 1_000_000);
    stop_cheat_caller_address(env.strk);
    for id in 101..105_u32 {
        IMintDispatcher { contract_address: env.nft }.mint(maker, id.into(), 1);
    }
    IMintDispatcher { contract_address: env.nft1155 }.mint(maker, 7, 100);
    start_cheat_caller_address(env.nft, maker);
    IERC721Dispatcher { contract_address: env.nft }.set_approval_for_all(env.address, true);
    stop_cheat_caller_address(env.nft);
    start_cheat_caller_address(env.nft1155, maker);
    IERC1155Dispatcher { contract_address: env.nft1155 }.set_approval_for_all(env.address, true);
    stop_cheat_caller_address(env.nft1155);
}

fn multisig_sign(hash: felt252) -> Span<felt252> {
    let a = sign_hash(CAROL_KEY, hash);
    let b = sign_hash(BOB_KEY, hash);
    array![*a[0], *a[1], *b[0], *b[1]].span()
}

/// A bulk signature by `maker` (account signature produced by `signer`) over `orders`.
fn bulk_by(
    env: Env, maker: ContractAddress, orders: Span<Order>, account_sig: Span<felt252>,
) -> Array<Span<felt252>> {
    let leaves = crate::utils::bulk_leaves(env.address, orders);
    let mut out: Array<Span<felt252>> = array![];
    for i in 0..orders.len() {
        out
            .append(
                crate::utils::bulk_signature(
                    account_sig, crate::utils::merkle_proof(leaves, i).span(),
                ),
            );
    }
    let _ = maker;
    out
}

#[test]
fn multisig_maker_trades_every_order_type_with_four_felt_signatures() {
    let env = setup();
    let m = multisig_maker(env);
    let m0 = strk_balance(env, m);

    // Listing (single signature, 4 felts).
    let l = order(env, ORDER_TYPE_ERC721_SELL_ORDER, m, env.nft, 101, 1, 1000);
    fill(env, env.bob.address, l, params(101, 1, multisig_sign(env.exchange.get_order_hash(l))));
    assert_eq!(IERC721Dispatcher { contract_address: env.nft }.owner_of(101), env.bob.address);
    assert_eq!(strk_balance(env, m), m0 + 1000);

    // Item offer: the multisig pays for alice's token 1.
    let offer = order(env, ORDER_TYPE_ERC721_BUY_ORDER, m, env.nft, 1, 1, 500);
    fill(
        env,
        env.alice.address,
        offer,
        params(1, 1, multisig_sign(env.exchange.get_order_hash(offer))),
    );
    assert_eq!(IERC721Dispatcher { contract_address: env.nft }.owner_of(1), m);

    // Collection offer, two sellers.
    let col = order(env, ORDER_TYPE_ERC721_CONTRACT_OFFER, m, env.nft, 0, 2, 400);
    let col_sig = multisig_sign(env.exchange.get_order_hash(col));
    fill(env, env.bob.address, col, params(11, 1, col_sig));
    fill(env, env.carol.address, col, params(21, 1, col_sig));
    assert_eq!(IERC721Dispatcher { contract_address: env.nft }.owner_of(11), m);
    assert_eq!(IERC721Dispatcher { contract_address: env.nft }.owner_of(21), m);

    // ERC1155 listing filled 3 + 7.
    let l1155 = order(env, ORDER_TYPE_ERC1155_SELL_ORDER, m, env.nft1155, 7, 10, 1000);
    let s1155 = multisig_sign(env.exchange.get_order_hash(l1155));
    fill(env, env.bob.address, l1155, params(7, 3, s1155));
    fill(env, env.carol.address, l1155, params(7, 7, s1155));
    assert_eq!(filled(env, l1155), 10);

    // Bulk of three listings with one 4-felt account signature; one is cancelled by the multisig.
    let mut b0 = order(env, ORDER_TYPE_ERC721_SELL_ORDER, m, env.nft, 102, 1, 10);
    b0.salt = 1;
    let mut b1 = b0;
    b1.nft_id = 103;
    b1.salt = 2;
    let mut b2 = b0;
    b2.nft_id = 104;
    b2.salt = 3;
    let orders = array![b0, b1, b2].span();
    let account_sig = multisig_sign(crate::utils::bulk_message_hash(env.address, m, orders));
    assert_eq!(account_sig.len(), 4);
    let sigs = bulk_by(env, m, orders, account_sig);
    fill(env, env.bob.address, b2, params(104, 1, *sigs.at(2)));
    fill(env, env.carol.address, b0, params(102, 1, *sigs.at(0)));
    assert_eq!(IERC721Dispatcher { contract_address: env.nft }.owner_of(104), env.bob.address);
    assert_eq!(IERC721Dispatcher { contract_address: env.nft }.owner_of(102), env.carol.address);
    // Three felts, five felts or only one signer's half do not verify.
    assert_fill_fails(
        env,
        env.bob.address,
        b1,
        params(103, 1, bulk_by(env, m, orders, array![1, 2, 3].span()).at(1).clone()),
        BAD_SIGNATURE,
    );
    let half = sign_hash(CAROL_KEY, crate::utils::bulk_message_hash(env.address, m, orders));
    assert_fill_fails(
        env,
        env.bob.address,
        b1,
        params(103, 1, bulk_by(env, m, orders, half.span()).at(1).clone()),
        BAD_SIGNATURE,
    );
    fill(env, env.bob.address, b1, params(103, 1, *sigs.at(1)));
}

#[test]
fn cairo0_style_account_signs_a_bulk() {
    // A Cairo 0 account only has isValidSignature and answers 1; the bulk layout must work with it.
    let env = setup();
    let maker = deploy("CamelOnlyAccount", array![public_key(ALICE_KEY)]);
    give_assets(env, maker);
    let mut o0 = order(env, ORDER_TYPE_ERC721_SELL_ORDER, maker, env.nft, 101, 1, 100);
    o0.salt = 1;
    let mut o1 = o0;
    o1.nft_id = 102;
    o1.salt = 2;
    let orders = array![o0, o1].span();
    let account_sig = sign_hash(
        ALICE_KEY, crate::utils::bulk_message_hash(env.address, maker, orders),
    );
    let sigs = bulk_by(env, maker, orders, account_sig.span());
    fill(env, env.bob.address, o1, params(102, 1, *sigs.at(1)));
    fill(env, env.carol.address, o0, params(101, 1, *sigs.at(0)));
    assert_eq!(IERC721Dispatcher { contract_address: env.nft }.owner_of(102), env.bob.address);
    assert_eq!(IERC721Dispatcher { contract_address: env.nft }.owner_of(101), env.carol.address);
    // A wrong key's bulk signature is rejected.
    let bad = sign_hash(BOB_KEY, crate::utils::bulk_message_hash(env.address, maker, orders));
    let bad_sigs = bulk_by(env, maker, orders, bad.span());
    // (o0 is already filled once, but the signature is checked first.)
    assert_fill_fails(env, env.bob.address, o0, params(101, 1, *bad_sigs.at(0)), BAD_SIGNATURE);
}

// ---------------------------------------------------------------------------------------------
// Property: value is conserved

/// For random prices, fees and fill splits of an ERC1155 listing: the exchange never keeps any
/// STRK, no STRK is created or destroyed (buyers' payments = seller's receipt + fees), the seller
/// is never paid more than the buyers paid, and units are conserved.
#[test]
#[fuzzer(runs: 100)]
fn erc1155_fills_conserve_value(
    price_seed: u128, fee0_seed: u128, fee1_seed: u128, n_seed: u8, a_seed: u8,
) {
    let env = setup();
    let price: u128 = price_seed % 100_000_000_000_000_000_000_000;
    let fee0 = fee0_seed % (price / 2 + 1);
    let fee1 = fee1_seed % (price - fee0 + 1);
    let n: u128 = 1 + (n_seed % 50).into();
    let a: u128 = 1 + (a_seed.into() % n);
    let b: u128 = n - a;
    let mut o = order(
        env, ORDER_TYPE_ERC1155_SELL_ORDER, env.alice.address, env.nft1155, 7, n, price,
    );
    o.fees = fees2(fee0, fee1);
    let sig = sign(env, env.alice, o);
    let total_before = strk_balance(env, env.alice.address)
        + strk_balance(env, env.bob.address)
        + strk_balance(env, env.carol.address);
    let (a0, b0, c0) = (
        strk_balance(env, env.alice.address),
        strk_balance(env, env.bob.address),
        strk_balance(env, env.carol.address),
    );

    fill(env, env.bob.address, o, params(7, a, sig));
    if b > 0 {
        fill(env, env.carol.address, o, params(7, b, sig));
    }

    let paid = (b0 - strk_balance(env, env.bob.address))
        + (c0 - strk_balance(env, env.carol.address));
    let received = strk_balance(env, env.alice.address) - a0;
    let fees_paid = strk_balance(env, PLATFORM()) + strk_balance(env, ROYALTY());
    assert_eq!(paid, received + fees_paid);
    assert_eq!(strk_balance(env, env.address), 0);
    assert!(paid <= price.into());
    // Two floors lose at most one wei in total, in the buyers' favour; a single full fill is exact.
    assert!(paid + 1 >= price.into());
    assert_eq!(
        total_before,
        strk_balance(env, env.alice.address)
            + strk_balance(env, env.bob.address)
            + strk_balance(env, env.carol.address)
            + fees_paid,
    );
    assert_eq!(bal1155(Kind::Oz, env.nft1155, env.alice.address, 7), 100 - n.into());
    assert_eq!(
        bal1155(Kind::Oz, env.nft1155, env.bob.address, 7)
            + bal1155(Kind::Oz, env.nft1155, env.carol.address, 7),
        200 + n.into(),
    );
}
