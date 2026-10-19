// Additional mocks written by the tester (the engineer's mocks.cairo is left untouched).

use starknet::ContractAddress;

#[starknet::interface]
pub trait IDivergentERC1155<T> {
    fn safeTransferFrom(
        ref self: T,
        from: ContractAddress,
        to: ContractAddress,
        id: u256,
        value: u256,
        data: Span<felt252>,
    );
    fn safe_transfer_from(
        ref self: T,
        from: ContractAddress,
        to: ContractAddress,
        token_id: u256,
        value: u256,
        data: Span<felt252>,
    );
    fn balanceOf(self: @T, account: ContractAddress, id: u256) -> u256;
}

/// ERC1155 exposing both entry points where camelCase works and snake_case always fails: shows the
/// exchange calls camelCase first.
#[starknet::contract]
pub mod DivergentERC1155 {
    use starknet::ContractAddress;
    use starknet::storage::{Map, StorageMapReadAccess, StorageMapWriteAccess};

    #[storage]
    struct Storage {
        balances: Map<(u256, ContractAddress), u256>,
    }

    #[abi(embed_v0)]
    impl Impl of super::IDivergentERC1155<ContractState> {
        fn safeTransferFrom(
            ref self: ContractState,
            from: ContractAddress,
            to: ContractAddress,
            id: u256,
            value: u256,
            data: Span<felt252>,
        ) {
            let from_balance = self.balances.read((id, from));
            assert(from_balance >= value, 'insufficient balance');
            self.balances.write((id, from), from_balance - value);
            self.balances.write((id, to), self.balances.read((id, to)) + value);
        }

        fn safe_transfer_from(
            ref self: ContractState,
            from: ContractAddress,
            to: ContractAddress,
            token_id: u256,
            value: u256,
            data: Span<felt252>,
        ) {
            core::panic_with_felt252('snake 1155 called');
        }

        fn balanceOf(self: @ContractState, account: ContractAddress, id: u256) -> u256 {
            self.balances.read((id, account))
        }
    }

    #[abi(embed_v0)]
    impl MintImpl of crate::mocks::IMint<ContractState> {
        fn mint(ref self: ContractState, to: ContractAddress, id: u256, amount: u256) {
            self.balances.write((id, to), self.balances.read((id, to)) + amount);
        }
    }
}

/// Account with both entry points that disagree: `is_valid_signature` accepts only the signature
/// [1, 2]; `isValidSignature` accepts anything. The exchange must use the snake_case one.
#[starknet::contract]
pub mod DivergentAccount {
    #[storage]
    struct Storage {}

    #[abi(embed_v0)]
    impl Snake of crate::mocks::ISnip6<ContractState> {
        fn is_valid_signature(
            self: @ContractState, hash: felt252, signature: Array<felt252>,
        ) -> felt252 {
            if signature.len() == 2 && *signature[0] == 1 && *signature[1] == 2 {
                starknet::VALIDATED
            } else {
                0
            }
        }
    }

    #[abi(embed_v0)]
    impl Camel of crate::mocks::ICamelAccount<ContractState> {
        fn isValidSignature(
            self: @ContractState, hash: felt252, signature: Array<felt252>,
        ) -> felt252 {
            1
        }
    }
}

/// Account whose `is_valid_signature` panics with its own error.
#[starknet::contract]
pub mod PanicAccount {
    #[storage]
    struct Storage {}

    #[abi(embed_v0)]
    impl Snake of crate::mocks::ISnip6<ContractState> {
        fn is_valid_signature(
            self: @ContractState, hash: felt252, signature: Array<felt252>,
        ) -> felt252 {
            core::panic_with_felt252('account exploded')
        }
    }
}

#[starknet::interface]
pub trait IEmptyPanic<T> {
    fn transferFrom(ref self: T, from: ContractAddress, to: ContractAddress, tokenId: u256);
}

/// ERC721 whose `transferFrom` panics with no data at all.
#[starknet::contract]
pub mod EmptyPanicERC721 {
    use starknet::ContractAddress;

    #[storage]
    struct Storage {}

    #[abi(embed_v0)]
    impl Impl of super::IEmptyPanic<ContractState> {
        fn transferFrom(
            ref self: ContractState, from: ContractAddress, to: ContractAddress, tokenId: u256,
        ) {
            core::panics::panic(array![]);
        }
    }
}
