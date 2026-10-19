// NFT call compatibility: OpenZeppelin (snake + camel), camelCase-only (Cairo 0 style),
// snake_case-only, and no fallback on failures other than a missing entry point.

use pavilion_exchange::market::interface::{
    ORDER_TYPE_ERC1155_BUY_ORDER, ORDER_TYPE_ERC1155_SELL_ORDER, ORDER_TYPE_ERC721_BUY_ORDER,
    ORDER_TYPE_ERC721_CONTRACT_OFFER, ORDER_TYPE_ERC721_SELL_ORDER,
};
use crate::mocks::{
    ICamelOnlyERC1155Dispatcher, ICamelOnlyERC1155DispatcherTrait, ICamelOnlyERC721Dispatcher,
    ICamelOnlyERC721DispatcherTrait, IDivergentERC721Dispatcher, IDivergentERC721DispatcherTrait,
    IMintDispatcher, IMintDispatcherTrait, ISnakeOnlyERC1155Dispatcher,
    ISnakeOnlyERC1155DispatcherTrait, ISnakeOnlyERC721Dispatcher, ISnakeOnlyERC721DispatcherTrait,
};
use crate::utils::{assert_fill_fails, deploy, fill, order, params, setup, sign};

#[test]
fn camel_case_only_collection_trades() {
    let env = setup();
    let nft = ICamelOnlyERC721Dispatcher { contract_address: env.camel_nft };
    let listing = order(
        env, ORDER_TYPE_ERC721_SELL_ORDER, env.alice.address, env.camel_nft, 1, 1, 100,
    );
    fill(env, env.bob.address, listing, params(1, 1, sign(env, env.alice, listing)));
    assert_eq!(nft.ownerOf(1), env.bob.address);

    let offer = order(
        env, ORDER_TYPE_ERC721_BUY_ORDER, env.alice.address, env.camel_nft, 11, 1, 100,
    );
    fill(env, env.bob.address, offer, params(11, 1, sign(env, env.alice, offer)));
    assert_eq!(nft.ownerOf(11), env.alice.address);

    let collection = order(
        env, ORDER_TYPE_ERC721_CONTRACT_OFFER, env.alice.address, env.camel_nft, 0, 2, 200,
    );
    fill(env, env.carol.address, collection, params(21, 1, sign(env, env.alice, collection)));
    assert_eq!(nft.ownerOf(21), env.alice.address);
}

#[test]
fn snake_case_only_collection_trades_through_fallback() {
    let env = setup();
    let nft = ISnakeOnlyERC721Dispatcher { contract_address: env.snake_nft };
    let listing = order(
        env, ORDER_TYPE_ERC721_SELL_ORDER, env.alice.address, env.snake_nft, 1, 1, 100,
    );
    fill(env, env.bob.address, listing, params(1, 1, sign(env, env.alice, listing)));
    assert_eq!(nft.owner_of(1), env.bob.address);

    let offer = order(
        env, ORDER_TYPE_ERC721_BUY_ORDER, env.alice.address, env.snake_nft, 11, 1, 100,
    );
    fill(env, env.bob.address, offer, params(11, 1, sign(env, env.alice, offer)));
    assert_eq!(nft.owner_of(11), env.alice.address);
}

#[test]
fn transfer_errors_propagate_without_fallback() {
    let env = setup();
    // The camelCase collection's own error (missing approval) is returned, not swallowed.
    let listing = order(
        env, ORDER_TYPE_ERC721_SELL_ORDER, env.alice.address, env.camel_nft, 11, 1, 100,
    );
    assert_fill_fails(
        env, env.bob.address, listing, params(11, 1, sign(env, env.alice, listing)), 'wrong owner',
    );

    // A failing camelCase entry point is not retried as snake_case, even if that would work.
    let divergent = deploy("DivergentERC721", array![]);
    IMintDispatcher { contract_address: divergent }.mint(env.alice.address, 1, 1);
    let o = order(env, ORDER_TYPE_ERC721_SELL_ORDER, env.alice.address, divergent, 1, 1, 100);
    assert_fill_fails(
        env, env.bob.address, o, params(1, 1, sign(env, env.alice, o)), 'camel transfer failed',
    );
    assert_eq!(
        IDivergentERC721Dispatcher { contract_address: divergent }.owner_of(1), env.alice.address,
    );
}

#[test]
fn erc1155_snake_only_and_camel_only_collections_trade() {
    let env = setup();
    let snake = deploy("SnakeOnlyERC1155", array![]);
    let camel = deploy("CamelOnlyERC1155", array![]);
    IMintDispatcher { contract_address: snake }.mint(env.alice.address, 5, 10);
    IMintDispatcher { contract_address: camel }.mint(env.alice.address, 5, 10);
    IMintDispatcher { contract_address: camel }.mint(env.bob.address, 6, 10);

    let o = order(env, ORDER_TYPE_ERC1155_SELL_ORDER, env.alice.address, snake, 5, 10, 1000);
    fill(env, env.bob.address, o, params(5, 4, sign(env, env.alice, o)));
    assert_eq!(
        ISnakeOnlyERC1155Dispatcher { contract_address: snake }.balance_of(env.bob.address, 5), 4,
    );

    let o = order(env, ORDER_TYPE_ERC1155_SELL_ORDER, env.alice.address, camel, 5, 10, 1000);
    fill(env, env.bob.address, o, params(5, 3, sign(env, env.alice, o)));
    let camel_nft = ICamelOnlyERC1155Dispatcher { contract_address: camel };
    assert_eq!(camel_nft.balanceOf(env.bob.address, 5), 3);
    assert_eq!(camel_nft.balanceOf(env.alice.address, 5), 7);

    let offer = order(env, ORDER_TYPE_ERC1155_BUY_ORDER, env.alice.address, camel, 6, 2, 100);
    fill(env, env.bob.address, offer, params(6, 2, sign(env, env.alice, offer)));
    assert_eq!(camel_nft.balanceOf(env.alice.address, 6), 2);
}
