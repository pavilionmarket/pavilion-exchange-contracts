// SPDX-License-Identifier: MIT

use starknet::ContractAddress;
use crate::market::interface::Fee;

#[derive(Drop, PartialEq, Debug, starknet::Event)]
pub struct CounterIncremented {
    #[key]
    pub account: ContractAddress,
    pub new_counter: u128,
}

#[derive(Drop, PartialEq, Debug, starknet::Event)]
pub struct OrderCancelled {
    #[key]
    pub account: ContractAddress,
    #[key]
    pub order_hash: felt252,
}

/// `taker` is the recipient of the fill: the buyer who receives the NFT for sell orders, the
/// seller who receives the payment for buy orders. `caller` is the account that sent the fill
/// transaction (for buy orders: the account that gave the NFT).
#[derive(Drop, PartialEq, Debug, starknet::Event)]
pub struct OrderFilled {
    #[key]
    pub order_hash: felt252,
    #[key]
    pub order_type: u128,
    #[key]
    pub maker: ContractAddress,
    pub taker: ContractAddress,
    pub erc20_address: ContractAddress,
    pub erc20_amount: u128,
    pub fees: Span<Fee>,
    pub nft_address: ContractAddress,
    pub nft_id: u256,
    pub nft_amount: u128,
    pub caller: ContractAddress,
}
