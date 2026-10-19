// GENERATED with the shared test vectors (test_vectors/vectors.json): the same orders and the
// hashes the backend must reproduce. Pins the exchange's SNIP-12 hashing; any change to the
// typed data, the field order or the encoding fails here.

use pavilion_exchange::market::interface::{
    Fee, IExchangeDispatcher, IExchangeDispatcherTrait, Order,
};
use pavilion_exchange::market::signature_validator::{
    BULK_ORDER_TYPE_HASH, FEE_TYPE_HASH, ORDER_TYPE_HASH, U256_TYPE_HASH, domain_hash,
    hash_bulk_order_struct, hash_order_struct, merkle_root, message_hash,
};
use snforge_std::{
    ContractClassTrait, DeclareResultTrait, declare, start_cheat_chain_id_global,
    stop_cheat_chain_id_global,
};
use crate::utils::{addr, merkle_proof, merkle_tree_root};

const EXCHANGE: felt252 = 0x640f3c5b1f0d5e8f1c2a7d9e3b4c5a6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a2;
const CHAIN_ID: felt252 = 'SN_SEPOLIA';

fn vector_exchange() -> IExchangeDispatcher {
    start_cheat_chain_id_global(CHAIN_ID);
    let class = declare("PavilionExchange").unwrap().contract_class();
    let calldata = array![
        'owner', 0x4718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d,
    ];
    let (address, _) = class.deploy_at(@calldata, addr(EXCHANGE)).unwrap();
    stop_cheat_chain_id_global();
    IExchangeDispatcher { contract_address: address }
}

fn check_order(
    exchange: IExchangeDispatcher,
    name: felt252,
    order: Order,
    struct_hash: felt252,
    order_hash: felt252,
    calldata: Array<felt252>,
) {
    assert!(hash_order_struct(@order, addr(EXCHANGE)) == struct_hash, "struct hash {}", name);
    assert!(exchange.get_order_hash(order) == order_hash, "order hash {}", name);
    let mut serialized: Array<felt252> = array![];
    order.serialize(ref serialized);
    assert!(serialized == calldata, "calldata {}", name);
}

fn erc721_listing_with_fees() -> Order {
    Order {
        order_type: 1,
        maker: addr(0x1f356106346812f62efa9c806313717cb77973a921b00d5b2734d2f2fb922d3),
        taker: addr(0x0),
        listing_time: 1760000000,
        expiry_time: 1762592000,
        salt: 0x1b2c3d4e5f60718293a4b5c6d7e8f901,
        erc20_address: addr(0x4718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d),
        erc20_amount: 25000000000000000000,
        fees: array![
            Fee {
                recipient: addr(0x3e389c14ebd5e4eb9706dfd360f568ce534198240e8316c2ef1863970610153),
                amount: 625000000000000000,
            },
            Fee {
                recipient: addr(0x279a1e0c1c0b6e2b7f5f0d1c2b3a4958677869504132231405f6e7d8c9ba0b1),
                amount: 1250000000000000000,
            },
        ]
            .span(),
        nft_address: addr(0x32115d69f363391f2f58cbee093e8b8b26b3df66aa36b3998d6fe75c4f5bc86),
        nft_id: u256 { low: 0x7, high: 0x0 },
        nft_amount: 1,
        order_validator: addr(0x0),
        counter: 0,
    }
}

fn erc721_listing_no_fees() -> Order {
    Order {
        order_type: 1,
        maker: addr(0x1f356106346812f62efa9c806313717cb77973a921b00d5b2734d2f2fb922d3),
        taker: addr(0x0),
        listing_time: 1760000000,
        expiry_time: 1762592000,
        salt: 0x7,
        erc20_address: addr(0x4718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d),
        erc20_amount: 12000000000000000000,
        fees: array![].span(),
        nft_address: addr(0x32115d69f363391f2f58cbee093e8b8b26b3df66aa36b3998d6fe75c4f5bc86),
        nft_id: u256 { low: 0x8, high: 0x0 },
        nft_amount: 1,
        order_validator: addr(0x0),
        counter: 0,
    }
}

