// Shared fixtures and helpers for the exchange tests.

use core::num::traits::{Bounded, Zero};
use core::poseidon::hades_permutation;
use openzeppelin_interfaces::erc1155::{IERC1155Dispatcher, IERC1155DispatcherTrait};
use openzeppelin_interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
use openzeppelin_interfaces::erc721::{IERC721Dispatcher, IERC721DispatcherTrait};
use pavilion_exchange::market::interface::{
    BULK_SIGNATURE_PREFIX, Fee, FillParams, IExchangeAdminDispatcher, IExchangeDispatcher,
    IExchangeDispatcherTrait, IExchangeSafeDispatcher, IExchangeSafeDispatcherTrait, Order,
};
use pavilion_exchange::market::signature_validator::{
    domain_hash, hash_bulk_order_struct, hash_order_struct, message_hash,
};
use snforge_std::signature::KeyPairTrait;
use snforge_std::signature::stark_curve::{StarkCurveKeyPairImpl, StarkCurveSignerImpl};
use snforge_std::{
    ContractClassTrait, DeclareResultTrait, declare, start_cheat_block_timestamp_global,
    start_cheat_caller_address, stop_cheat_caller_address,
};
use starknet::ContractAddress;
use crate::mocks::{
    ICamelOnlyERC721Dispatcher, ICamelOnlyERC721DispatcherTrait, IMintDispatcher,
    IMintDispatcherTrait, ISnakeOnlyERC721Dispatcher, ISnakeOnlyERC721DispatcherTrait,
};

pub const NOW: u64 = 1_760_000_000;
pub const LISTING_TIME: u64 = 1_759_990_000;
pub const EXPIRY_TIME: u64 = 1_762_592_000;
pub const ONE_STRK: u128 = 1_000_000_000_000_000_000;
pub const BALANCE: u256 = 1_000_000_000_000_000_000_000_000; // 1M STRK

pub const ALICE_KEY: felt252 = 0x1a11ce;
pub const BOB_KEY: felt252 = 0xb0b;
pub const CAROL_KEY: felt252 = 0xca201;

pub fn addr(value: felt252) -> ContractAddress {
    value.try_into().unwrap()
}

pub fn OWNER() -> ContractAddress {
    addr('owner')
}
pub fn PLATFORM() -> ContractAddress {
    addr('platform')
}
pub fn ROYALTY() -> ContractAddress {
    addr('royalty')
}

#[derive(Copy, Drop, Debug)]
pub struct Actor {
    pub address: ContractAddress,
    pub secret: felt252,
}

#[derive(Copy, Drop)]
pub struct Env {
    pub address: ContractAddress,
    pub exchange: IExchangeDispatcher,
    pub safe: IExchangeSafeDispatcher,
    pub admin: IExchangeAdminDispatcher,
    pub strk: ContractAddress,
    pub other_token: ContractAddress,
    pub nft: ContractAddress,
    pub nft1155: ContractAddress,
    pub camel_nft: ContractAddress,
    pub snake_nft: ContractAddress,
    pub alice: Actor,
    pub bob: Actor,
    pub carol: Actor,
}

pub fn deploy(name: ByteArray, calldata: Array<felt252>) -> ContractAddress {
    let (address, _) = declare(name).unwrap().contract_class().deploy(@calldata).unwrap();
    address
}

pub fn public_key(secret: felt252) -> felt252 {
    KeyPairTrait::<felt252, felt252>::from_secret_key(secret).public_key
}

pub fn deploy_account(secret: felt252) -> Actor {
    Actor { address: deploy("MockAccount", array![public_key(secret)]), secret }
}

pub fn deploy_exchange(owner: ContractAddress, payment_token: ContractAddress) -> ContractAddress {
    deploy("PavilionExchange", array![owner.into(), payment_token.into()])
}

pub fn exchange_at(address: ContractAddress) -> (IExchangeDispatcher, IExchangeSafeDispatcher) {
    (
        IExchangeDispatcher { contract_address: address },
        IExchangeSafeDispatcher { contract_address: address },
    )
}

/// Exchange plus three funded accounts holding NFTs in every collection type, all approved.
/// alice: ERC721 ids 1..=5 in every ERC721 collection, 100 units of ERC1155 ids 1 and 7.
/// bob: ids 11..=15 / 100 units of ids 1, 7 and 9. carol: ids 21..=25 / 100 units of 7 and 9.
pub fn setup() -> Env {
    start_cheat_block_timestamp_global(NOW);
    let strk = deploy("MockERC20", array![]);
    let other_token = deploy("MockERC20", array![]);
    let address = deploy_exchange(OWNER(), strk);
    let nft = deploy("MockERC721", array![]);
    let nft1155 = deploy("MockERC1155", array![]);
    let camel_nft = deploy("CamelOnlyERC721", array![]);
    let snake_nft = deploy("SnakeOnlyERC721", array![]);
    let alice = deploy_account(ALICE_KEY);
    let bob = deploy_account(BOB_KEY);
    let carol = deploy_account(CAROL_KEY);
    let (exchange, safe) = exchange_at(address);
    let env = Env {
        address,
        exchange,
        safe,
        admin: IExchangeAdminDispatcher { contract_address: address },
        strk,
        other_token,
        nft,
        nft1155,
        camel_nft,
        snake_nft,
        alice,
        bob,
        carol,
    };
    fund(env, alice.address, 1);
    fund(env, bob.address, 11);
    fund(env, carol.address, 21);
    mint_1155(env, alice.address, array![1, 7]);
    mint_1155(env, bob.address, array![1, 7, 9]);
    mint_1155(env, carol.address, array![7, 9]);
    env
}

