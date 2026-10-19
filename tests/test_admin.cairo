// Owner, pause, constructor, immutability.

use core::num::traits::Zero;
use openzeppelin_access::ownable::OwnableComponent;
use openzeppelin_security::pausable::PausableComponent;
use pavilion_exchange::market::interface::{
    ERC721SellOrder, IExchangeAdminDispatcherTrait, IExchangeAdminSafeDispatcher,
    IExchangeAdminSafeDispatcherTrait, IExchangeDispatcherTrait, IExchangeSafeDispatcherTrait,
    ORDER_TYPE_ERC721_SELL_ORDER,
};
use pavilion_exchange::market::market::PavilionExchange;
use snforge_std::{
    ContractClassTrait, DeclareResultTrait, EventSpyAssertionsTrait, declare, spy_events,
    start_cheat_caller_address, stop_cheat_caller_address,
};
use starknet::ContractAddress;
use starknet::syscalls::call_contract_syscall;
use crate::utils::{
    EXPIRY_TIME, Env, LISTING_TIME, OWNER, addr, assert_fails_with, fill, order, owner_of, params,
    setup, sign,
};

const PAUSED: felt252 = 'Pausable: paused';
const NOT_OWNER: felt252 = 'Caller is not the owner';

fn admin_safe(env: Env) -> IExchangeAdminSafeDispatcher {
    IExchangeAdminSafeDispatcher { contract_address: env.address }
}

fn pause(env: Env) {
    start_cheat_caller_address(env.address, OWNER());
    env.admin.pause();
    stop_cheat_caller_address(env.address);
}

#[feature("safe_dispatcher")]
fn try_admin(env: Env, caller: ContractAddress, action: felt252) -> Result<(), Array<felt252>> {
    start_cheat_caller_address(env.address, caller);
    let safe = admin_safe(env);
    let result = if action == 'pause' {
        safe.pause()
    } else if action == 'unpause' {
        safe.unpause()
    } else {
        safe.transfer_ownership(addr('new owner'))
    };
    stop_cheat_caller_address(env.address);
    result
}

fn deploy_raw(calldata: Array<felt252>) -> Result<ContractAddress, Array<felt252>> {
    match declare("PavilionExchange").unwrap().contract_class().deploy(@calldata) {
        Result::Ok((address, _)) => Result::Ok(address),
        Result::Err(error) => Result::Err(error),
    }
}

#[test]
fn constructor_sets_owner_and_payment_token() {
    let env = setup();
    assert_eq!(env.admin.owner(), OWNER());
    assert_eq!(env.exchange.payment_token(), env.strk);
}

#[test]
fn constructor_rejects_zero_owner_or_token() {
    let token: felt252 = 0x1234;
    match deploy_raw(array![0, token]) {
        Result::Ok(_) => panic!("zero owner accepted"),
        Result::Err(error) => assert_eq!(*error[0], 'Exchange: zero owner'),
    }
    match deploy_raw(array![OWNER().into(), 0]) {
        Result::Ok(_) => panic!("zero payment token accepted"),
        Result::Err(error) => assert_eq!(*error[0], 'Exchange: zero payment token'),
    }
}

#[test]
fn only_owner_can_pause_and_unpause() {
    let env = setup();
    assert_fails_with(try_admin(env, env.alice.address, 'pause'), NOT_OWNER);
    assert!(!PavilionExchangeIsPaused::is_paused(env));
    let mut spy = spy_events();
    pause(env);
    assert!(PavilionExchangeIsPaused::is_paused(env));
    spy
        .assert_emitted(
            @array![
                (
                    env.address,
                    PavilionExchange::Event::PausableEvent(
                        PausableComponent::Event::Paused(
                            PausableComponent::Paused { account: OWNER() },
                        ),
                    ),
                ),
            ],
        );
    assert_fails_with(try_admin(env, env.alice.address, 'unpause'), NOT_OWNER);
    assert_fails_with(try_admin(env, OWNER(), 'pause'), PAUSED);
    start_cheat_caller_address(env.address, OWNER());
    env.admin.unpause();
    stop_cheat_caller_address(env.address);
    assert!(!PavilionExchangeIsPaused::is_paused(env));
    assert_fails_with(try_admin(env, OWNER(), 'unpause'), 'Pausable: not paused');
}

mod PavilionExchangeIsPaused {
    use openzeppelin_interfaces::security::pausable::{
        IPausableDispatcher, IPausableDispatcherTrait,
    };
    pub fn is_paused(env: crate::utils::Env) -> bool {
        IPausableDispatcher { contract_address: env.address }.is_paused()
    }
}