fn erc721_item_offer_private_taker() -> Order {
    Order {
        order_type: 0,
        maker: addr(0x4c2b104811b11185f53c18f91e380022a796a5944014710d56583804c8ce929),
        taker: addr(0x1f356106346812f62efa9c806313717cb77973a921b00d5b2734d2f2fb922d3),
        listing_time: 1760000000,
        expiry_time: 1762592000,
        salt: 0x63,
        erc20_address: addr(0x4718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d),
        erc20_amount: 10000000000000000000,
        fees: array![
            Fee {
                recipient: addr(0x3e389c14ebd5e4eb9706dfd360f568ce534198240e8316c2ef1863970610153),
                amount: 250000000000000000,
            },
        ]
            .span(),
        nft_address: addr(0x5f5dfbdfc711337e90d2d1f7ad0080fce443274f2268c614224a79a81484363),
        nft_id: u256 { low: 0x3, high: 0x0 },
        nft_amount: 1,
        order_validator: addr(0x0),
        counter: 2,
    }
}

fn erc721_collection_offer() -> Order {
    Order {
        order_type: 4,
        maker: addr(0x3894f3298abb545c394540ff9c7d079d6be9bf841ebe2cbb5c961333bece104),
        taker: addr(0x0),
        listing_time: 1760000000,
        expiry_time: 1762592000,
        salt: 0x1,
        erc20_address: addr(0x4718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d),
        erc20_amount: 50000000000000000000,
        fees: array![
            Fee {
                recipient: addr(0x3e389c14ebd5e4eb9706dfd360f568ce534198240e8316c2ef1863970610153),
                amount: 1250000000000000000,
            },
            Fee {
                recipient: addr(0x279a1e0c1c0b6e2b7f5f0d1c2b3a4958677869504132231405f6e7d8c9ba0b1),
                amount: 2500000000000000000,
            },
        ]
            .span(),
        nft_address: addr(0x32115d69f363391f2f58cbee093e8b8b26b3df66aa36b3998d6fe75c4f5bc86),
        nft_id: u256 { low: 0x0, high: 0x0 },
        nft_amount: 5,
        order_validator: addr(0x0),
        counter: 0,
    }
}

fn erc721_collection_offer_with_validator() -> Order {
    Order {
        order_type: 4,
        maker: addr(0x3894f3298abb545c394540ff9c7d079d6be9bf841ebe2cbb5c961333bece104),
        taker: addr(0x0),
        listing_time: 1760000000,
        expiry_time: 1762592000,
        salt: 0x2,
        erc20_address: addr(0x4718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d),
        erc20_amount: 30000000000000000000,
        fees: array![].span(),
        nft_address: addr(0x32115d69f363391f2f58cbee093e8b8b26b3df66aa36b3998d6fe75c4f5bc86),
        nft_id: u256 {
            low: 0xd5b7f9a2c4e6b8d0f2a4c6e8b1d3f5a7, high: 0x5a9d1c3e7b2f4a6d8c0e2b4f6a8c1e3,
        },
        nft_amount: 3,
        order_validator: addr(0x7b1d3f5a7c9e1b3d5f7a9c1e3b5d7f9a1c3e5b7d9f1a3c5e7b9d1f3a5c7e9b1),
        counter: 0,
    }
}

fn erc1155_listing() -> Order {
    Order {
        order_type: 3,
        maker: addr(0x1f356106346812f62efa9c806313717cb77973a921b00d5b2734d2f2fb922d3),
        taker: addr(0x0),
        listing_time: 1760000000,
        expiry_time: 1762592000,
        salt: 0x3,
        erc20_address: addr(0x4718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d),
        erc20_amount: 1000000000000000000000,
        fees: array![
            Fee {
                recipient: addr(0x3e389c14ebd5e4eb9706dfd360f568ce534198240e8316c2ef1863970610153),
                amount: 25000000000000000000,
            },
            Fee {
                recipient: addr(0x279a1e0c1c0b6e2b7f5f0d1c2b3a4958677869504132231405f6e7d8c9ba0b1),
                amount: 50000000000000000000,
            },
        ]
            .span(),
        nft_address: addr(0x123a5e3c9b1d7f4e2a6c8b0d2f4a6c8e0b2d4f6a8c0e2b4d6f8a0c2e4b6d8f0),
        nft_id: u256 { low: 0x2a, high: 0x0 },
        nft_amount: 100,
        order_validator: addr(0x0),
        counter: 0,
    }
}