fn fund(env: Env, account: ContractAddress, first_id: u256) {
    for token in array![env.strk, env.other_token] {
        IMintDispatcher { contract_address: token }.mint(account, 0, BALANCE);
        start_cheat_caller_address(token, account);
        IERC20Dispatcher { contract_address: token }.approve(env.address, Bounded::MAX);
        stop_cheat_caller_address(token);
    }
    for i in 0..5_u8 {
        let id = first_id + i.into();
        for collection in array![env.nft, env.camel_nft, env.snake_nft] {
            IMintDispatcher { contract_address: collection }.mint(account, id, 1);
        }
    }
    start_cheat_caller_address(env.nft, account);
    IERC721Dispatcher { contract_address: env.nft }.set_approval_for_all(env.address, true);
    stop_cheat_caller_address(env.nft);
    start_cheat_caller_address(env.camel_nft, account);
    ICamelOnlyERC721Dispatcher { contract_address: env.camel_nft }
        .setApprovalForAll(env.address, true);
    stop_cheat_caller_address(env.camel_nft);
    start_cheat_caller_address(env.snake_nft, account);
    ISnakeOnlyERC721Dispatcher { contract_address: env.snake_nft }
        .set_approval_for_all(env.address, true);
    stop_cheat_caller_address(env.snake_nft);
    start_cheat_caller_address(env.nft1155, account);
    IERC1155Dispatcher { contract_address: env.nft1155 }.set_approval_for_all(env.address, true);
    stop_cheat_caller_address(env.nft1155);
}

fn mint_1155(env: Env, account: ContractAddress, ids: Array<u256>) {
    for id in ids {
        IMintDispatcher { contract_address: env.nft1155 }.mint(account, id, 100);
    }
}

// ---------------------------------------------------------------------------------------------
// Orders

pub fn order(
    env: Env,
    order_type: u128,
    maker: ContractAddress,
    nft_address: ContractAddress,
    nft_id: u256,
    nft_amount: u128,
    erc20_amount: u128,
) -> Order {
    Order {
        order_type,
        maker,
        taker: Zero::zero(),
        listing_time: LISTING_TIME,
        expiry_time: EXPIRY_TIME,
        salt: 42,
        erc20_address: env.strk,
        erc20_amount,
        fees: array![].span(),
        nft_address,
        nft_id,
        nft_amount,
        order_validator: Zero::zero(),
        counter: 0,
    }
}

/// 2.5% platform fee and 5% royalty of `price`.
pub fn standard_fees(price: u128) -> Span<Fee> {
    array![
        Fee { recipient: PLATFORM(), amount: price * 25 / 1000 },
        Fee { recipient: ROYALTY(), amount: price * 50 / 1000 },
    ]
        .span()
}

pub fn params(fill_id: u256, fill_amount: u128, signature: Span<felt252>) -> FillParams {
    FillParams {
        fill_id, fill_amount, recipient: Zero::zero(), signature, extra_data: array![].span(),
    }
}

// ---------------------------------------------------------------------------------------------
// Signing

pub fn chain_id() -> felt252 {
    starknet::get_tx_info().unbox().chain_id
}

pub fn sign_hash(secret: felt252, hash: felt252) -> Array<felt252> {
    let key_pair = KeyPairTrait::<felt252, felt252>::from_secret_key(secret);
    let (r, s) = key_pair.sign(hash).unwrap();
    array![r, s]
}

/// Single-order signature, signing the hash the exchange reports.
pub fn sign(env: Env, signer: Actor, order: Order) -> Span<felt252> {
    sign_hash(signer.secret, env.exchange.get_order_hash(order)).span()
}

/// Single-order signature over an independently built SNIP-12 message for `exchange` on
/// `chain`, using `domain` as the domain hash.
pub fn sign_for(
    signer: Actor, order: Order, exchange: ContractAddress, domain: felt252,
) -> Span<felt252> {
    let hash = message_hash(domain, order.maker, hash_order_struct(@order, exchange));
    sign_hash(signer.secret, hash).span()
}

