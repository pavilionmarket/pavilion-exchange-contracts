// Fill paths: every order type, fees, rounding, private taker, order validator, parameter checks.

use core::num::traits::Zero;
use openzeppelin_interfaces::erc721::IERC721DispatcherTrait;
use pavilion_exchange::market::event::OrderFilled;
use pavilion_exchange::market::interface::{
    ERC721SellOrder, Fee, IExchangeDispatcherTrait, ORDER_TYPE_ERC1155_BUY_ORDER,
    ORDER_TYPE_ERC1155_CONTRACT_OFFER, ORDER_TYPE_ERC1155_SELL_ORDER, ORDER_TYPE_ERC721_BUY_ORDER,
    ORDER_TYPE_ERC721_CONTRACT_OFFER, ORDER_TYPE_ERC721_SELL_ORDER, OrderStatus,
    VALIDATE_ORDER_MAGIC,
};
use pavilion_exchange::market::market::PavilionExchange;
use pavilion_exchange::market::order_checker::Errors as CheckErrors;
use pavilion_exchange::market::order_executor::calculate_payable_amount;
use snforge_std::{
    EventSpyAssertionsTrait, EventSpyTrait, spy_events, start_cheat_block_timestamp_global,
    start_cheat_caller_address, stop_cheat_caller_address,
};
use starknet::ContractAddress;
use crate::mocks::{IMockValidatorDispatcher, IMockValidatorDispatcherTrait};
use crate::utils::{
    EXPIRY_TIME, Env, LISTING_TIME, ONE_STRK, PLATFORM, ROYALTY, assert_fill_fails, balance_1155,
    deploy, fill, order, owner_of, params, setup, sign, standard_fees, strk_balance,
};

fn filled_event(
    order_hash: felt252,
    order: pavilion_exchange::market::interface::Order,
    taker: ContractAddress,
    erc20_amount: u128,
    fees: Span<Fee>,
    nft_id: u256,
    nft_amount: u128,
    caller: ContractAddress,
) -> PavilionExchange::Event {
    PavilionExchange::Event::OrderFilled(
        OrderFilled {
            order_hash,
            order_type: order.order_type,
            maker: order.maker,
            taker,
            erc20_address: order.erc20_address,
            erc20_amount,
            fees,
            nft_address: order.nft_address,
            nft_id,
            nft_amount,
            caller,
        },
    )
}

// ---------------------------------------------------------------------------------------------
// ERC721 listing

#[test]
fn erc721_listing_fills_with_fees() {
    let env = setup();
    let price = 100 * ONE_STRK;
    let mut o = order(env, ORDER_TYPE_ERC721_SELL_ORDER, env.alice.address, env.nft, 1, 1, price);
    o.fees = standard_fees(price);
    let sig = sign(env, env.alice, o);
    let hash = env.exchange.get_order_hash(o);
    let alice_before = strk_balance(env, env.alice.address);
    let bob_before = strk_balance(env, env.bob.address);
    let mut spy = spy_events();

    fill(env, env.bob.address, o, params(1, 1, sig));

    assert_eq!(owner_of(env, 1), env.bob.address);
    assert_eq!(strk_balance(env, PLATFORM()), (price * 25 / 1000).into());
    assert_eq!(strk_balance(env, ROYALTY()), (price * 50 / 1000).into());
    assert_eq!(strk_balance(env, env.alice.address) - alice_before, (price * 925 / 1000).into());
    assert_eq!(bob_before - strk_balance(env, env.bob.address), price.into());
    assert_eq!(
        env.exchange.get_order_status(hash), OrderStatus { is_cancelled: false, filled_amount: 1 },
    );
    spy
        .assert_emitted(
            @array![
                (
                    env.address,
                    filled_event(hash, o, env.bob.address, price, o.fees, 1, 1, env.bob.address),
                ),
            ],
        );
}

#[test]
fn erc721_listing_recipient_receives_nft_caller_pays() {
    let env = setup();
    let price = 10 * ONE_STRK;
    let o = order(env, ORDER_TYPE_ERC721_SELL_ORDER, env.alice.address, env.nft, 2, 1, price);
    let mut p = params(2, 1, sign(env, env.alice, o));
    p.recipient = env.carol.address;
    let bob_before = strk_balance(env, env.bob.address);
    let carol_before = strk_balance(env, env.carol.address);
    let mut spy = spy_events();

    fill(env, env.bob.address, o, p);

    assert_eq!(owner_of(env, 2), env.carol.address);
    assert_eq!(bob_before - strk_balance(env, env.bob.address), price.into());
    assert_eq!(strk_balance(env, env.carol.address), carol_before);
    let hash = env.exchange.get_order_hash(o);
    spy
        .assert_emitted(
            @array![
                (
                    env.address,
                    filled_event(
                        hash, o, env.carol.address, price, array![].span(), 2, 1, env.bob.address,
                    ),
                ),
            ],
        );
}

