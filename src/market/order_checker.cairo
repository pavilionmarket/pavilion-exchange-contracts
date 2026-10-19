// SPDX-License-Identifier: MIT

use core::num::traits::Zero;
use starknet::{ContractAddress, get_block_timestamp, get_caller_address};
use crate::market::interface::{
    Fee, FillParams, ORDER_TYPE_ERC1155_CONTRACT_OFFER, ORDER_TYPE_ERC721_CONTRACT_OFFER, Order,
};

pub mod Errors {
    pub const UNMATCHED_COUNTER: felt252 = 'Exchange: unmatched counter';
    pub const INVALID_MAKER: felt252 = 'Exchange: invalid maker';
    pub const INVALID_PAYMENT_TOKEN: felt252 = 'Exchange: invalid erc20 address';
    pub const INVALID_NFT_ADDRESS: felt252 = 'Exchange: invalid nft address';
    pub const NOT_STARTED: felt252 = 'Exchange: not started';
    pub const EXPIRED: felt252 = 'Exchange: is expired';
    pub const INVALID_RECIPIENT: felt252 = 'Exchange: invalid recipient';
    pub const INVALID_ORDER_TYPE: felt252 = 'Exchange: invalid order type';
    pub const INVALID_NFT_AMOUNT: felt252 = 'Exchange: invalid nft amount';
    pub const INVALID_FILL_AMOUNT: felt252 = 'Exchange: invalid fill amount';
    pub const INVALID_NFT_ID: felt252 = 'Exchange: invalid nft id';
    pub const INVALID_FILL_ID: felt252 = 'Exchange: invalid fill id';
    pub const INVALID_FEE_RECIPIENT: felt252 = 'Exchange: invalid fee recipient';
    pub const INVALID_FEES: felt252 = 'Exchange: invalid fees';
}

#[inline(always)]
pub fn is_sell_order(order_type: u128) -> bool {
    (order_type & 0x1) != 0
}

#[inline(always)]
pub fn is_erc721(order_type: u128) -> bool {
    (order_type & 0x2) == 0
}

#[inline(always)]
pub fn is_contract_offer(order_type: u128) -> bool {
    order_type == ORDER_TYPE_ERC721_CONTRACT_OFFER
        || order_type == ORDER_TYPE_ERC1155_CONTRACT_OFFER
}

/// Checks the order and fill parameters (everything except the signature, the order validator and
/// the order status). Returns `(caller, recipient, merkle_root)`.
pub fn check_order(
    order: @Order, params: @FillParams, counter: u128, payment_token: ContractAddress,
) -> (ContractAddress, ContractAddress, felt252) {
    assert(*order.counter == counter, Errors::UNMATCHED_COUNTER);
    assert(!(*order.maker).is_zero(), Errors::INVALID_MAKER);
    assert(*order.erc20_address == payment_token, Errors::INVALID_PAYMENT_TOKEN);
    let nft_address = *order.nft_address;
    assert(!nft_address.is_zero() && nft_address != payment_token, Errors::INVALID_NFT_ADDRESS);

    let now = get_block_timestamp();
    assert(now >= *order.listing_time, Errors::NOT_STARTED);
    assert(now < *order.expiry_time, Errors::EXPIRED);

    let caller = get_caller_address();
    let mut recipient = *params.recipient;
    if recipient.is_zero() {
        recipient = caller;
    }
    let taker = *order.taker;
    if !taker.is_zero() {
        assert(taker == recipient, Errors::INVALID_RECIPIENT);
    }

    check_fees(*order.fees, *order.erc20_amount);

    let order_type = *order.order_type;
    assert(order_type != 5 && order_type <= 6, Errors::INVALID_ORDER_TYPE);

    let nft_amount = *order.nft_amount;
    assert(nft_amount != 0, Errors::INVALID_NFT_AMOUNT);

    let fill_amount = *params.fill_amount;
    let erc721 = is_erc721(order_type);
    if erc721 {
        assert(fill_amount == 1, Errors::INVALID_FILL_AMOUNT);
    } else {
        assert(fill_amount != 0 && fill_amount <= nft_amount, Errors::INVALID_FILL_AMOUNT);
    }

    let mut merkle_root: felt252 = 0;
    let nft_id = *order.nft_id;
    if is_contract_offer(order_type) {
        if (*order.order_validator).is_zero() {
            assert(nft_id == 0, Errors::INVALID_NFT_ID);
        } else {
            // With a validator, `nft_id` carries a merkle root (e.g. a trait offer).
            merkle_root = match nft_id.try_into() {
                Option::Some(root) => root,
                Option::None => core::panic_with_felt252(Errors::INVALID_NFT_ID),
            };
        }
    } else {
        assert(*params.fill_id == nft_id, Errors::INVALID_FILL_ID);
        if erc721 {
            assert(nft_amount == 1, Errors::INVALID_NFT_AMOUNT);
        }
    }

    (caller, recipient, merkle_root)
}

pub fn check_fees(fees: Span<Fee>, erc20_amount: u128) {
    let mut total_fee: u128 = 0;
    for fee in fees {
        assert(!(*fee.recipient).is_zero(), Errors::INVALID_FEE_RECIPIENT);
        total_fee += *fee.amount;
    }
    assert(total_fee <= erc20_amount, Errors::INVALID_FEES);
}