pub fn merkle_hash(a: felt252, b: felt252) -> felt252 {
    let a_u256: u256 = a.into();
    let b_u256: u256 = b.into();
    let (x, y) = if a_u256 <= b_u256 {
        (a, b)
    } else {
        (b, a)
    };
    let (hash, _, _) = hades_permutation(x, y, 2);
    hash
}

/// starknet.js `MerkleTree`: pairs left to right, an odd last node is paired with 0.
pub fn merkle_next_level(level: Span<felt252>) -> Span<felt252> {
    let mut next: Array<felt252> = array![];
    let mut i = 0;
    while i < level.len() {
        let right = if i + 1 < level.len() {
            *level[i + 1]
        } else {
            0
        };
        next.append(merkle_hash(*level[i], right));
        i += 2;
    }
    next.span()
}

pub fn merkle_tree_root(leaves: Span<felt252>) -> felt252 {
    let mut level = leaves;
    while level.len() > 1 {
        level = merkle_next_level(level);
    }
    let root = *level[0];
    root
}

pub fn merkle_proof(leaves: Span<felt252>, index: u32) -> Array<felt252> {
    let mut proof: Array<felt252> = array![];
    let mut level = leaves;
    let mut index = index;
    while level.len() > 1 {
        let sibling_index = if index % 2 == 0 {
            index + 1
        } else {
            index - 1
        };
        proof.append(if sibling_index < level.len() {
            *level[sibling_index]
        } else {
            0
        });
        level = merkle_next_level(level);
        index /= 2;
    }
    proof
}

pub fn bulk_leaves(exchange: ContractAddress, orders: Span<Order>) -> Span<felt252> {
    let mut leaves: Array<felt252> = array![];
    for order in orders {
        leaves.append(hash_order_struct(order, exchange));
    }
    leaves.span()
}

pub fn bulk_message_hash(
    exchange: ContractAddress, maker: ContractAddress, orders: Span<Order>,
) -> felt252 {
    let root = merkle_tree_root(bulk_leaves(exchange, orders));
    message_hash(domain_hash(chain_id()), maker, hash_bulk_order_struct(exchange, root))
}

/// Bulk layout around an account signature: [prefix, n, sig..., proof...].
pub fn bulk_signature(account_signature: Span<felt252>, proof: Span<felt252>) -> Span<felt252> {
    let mut signature = array![BULK_SIGNATURE_PREFIX, account_signature.len().into()];
    for x in account_signature {
        signature.append(*x);
    }
    for x in proof {
        signature.append(*x);
    }
    signature.span()
}

/// One bulk signature by `signer` over `orders`; returns each order's signature.
pub fn sign_bulk(env: Env, signer: Actor, orders: Span<Order>) -> Array<Span<felt252>> {
    let hash = bulk_message_hash(env.address, signer.address, orders);
    let account_signature = sign_hash(signer.secret, hash);
    let leaves = bulk_leaves(env.address, orders);
    let mut signatures: Array<Span<felt252>> = array![];
    for i in 0..orders.len() {
        signatures.append(bulk_signature(account_signature.span(), merkle_proof(leaves, i).span()));
    }
    signatures
}

// ---------------------------------------------------------------------------------------------
// Calls

pub fn fill(env: Env, caller: ContractAddress, order: Order, params: FillParams) {
    start_cheat_caller_address(env.address, caller);
    env.exchange.fill_order(order, params);
    stop_cheat_caller_address(env.address);
}

#[feature("safe_dispatcher")]
pub fn try_fill(
    env: Env, caller: ContractAddress, order: Order, params: FillParams,
) -> Result<(), Array<felt252>> {
    start_cheat_caller_address(env.address, caller);
    let result = env.safe.fill_order(order, params);
    stop_cheat_caller_address(env.address);
    result
}

pub fn assert_fails_with(result: Result<(), Array<felt252>>, expected: felt252) {
    match result {
        Result::Ok(_) => panic!("expected failure {}, but the call succeeded", expected),
        Result::Err(error) => assert!(
            *error.at(0) == expected, "expected {}, got {:?}", expected, error,
        ),
    }
}

/// Fails with `expected` and succeeds otherwise unchanged: the order is valid.
pub fn assert_fill_fails(
    env: Env, caller: ContractAddress, order: Order, params: FillParams, expected: felt252,
) {
    assert_fails_with(try_fill(env, caller, order, params), expected);
}

pub fn strk_balance(env: Env, account: ContractAddress) -> u256 {
    IERC20Dispatcher { contract_address: env.strk }.balance_of(account)
}

pub fn owner_of(env: Env, id: u256) -> ContractAddress {
    IERC721Dispatcher { contract_address: env.nft }.owner_of(id)
}

pub fn balance_1155(env: Env, account: ContractAddress, id: u256) -> u256 {
    IERC1155Dispatcher { contract_address: env.nft1155 }.balance_of(account, id)
}