/// Pins the raw event layout the backend indexer decodes.
#[test]
fn order_filled_event_raw_layout() {
    let env = setup();
    let price = 1000;
    let mut o = order(env, ORDER_TYPE_ERC721_SELL_ORDER, env.alice.address, env.nft, 3, 1, price);
    o.fees = array![Fee { recipient: PLATFORM(), amount: 30 }].span();
    let hash = env.exchange.get_order_hash(o);
    let mut spy = spy_events();
    fill(env, env.bob.address, o, params(3, 1, sign(env, env.alice, o)));

    let events = spy.get_events().events;
    let mut found = false;
    for (from, event) in events.span() {
        if *from == env.address && *event.keys[0] == selector!("OrderFilled") {
            found = true;
            assert_eq!(
                event.keys.span(),
                array![selector!("OrderFilled"), hash, 1, env.alice.address.into()].span(),
            );
            assert_eq!(
                event.data.span(),
                array![
                    env.bob.address.into(), // taker
                    env.strk.into(), // erc20_address
                    1000, // erc20_amount
                    1, // fees.len
                    PLATFORM().into(), 30,
                    env.nft.into(), // nft_address
                    3, // nft_id.low
                    0, // nft_id.high
                    1, // nft_amount
                    env.bob.address.into() // caller
                ]
                    .span(),
            );
        }
    }
    assert!(found, "no OrderFilled event");
}

// ---------------------------------------------------------------------------------------------
// buy_erc721 fast path

fn short_listing(env: Env) -> ERC721SellOrder {
    ERC721SellOrder {
        maker: env.alice.address,
        listing_time: LISTING_TIME,
        expiry_time: EXPIRY_TIME,
        salt: 42,
        erc20_address: env.strk,
        erc20_amount: 1000,
        fee0_recipient: PLATFORM(),
        fee0_amount: 25,
        fee1_recipient: ROYALTY(),
        fee1_amount: 50,
        nft_address: env.nft,
        nft_id: 4,
    }
}

fn expanded(env: Env, s: ERC721SellOrder) -> pavilion_exchange::market::interface::Order {
    let mut fees: Array<Fee> = array![];
    if !s.fee0_recipient.is_zero() {
        fees.append(Fee { recipient: s.fee0_recipient, amount: s.fee0_amount });
    }
    if !s.fee1_recipient.is_zero() {
        fees.append(Fee { recipient: s.fee1_recipient, amount: s.fee1_amount });
    }
    let mut o = order(
        env, ORDER_TYPE_ERC721_SELL_ORDER, s.maker, s.nft_address, s.nft_id, 1, s.erc20_amount,
    );
    o.fees = fees.span();
    o.salt = s.salt;
    o
}

#[test]
fn buy_erc721_uses_same_hash_and_checks_as_fill_order() {
    let env = setup();
    let s = short_listing(env);
    let full = expanded(env, s);
    let hash = env.exchange.get_order_hash(full);
    let sig = sign(env, env.alice, full);
    let alice_before = strk_balance(env, env.alice.address);
    let mut spy = spy_events();

    start_cheat_caller_address(env.address, env.bob.address);
    env.exchange.buy_erc721(s, sig);
    stop_cheat_caller_address(env.address);

    assert_eq!(owner_of(env, 4), env.bob.address);
    assert_eq!(strk_balance(env, env.alice.address) - alice_before, 925);
    assert_eq!(strk_balance(env, PLATFORM()), 25);
    assert_eq!(strk_balance(env, ROYALTY()), 50);
    assert_eq!(env.exchange.get_order_status(hash).filled_amount, 1);
    spy
        .assert_emitted(
            @array![
                (
                    env.address,
                    filled_event(
                        hash, full, env.bob.address, 1000, full.fees, 4, 1, env.bob.address,
                    ),
                ),
            ],
        );
    // Same order through fill_order is now filled.
    assert_fill_fails(
        env, env.carol.address, full, params(4, 1, sig), 'Exchange: exceeds nft amount',
    );
}

#[test]
fn buy_erc721_fee_slots_are_optional() {
    let env = setup();
    let mut s = short_listing(env);
    s.fee0_recipient = Zero::zero();
    s.fee0_amount = 0;
    let full = expanded(env, s);
    assert_eq!(full.fees.len(), 1);
    let sig = sign(env, env.alice, full);
    start_cheat_caller_address(env.address, env.bob.address);
    env.exchange.buy_erc721(s, sig);
    stop_cheat_caller_address(env.address);
    assert_eq!(owner_of(env, 4), env.bob.address);
    assert_eq!(strk_balance(env, ROYALTY()), 50);
    assert_eq!(strk_balance(env, PLATFORM()), 0);
}

