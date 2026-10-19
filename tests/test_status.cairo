// Order status: double fill, over-fill, cancel, counter.

use openzeppelin_interfaces::erc721::IERC721DispatcherTrait;
use pavilion_exchange::market::event::{CounterIncremented, OrderCancelled};
use pavilion_exchange::market::interface::{
    IExchangeDispatcherTrait, IExchangeSafeDispatcherTrait, ORDER_TYPE_ERC1155_SELL_ORDER,
    ORDER_TYPE_ERC721_SELL_ORDER, Order, OrderStatus,
};
use pavilion_exchange::market::market::PavilionExchange;
use snforge_std::{
    EventSpyAssertionsTrait, spy_events, start_cheat_caller_address, stop_cheat_caller_address,
};
use crate::utils::{
    Env, assert_fails_with, assert_fill_fails, fill, order, owner_of, params, setup, sign,
};

fn listing(env: Env, id: u256) -> Order {
    order(env, ORDER_TYPE_ERC721_SELL_ORDER, env.alice.address, env.nft, id, 1, 100)
}

fn cancel(env: Env, caller: starknet::ContractAddress, orders: Array<Order>) {
    start_cheat_caller_address(env.address, caller);
    env.exchange.cancel_orders(orders.span());
    stop_cheat_caller_address(env.address);
}

#[feature("safe_dispatcher")]
fn try_cancel(
    env: Env, caller: starknet::ContractAddress, orders: Array<Order>,
) -> Result<(), Array<felt252>> {
    start_cheat_caller_address(env.address, caller);
    let result = env.safe.cancel_orders(orders.span());
    stop_cheat_caller_address(env.address);
    result
}

fn increment(env: Env, caller: starknet::ContractAddress) -> u128 {
    start_cheat_caller_address(env.address, caller);
    let counter = env.exchange.increment_counter();
    stop_cheat_caller_address(env.address);
    counter
}

#[test]
fn erc721_order_cannot_be_filled_twice() {
    let env = setup();
    let o = listing(env, 1);
    let sig = sign(env, env.alice, o);
    fill(env, env.bob.address, o, params(1, 1, sig));
    // Even if the NFT came back to the maker, the order stays filled.
    start_cheat_caller_address(env.nft, env.bob.address);
    openzeppelin_interfaces::erc721::IERC721Dispatcher { contract_address: env.nft }
        .transfer_from(env.bob.address, env.alice.address, 1);
    stop_cheat_caller_address(env.nft);
    assert_fill_fails(env, env.carol.address, o, params(1, 1, sig), 'Exchange: exceeds nft amount');
}

#[test]
fn erc1155_over_fill_rejected() {
    let env = setup();
    let o = order(env, ORDER_TYPE_ERC1155_SELL_ORDER, env.alice.address, env.nft1155, 7, 5, 500);
    let sig = sign(env, env.alice, o);
    fill(env, env.bob.address, o, params(7, 3, sig));
    assert_fill_fails(env, env.bob.address, o, params(7, 3, sig), 'Exchange: exceeds nft amount');
    fill(env, env.bob.address, o, params(7, 2, sig));
    assert_eq!(
        env.exchange.get_order_status(env.exchange.get_order_hash(o)),
        OrderStatus { is_cancelled: false, filled_amount: 5 },
    );
}

#[test]
fn cancel_then_fill_rejected() {
    let env = setup();
    let o1 = listing(env, 1);
    let o2 = listing(env, 2);
    let sig1 = sign(env, env.alice, o1);
    let sig2 = sign(env, env.alice, o2);
    let mut spy = spy_events();
    cancel(env, env.alice.address, array![o1, o2]);
    let h1 = env.exchange.get_order_hash(o1);
    let h2 = env.exchange.get_order_hash(o2);
    spy
        .assert_emitted(
            @array![
                (
                    env.address,
                    PavilionExchange::Event::OrderCancelled(
                        OrderCancelled { account: env.alice.address, order_hash: h1 },
                    ),
                ),
                (
                    env.address,
                    PavilionExchange::Event::OrderCancelled(
                        OrderCancelled { account: env.alice.address, order_hash: h2 },
                    ),
                ),
            ],
        );
    assert_eq!(
        env.exchange.get_order_status(h1), OrderStatus { is_cancelled: true, filled_amount: 0 },
    );
    assert_fill_fails(env, env.bob.address, o1, params(1, 1, sig1), 'Exchange: order cancelled');
    assert_fill_fails(env, env.bob.address, o2, params(2, 1, sig2), 'Exchange: order cancelled');
    assert_eq!(owner_of(env, 1), env.alice.address);
}

#[test]
fn cancel_after_partial_fill_keeps_filled_amount() {
    let env = setup();
    let o = order(env, ORDER_TYPE_ERC1155_SELL_ORDER, env.alice.address, env.nft1155, 7, 10, 1000);
    let sig = sign(env, env.alice, o);
    fill(env, env.bob.address, o, params(7, 4, sig));
    cancel(env, env.alice.address, array![o]);
    let hash = env.exchange.get_order_hash(o);
    assert_eq!(
        env.exchange.get_order_status(hash), OrderStatus { is_cancelled: true, filled_amount: 4 },
    );
    assert_fill_fails(env, env.bob.address, o, params(7, 1, sig), 'Exchange: order cancelled');
    // Cancelling again is harmless.
    cancel(env, env.alice.address, array![o]);
    assert_eq!(
        env.exchange.get_order_status(hash), OrderStatus { is_cancelled: true, filled_amount: 4 },
    );
}

#[test]
fn only_the_maker_can_cancel() {
    let env = setup();
    let o = listing(env, 1);
    assert_fails_with(try_cancel(env, env.bob.address, array![o]), 'Exchange: invalid caller');
    // One foreign order makes the whole batch fail.
    let mine = order(env, ORDER_TYPE_ERC721_SELL_ORDER, env.bob.address, env.nft, 11, 1, 100);
    assert_fails_with(
        try_cancel(env, env.bob.address, array![mine, o]), 'Exchange: invalid caller',
    );
    assert!(!env.exchange.get_order_status(env.exchange.get_order_hash(mine)).is_cancelled);
    fill(env, env.carol.address, o, params(1, 1, sign(env, env.alice, o)));
}

#[test]
fn counter_bump_invalidates_old_orders() {
    let env = setup();
    let o = listing(env, 1);
    let sig = sign(env, env.alice, o);
    assert_eq!(env.exchange.get_counter(env.alice.address), 0);
    let mut spy = spy_events();
    assert_eq!(increment(env, env.alice.address), 1);
    spy
        .assert_emitted(
            @array![
                (
                    env.address,
                    PavilionExchange::Event::CounterIncremented(
                        CounterIncremented { account: env.alice.address, new_counter: 1 },
                    ),
                ),
            ],
        );
    assert_eq!(env.exchange.get_counter(env.alice.address), 1);
    assert_eq!(env.exchange.get_counter(env.bob.address), 0);
    assert_fill_fails(env, env.bob.address, o, params(1, 1, sig), 'Exchange: unmatched counter');

    // New orders carry the new counter.
    let mut fresh = o;
    fresh.counter = 1;
    fill(env, env.bob.address, fresh, params(1, 1, sign(env, env.alice, fresh)));
    assert_eq!(increment(env, env.alice.address), 2);
    assert_eq!(env.exchange.get_counter(env.alice.address), 2);
}

#[test]
fn counter_is_per_account() {
    let env = setup();
    increment(env, env.bob.address);
    let o = listing(env, 1);
    fill(env, env.carol.address, o, params(1, 1, sign(env, env.alice, o)));
}
