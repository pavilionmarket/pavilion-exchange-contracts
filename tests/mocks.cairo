// Mock contracts for the exchange's unit tests. Never deployed outside tests.

use starknet::ContractAddress;

#[starknet::interface]
pub trait IMint<T> {
    fn mint(ref self: T, to: ContractAddress, id: u256, amount: u256);
}

/// Stand-in for STRK (and for any "other" ERC20): OpenZeppelin ERC20, public mint.
#[starknet::contract]
pub mod MockERC20 {
    use openzeppelin_token::erc20::{DefaultConfig, ERC20Component, ERC20HooksEmptyImpl};
    use starknet::ContractAddress;

    component!(path: ERC20Component, storage: erc20, event: ERC20Event);

    #[abi(embed_v0)]
    impl ERC20MixinImpl = ERC20Component::ERC20MixinImpl<ContractState>;
    impl ERC20InternalImpl = ERC20Component::InternalImpl<ContractState>;

    #[storage]
    struct Storage {
        #[substorage(v0)]
        erc20: ERC20Component::Storage,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        #[flat]
        ERC20Event: ERC20Component::Event,
    }

    #[constructor]
    fn constructor(ref self: ContractState) {
        self.erc20.initializer("Mock STRK", "MSTRK");
    }

    #[abi(embed_v0)]
    impl MintImpl of super::IMint<ContractState> {
        fn mint(ref self: ContractState, to: ContractAddress, id: u256, amount: u256) {
            self.erc20.mint(to, amount);
        }
    }
}

/// OpenZeppelin Cairo 1 ERC721: exposes snake_case and camelCase.
#[starknet::contract]
pub mod MockERC721 {
    use openzeppelin_introspection::src5::SRC5Component;
    use openzeppelin_token::erc721::{
        ERC721Component, ERC721HooksEmptyImpl, ERC721OwnerOfDefaultImpl, ERC721TokenURIDefaultImpl,
    };
    use starknet::ContractAddress;

    component!(path: ERC721Component, storage: erc721, event: ERC721Event);
    component!(path: SRC5Component, storage: src5, event: SRC5Event);

    #[abi(embed_v0)]
    impl ERC721MixinImpl = ERC721Component::ERC721MixinImpl<ContractState>;
    impl ERC721InternalImpl = ERC721Component::InternalImpl<ContractState>;

    #[storage]
    struct Storage {
        #[substorage(v0)]
        erc721: ERC721Component::Storage,
        #[substorage(v0)]
        src5: SRC5Component::Storage,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        #[flat]
        ERC721Event: ERC721Component::Event,
        #[flat]
        SRC5Event: SRC5Component::Event,
    }

    #[constructor]
    fn constructor(ref self: ContractState) {
        self.erc721.initializer("Mock 721", "M721", "");
    }

    #[abi(embed_v0)]
    impl MintImpl of super::IMint<ContractState> {
        fn mint(ref self: ContractState, to: ContractAddress, id: u256, amount: u256) {
            self.erc721.mint(to, id);
        }
    }
}

/// OpenZeppelin Cairo 1 ERC1155 (snake_case and camelCase), public mint without acceptance check.
#[starknet::contract]
pub mod MockERC1155 {
    use openzeppelin_introspection::src5::SRC5Component;
    use openzeppelin_token::erc1155::{
        ERC1155Component, ERC1155HooksEmptyImpl, ERC1155TokenURIDefaultImpl,
    };
    use starknet::ContractAddress;

    component!(path: ERC1155Component, storage: erc1155, event: ERC1155Event);
    component!(path: SRC5Component, storage: src5, event: SRC5Event);

    #[abi(embed_v0)]
    impl ERC1155MixinImpl = ERC1155Component::ERC1155MixinImpl<ContractState>;
    impl ERC1155InternalImpl = ERC1155Component::InternalImpl<ContractState>;

    #[storage]
    struct Storage {
        #[substorage(v0)]
        erc1155: ERC1155Component::Storage,
        #[substorage(v0)]
        src5: SRC5Component::Storage,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        #[flat]
        ERC1155Event: ERC1155Component::Event,
        #[flat]
        SRC5Event: SRC5Component::Event,
    }

    #[constructor]
    fn constructor(ref self: ContractState) {
        self.erc1155.initializer("");
    }