#[test]
#[should_panic(expected: 'Exchange: invalid fee')]
fn buy_erc721_rejects_amount_without_fee0_recipient() {
    let env = setup();
    let mut s = short_listing(env);
    s.fee0_recipient = Zero::zero();
    let sig = sign(env, env.alice, expanded(env, s));
    start_cheat_caller_address(env.address, env.bob.address);
    env.exchange.buy_erc721(s, sig);
}

#[test]
#[should_panic(expected: 'Exchange: invalid fee')]
fn buy_erc721_rejects_amount_without_fee1_recipient() {
    let env = setup();
    let mut s = short_listing(env);
    s.fee1_recipient = Zero::zero();
    let sig = sign(env, env.alice, expanded(env, s));
    start_cheat_caller_address(env.address, env.bob.address);
    env.exchange.buy_erc721(s, sig);
}

#[test]
#[should_panic(expected: 'Exchange: invalid signature')]
fn buy_erc721_signature_with_old_counter_fails() {
    let env = setup();
    let s = short_listing(env);
    let sig = sign(env, env.alice, expanded(env, s));
    start_cheat_caller_address(env.address, env.alice.address);
    env.exchange.increment_counter();
    // buy_erc721 hashes with the current counter (1); the signature was for counter 0.
    start_cheat_caller_address(env.address, env.bob.address);
    env.exchange.buy_erc721(s, sig);
}

// ---------------------------------------------------------------------------------------------
// ERC721 item offer and collection offer

#[test]
fn erc721_item_offer_fills() {
    let env = setup();
    let price = 50 * ONE_STRK;
    let mut o = order(env, ORDER_TYPE_ERC721_BUY_ORDER, env.alice.address, env.nft, 11, 1, price);
    o.fees = standard_fees(price);
    let alice_before = strk_balance(env, env.alice.address);
    let bob_before = strk_balance(env, env.bob.address);
    let hash = env.exchange.get_order_hash(o);
    let mut spy = spy_events();

    fill(env, env.bob.address, o, params(11, 1, sign(env, env.alice, o)));

    assert_eq!(owner_of(env, 11), env.alice.address);
    assert_eq!(alice_before - strk_balance(env, env.alice.address), price.into());
    assert_eq!(strk_balance(env, env.bob.address) - bob_before, (price * 925 / 1000).into());
    spy
        .assert_emitted(
            @array![
                (
                    env.address,
                    filled_event(hash, o, env.bob.address, price, o.fees, 11, 1, env.bob.address),
                ),
            ],
        );
}

#[test]
fn erc721_item_offer_payment_goes_to_recipient() {
    let env = setup();
    let o = order(env, ORDER_TYPE_ERC721_BUY_ORDER, env.alice.address, env.nft, 12, 1, 500);
    let mut p = params(12, 1, sign(env, env.alice, o));
    p.recipient = env.carol.address;
    let bob_before = strk_balance(env, env.bob.address);
    let carol_before = strk_balance(env, env.carol.address);
    let mut spy = spy_events();
    fill(env, env.bob.address, o, p);
    assert_eq!(owner_of(env, 12), env.alice.address);
    assert_eq!(strk_balance(env, env.carol.address) - carol_before, 500);
    assert_eq!(strk_balance(env, env.bob.address), bob_before);
    let hash = env.exchange.get_order_hash(o);
    // taker = payment recipient (carol), caller = the account that gave the NFT (bob).
    spy
        .assert_emitted(
            @array![
                (
                    env.address,
                    filled_event(
                        hash, o, env.carol.address, 500, array![].span(), 12, 1, env.bob.address,
                    ),
                ),
            ],
        );
}

#[test]
fn erc721_collection_offer_fills_multiple_times() {
    let env = setup();
    let unit = 10 * ONE_STRK;
    let mut o = order(
        env, ORDER_TYPE_ERC721_CONTRACT_OFFER, env.alice.address, env.nft, 0, 3, 3 * unit,
    );
    o.fees = standard_fees(3 * unit);
    let sig = sign(env, env.alice, o);
    let hash = env.exchange.get_order_hash(o);
    let alice_before = strk_balance(env, env.alice.address);
    let bob_before = strk_balance(env, env.bob.address);
    let carol_before = strk_balance(env, env.carol.address);
    let mut spy = spy_events();

    fill(env, env.bob.address, o, params(11, 1, sig));
    fill(env, env.carol.address, o, params(21, 1, sig));
    fill(env, env.bob.address, o, params(13, 1, sig));

    assert_eq!(owner_of(env, 11), env.alice.address);
    assert_eq!(owner_of(env, 21), env.alice.address);
    assert_eq!(owner_of(env, 13), env.alice.address);
    assert_eq!(alice_before - strk_balance(env, env.alice.address), (3 * unit).into());
    let net = unit * 925 / 1000;
    assert_eq!(strk_balance(env, env.bob.address) - bob_before, (2 * net).into());
    assert_eq!(strk_balance(env, env.carol.address) - carol_before, net.into());
    assert_eq!(env.exchange.get_order_status(hash).filled_amount, 3);
    let unit_fees = array![
        Fee { recipient: PLATFORM(), amount: unit * 25 / 1000 },
        Fee { recipient: ROYALTY(), amount: unit * 50 / 1000 },
    ]
        .span();
    spy
        .assert_emitted(
            @array![
                (
                    env.address,
                    filled_event(
                        hash, o, env.carol.address, unit, unit_fees, 21, 1, env.carol.address,
                    ),
                ),
            ],
        );

    assert_fill_fails(
        env, env.carol.address, o, params(22, 1, sig), 'Exchange: exceeds nft amount',
    );
}