fn erc1155_item_offer() -> Order {
    Order {
        order_type: 2,
        maker: addr(0x4c2b104811b11185f53c18f91e380022a796a5944014710d56583804c8ce929),
        taker: addr(0x0),
        listing_time: 1760000000,
        expiry_time: 1762592000,
        salt: 0x4,
        erc20_address: addr(0x4718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d),
        erc20_amount: 90000000000000000000,
        fees: array![
            Fee {
                recipient: addr(0x3e389c14ebd5e4eb9706dfd360f568ce534198240e8316c2ef1863970610153),
                amount: 2250000000000000000,
            },
            Fee {
                recipient: addr(0x279a1e0c1c0b6e2b7f5f0d1c2b3a4958677869504132231405f6e7d8c9ba0b1),
                amount: 4500000000000000000,
            },
        ]
            .span(),
        nft_address: addr(0x123a5e3c9b1d7f4e2a6c8b0d2f4a6c8e0b2d4f6a8c0e2b4d6f8a0c2e4b6d8f0),
        nft_id: u256 { low: 0x2a, high: 0x0 },
        nft_amount: 10,
        order_validator: addr(0x0),
        counter: 0,
    }
}

fn erc1155_collection_offer() -> Order {
    Order {
        order_type: 6,
        maker: addr(0x4c2b104811b11185f53c18f91e380022a796a5944014710d56583804c8ce929),
        taker: addr(0x0),
        listing_time: 1760000000,
        expiry_time: 1762592000,
        salt: 0x5,
        erc20_address: addr(0x4718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d),
        erc20_amount: 200000000000000000000,
        fees: array![].span(),
        nft_address: addr(0x123a5e3c9b1d7f4e2a6c8b0d2f4a6c8e0b2d4f6a8c0e2b4d6f8a0c2e4b6d8f0),
        nft_id: u256 { low: 0x0, high: 0x0 },
        nft_amount: 20,
        order_validator: addr(0x0),
        counter: 0,
    }
}

fn edge_values() -> Order {
    Order {
        order_type: 3,
        maker: addr(0x1f356106346812f62efa9c806313717cb77973a921b00d5b2734d2f2fb922d3),
        taker: addr(0x3894f3298abb545c394540ff9c7d079d6be9bf841ebe2cbb5c961333bece104),
        listing_time: 0,
        expiry_time: 18446744073709551615,
        salt: 0xffffffffffffffffffffffffffffffff,
        erc20_address: addr(0x4718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d),
        erc20_amount: 340282366920938463463374607431768211455,
        fees: array![
            Fee {
                recipient: addr(0x3e389c14ebd5e4eb9706dfd360f568ce534198240e8316c2ef1863970610153),
                amount: 1,
            },
            Fee {
                recipient: addr(0x279a1e0c1c0b6e2b7f5f0d1c2b3a4958677869504132231405f6e7d8c9ba0b1),
                amount: 170141183460469231731687303715884105727,
            },
            Fee {
                recipient: addr(0x4c2b104811b11185f53c18f91e380022a796a5944014710d56583804c8ce929),
                amount: 0,
            },
        ]
            .span(),
        nft_address: addr(0x123a5e3c9b1d7f4e2a6c8b0d2f4a6c8e0b2d4f6a8c0e2b4d6f8a0c2e4b6d8f0),
        nft_id: u256 { low: 0xffffffffffffffffffffffffffffffff, high: 0x1 },
        nft_amount: 340282366920938463463374607431768211455,
        order_validator: addr(0x0),
        counter: 340282366920938463463374607431768211455,
    }
}

#[test]
fn constants() {
    assert_eq!(
        domain_hash(CHAIN_ID), 0x2b4ad2eac49f5a43c846a65bf35e30b2048734c5be4916972500d1162f24843,
    );
    assert_eq!(ORDER_TYPE_HASH, 0x2c71aa86965a43fb7f68d9e765a643564fee8efc08bb084a5f6c225d0e1fb93);
    assert_eq!(FEE_TYPE_HASH, 0x12c82fd6d8f5ed6c0e86017e35d6c933a987a3cd7ffe244576b05033bfd7ebd);
    assert_eq!(U256_TYPE_HASH, 0x3b143be38b811560b45593fb2a071ec4ddd0a020e10782be62ffe6f39e0e82c);
    assert_eq!(
        BULK_ORDER_TYPE_HASH, 0x104e33a39397c82b047b654fb23f762dde5e41e1ff49b005342b7e0b1e9cf19,
    );
}

