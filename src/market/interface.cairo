// SPDX-License-Identifier: MIT

use starknet::ContractAddress;

// Order types. Bit 0: sell order (maker gives the NFT). Bit 1: ERC1155. Bit 2: collection offer.
pub const ORDER_TYPE_ERC721_BUY_ORDER: u128 = 0; // 0b000 item offer
pub const ORDER_TYPE_ERC721_SELL_ORDER: u128 = 1; // 0b001 listing
pub const ORDER_TYPE_ERC1155_BUY_ORDER: u128 = 2; // 0b010 item offer
pub const ORDER_TYPE_ERC1155_SELL_ORDER: u128 = 3; // 0b011 listing
pub const ORDER_TYPE_ERC721_CONTRACT_OFFER: u128 = 4; // 0b100 collection offer
pub const ORDER_TYPE_ERC1155_CONTRACT_OFFER: u128 = 6; // 0b110 collection offer

/// First felt of a bulk signature (see `signature_validator`).
pub const BULK_SIGNATURE_PREFIX: felt252 = 0xfefefef0;

/// SNIP-6 `is_valid_signature` success value (`'VALID'`).
pub const SIGNATURE_VALID: felt252 = 'VALID';

#[derive(Copy, Drop, Serde, PartialEq, Debug)]
pub struct OrderStatus {
    pub is_cancelled: bool,
    pub filled_amount: u128,
}

#[derive(Copy, Drop, Serde, PartialEq, Debug)]
pub struct Fee {
    pub recipient: ContractAddress,
    pub amount: u128,
}

/// A signed order. Its hash is the SNIP-12 revision 1 message hash of the `Order` typed-data
/// struct, which adds the exchange's own address (`exchange`) to the fields below.
#[derive(Copy, Drop, Serde, PartialEq, Debug)]
pub struct Order {
    pub order_type: u128,
    pub maker: ContractAddress,
    pub taker: ContractAddress,
    pub listing_time: u64,
    pub expiry_time: u64,
    pub salt: u128,
    pub erc20_address: ContractAddress,
    pub erc20_amount: u128,
    pub fees: Span<Fee>,
    pub nft_address: ContractAddress,
    pub nft_id: u256,
    pub nft_amount: u128,
    pub order_validator: ContractAddress,
    pub counter: u128,
}

#[derive(Copy, Drop, Serde, PartialEq, Debug)]
pub struct FillParams {
    pub fill_id: u256,
    pub fill_amount: u128,
    /// Receives the NFT (sell orders) or the payment (buy orders). Zero means the caller.
    pub recipient: ContractAddress,
    pub signature: Span<felt252>,
    pub extra_data: Span<felt252>,
}

/// Short form of an ERC721 listing (`ORDER_TYPE_ERC721_SELL_ORDER`) with no private taker, no
/// order validator, `nft_amount` 1, the maker's current counter and at most two fees. A fee whose
/// recipient is zero is absent. `buy_erc721` expands it into the equivalent `Order`, so it has
/// the same order hash and goes through the same checks as `fill_order`.
#[derive(Copy, Drop, Serde, PartialEq, Debug)]
pub struct ERC721SellOrder {
    pub maker: ContractAddress,
    pub listing_time: u64,
    pub expiry_time: u64,
    pub salt: u128,
    pub erc20_address: ContractAddress,
    pub erc20_amount: u128,
    pub fee0_recipient: ContractAddress,
    pub fee0_amount: u128,
    pub fee1_recipient: ContractAddress,
    pub fee1_amount: u128,
    pub nft_address: ContractAddress,
    pub nft_id: u256,
}

#[starknet::interface]
pub trait IExchange<TState> {
    /// Buys an ERC721 listing given in short form. Same as `fill_order` with fill amount 1 and
    /// the caller as recipient.
    fn buy_erc721(ref self: TState, order: ERC721SellOrder, signature: Span<felt252>);
    fn fill_order(ref self: TState, order: Order, params: FillParams);
    /// Cancels orders; the caller must be the maker of each. Works while paused.
    fn cancel_orders(ref self: TState, orders: Span<Order>);
    /// Invalidates every order the caller signed with the previous counter. Works while paused.
    fn increment_counter(ref self: TState) -> u128;
    fn get_counter(self: @TState, account: ContractAddress) -> u128;
    fn get_order_status(self: @TState, order_hash: felt252) -> OrderStatus;
    /// The order's identity: its SNIP-12 message hash as signed alone, also when signed in a
    /// bulk.
    fn get_order_hash(self: @TState, order: Order) -> felt252;
    /// Panics unless `signature` (single or bulk layout) is the maker's valid signature.
    fn validate_signature(self: @TState, order: Order, signature: Span<felt252>);
    /// The only accepted payment token (STRK), fixed at deployment.
    fn payment_token(self: @TState) -> ContractAddress;
}

#[starknet::interface]
pub trait IExchangeAdmin<TState> {
    fn owner(self: @TState) -> ContractAddress;
    fn transfer_ownership(ref self: TState, new_owner: ContractAddress);
    fn pause(ref self: TState);
    fn unpause(ref self: TState);
}

/// Optional per-order validator (e.g. trait offers). Must return `VALIDATE_ORDER_MAGIC`.
#[starknet::interface]
pub trait IOrderValidator<TState> {
    fn validate_pavilion_order(
        self: @TState,
        nft_address: ContractAddress,
        nft_id: u256,
        merkle_root: felt252,
        order_hash: felt252,
        extra_data: Span<felt252>,
    ) -> felt252;
}

pub const VALIDATE_ORDER_MAGIC: felt252 = selector!("validate_pavilion_order");