#[test]
fn collection_offer_without_validator_requires_zero_nft_id() {
    let env = setup();
    let o = order(env, ORDER_TYPE_ERC721_CONTRACT_OFFER, env.alice.address, env.nft, 5, 2, 100);
    assert_fill_fails(
        env,
        env.bob.address,
        o,
        params(11, 1, sign(env, env.alice, o)),
        CheckErrors::INVALID_NFT_ID,
    );
    let o = order(
        env, ORDER_TYPE_ERC1155_CONTRACT_OFFER, env.alice.address, env.nft1155, 5, 2, 100,
    );
    assert_fill_fails(
        env, env.bob.address, o, params(7, 1, sign(env, env.alice, o)), CheckErrors::INVALID_NFT_ID,
    );
}

#[test]
fn erc721_fill_amount_must_be_one() {
    let env = setup();
    let o = order(env, ORDER_TYPE_ERC721_CONTRACT_OFFER, env.alice.address, env.nft, 0, 3, 300);
    let sig = sign(env, env.alice, o);
    assert_fill_fails(
        env, env.bob.address, o, params(11, 2, sig), CheckErrors::INVALID_FILL_AMOUNT,
    );
    assert_fill_fails(
        env, env.bob.address, o, params(11, 0, sig), CheckErrors::INVALID_FILL_AMOUNT,
    );
}

#[test]
fn erc721_listing_and_item_offer_need_nft_amount_one() {
    let env = setup();
    let o = order(env, ORDER_TYPE_ERC721_SELL_ORDER, env.alice.address, env.nft, 1, 2, 300);
    assert_fill_fails(
        env,
        env.bob.address,
        o,
        params(1, 1, sign(env, env.alice, o)),
        CheckErrors::INVALID_NFT_AMOUNT,
    );
    let o = order(env, ORDER_TYPE_ERC721_BUY_ORDER, env.alice.address, env.nft, 11, 2, 300);
    assert_fill_fails(
        env,
        env.bob.address,
        o,
        params(11, 1, sign(env, env.alice, o)),
        CheckErrors::INVALID_NFT_AMOUNT,
    );
}

#[test]
fn fill_id_must_match_nft_id_except_for_collection_offers() {
    let env = setup();
    let o = order(env, ORDER_TYPE_ERC721_SELL_ORDER, env.alice.address, env.nft, 1, 1, 300);
    assert_fill_fails(
        env,
        env.bob.address,
        o,
        params(2, 1, sign(env, env.alice, o)),
        CheckErrors::INVALID_FILL_ID,
    );
    let o = order(env, ORDER_TYPE_ERC1155_SELL_ORDER, env.alice.address, env.nft1155, 7, 5, 300);
    assert_fill_fails(
        env,
        env.bob.address,
        o,
        params(1, 1, sign(env, env.alice, o)),
        CheckErrors::INVALID_FILL_ID,
    );
}

// ---------------------------------------------------------------------------------------------
// ERC1155