#[test]
fn single_order_vectors() {
    let exchange = vector_exchange();
    check_order(
        exchange,
        'erc721_listing_with_fees',
        erc721_listing_with_fees(),
        0x42348cdc04b62b4d3346a4d36d87150acfd8f23158e7f24e3c12b440411bb78,
        0x11a029a984e82c6ba2cc99235ae1d84796e508efd84b468e9ed714a800a3982,
        array![
            0x1, 0x1f356106346812f62efa9c806313717cb77973a921b00d5b2734d2f2fb922d3, 0x0, 0x68e77800,
            0x690f0500, 0x1b2c3d4e5f60718293a4b5c6d7e8f901,
            0x4718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d, 0x15af1d78b58c40000,
            0x2, 0x3e389c14ebd5e4eb9706dfd360f568ce534198240e8316c2ef1863970610153,
            0x8ac7230489e8000, 0x279a1e0c1c0b6e2b7f5f0d1c2b3a4958677869504132231405f6e7d8c9ba0b1,
            0x1158e460913d0000, 0x32115d69f363391f2f58cbee093e8b8b26b3df66aa36b3998d6fe75c4f5bc86,
            0x7, 0x0, 0x1, 0x0, 0x0,
        ],
    );
    check_order(
        exchange,
        'erc721_listing_no_fees',
        erc721_listing_no_fees(),
        0x520b131c2688598f5f92dd45453048ac86146efccbded2242a9398358843a80,
        0x355f510f4788da7ac542383337fe205f1d5e43c13a5dd67b7a5fddd23a05493,
        array![
            0x1, 0x1f356106346812f62efa9c806313717cb77973a921b00d5b2734d2f2fb922d3, 0x0, 0x68e77800,
            0x690f0500, 0x7, 0x4718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d,
            0xa688906bd8b00000, 0x0,
            0x32115d69f363391f2f58cbee093e8b8b26b3df66aa36b3998d6fe75c4f5bc86, 0x8, 0x0, 0x1, 0x0,
            0x0,
        ],
    );
    check_order(
        exchange,
        'erc721_item_offer_private_taker',
        erc721_item_offer_private_taker(),
        0x1e6c2e69a8adf3b7147ffdc6cd3b532b43b386b94fa0a9ea8ac78ab697d7de0,
        0x13dabe05faeecee575b9da182b61a34a79a63ddaa3b03ff1dec3f030e203a62,
        array![
            0x0, 0x4c2b104811b11185f53c18f91e380022a796a5944014710d56583804c8ce929,
            0x1f356106346812f62efa9c806313717cb77973a921b00d5b2734d2f2fb922d3, 0x68e77800,
            0x690f0500, 0x63, 0x4718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d,
            0x8ac7230489e80000, 0x1,
            0x3e389c14ebd5e4eb9706dfd360f568ce534198240e8316c2ef1863970610153, 0x3782dace9d90000,
            0x5f5dfbdfc711337e90d2d1f7ad0080fce443274f2268c614224a79a81484363, 0x3, 0x0, 0x1, 0x0,
            0x2,
        ],
    );
    check_order(
        exchange,
        'erc721_collection_offer',
        erc721_collection_offer(),
        0x1a4509ba55d4072bf1aeefd411a3a668f23b49d60aad8584302f6bd34d50a37,
        0x643a33e941c557895e569aa1efd9a70da1ca284c8bb2fb6ab30d99dac40d1c3,
        array![
            0x4, 0x3894f3298abb545c394540ff9c7d079d6be9bf841ebe2cbb5c961333bece104, 0x0, 0x68e77800,
            0x690f0500, 0x1, 0x4718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d,
            0x2b5e3af16b1880000, 0x2,
            0x3e389c14ebd5e4eb9706dfd360f568ce534198240e8316c2ef1863970610153, 0x1158e460913d0000,
            0x279a1e0c1c0b6e2b7f5f0d1c2b3a4958677869504132231405f6e7d8c9ba0b1, 0x22b1c8c1227a0000,
            0x32115d69f363391f2f58cbee093e8b8b26b3df66aa36b3998d6fe75c4f5bc86, 0x0, 0x0, 0x5, 0x0,
            0x0,
        ],
    );
    check_order(
        exchange,
        'erc721_collection_offer_with_va',
        erc721_collection_offer_with_validator(),
        0xd99834dbb144f6518fa6281e0cf65fe76145b0eeeba2ef776996a6182aa7ff,
        0x54d6624f9aa819d0cf5e3bbd4cfe2af9d1fdfbb0d7b28192c775c0ebb039541,
        array![
            0x4, 0x3894f3298abb545c394540ff9c7d079d6be9bf841ebe2cbb5c961333bece104, 0x0, 0x68e77800,
            0x690f0500, 0x2, 0x4718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d,
            0x1a055690d9db80000, 0x0,
            0x32115d69f363391f2f58cbee093e8b8b26b3df66aa36b3998d6fe75c4f5bc86,
            0xd5b7f9a2c4e6b8d0f2a4c6e8b1d3f5a7, 0x5a9d1c3e7b2f4a6d8c0e2b4f6a8c1e3, 0x3,
            0x7b1d3f5a7c9e1b3d5f7a9c1e3b5d7f9a1c3e5b7d9f1a3c5e7b9d1f3a5c7e9b1, 0x0,
        ],
    );
    check_order(
        exchange,
        'erc1155_listing',
        erc1155_listing(),
        0x4dcea69a6c678c8710a38bd9dea5ec9341f59a9357250f462e3166602568540,
        0x5a5b652b988da34808f4a258d97be4cd526ac9138d685b978ad5cc4771308ea,
        array![
            0x3, 0x1f356106346812f62efa9c806313717cb77973a921b00d5b2734d2f2fb922d3, 0x0, 0x68e77800,
            0x690f0500, 0x3, 0x4718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d,
            0x3635c9adc5dea00000, 0x2,
            0x3e389c14ebd5e4eb9706dfd360f568ce534198240e8316c2ef1863970610153, 0x15af1d78b58c40000,
            0x279a1e0c1c0b6e2b7f5f0d1c2b3a4958677869504132231405f6e7d8c9ba0b1, 0x2b5e3af16b1880000,
            0x123a5e3c9b1d7f4e2a6c8b0d2f4a6c8e0b2d4f6a8c0e2b4d6f8a0c2e4b6d8f0, 0x2a, 0x0, 0x64, 0x0,
            0x0,
        ],
    );
    check_order(
        exchange,
        'erc1155_item_offer',
        erc1155_item_offer(),
        0xad3b52a4516db8142f406d125fa7b17d4bf7b48ed666948992aa56c37a3323,
        0x3a82a7012ec17e904f9c96d6cc5aece6ff89cca8cd2dfb82c6c7b455ef12947,
        array![
            0x2, 0x4c2b104811b11185f53c18f91e380022a796a5944014710d56583804c8ce929, 0x0, 0x68e77800,
            0x690f0500, 0x4, 0x4718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d,
            0x4e1003b28d9280000, 0x2,
            0x3e389c14ebd5e4eb9706dfd360f568ce534198240e8316c2ef1863970610153, 0x1f399b1438a10000,
            0x279a1e0c1c0b6e2b7f5f0d1c2b3a4958677869504132231405f6e7d8c9ba0b1, 0x3e73362871420000,
            0x123a5e3c9b1d7f4e2a6c8b0d2f4a6c8e0b2d4f6a8c0e2b4d6f8a0c2e4b6d8f0, 0x2a, 0x0, 0xa, 0x0,
            0x0,
        ],
    );
    check_order(
        exchange,
        'erc1155_collection_offer',
        erc1155_collection_offer(),
        0x71cb6eacca66bf6d2e78901e796dfc767ca5fa5c45774054f2909bcd6ad884d,
        0x89d317fed702923d44fd0cdd372bcf92c896990c28d41851198fca1d438121,
        array![
            0x6, 0x4c2b104811b11185f53c18f91e380022a796a5944014710d56583804c8ce929, 0x0, 0x68e77800,
            0x690f0500, 0x5, 0x4718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d,
            0xad78ebc5ac6200000, 0x0,
            0x123a5e3c9b1d7f4e2a6c8b0d2f4a6c8e0b2d4f6a8c0e2b4d6f8a0c2e4b6d8f0, 0x0, 0x0, 0x14, 0x0,
            0x0,
        ],
    );
    check_order(
        exchange,
        'edge_values',
        edge_values(),
        0x57b26681c4aca99b174f3be7581c1ace20037af9a37047d195aac444652fed0,
        0x2e7c5b1c9bf59a6dccc94ceb37929141c2647ff58201e351a733e994032ac,
        array![
            0x3, 0x1f356106346812f62efa9c806313717cb77973a921b00d5b2734d2f2fb922d3,
            0x3894f3298abb545c394540ff9c7d079d6be9bf841ebe2cbb5c961333bece104, 0x0,
            0xffffffffffffffff, 0xffffffffffffffffffffffffffffffff,
            0x4718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d,
            0xffffffffffffffffffffffffffffffff, 0x3,
            0x3e389c14ebd5e4eb9706dfd360f568ce534198240e8316c2ef1863970610153, 0x1,
            0x279a1e0c1c0b6e2b7f5f0d1c2b3a4958677869504132231405f6e7d8c9ba0b1,
            0x7fffffffffffffffffffffffffffffff,
            0x4c2b104811b11185f53c18f91e380022a796a5944014710d56583804c8ce929, 0x0,
            0x123a5e3c9b1d7f4e2a6c8b0d2f4a6c8e0b2d4f6a8c0e2b4d6f8a0c2e4b6d8f0,
            0xffffffffffffffffffffffffffffffff, 0x1, 0xffffffffffffffffffffffffffffffff, 0x0,
            0xffffffffffffffffffffffffffffffff,
        ],
    );
}

