// Reentrancy: a malicious collection, ERC1155 receiver, maker account or payment token re-enters
// the exchange from inside a fill. Each re-entrant call must fail with the guard's error.

use core::num::traits::Zero;
use openzeppelin_interfaces::erc20::IERC20DispatcherTrait;
use openzeppelin_interfaces::erc721::{IERC721Dispatcher, IERC721DispatcherTrait};
use pavilion_exchange::market::interface::{
    ERC721SellOrder, FillParams, ORDER_TYPE_ERC1155_SELL_ORDER, ORDER_TYPE_ERC721_SELL_ORDER, Order,
};
use snforge_std::{start_cheat_caller_address, stop_cheat_caller_address};
use starknet::ContractAddress;
use crate::mocks::{IAttackerDispatcher, IAttackerDispatcherTrait, IMintDispatcherTrait};
use crate::utils::{
    EXPIRY_TIME, Env, LISTING_TIME, OWNER, deploy, deploy_account, deploy_exchange, exchange_at,
    fill, order, params, setup, sign,
};

const REENTRANT: felt252 = 'ReentrancyGuard: reentrant call';

/// A re-entrant call for each guarded entry point. Each would succeed (or fail differently)
/// without the guard.
fn reentry_calls(env: Env, victim_order: Order) -> Array<(felt252, Array<felt252>)> {
    let mut fill_calldata: Array<felt252> = array![];
    victim_order.serialize(ref fill_calldata);
    let p = FillParams {
        fill_id: victim_order.nft_id,
        fill_amount: 1,
        recipient: Zero::zero(),
        signature: sign(env, env.alice, victim_order),
        extra_data: array![].span(),
    };
    p.serialize(ref fill_calldata);

    let short = ERC721SellOrder {
        maker: victim_order.maker,
        listing_time: LISTING_TIME,
        expiry_time: EXPIRY_TIME,
        salt: victim_order.salt,
        erc20_address: victim_order.erc20_address,
        erc20_amount: victim_order.erc20_amount,
        fee0_recipient: Zero::zero(),
        fee0_amount: 0,
        fee1_recipient: Zero::zero(),
        fee1_amount: 0,
        nft_address: victim_order.nft_address,
        nft_id: victim_order.nft_id,
    };
    let mut buy_calldata: Array<felt252> = array![];
    short.serialize(ref buy_calldata);
    p.signature.serialize(ref buy_calldata);

    array![
        (selector!("fill_order"), fill_calldata), (selector!("buy_erc721"), buy_calldata),
        (selector!("cancel_orders"), array![0]), (selector!("increment_counter"), array![]),
    ]
}

fn assert_blocked(attacker: ContractAddress, entry_point: felt252) {
    let (called_back, succeeded, error) = IAttackerDispatcher { contract_address: attacker }
        .outcome();
    assert!(called_back, "no callback for {}", entry_point);
    assert!(!succeeded, "re-entrant {} succeeded", entry_point);
    assert!(error == REENTRANT, "re-entrant {} failed with {}", entry_point, error);
}

/// A listing alice signs that the attacker would like to buy from inside a callback: valid in
/// every respect, so only the guard can stop it.
fn victim_listing(env: Env, attacker: ContractAddress) -> Order {
    // Fund the attacker so the victim fill would really go through without the guard.
    crate::mocks::IMintDispatcher { contract_address: env.strk }.mint(attacker, 0, 1_000_000);
    start_cheat_caller_address(env.strk, attacker);
    openzeppelin_interfaces::erc20::IERC20Dispatcher { contract_address: env.strk }
        .approve(env.address, 1_000_000);
    stop_cheat_caller_address(env.strk);
    order(env, ORDER_TYPE_ERC721_SELL_ORDER, env.alice.address, env.nft, 5, 1, 100)
}