#[test]
fn erc1155_listing_partial_fills_round_down() {
    let env = setup();
    // 10 units of id 7 for 1001 wei with fees 25 + 50: not divisible, so amounts round down.
    let mut o = order(
        env, ORDER_TYPE_ERC1155_SELL_ORDER, env.alice.address, env.nft1155, 7, 10, 1001,
    );
    o
        .fees =
            array![
                Fee { recipient: PLATFORM(), amount: 25 }, Fee { recipient: ROYALTY(), amount: 50 },
            ]
        .span();
    let sig = sign(env, env.alice, o);
    let hash = env.exchange.get_order_hash(o);
    let alice_before = strk_balance(env, env.alice.address);
    let bob_before = strk_balance(env, env.bob.address);
    let mut spy = spy_events();

    fill(env, env.bob.address, o, params(7, 3, sig));
    // 1001 * 3 / 10 = 300; fees 7 and 15; seller 278.
    assert_eq!(balance_1155(env, env.bob.address, 7), 103);
    assert_eq!(bob_before - strk_balance(env, env.bob.address), 300);
    assert_eq!(strk_balance(env, env.alice.address) - alice_before, 278);
    assert_eq!(strk_balance(env, PLATFORM()), 7);
    assert_eq!(strk_balance(env, ROYALTY()), 15);
    spy
        .assert_emitted(
            @array![
                (
                    env.address,
                    filled_event(
                        hash,
                        o,
                        env.bob.address,
                        300,
                        array![
                            Fee { recipient: PLATFORM(), amount: 7 },
                            Fee { recipient: ROYALTY(), amount: 15 },
                        ]
                            .span(),
                        7,
                        3,
                        env.bob.address,
                    ),
                ),
            ],
        );

    let carol_before = strk_balance(env, env.carol.address);
    fill(env, env.carol.address, o, params(7, 7, sig));
    // Last fill takes the full remainder: fill_amount 7 != nft_amount 10, so 1001 * 7 / 10 = 700.
    assert_eq!(balance_1155(env, env.carol.address, 7), 107);
    assert_eq!(carol_before - strk_balance(env, env.carol.address), 700);
    assert_eq!(strk_balance(env, PLATFORM()), 7 + 17);
    assert_eq!(strk_balance(env, ROYALTY()), 15 + 35);
    assert_eq!(strk_balance(env, env.alice.address) - alice_before, 278 + 648);
    assert_eq!(balance_1155(env, env.alice.address, 7), 90);
    assert_eq!(
        env.exchange.get_order_status(hash), OrderStatus { is_cancelled: false, filled_amount: 10 },
    );
    assert_fill_fails(env, env.bob.address, o, params(7, 1, sig), 'Exchange: exceeds nft amount');
}

#[test]
fn erc1155_full_fill_pays_exact_amounts() {
    let env = setup();
    let mut o = order(
        env, ORDER_TYPE_ERC1155_SELL_ORDER, env.alice.address, env.nft1155, 1, 4, 1001,
    );
    o.fees = array![Fee { recipient: PLATFORM(), amount: 33 }].span();
    let alice_before = strk_balance(env, env.alice.address);
    fill(env, env.bob.address, o, params(1, 4, sign(env, env.alice, o)));
    assert_eq!(strk_balance(env, PLATFORM()), 33);
    assert_eq!(strk_balance(env, env.alice.address) - alice_before, 968);
    assert_eq!(balance_1155(env, env.bob.address, 1), 104);
}

#[test]
fn erc1155_item_offer_partial_fills() {
    let env = setup();
    let o = order(env, ORDER_TYPE_ERC1155_BUY_ORDER, env.alice.address, env.nft1155, 9, 5, 500);
    let sig = sign(env, env.alice, o);
    let alice_before = strk_balance(env, env.alice.address);
    let bob_before = strk_balance(env, env.bob.address);
    fill(env, env.bob.address, o, params(9, 2, sig));
    fill(env, env.carol.address, o, params(9, 3, sig));
    assert_eq!(balance_1155(env, env.alice.address, 9), 5);
    assert_eq!(balance_1155(env, env.bob.address, 9), 98);
    assert_eq!(balance_1155(env, env.carol.address, 9), 97);
    assert_eq!(alice_before - strk_balance(env, env.alice.address), 500);
    assert_eq!(strk_balance(env, env.bob.address) - bob_before, 200);
    assert_fill_fails(env, env.bob.address, o, params(9, 1, sig), 'Exchange: exceeds nft amount');
}

#[test]
fn erc1155_collection_offer_any_id() {
    let env = setup();
    let o = order(
        env, ORDER_TYPE_ERC1155_CONTRACT_OFFER, env.alice.address, env.nft1155, 0, 4, 400,
    );
    let sig = sign(env, env.alice, o);
    fill(env, env.bob.address, o, params(7, 2, sig));
    fill(env, env.carol.address, o, params(9, 2, sig));
    assert_eq!(balance_1155(env, env.alice.address, 7), 102);
    assert_eq!(balance_1155(env, env.alice.address, 9), 2);
    assert_fill_fails(env, env.bob.address, o, params(7, 1, sig), 'Exchange: exceeds nft amount');
}

#[test]
fn erc1155_fill_amount_bounds() {
    let env = setup();
    let o = order(env, ORDER_TYPE_ERC1155_SELL_ORDER, env.alice.address, env.nft1155, 7, 5, 500);
    let sig = sign(env, env.alice, o);
    assert_fill_fails(env, env.bob.address, o, params(7, 0, sig), CheckErrors::INVALID_FILL_AMOUNT);
    assert_fill_fails(env, env.bob.address, o, params(7, 6, sig), CheckErrors::INVALID_FILL_AMOUNT);
    fill(env, env.bob.address, o, params(7, 5, sig));
}