    #[abi(embed_v0)]
    impl MintImpl of super::IMint<ContractState> {
        fn mint(ref self: ContractState, to: ContractAddress, id: u256, amount: u256) {
            self
                .erc1155
                .update(
                    core::num::traits::Zero::zero(), to, array![id].span(), array![amount].span(),
                );
        }
    }
}

#[starknet::interface]
pub trait ICamelOnlyERC721<T> {
    fn ownerOf(self: @T, tokenId: u256) -> ContractAddress;
    fn transferFrom(ref self: T, from: ContractAddress, to: ContractAddress, tokenId: u256);
    fn setApprovalForAll(ref self: T, operator: ContractAddress, approved: bool);
    fn isApprovedForAll(self: @T, owner: ContractAddress, operator: ContractAddress) -> bool;
}

/// Cairo 0-style collection (like PVL): camelCase entry points only.
#[starknet::contract]
pub mod CamelOnlyERC721 {
    use core::num::traits::Zero;
    use starknet::storage::{Map, StorageMapReadAccess, StorageMapWriteAccess};
    use starknet::{ContractAddress, get_caller_address};

    #[storage]
    struct Storage {
        owners: Map<u256, ContractAddress>,
        operators: Map<(ContractAddress, ContractAddress), bool>,
    }

    #[abi(embed_v0)]
    impl Impl of super::ICamelOnlyERC721<ContractState> {
        fn ownerOf(self: @ContractState, tokenId: u256) -> ContractAddress {
            self.owners.read(tokenId)
        }

        fn transferFrom(
            ref self: ContractState, from: ContractAddress, to: ContractAddress, tokenId: u256,
        ) {
            let caller = get_caller_address();
            assert(self.owners.read(tokenId) == from, 'wrong owner');
            assert(caller == from || self.operators.read((from, caller)), 'not approved');
            assert(!to.is_zero(), 'zero to');
            self.owners.write(tokenId, to);
        }

        fn setApprovalForAll(ref self: ContractState, operator: ContractAddress, approved: bool) {
            self.operators.write((get_caller_address(), operator), approved);
        }

        fn isApprovedForAll(
            self: @ContractState, owner: ContractAddress, operator: ContractAddress,
        ) -> bool {
            self.operators.read((owner, operator))
        }
    }

    #[abi(embed_v0)]
    impl MintImpl of super::IMint<ContractState> {
        fn mint(ref self: ContractState, to: ContractAddress, id: u256, amount: u256) {
            self.owners.write(id, to);
        }
    }
}

#[starknet::interface]
pub trait ISnakeOnlyERC721<T> {
    fn owner_of(self: @T, token_id: u256) -> ContractAddress;
    fn transfer_from(ref self: T, from: ContractAddress, to: ContractAddress, token_id: u256);
    fn set_approval_for_all(ref self: T, operator: ContractAddress, approved: bool);
}

/// Collection exposing snake_case entry points only.
#[starknet::contract]
pub mod SnakeOnlyERC721 {
    use core::num::traits::Zero;
    use starknet::storage::{Map, StorageMapReadAccess, StorageMapWriteAccess};
    use starknet::{ContractAddress, get_caller_address};

    #[storage]
    struct Storage {
        owners: Map<u256, ContractAddress>,
        operators: Map<(ContractAddress, ContractAddress), bool>,
    }

    #[abi(embed_v0)]
    impl Impl of super::ISnakeOnlyERC721<ContractState> {
        fn owner_of(self: @ContractState, token_id: u256) -> ContractAddress {
            self.owners.read(token_id)
        }

        fn transfer_from(
            ref self: ContractState, from: ContractAddress, to: ContractAddress, token_id: u256,
        ) {
            let caller = get_caller_address();
            assert(self.owners.read(token_id) == from, 'wrong owner');
            assert(caller == from || self.operators.read((from, caller)), 'not approved');
            assert(!to.is_zero(), 'zero to');
            self.owners.write(token_id, to);
        }

        fn set_approval_for_all(
            ref self: ContractState, operator: ContractAddress, approved: bool,
        ) {
            self.operators.write((get_caller_address(), operator), approved);
        }
    }

    #[abi(embed_v0)]
    impl MintImpl of super::IMint<ContractState> {
        fn mint(ref self: ContractState, to: ContractAddress, id: u256, amount: u256) {
            self.owners.write(id, to);
        }
    }
}

/// OpenZeppelin account (SNIP-6 `is_valid_signature` returning 'VALID', 2-felt signatures).
#[starknet::contract(account)]
pub mod MockAccount {
    use openzeppelin_account::AccountComponent;
    use openzeppelin_introspection::src5::SRC5Component;