#[test]
fn malicious_collection_cannot_reenter() {
    for i in 0..4_u32 {
        let env = setup();
        let attacker = deploy("Attacker", array![]);
        let victim = victim_listing(env, attacker);
        let (entry_point, calldata) = reentry_calls(env, victim).at(i).clone();
        IAttackerDispatcher { contract_address: attacker }.arm(env.address, entry_point, calldata);
        // bob sells an "NFT" of the attacker's collection into alice's offer... simplest: a listing
        // by alice of the attacker collection; transferFrom re-enters.
        let o = order(env, ORDER_TYPE_ERC721_SELL_ORDER, env.alice.address, attacker, 1, 1, 100);
        fill(env, env.bob.address, o, params(1, 1, sign(env, env.alice, o)));
        assert_blocked(attacker, entry_point);
        // The guard is released afterwards: the victim order is fillable normally.
        fill(env, env.bob.address, victim, params(5, 1, sign(env, env.alice, victim)));
    }
}

#[test]
fn malicious_erc1155_receiver_cannot_reenter() {
    for i in 0..4_u32 {
        let env = setup();
        let attacker = deploy("Attacker", array![]);
        let victim = victim_listing(env, attacker);
        let (entry_point, calldata) = reentry_calls(env, victim).at(i).clone();
        IAttackerDispatcher { contract_address: attacker }.arm(env.address, entry_point, calldata);
        let o = order(
            env, ORDER_TYPE_ERC1155_SELL_ORDER, env.alice.address, env.nft1155, 7, 10, 100,
        );
        let mut p = params(7, 2, sign(env, env.alice, o));
        p.recipient = attacker;
        fill(env, env.bob.address, o, p);
        assert_blocked(attacker, entry_point);
    }
}

#[test]
fn malicious_maker_account_cannot_reenter() {
    for i in 0..4_u32 {
        let env = setup();
        let attacker = deploy("Attacker", array![]);
        let victim = victim_listing(env, attacker);
        let (entry_point, calldata) = reentry_calls(env, victim).at(i).clone();
        IAttackerDispatcher { contract_address: attacker }.arm(env.address, entry_point, calldata);
        // The attacker is the maker: is_valid_signature is called during the fill.
        crate::mocks::IMintDispatcher { contract_address: env.nft }.mint(attacker, 100, 1);
        start_cheat_caller_address(env.nft, attacker);
        IERC721Dispatcher { contract_address: env.nft }.set_approval_for_all(env.address, true);
        stop_cheat_caller_address(env.nft);
        let o = order(env, ORDER_TYPE_ERC721_SELL_ORDER, attacker, env.nft, 100, 1, 100);
        fill(env, env.bob.address, o, params(100, 1, array![1, 2].span()));
        assert_blocked(attacker, entry_point);
    }
}

#[test]
fn malicious_payment_token_cannot_reenter() {
    for i in 0..4_u32 {
        let env0 = setup();
        let attacker = deploy("Attacker", array![]);
        // An exchange whose payment token is the attacker.
        let address = deploy_exchange(OWNER(), attacker);
        let (exchange, safe) = exchange_at(address);
        let env = Env {
            address,
            exchange,
            safe,
            admin: pavilion_exchange::market::interface::IExchangeAdminDispatcher {
                contract_address: address,
            },
            strk: attacker,
            ..env0,
        };
        let alice = env.alice;
        let bob = deploy_account(0xb0b2);
        crate::mocks::IMintDispatcher { contract_address: env.nft }.mint(alice.address, 200, 1);
        start_cheat_caller_address(env.nft, alice.address);
        IERC721Dispatcher { contract_address: env.nft }.set_approval_for_all(address, true);
        stop_cheat_caller_address(env.nft);
        let (entry_point, calldata) = reentry_calls(
            env, order(env, ORDER_TYPE_ERC721_SELL_ORDER, alice.address, env.nft, 3, 1, 100),
        )
            .at(i)
            .clone();
        IAttackerDispatcher { contract_address: attacker }.arm(address, entry_point, calldata);
        let o = order(env, ORDER_TYPE_ERC721_SELL_ORDER, alice.address, env.nft, 200, 1, 100);
        fill(env, bob.address, o, params(200, 1, sign(env, alice, o)));
        assert_blocked(attacker, entry_point);
        assert_eq!(IERC721Dispatcher { contract_address: env.nft }.owner_of(200), bob.address);
    }
}