#[test]
fn nft_amount_zero_rejected() {
    let env = setup();
    let o = order(env, ORDER_TYPE_ERC1155_SELL_ORDER, env.alice.address, env.nft1155, 7, 0, 500);
    assert_fill_fails(
        env,
        env.bob.address,
        o,
        params(7, 0, sign(env, env.alice, o)),
        CheckErrors::INVALID_NFT_AMOUNT,
    );
}

// ---------------------------------------------------------------------------------------------
// Fees

#[test]
fn fees_may_not_exceed_price() {
    let env = setup();
    let mut o = order(env, ORDER_TYPE_ERC721_SELL_ORDER, env.alice.address, env.nft, 1, 1, 100);
    o
        .fees =
            array![
                Fee { recipient: PLATFORM(), amount: 60 }, Fee { recipient: ROYALTY(), amount: 41 },
            ]
        .span();
    assert_fill_fails(
        env, env.bob.address, o, params(1, 1, sign(env, env.alice, o)), CheckErrors::INVALID_FEES,
    );
    // Exactly the price is allowed: the seller gets nothing.
    o
        .fees =
            array![
                Fee { recipient: PLATFORM(), amount: 60 }, Fee { recipient: ROYALTY(), amount: 40 },
            ]
        .span();
    let alice_before = strk_balance(env, env.alice.address);
    fill(env, env.bob.address, o, params(1, 1, sign(env, env.alice, o)));
    assert_eq!(strk_balance(env, env.alice.address), alice_before);
    assert_eq!(strk_balance(env, ROYALTY()), 40);
}

#[test]
fn fee_recipient_may_not_be_zero() {
    let env = setup();
    let mut o = order(env, ORDER_TYPE_ERC721_SELL_ORDER, env.alice.address, env.nft, 1, 1, 100);
    o
        .fees =
            array![
                Fee { recipient: PLATFORM(), amount: 1 },
                Fee { recipient: Zero::zero(), amount: 0 },
            ]
        .span();
    assert_fill_fails(
        env,
        env.bob.address,
        o,
        params(1, 1, sign(env, env.alice, o)),
        CheckErrors::INVALID_FEE_RECIPIENT,
    );
}

#[test]
fn zero_fee_is_skipped_but_reported() {
    let env = setup();
    let mut o = order(
        env, ORDER_TYPE_ERC1155_SELL_ORDER, env.alice.address, env.nft1155, 7, 10, 100,
    );
    // 3 * 3 / 10 rounds to 0: no transfer for that fee, the event still lists it with 0.
    o.fees = array![Fee { recipient: PLATFORM(), amount: 3 }].span();
    let hash = env.exchange.get_order_hash(o);
    let mut spy = spy_events();
    fill(env, env.bob.address, o, params(7, 3, sign(env, env.alice, o)));
    assert_eq!(strk_balance(env, PLATFORM()), 0);
    spy
        .assert_emitted(
            @array![
                (
                    env.address,
                    filled_event(
                        hash,
                        o,
                        env.bob.address,
                        30,
                        array![Fee { recipient: PLATFORM(), amount: 0 }].span(),
                        7,
                        3,
                        env.bob.address,
                    ),
                ),
            ],
        );
}

#[test]
fn payable_amount_is_exact_for_full_fill_and_never_overflows() {
    let max: u128 = core::num::traits::Bounded::MAX;
    assert_eq!(calculate_payable_amount(max, 7, 7), max);
    assert_eq!(calculate_payable_amount(max, max - 1, max), max - 1);
    assert_eq!(calculate_payable_amount(1001, 3, 10), 300);
    assert_eq!(calculate_payable_amount(9, 1, 10), 0);
}

/// Prorated fees never exceed the prorated price, so the seller's share never underflows.
#[test]
#[fuzzer(runs: 300)]
fn prorated_fees_never_exceed_prorated_price(
    price: u128, fee0: u128, fee1: u128, fill_amount: u128, nft_amount: u128,
) {
    let nft_amount = nft_amount % 1_000_000 + 1;
    let fill_amount = fill_amount % nft_amount + 1;
    let fee0 = if price == 0 {
        0
    } else {
        fee0 % (price / 2 + 1)
    };
    let fee1 = if price == 0 {
        0
    } else {
        fee1 % (price - fee0 + 1)
    };
    let payable = calculate_payable_amount(price, fill_amount, nft_amount);
    let f0 = calculate_payable_amount(fee0, fill_amount, nft_amount);
    let f1 = calculate_payable_amount(fee1, fill_amount, nft_amount);
    assert!(f0 + f1 <= payable);
    assert!(payable <= price);
}

// ---------------------------------------------------------------------------------------------
// Private taker