    component!(path: AccountComponent, storage: account, event: AccountEvent);
    component!(path: SRC5Component, storage: src5, event: SRC5Event);

    #[abi(embed_v0)]
    impl AccountMixinImpl = AccountComponent::AccountMixinImpl<ContractState>;
    impl AccountInternalImpl = AccountComponent::InternalImpl<ContractState>;

    #[storage]
    struct Storage {
        #[substorage(v0)]
        account: AccountComponent::Storage,
        #[substorage(v0)]
        src5: SRC5Component::Storage,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        #[flat]
        AccountEvent: AccountComponent::Event,
        #[flat]
        SRC5Event: SRC5Component::Event,
    }

    #[constructor]
    fn constructor(ref self: ContractState, public_key: felt252) {
        self.account.initializer(public_key);
    }
}

#[starknet::interface]
pub trait ISnip6<T> {
    fn is_valid_signature(self: @T, hash: felt252, signature: Array<felt252>) -> felt252;
}

#[starknet::interface]
pub trait ISrc5<T> {
    fn supports_interface(self: @T, interface_id: felt252) -> bool;
}

/// Account that needs two signers (like a guardian or 2-of-2 multisig): the signature is
/// [r1, s1, r2, s2] over the hash, by `key1` then `key2`.
#[starknet::contract]
pub mod MultisigAccount {
    use core::ecdsa::check_ecdsa_signature;
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};

    #[storage]
    struct Storage {
        key1: felt252,
        key2: felt252,
    }

    #[constructor]
    fn constructor(ref self: ContractState, key1: felt252, key2: felt252) {
        self.key1.write(key1);
        self.key2.write(key2);
    }

    #[abi(embed_v0)]
    impl Snip6 of super::ISnip6<ContractState> {
        fn is_valid_signature(
            self: @ContractState, hash: felt252, signature: Array<felt252>,
        ) -> felt252 {
            if signature.len() == 4
                && check_ecdsa_signature(hash, self.key1.read(), *signature[0], *signature[1])
                && check_ecdsa_signature(hash, self.key2.read(), *signature[2], *signature[3]) {
                starknet::VALIDATED
            } else {
                0
            }
        }
    }

    #[abi(embed_v0)]
    impl Src5 of super::ISrc5<ContractState> {
        fn supports_interface(self: @ContractState, interface_id: felt252) -> bool {
            interface_id == openzeppelin_interfaces::accounts::ISRC6_ID
        }
    }
}

#[starknet::interface]
pub trait ICamelAccount<T> {
    fn isValidSignature(self: @T, hash: felt252, signature: Array<felt252>) -> felt252;
}

/// Cairo 0-era account: only `isValidSignature`, returns 1 (TRUE) when valid.
#[starknet::contract]
pub mod CamelOnlyAccount {
    use core::ecdsa::check_ecdsa_signature;
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};

    #[storage]
    struct Storage {
        key: felt252,
    }

    #[constructor]
    fn constructor(ref self: ContractState, key: felt252) {
        self.key.write(key);
    }

    #[abi(embed_v0)]
    impl Impl of super::ICamelAccount<ContractState> {
        fn isValidSignature(
            self: @ContractState, hash: felt252, signature: Array<felt252>,
        ) -> felt252 {
            if signature.len() == 2
                && check_ecdsa_signature(hash, self.key.read(), *signature[0], *signature[1]) {
                1
            } else {
                0
            }
        }
    }
}

/// Account whose `is_valid_signature` returns a fixed value, whatever the signature.
#[starknet::contract]
pub mod FixedReturnAccount {
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};

    #[storage]
    struct Storage {
        value: felt252,
    }

    #[constructor]
    fn constructor(ref self: ContractState, value: felt252) {
        self.value.write(value);
    }

    #[abi(embed_v0)]
    impl Snip6 of super::ISnip6<ContractState> {
        fn is_valid_signature(
            self: @ContractState, hash: felt252, signature: Array<felt252>,
        ) -> felt252 {
            self.value.read()
        }
    }
}

#[starknet::interface]
pub trait IMockValidator<T> {
    fn set_result(ref self: T, result: felt252);
    fn last_call(self: @T) -> (ContractAddress, u256, felt252, felt252, Span<felt252>);
    fn calls(self: @T) -> u32;
}