#[test]
fn bulk_5_vector() {
    let exchange = vector_exchange();
    let orders = array![
        Order {
            order_type: 1,
            maker: addr(0x1f356106346812f62efa9c806313717cb77973a921b00d5b2734d2f2fb922d3),
            taker: addr(0x0),
            listing_time: 1760000000,
            expiry_time: 1762592000,
            salt: 0xb,
            erc20_address: addr(0x4718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d),
            erc20_amount: 25000000000000000000,
            fees: array![].span(),
            nft_address: addr(0x32115d69f363391f2f58cbee093e8b8b26b3df66aa36b3998d6fe75c4f5bc86),
            nft_id: u256 { low: 0x1, high: 0x0 },
            nft_amount: 1,
            order_validator: addr(0x0),
            counter: 0,
        },
        Order {
            order_type: 1,
            maker: addr(0x1f356106346812f62efa9c806313717cb77973a921b00d5b2734d2f2fb922d3),
            taker: addr(0x0),
            listing_time: 1760000000,
            expiry_time: 1762592000,
            salt: 0xc,
            erc20_address: addr(0x4718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d),
            erc20_amount: 25000000000000000000,
            fees: array![
                Fee {
                    recipient: addr(
                        0x3e389c14ebd5e4eb9706dfd360f568ce534198240e8316c2ef1863970610153,
                    ),
                    amount: 625000000000000000,
                },
                Fee {
                    recipient: addr(
                        0x279a1e0c1c0b6e2b7f5f0d1c2b3a4958677869504132231405f6e7d8c9ba0b1,
                    ),
                    amount: 1250000000000000000,
                },
            ]
                .span(),
            nft_address: addr(0x32115d69f363391f2f58cbee093e8b8b26b3df66aa36b3998d6fe75c4f5bc86),
            nft_id: u256 { low: 0x2, high: 0x0 },
            nft_amount: 1,
            order_validator: addr(0x0),
            counter: 0,
        },
        Order {
            order_type: 3,
            maker: addr(0x1f356106346812f62efa9c806313717cb77973a921b00d5b2734d2f2fb922d3),
            taker: addr(0x0),
            listing_time: 1760000000,
            expiry_time: 1762592000,
            salt: 0xd,
            erc20_address: addr(0x4718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d),
            erc20_amount: 100000000000000000000,
            fees: array![].span(),
            nft_address: addr(0x123a5e3c9b1d7f4e2a6c8b0d2f4a6c8e0b2d4f6a8c0e2b4d6f8a0c2e4b6d8f0),
            nft_id: u256 { low: 0x2a, high: 0x0 },
            nft_amount: 10,
            order_validator: addr(0x0),
            counter: 0,
        },
        Order {
            order_type: 0,
            maker: addr(0x1f356106346812f62efa9c806313717cb77973a921b00d5b2734d2f2fb922d3),
            taker: addr(0x0),
            listing_time: 1760000000,
            expiry_time: 1762592000,
            salt: 0xe,
            erc20_address: addr(0x4718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d),
            erc20_amount: 5000000000000000000,
            fees: array![].span(),
            nft_address: addr(0x5f5dfbdfc711337e90d2d1f7ad0080fce443274f2268c614224a79a81484363),
            nft_id: u256 { low: 0x3, high: 0x0 },
            nft_amount: 1,
            order_validator: addr(0x0),
            counter: 0,
        },
        Order {
            order_type: 4,
            maker: addr(0x1f356106346812f62efa9c806313717cb77973a921b00d5b2734d2f2fb922d3),
            taker: addr(0x0),
            listing_time: 1760000000,
            expiry_time: 1762592000,
            salt: 0xf,
            erc20_address: addr(0x4718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d),
            erc20_amount: 20000000000000000000,
            fees: array![].span(),
            nft_address: addr(0x32115d69f363391f2f58cbee093e8b8b26b3df66aa36b3998d6fe75c4f5bc86),
            nft_id: u256 { low: 0x0, high: 0x0 },
            nft_amount: 2,
            order_validator: addr(0x0),
            counter: 0,
        },
    ];
    let mut leaves: Array<felt252> = array![];
    for order in orders.span() {
        leaves.append(hash_order_struct(order, addr(EXCHANGE)));
    }
    let root = merkle_tree_root(leaves.span());
    let maker = addr(0x1f356106346812f62efa9c806313717cb77973a921b00d5b2734d2f2fb922d3);
    let bulk_hash = message_hash(
        domain_hash(CHAIN_ID), maker, hash_bulk_order_struct(addr(EXCHANGE), root),
    );
    assert_eq!(root, 0x620a012ac8a7e148cb792e67a4cb15fc86390c6ac1db1039cd731bce29caab4);
    assert_eq!(bulk_hash, 0x48b5d53293a312698f13701a29c35b45ed07d5d1ee9809fef3f8c1d5422580c);
    assert_eq!(*leaves[0], 0x612c346e0e561863a3a72966ee61fb03d6c8fdccafd044da738bb9095a08007);
    assert_eq!(
        exchange.get_order_hash(*orders[0]),
        0xc3c7d013223fcb27d02e120076f9c1bf784fb6714716758d3c7474e2c40eab,
    );
    assert_eq!(
        merkle_proof(leaves.span(), 0),
        array![
            0x553b5d13c5e5e4a70380e93c0e722136eddfaf1c6d9dcd906ecd233423443cd,
            0x3da96e537a42aa562340d42da8d5570515add5b7b79d25941643af6586b7c59,
            0x27e7dde60f9f9ca381f7f81c95f210aa194b1f3d8647f71c654bc38aaa7b17e,
        ],
    );
    assert_eq!(
        merkle_root(
            *leaves[0],
            array![
                0x553b5d13c5e5e4a70380e93c0e722136eddfaf1c6d9dcd906ecd233423443cd,
                0x3da96e537a42aa562340d42da8d5570515add5b7b79d25941643af6586b7c59,
                0x27e7dde60f9f9ca381f7f81c95f210aa194b1f3d8647f71c654bc38aaa7b17e,
            ]
                .span(),
        ),
        root,
    );
    assert_eq!(*leaves[1], 0x553b5d13c5e5e4a70380e93c0e722136eddfaf1c6d9dcd906ecd233423443cd);
    assert_eq!(
        exchange.get_order_hash(*orders[1]),
        0x289dc9919cf8186e1416df202d2232c25425f45c350761174073715294e37f,
    );
    assert_eq!(
        merkle_proof(leaves.span(), 1),
        array![
            0x612c346e0e561863a3a72966ee61fb03d6c8fdccafd044da738bb9095a08007,
            0x3da96e537a42aa562340d42da8d5570515add5b7b79d25941643af6586b7c59,
            0x27e7dde60f9f9ca381f7f81c95f210aa194b1f3d8647f71c654bc38aaa7b17e,
        ],
    );
    assert_eq!(
        merkle_root(
            *leaves[1],
            array![
                0x612c346e0e561863a3a72966ee61fb03d6c8fdccafd044da738bb9095a08007,
                0x3da96e537a42aa562340d42da8d5570515add5b7b79d25941643af6586b7c59,
                0x27e7dde60f9f9ca381f7f81c95f210aa194b1f3d8647f71c654bc38aaa7b17e,
            ]
                .span(),
        ),
        root,
    );
    assert_eq!(*leaves[2], 0x42592ce77bd5b841579a15b0cf00806f11100d09948ff8c98db07d2adc0c16a);
    assert_eq!(
        exchange.get_order_hash(*orders[2]),
        0x5c05d5f0dd59beb4ae6bb1daa2a4c133dfd0b2dba7a7b23feee195ffe1dc4d2,
    );
    assert_eq!(
        merkle_proof(leaves.span(), 2),
        array![
            0x2bcef0faa22f715178211d6369ff75821486da95ae78de4e3f4949ee854417d,
            0x2fcc25ab30819999b344b7d6f574fb6b97bd86ac78a86ab07d2e3a925cfe6fc,
            0x27e7dde60f9f9ca381f7f81c95f210aa194b1f3d8647f71c654bc38aaa7b17e,
        ],
    );
    assert_eq!(
        merkle_root(
            *leaves[2],
            array![
                0x2bcef0faa22f715178211d6369ff75821486da95ae78de4e3f4949ee854417d,
                0x2fcc25ab30819999b344b7d6f574fb6b97bd86ac78a86ab07d2e3a925cfe6fc,
                0x27e7dde60f9f9ca381f7f81c95f210aa194b1f3d8647f71c654bc38aaa7b17e,
            ]
                .span(),
        ),
        root,
    );
    assert_eq!(*leaves[3], 0x2bcef0faa22f715178211d6369ff75821486da95ae78de4e3f4949ee854417d);
    assert_eq!(
        exchange.get_order_hash(*orders[3]),
        0x3caa13e801396205b0a8c6f9c0efadff106b7f1888bc513412955b0f52db3c3,
    );
    assert_eq!(
        merkle_proof(leaves.span(), 3),
        array![
            0x42592ce77bd5b841579a15b0cf00806f11100d09948ff8c98db07d2adc0c16a,
            0x2fcc25ab30819999b344b7d6f574fb6b97bd86ac78a86ab07d2e3a925cfe6fc,
            0x27e7dde60f9f9ca381f7f81c95f210aa194b1f3d8647f71c654bc38aaa7b17e,
        ],
    );
    assert_eq!(
        merkle_root(
            *leaves[3],
            array![
                0x42592ce77bd5b841579a15b0cf00806f11100d09948ff8c98db07d2adc0c16a,
                0x2fcc25ab30819999b344b7d6f574fb6b97bd86ac78a86ab07d2e3a925cfe6fc,
                0x27e7dde60f9f9ca381f7f81c95f210aa194b1f3d8647f71c654bc38aaa7b17e,
            ]
                .span(),
        ),
        root,
    );
    assert_eq!(*leaves[4], 0x230c19e640b155069293fe764ff4aa73e42e17a0ce58a354c763998e31c5a93);
    assert_eq!(
        exchange.get_order_hash(*orders[4]),
        0x33b49714f6113b5d58cbcda026573ed21237066e98ec60dd7a9d5549015129e,
    );
    assert_eq!(
        merkle_proof(leaves.span(), 4),
        array![0x0, 0x0, 0x2d8ae643486266e17aa8bd4acf644af2d5502248c9d1236482413e53dee83af],
    );
    assert_eq!(
        merkle_root(
            *leaves[4],
            array![0x0, 0x0, 0x2d8ae643486266e17aa8bd4acf644af2d5502248c9d1236482413e53dee83af]
                .span(),
        ),
        root,
    );
}