#[test]
fn private_taker_listing() {
    let env = setup();
    let mut o = order(env, ORDER_TYPE_ERC721_SELL_ORDER, env.alice.address, env.nft, 1, 1, 100);
    o.taker = env.bob.address;
    let sig = sign(env, env.alice, o);
    assert_fill_fails(env, env.carol.address, o, params(1, 1, sig), CheckErrors::INVALID_RECIPIENT);
    // The taker restricts who receives the NFT; anyone may pay for it.
    let mut p = params(1, 1, sig);
    p.recipient = env.bob.address;
    let carol_before = strk_balance(env, env.carol.address);
    fill(env, env.carol.address, o, p);
    assert_eq!(owner_of(env, 1), env.bob.address);
    assert_eq!(carol_before - strk_balance(env, env.carol.address), 100);
}

#[test]
fn private_taker_offer() {
    let env = setup();
    let mut o = order(env, ORDER_TYPE_ERC721_BUY_ORDER, env.alice.address, env.nft, 11, 1, 100);
    o.taker = env.bob.address;
    let sig = sign(env, env.alice, o);
    let mut p = params(11, 1, sig);
    p.recipient = env.carol.address;
    assert_fill_fails(env, env.bob.address, o, p, CheckErrors::INVALID_RECIPIENT);
    fill(env, env.bob.address, o, params(11, 1, sig));
    assert_eq!(owner_of(env, 11), env.alice.address);
}

// ---------------------------------------------------------------------------------------------
// Order validator

#[test]
fn validator_approves_collection_offer_with_merkle_root() {
    let env = setup();
    let validator = deploy("MockOrderValidator", array![VALIDATE_ORDER_MAGIC]);
    let root = 0x1234abcd;
    let mut o = order(
        env, ORDER_TYPE_ERC721_CONTRACT_OFFER, env.alice.address, env.nft, root, 2, 200,
    );
    o.order_validator = validator;
    let mut p = params(13, 1, sign(env, env.alice, o));
    p.extra_data = array![7, 8, 9].span();
    fill(env, env.bob.address, o, p);
    assert_eq!(owner_of(env, 13), env.alice.address);
    let mock = IMockValidatorDispatcher { contract_address: validator };
    assert_eq!(mock.calls(), 1);
    let (nft_address, nft_id, merkle_root, order_hash, extra) = mock.last_call();
    assert_eq!(nft_address, env.nft);
    assert_eq!(nft_id, 13);
    assert_eq!(merkle_root, root.try_into().unwrap());
    assert_eq!(order_hash, env.exchange.get_order_hash(o));
    assert_eq!(extra, array![7, 8, 9].span());
}

#[test]
fn validator_rejection_blocks_fill() {
    let env = setup();
    let validator = deploy("MockOrderValidator", array!['nope']);
    let mut o = order(env, ORDER_TYPE_ERC721_SELL_ORDER, env.alice.address, env.nft, 1, 1, 100);
    o.order_validator = validator;
    let sig = sign(env, env.alice, o);
    assert_fill_fails(env, env.bob.address, o, params(1, 1, sig), 'Exchange: validate order error');
    // On a listing the validator sees merkle root 0; approving makes the fill go through.
    IMockValidatorDispatcher { contract_address: validator }.set_result(VALIDATE_ORDER_MAGIC);
    fill(env, env.bob.address, o, params(1, 1, sig));
    let (_, nft_id, merkle_root, _, _) = IMockValidatorDispatcher { contract_address: validator }
        .last_call();
    assert_eq!(merkle_root, 0);
    assert_eq!(nft_id, 1);
}

#[test]
fn validator_merkle_root_must_fit_a_felt() {
    let env = setup();
    let validator = deploy("MockOrderValidator", array![VALIDATE_ORDER_MAGIC]);
    let too_big: u256 = u256 { low: 1, high: 0x8000000000000110000000000000000 }; // the field prime
    let mut o = order(
        env, ORDER_TYPE_ERC721_CONTRACT_OFFER, env.alice.address, env.nft, too_big, 1, 1,
    );
    o.order_validator = validator;
    assert_fill_fails(
        env,
        env.bob.address,
        o,
        params(11, 1, sign(env, env.alice, o)),
        CheckErrors::INVALID_NFT_ID,
    );
}

// ---------------------------------------------------------------------------------------------
// Parameter checks

#[test]
fn invalid_order_types_rejected() {
    let env = setup();
    for order_type in array![5_u128, 7, 8, 0xff] {
        let o = order(env, order_type, env.alice.address, env.nft, 0, 1, 100);
        assert_fill_fails(
            env,
            env.bob.address,
            o,
            params(0, 1, sign(env, env.alice, o)),
            CheckErrors::INVALID_ORDER_TYPE,
        );
    }
}

#[test]
fn zero_maker_rejected() {
    let env = setup();
    let o = order(env, ORDER_TYPE_ERC721_SELL_ORDER, Zero::zero(), env.nft, 1, 1, 100);
    assert_fill_fails(
        env, env.bob.address, o, params(1, 1, array![1, 2].span()), CheckErrors::INVALID_MAKER,
    );
}