/// Order validator returning a configurable value. As a mock it records its last call, so it is a
/// state-changing entry point (the exchange calls it through a dispatcher either way).
#[starknet::contract]
pub mod MockOrderValidator {
    use starknet::ContractAddress;
    use starknet::storage::{
        MutableVecTrait, StoragePointerReadAccess, StoragePointerWriteAccess, Vec, VecTrait,
    };

    #[storage]
    struct Storage {
        result: felt252,
        nft_address: ContractAddress,
        nft_id: u256,
        merkle_root: felt252,
        order_hash: felt252,
        extra_data: Vec<felt252>,
        calls: u32,
    }

    #[constructor]
    fn constructor(ref self: ContractState, result: felt252) {
        self.result.write(result);
    }

    #[starknet::interface]
    trait IRecordingValidator<T> {
        fn validate_pavilion_order(
            ref self: T,
            nft_address: ContractAddress,
            nft_id: u256,
            merkle_root: felt252,
            order_hash: felt252,
            extra_data: Span<felt252>,
        ) -> felt252;
    }

    #[abi(embed_v0)]
    impl Validator of IRecordingValidator<ContractState> {
        fn validate_pavilion_order(
            ref self: ContractState,
            nft_address: ContractAddress,
            nft_id: u256,
            merkle_root: felt252,
            order_hash: felt252,
            extra_data: Span<felt252>,
        ) -> felt252 {
            self.nft_address.write(nft_address);
            self.nft_id.write(nft_id);
            self.merkle_root.write(merkle_root);
            self.order_hash.write(order_hash);
            for _ in 0..self.extra_data.len() {
                let _ = self.extra_data.pop();
            }
            for x in extra_data {
                self.extra_data.push(*x);
            }
            self.calls.write(self.calls.read() + 1);
            self.result.read()
        }
    }

    #[abi(embed_v0)]
    impl Mock of super::IMockValidator<ContractState> {
        fn set_result(ref self: ContractState, result: felt252) {
            self.result.write(result);
        }

        fn last_call(
            self: @ContractState,
        ) -> (ContractAddress, u256, felt252, felt252, Span<felt252>) {
            let mut extra: Array<felt252> = array![];
            for i in 0..self.extra_data.len() {
                extra.append(self.extra_data.at(i).read());
            }
            (
                self.nft_address.read(),
                self.nft_id.read(),
                self.merkle_root.read(),
                self.order_hash.read(),
                extra.span(),
            )
        }

        fn calls(self: @ContractState) -> u32 {
            self.calls.read()
        }
    }
}

#[starknet::interface]
pub trait IAttacker<T> {
    /// On its next callback, call `selector` on `target` with `calldata` and record the outcome.
    fn arm(ref self: T, target: ContractAddress, selector: felt252, calldata: Array<felt252>);
    /// (callback happened, re-entrant call succeeded, first felt of its error)
    fn outcome(self: @T) -> (bool, bool, felt252);
}

/// Malicious contract that re-enters the exchange from every callback the exchange can trigger:
/// as an ERC721 collection (`transferFrom`), an ERC1155 receiver (`on_erc1155_received`), a maker
/// account (`is_valid_signature`, always 'VALID') and a payment token (`transfer_from`, moves
/// nothing and returns true).
#[starknet::contract]
pub mod Attacker {
    use starknet::ContractAddress;
    use starknet::storage::{
        MutableVecTrait, StoragePointerReadAccess, StoragePointerWriteAccess, Vec,
    };
    use starknet::syscalls::call_contract_syscall;

    #[storage]
    struct Storage {
        armed: bool,
        target: ContractAddress,
        selector: felt252,
        calldata: Vec<felt252>,
        called_back: bool,
        succeeded: bool,
        error: felt252,
    }

    #[abi(embed_v0)]
    impl AttackerImpl of super::IAttacker<ContractState> {
        fn arm(
            ref self: ContractState,
            target: ContractAddress,
            selector: felt252,
            calldata: Array<felt252>,
        ) {
            self.armed.write(true);
            self.target.write(target);
            self.selector.write(selector);
            for _ in 0..self.calldata.len() {
                let _ = self.calldata.pop();
            }
            for x in calldata {
                self.calldata.push(x);
            }
        }

        fn outcome(self: @ContractState) -> (bool, bool, felt252) {
            (self.called_back.read(), self.succeeded.read(), self.error.read())
        }
    }