#[test]
fn bulk_1_vector() {
    let exchange = vector_exchange();
    let orders = array![
        Order {
            order_type: 1,
            maker: addr(0x1f356106346812f62efa9c806313717cb77973a921b00d5b2734d2f2fb922d3),
            taker: addr(0x0),
            listing_time: 1760000000,
            expiry_time: 1762592000,
            salt: 0x10,
            erc20_address: addr(0x4718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d),
            erc20_amount: 25000000000000000000,
            fees: array![].span(),
            nft_address: addr(0x32115d69f363391f2f58cbee093e8b8b26b3df66aa36b3998d6fe75c4f5bc86),
            nft_id: u256 { low: 0x9, high: 0x0 },
            nft_amount: 1,
            order_validator: addr(0x0),
            counter: 0,
        },
    ];
    let mut leaves: Array<felt252> = array![];
    for order in orders.span() {
        leaves.append(hash_order_struct(order, addr(EXCHANGE)));
    }
    let root = merkle_tree_root(leaves.span());
    let maker = addr(0x1f356106346812f62efa9c806313717cb77973a921b00d5b2734d2f2fb922d3);
    let bulk_hash = message_hash(
        domain_hash(CHAIN_ID), maker, hash_bulk_order_struct(addr(EXCHANGE), root),
    );
    assert_eq!(root, 0x154ed8581fbe6c1e1f06d2820ec43ab6072c3ef26268ccc6fbaed855d141821);
    assert_eq!(bulk_hash, 0x663eb4362b8dc7ef0975b8bd221eafe24eac18941c638a50f1a90819a5ba9d6);
    assert_eq!(*leaves[0], 0x154ed8581fbe6c1e1f06d2820ec43ab6072c3ef26268ccc6fbaed855d141821);
    assert_eq!(
        exchange.get_order_hash(*orders[0]),
        0x162ea29b2e57327f0af5cc65515cb3d52160352c45a96b0713be0ec3a01c8f,
    );
    assert_eq!(merkle_proof(leaves.span(), 0), array![]);
    assert_eq!(merkle_root(*leaves[0], array![].span()), root);
}