#[test]
fn nft_address_zero_or_payment_token_rejected() {
    let env = setup();
    let o = order(env, ORDER_TYPE_ERC721_SELL_ORDER, env.alice.address, Zero::zero(), 1, 1, 100);
    assert_fill_fails(
        env,
        env.bob.address,
        o,
        params(1, 1, sign(env, env.alice, o)),
        CheckErrors::INVALID_NFT_ADDRESS,
    );
    let o = order(env, ORDER_TYPE_ERC721_BUY_ORDER, env.alice.address, env.strk, 1000, 1, 100);
    assert_fill_fails(
        env,
        env.bob.address,
        o,
        params(1000, 1, sign(env, env.alice, o)),
        CheckErrors::INVALID_NFT_ADDRESS,
    );
}

#[test]
fn only_the_payment_token_is_accepted() {
    let env = setup();
    let mut o = order(env, ORDER_TYPE_ERC721_SELL_ORDER, env.alice.address, env.nft, 1, 1, 100);
    o.erc20_address = env.other_token;
    assert_fill_fails(
        env,
        env.bob.address,
        o,
        params(1, 1, sign(env, env.alice, o)),
        CheckErrors::INVALID_PAYMENT_TOKEN,
    );
    o.erc20_address = Zero::zero();
    assert_fill_fails(
        env,
        env.bob.address,
        o,
        params(1, 1, sign(env, env.alice, o)),
        CheckErrors::INVALID_PAYMENT_TOKEN,
    );
    assert_eq!(env.exchange.payment_token(), env.strk);
}

#[test]
#[should_panic(expected: 'Exchange: invalid erc20 address')]
fn buy_erc721_only_accepts_the_payment_token() {
    let env = setup();
    let mut s = short_listing(env);
    s.erc20_address = env.other_token;
    let sig = sign(env, env.alice, expanded(env, s));
    start_cheat_caller_address(env.address, env.bob.address);
    env.exchange.buy_erc721(s, sig);
}

#[test]
fn listing_and_expiry_time_bounds() {
    let env = setup();
    let mut o = order(env, ORDER_TYPE_ERC721_SELL_ORDER, env.alice.address, env.nft, 1, 1, 100);
    o.listing_time = 1000;
    o.expiry_time = 2000;
    let sig = sign(env, env.alice, o);
    start_cheat_block_timestamp_global(999);
    assert_fill_fails(env, env.bob.address, o, params(1, 1, sig), CheckErrors::NOT_STARTED);
    start_cheat_block_timestamp_global(2000);
    assert_fill_fails(env, env.bob.address, o, params(1, 1, sig), CheckErrors::EXPIRED);
    start_cheat_block_timestamp_global(1999);
    fill(env, env.bob.address, o, params(1, 1, sig));
    let mut o2 = order(env, ORDER_TYPE_ERC721_SELL_ORDER, env.alice.address, env.nft, 2, 1, 100);
    o2.listing_time = 1000;
    o2.expiry_time = 2000;
    start_cheat_block_timestamp_global(1000);
    fill(env, env.bob.address, o2, params(2, 1, sign(env, env.alice, o2)));
    assert_eq!(owner_of(env, 2), env.bob.address);
}

#[test]
fn seller_without_nft_cannot_be_filled() {
    let env = setup();
    // alice does not own token 11.
    let o = order(env, ORDER_TYPE_ERC721_SELL_ORDER, env.alice.address, env.nft, 11, 1, 100);
    let result = crate::utils::try_fill(
        env, env.bob.address, o, params(11, 1, sign(env, env.alice, o)),
    );
    assert!(result.is_err());
}

#[test]
fn payment_token_returning_false_fails_the_fill() {
    let env0 = setup();
    let token = deploy("FalseERC20", array![]);
    let address = crate::utils::deploy_exchange(crate::utils::OWNER(), token);
    let (exchange, safe) = crate::utils::exchange_at(address);
    let env = Env { address, exchange, safe, strk: token, ..env0 };
    start_cheat_caller_address(env.nft, env.alice.address);
    openzeppelin_interfaces::erc721::IERC721Dispatcher { contract_address: env.nft }
        .set_approval_for_all(address, true);
    stop_cheat_caller_address(env.nft);
    let o = order(env, ORDER_TYPE_ERC721_SELL_ORDER, env.alice.address, env.nft, 1, 1, 100);
    assert_fill_fails(
        env,
        env.bob.address,
        o,
        params(1, 1, sign(env, env.alice, o)),
        'Exchange: erc20 transfer failed',
    );
    // A zero price makes no ERC20 call at all.
    let free = order(env, ORDER_TYPE_ERC721_SELL_ORDER, env.alice.address, env.nft, 2, 1, 0);
    fill(env, env.bob.address, free, params(2, 1, sign(env, env.alice, free)));
    assert_eq!(owner_of(env, 2), env.bob.address);
}