    #[generate_trait]
    impl Internal of InternalTrait {
        fn reenter(ref self: ContractState) {
            if !self.armed.read() {
                return;
            }
            self.armed.write(false);
            self.called_back.write(true);
            let mut calldata: Array<felt252> = array![];
            for i in 0..self.calldata.len() {
                calldata.append(self.calldata.at(i).read());
            }
            match call_contract_syscall(self.target.read(), self.selector.read(), calldata.span()) {
                Result::Ok(_) => self.succeeded.write(true),
                Result::Err(error) => self.error.write(*error.at(0)),
            }
        }
    }

    #[starknet::interface]
    trait ICallbacks<T> {
        fn transferFrom(ref self: T, from: ContractAddress, to: ContractAddress, token_id: u256);
        fn transfer_from(
            ref self: T, sender: ContractAddress, recipient: ContractAddress, amount: u256,
        ) -> bool;
        fn on_erc1155_received(
            ref self: T,
            operator: ContractAddress,
            from: ContractAddress,
            token_id: u256,
            value: u256,
            data: Span<felt252>,
        ) -> felt252;
        fn supports_interface(self: @T, interface_id: felt252) -> bool;
        fn is_valid_signature(ref self: T, hash: felt252, signature: Array<felt252>) -> felt252;
    }

    #[abi(embed_v0)]
    impl Callbacks of ICallbacks<ContractState> {
        fn transferFrom(
            ref self: ContractState, from: ContractAddress, to: ContractAddress, token_id: u256,
        ) {
            self.reenter();
        }

        fn transfer_from(
            ref self: ContractState,
            sender: ContractAddress,
            recipient: ContractAddress,
            amount: u256,
        ) -> bool {
            self.reenter();
            true
        }

        fn on_erc1155_received(
            ref self: ContractState,
            operator: ContractAddress,
            from: ContractAddress,
            token_id: u256,
            value: u256,
            data: Span<felt252>,
        ) -> felt252 {
            self.reenter();
            openzeppelin_interfaces::erc1155::IERC1155_RECEIVER_ID
        }

        fn supports_interface(self: @ContractState, interface_id: felt252) -> bool {
            interface_id == openzeppelin_interfaces::erc1155::IERC1155_RECEIVER_ID
                || interface_id == openzeppelin_interfaces::accounts::ISRC6_ID
        }

        fn is_valid_signature(
            ref self: ContractState, hash: felt252, signature: Array<felt252>,
        ) -> felt252 {
            self.reenter();
            starknet::VALIDATED
        }
    }
}

#[starknet::interface]
pub trait IDivergentERC721<T> {
    fn transferFrom(ref self: T, from: ContractAddress, to: ContractAddress, tokenId: u256);
    fn transfer_from(ref self: T, from: ContractAddress, to: ContractAddress, token_id: u256);
    fn owner_of(self: @T, token_id: u256) -> ContractAddress;
}

/// camelCase `transferFrom` always fails; snake_case `transfer_from` works. Shows that the exchange
/// falls back only on a missing entry point, never on another failure.
#[starknet::contract]
pub mod DivergentERC721 {
    use starknet::ContractAddress;
    use starknet::storage::{Map, StorageMapReadAccess, StorageMapWriteAccess};

    #[storage]
    struct Storage {
        owners: Map<u256, ContractAddress>,
    }

    #[abi(embed_v0)]
    impl Impl of super::IDivergentERC721<ContractState> {
        fn transferFrom(
            ref self: ContractState, from: ContractAddress, to: ContractAddress, tokenId: u256,
        ) {
            core::panic_with_felt252('camel transfer failed');
        }

        fn transfer_from(
            ref self: ContractState, from: ContractAddress, to: ContractAddress, token_id: u256,
        ) {
            assert(self.owners.read(token_id) == from, 'wrong owner');
            self.owners.write(token_id, to);
        }

        fn owner_of(self: @ContractState, token_id: u256) -> ContractAddress {
            self.owners.read(token_id)
        }
    }

    #[abi(embed_v0)]
    impl MintImpl of super::IMint<ContractState> {
        fn mint(ref self: ContractState, to: ContractAddress, id: u256, amount: u256) {
            self.owners.write(id, to);
        }
    }
}

#[starknet::interface]
pub trait ISnakeOnlyERC1155<T> {
    fn safe_transfer_from(
        ref self: T,
        from: ContractAddress,
        to: ContractAddress,
        token_id: u256,
        value: u256,
        data: Span<felt252>,
    );
    fn balance_of(self: @T, account: ContractAddress, token_id: u256) -> u256;
}