#[test]
#[feature("safe_dispatcher")]
fn pause_blocks_every_fill_path() {
    let env = setup();
    let o = order(env, ORDER_TYPE_ERC721_SELL_ORDER, env.alice.address, env.nft, 1, 1, 100);
    let sig = sign(env, env.alice, o);
    let short = ERC721SellOrder {
        maker: env.alice.address,
        listing_time: LISTING_TIME,
        expiry_time: EXPIRY_TIME,
        salt: 42,
        erc20_address: env.strk,
        erc20_amount: 100,
        fee0_recipient: Zero::zero(),
        fee0_amount: 0,
        fee1_recipient: Zero::zero(),
        fee1_amount: 0,
        nft_address: env.nft,
        nft_id: 1,
    };
    pause(env);

    start_cheat_caller_address(env.address, env.bob.address);
    assert_fails_with(env.safe.fill_order(o, params(1, 1, sig)), PAUSED);
    assert_fails_with(env.safe.buy_erc721(short, sig), PAUSED);
    stop_cheat_caller_address(env.address);

    // Both paths work again after unpausing (the same signature fits both forms).
    start_cheat_caller_address(env.address, OWNER());
    env.admin.unpause();
    start_cheat_caller_address(env.address, env.bob.address);
    env.exchange.buy_erc721(short, sig);
    stop_cheat_caller_address(env.address);
    assert_eq!(owner_of(env, 1), env.bob.address);
    let o2 = order(env, ORDER_TYPE_ERC721_SELL_ORDER, env.alice.address, env.nft, 2, 1, 100);
    fill(env, env.bob.address, o2, params(2, 1, sign(env, env.alice, o2)));
    assert_eq!(owner_of(env, 2), env.bob.address);
}

#[test]
fn cancel_and_counter_work_while_paused() {
    let env = setup();
    let o = order(env, ORDER_TYPE_ERC721_SELL_ORDER, env.alice.address, env.nft, 1, 1, 100);
    pause(env);
    start_cheat_caller_address(env.address, env.alice.address);
    env.exchange.cancel_orders(array![o].span());
    assert_eq!(env.exchange.increment_counter(), 1);
    stop_cheat_caller_address(env.address);
    assert!(env.exchange.get_order_status(env.exchange.get_order_hash(o)).is_cancelled);
    assert_eq!(env.exchange.get_counter(env.alice.address), 1);
}

#[test]
fn ownership_transfer() {
    let env = setup();
    assert_fails_with(try_admin(env, env.alice.address, 'transfer'), NOT_OWNER);
    let mut spy = spy_events();
    start_cheat_caller_address(env.address, OWNER());
    env.admin.transfer_ownership(env.alice.address);
    stop_cheat_caller_address(env.address);
    assert_eq!(env.admin.owner(), env.alice.address);
    spy
        .assert_emitted(
            @array![
                (
                    env.address,
                    PavilionExchange::Event::OwnableEvent(
                        OwnableComponent::Event::OwnershipTransferred(
                            OwnableComponent::OwnershipTransferred {
                                previous_owner: OWNER(), new_owner: env.alice.address,
                            },
                        ),
                    ),
                ),
            ],
        );
    // The old owner lost every power; the new one has them.
    assert_fails_with(try_admin(env, OWNER(), 'pause'), NOT_OWNER);
    assert_fails_with(try_admin(env, OWNER(), 'transfer'), NOT_OWNER);
    start_cheat_caller_address(env.address, env.alice.address);
    env.admin.pause();
    stop_cheat_caller_address(env.address);
}

#[test]
#[should_panic(expected: 'Exchange: zero owner')]
fn ownership_cannot_go_to_zero() {
    let env = setup();
    start_cheat_caller_address(env.address, OWNER());
    env.admin.transfer_ownership(Zero::zero());
}

/// The contract is immutable: no upgrade, no renounce, no setter for the payment token.
#[test]
fn no_upgrade_renounce_or_token_setter_entry_points() {
    let env = setup();
    start_cheat_caller_address(env.address, OWNER());
    let missing = array![
        selector!("upgrade"), selector!("replace_class"), selector!("renounce_ownership"),
        selector!("renounceOwnership"), selector!("set_payment_token"),
    ];
    for entry_point in missing {
        let class_hash: felt252 = 0x1234;
        match call_contract_syscall(env.address, entry_point, array![class_hash].span()) {
            Result::Ok(_) => panic!("entry point exists"),
            Result::Err(error) => assert_eq!(*error[0], 'ENTRYPOINT_NOT_FOUND'),
        }
    }
}