/// ERC1155 exposing snake_case only. Operator approval is not modelled: anyone may move tokens.
#[starknet::contract]
pub mod SnakeOnlyERC1155 {
    use starknet::ContractAddress;
    use starknet::storage::{Map, StorageMapReadAccess, StorageMapWriteAccess};

    #[storage]
    struct Storage {
        balances: Map<(u256, ContractAddress), u256>,
    }

    #[abi(embed_v0)]
    impl Impl of super::ISnakeOnlyERC1155<ContractState> {
        fn safe_transfer_from(
            ref self: ContractState,
            from: ContractAddress,
            to: ContractAddress,
            token_id: u256,
            value: u256,
            data: Span<felt252>,
        ) {
            assert(data.len() == 0, 'unexpected data');
            let from_balance = self.balances.read((token_id, from));
            assert(from_balance >= value, 'insufficient balance');
            self.balances.write((token_id, from), from_balance - value);
            self.balances.write((token_id, to), self.balances.read((token_id, to)) + value);
        }

        fn balance_of(self: @ContractState, account: ContractAddress, token_id: u256) -> u256 {
            self.balances.read((token_id, account))
        }
    }

    #[abi(embed_v0)]
    impl MintImpl of super::IMint<ContractState> {
        fn mint(ref self: ContractState, to: ContractAddress, id: u256, amount: u256) {
            self.balances.write((id, to), self.balances.read((id, to)) + amount);
        }
    }
}

#[starknet::interface]
pub trait ICamelOnlyERC1155<T> {
    fn safeTransferFrom(
        ref self: T,
        from: ContractAddress,
        to: ContractAddress,
        id: u256,
        value: u256,
        data: Span<felt252>,
    );
    fn balanceOf(self: @T, account: ContractAddress, id: u256) -> u256;
}

/// ERC1155 exposing camelCase only. Operator approval is not modelled: anyone may move tokens.
#[starknet::contract]
pub mod CamelOnlyERC1155 {
    use starknet::ContractAddress;
    use starknet::storage::{Map, StorageMapReadAccess, StorageMapWriteAccess};

    #[storage]
    struct Storage {
        balances: Map<(u256, ContractAddress), u256>,
    }

    #[abi(embed_v0)]
    impl Impl of super::ICamelOnlyERC1155<ContractState> {
        fn safeTransferFrom(
            ref self: ContractState,
            from: ContractAddress,
            to: ContractAddress,
            id: u256,
            value: u256,
            data: Span<felt252>,
        ) {
            assert(data.len() == 0, 'unexpected data');
            let from_balance = self.balances.read((id, from));
            assert(from_balance >= value, 'insufficient balance');
            self.balances.write((id, from), from_balance - value);
            self.balances.write((id, to), self.balances.read((id, to)) + value);
        }

        fn balanceOf(self: @ContractState, account: ContractAddress, id: u256) -> u256 {
            self.balances.read((id, account))
        }
    }

    #[abi(embed_v0)]
    impl MintImpl of super::IMint<ContractState> {
        fn mint(ref self: ContractState, to: ContractAddress, id: u256, amount: u256) {
            self.balances.write((id, to), self.balances.read((id, to)) + amount);
        }
    }
}

#[starknet::interface]
pub trait IFalseERC20<T> {
    fn transfer_from(
        ref self: T, sender: ContractAddress, recipient: ContractAddress, amount: u256,
    ) -> bool;
}

/// Payment token whose `transfer_from` moves nothing and returns false.
#[starknet::contract]
pub mod FalseERC20 {
    use starknet::ContractAddress;

    #[storage]
    struct Storage {}

    #[abi(embed_v0)]
    impl Impl of super::IFalseERC20<ContractState> {
        fn transfer_from(
            ref self: ContractState,
            sender: ContractAddress,
            recipient: ContractAddress,
            amount: u256,
        ) -> bool {
            false
        }
    }
}

#[starknet::interface]
pub trait IEmptyReturnAccount<T> {
    fn is_valid_signature(self: @T, hash: felt252, signature: Array<felt252>);
}

/// Account whose `is_valid_signature` returns nothing.
#[starknet::contract]
pub mod EmptyReturnAccount {
    #[storage]
    struct Storage {}

    #[abi(embed_v0)]
    impl Impl of super::IEmptyReturnAccount<ContractState> {
        fn is_valid_signature(self: @ContractState, hash: felt252, signature: Array<felt252>) {}
    }
}
