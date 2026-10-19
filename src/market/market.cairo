// SPDX-License-Identifier: MIT

/// Pavilion Market exchange. Immutable (no upgrade); the owner can only pause, unpause and
/// transfer ownership. Pays only in the payment token fixed at deployment (STRK).
#[starknet::contract]
pub mod PavilionExchange {
    use core::num::traits::Zero;
    use openzeppelin_access::ownable::OwnableComponent;
    use openzeppelin_security::pausable::PausableComponent;
    use openzeppelin_security::reentrancyguard::ReentrancyGuardComponent;
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
        StoragePointerWriteAccess,
    };
    use starknet::storage_access::StorePacking;
    use starknet::{ContractAddress, get_caller_address, get_contract_address, get_tx_info};
    use crate::market::event::{CounterIncremented, OrderCancelled, OrderFilled};
    use crate::market::interface::{
        ERC721SellOrder, Fee, FillParams, IExchange, IExchangeAdmin, IOrderValidatorDispatcher,
        IOrderValidatorDispatcherTrait, ORDER_TYPE_ERC721_SELL_ORDER, Order, OrderStatus,
        VALIDATE_ORDER_MAGIC,
    };
    use crate::market::order_checker::check_order;
    use crate::market::order_executor::{transfer_erc20, transfer_nft};
    use crate::market::signature_validator::{
        domain_hash, hash_order_struct, message_hash, validate_signature,
    };

    component!(path: OwnableComponent, storage: ownable, event: OwnableEvent);
    component!(path: PausableComponent, storage: pausable, event: PausableEvent);
    component!(
        path: ReentrancyGuardComponent, storage: reentrancy_guard, event: ReentrancyGuardEvent,
    );

    // `is_paused` view.
    #[abi(embed_v0)]
    impl PausableImpl = PausableComponent::PausableImpl<ContractState>;

    impl OwnableInternalImpl = OwnableComponent::InternalImpl<ContractState>;
    impl PausableInternalImpl = PausableComponent::InternalImpl<ContractState>;
    impl ReentrancyGuardInternalImpl = ReentrancyGuardComponent::InternalImpl<ContractState>;

    pub mod Errors {
        pub const INVALID_CALLER: felt252 = 'Exchange: invalid caller';
        pub const ORDER_CANCELLED: felt252 = 'Exchange: order cancelled';
        pub const EXCEEDS_NFT_AMOUNT: felt252 = 'Exchange: exceeds nft amount';
        pub const VALIDATE_ORDER_ERROR: felt252 = 'Exchange: validate order error';
        pub const INVALID_FEE: felt252 = 'Exchange: invalid fee';
        pub const ZERO_PAYMENT_TOKEN: felt252 = 'Exchange: zero payment token';
        pub const ZERO_OWNER: felt252 = 'Exchange: zero owner';
    }

    #[storage]
    struct Storage {
        #[substorage(v0)]
        ownable: OwnableComponent::Storage,
        #[substorage(v0)]
        pausable: PausableComponent::Storage,
        #[substorage(v0)]
        reentrancy_guard: ReentrancyGuardComponent::Storage,
        counters: Map<ContractAddress, u128>,
        order_status: Map<felt252, OrderStatus>,
        payment_token: ContractAddress,
        chain_id: felt252,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        CounterIncremented: CounterIncremented,
        OrderCancelled: OrderCancelled,
        OrderFilled: OrderFilled,
        #[flat]
        OwnableEvent: OwnableComponent::Event,
        #[flat]
        PausableEvent: PausableComponent::Event,
        #[flat]
        ReentrancyGuardEvent: ReentrancyGuardComponent::Event,
    }

    /// `chain_id` is read once here, from the deploy transaction, and used for every hash.
    #[constructor]
    fn constructor(
        ref self: ContractState, owner: ContractAddress, payment_token: ContractAddress,
    ) {
        assert(!owner.is_zero(), Errors::ZERO_OWNER);
        assert(!payment_token.is_zero(), Errors::ZERO_PAYMENT_TOKEN);
        self.ownable.initializer(owner);
        self.payment_token.write(payment_token);
        self.chain_id.write(get_tx_info().unbox().chain_id);
    }

    #[abi(embed_v0)]
    impl ExchangeImpl of IExchange<ContractState> {
        fn buy_erc721(ref self: ContractState, order: ERC721SellOrder, signature: Span<felt252>) {
            self.reentrancy_guard.start();
            self.pausable.assert_not_paused();

            let mut fees: Array<Fee> = array![];
            push_short_form_fee(ref fees, order.fee0_recipient, order.fee0_amount);
            push_short_form_fee(ref fees, order.fee1_recipient, order.fee1_amount);

            let full_order = Order {
                order_type: ORDER_TYPE_ERC721_SELL_ORDER,
                maker: order.maker,
                taker: Zero::zero(),
                listing_time: order.listing_time,
                expiry_time: order.expiry_time,
                salt: order.salt,
                erc20_address: order.erc20_address,
                erc20_amount: order.erc20_amount,
                fees: fees.span(),
                nft_address: order.nft_address,
                nft_id: order.nft_id,
                nft_amount: 1,
                order_validator: Zero::zero(),
                counter: self.counters.read(order.maker),
            };
            let params = FillParams {
                fill_id: order.nft_id,
                fill_amount: 1,
                recipient: Zero::zero(),
                signature,
                extra_data: array![].span(),
            };
            self._fill_order(@full_order, @params);

            self.reentrancy_guard.end();
        }

        fn fill_order(ref self: ContractState, order: Order, params: FillParams) {
            self.reentrancy_guard.start();
            self.pausable.assert_not_paused();
            self._fill_order(@order, @params);
            self.reentrancy_guard.end();
        }

        fn cancel_orders(ref self: ContractState, orders: Span<Order>) {
            self.reentrancy_guard.start();
            let caller = get_caller_address();
            for order in orders {
                assert(caller == *order.maker, Errors::INVALID_CALLER);
                let order_hash = self._order_hash(order);
                let mut status = self.order_status.read(order_hash);
                status.is_cancelled = true;
                self.order_status.write(order_hash, status);
                self.emit(OrderCancelled { account: caller, order_hash });
            }
            self.reentrancy_guard.end();
        }

        fn increment_counter(ref self: ContractState) -> u128 {
            self.reentrancy_guard.start();
            let account = get_caller_address();
            let new_counter = self.counters.read(account) + 1;
            self.counters.write(account, new_counter);
            self.emit(CounterIncremented { account, new_counter });
            self.reentrancy_guard.end();
            new_counter
        }

        fn get_counter(self: @ContractState, account: ContractAddress) -> u128 {
            self.counters.read(account)
        }

        fn get_order_status(self: @ContractState, order_hash: felt252) -> OrderStatus {
            self.order_status.read(order_hash)
        }

        fn get_order_hash(self: @ContractState, order: Order) -> felt252 {
            self._order_hash(@order)
        }

        fn validate_signature(self: @ContractState, order: Order, signature: Span<felt252>) {
            let exchange = get_contract_address();
            let domain = domain_hash(self.chain_id.read());
            let leaf = hash_order_struct(@order, exchange);
            let order_hash = message_hash(domain, order.maker, leaf);
            validate_signature(order.maker, exchange, domain, order_hash, leaf, signature);
        }

        fn payment_token(self: @ContractState) -> ContractAddress {
            self.payment_token.read()
        }
    }

    #[abi(embed_v0)]
    impl ExchangeAdminImpl of IExchangeAdmin<ContractState> {
        fn owner(self: @ContractState) -> ContractAddress {
            self.ownable.Ownable_owner.read()
        }

        fn transfer_ownership(ref self: ContractState, new_owner: ContractAddress) {
            self.ownable.assert_only_owner();
            assert(!new_owner.is_zero(), Errors::ZERO_OWNER);
            self.ownable._transfer_ownership(new_owner);
        }

        fn pause(ref self: ContractState) {
            self.ownable.assert_only_owner();
            self.pausable.pause();
        }

        fn unpause(ref self: ContractState) {
            self.ownable.assert_only_owner();
            self.pausable.unpause();
        }
    }

    #[generate_trait]
    impl InternalImpl of InternalTrait {
        fn _order_hash(self: @ContractState, order: @Order) -> felt252 {
            let leaf = hash_order_struct(order, get_contract_address());
            message_hash(domain_hash(self.chain_id.read()), *order.maker, leaf)
        }

        fn _fill_order(ref self: ContractState, order: @Order, params: @FillParams) {
            // 1. Check the order and fill parameters.
            let maker = *order.maker;
            let counter = self.counters.read(maker);
            let (caller, recipient, merkle_root) = check_order(
                order, params, counter, self.payment_token.read(),
            );

            // 2. Validate the signature (single or bulk). The order hash is the single-order hash.
            let exchange = get_contract_address();
            let domain = domain_hash(self.chain_id.read());
            let leaf = hash_order_struct(order, exchange);
            let order_hash = message_hash(domain, maker, leaf);
            validate_signature(maker, exchange, domain, order_hash, leaf, *params.signature);

            // 3. Ask the order validator, if any.
            let validator = *order.order_validator;
            if !validator.is_zero() {
                let magic = IOrderValidatorDispatcher { contract_address: validator }
                    .validate_pavilion_order(
                        *order.nft_address,
                        *params.fill_id,
                        merkle_root,
                        order_hash,
                        *params.extra_data,
                    );
                assert(magic == VALIDATE_ORDER_MAGIC, Errors::VALIDATE_ORDER_ERROR);
            }

            // 4. Check and update the order status before any transfer.
            let fill_amount = *params.fill_amount;
            let mut status = self.order_status.read(order_hash);
            assert(!status.is_cancelled, Errors::ORDER_CANCELLED);
            let filled_amount = status.filled_amount + fill_amount;
            assert(filled_amount <= *order.nft_amount, Errors::EXCEEDS_NFT_AMOUNT);
            status.filled_amount = filled_amount;
            self.order_status.write(order_hash, status);

            // 5. Transfers.
            let fill_id = *params.fill_id;
            transfer_nft(order, fill_id, fill_amount, caller, recipient);
            let (erc20_amount, fees) = transfer_erc20(order, fill_amount, caller, recipient);

            self
                .emit(
                    OrderFilled {
                        order_hash,
                        order_type: *order.order_type,
                        maker,
                        taker: recipient,
                        erc20_address: *order.erc20_address,
                        erc20_amount,
                        fees,
                        nft_address: *order.nft_address,
                        nft_id: fill_id,
                        nft_amount: fill_amount,
                        caller,
                    },
                );
        }
    }

    /// Short-form fee: a zero recipient means "no fee" and must come with a zero amount.
    fn push_short_form_fee(ref fees: Array<Fee>, recipient: ContractAddress, amount: u128) {
        if recipient.is_zero() {
            assert(amount == 0, Errors::INVALID_FEE);
        } else {
            fees.append(Fee { recipient, amount });
        }
    }

    /// One storage slot: `filled_amount` in the low 128 bits, the cancelled flag at bit 128.
    impl OrderStatusStorePacking of StorePacking<OrderStatus, felt252> {
        fn pack(value: OrderStatus) -> felt252 {
            let filled: felt252 = value.filled_amount.into();
            if value.is_cancelled {
                filled + 0x100000000000000000000000000000000
            } else {
                filled
            }
        }

        fn unpack(value: felt252) -> OrderStatus {
            let value: u256 = value.into();
            OrderStatus { is_cancelled: value.high != 0, filled_amount: value.low }
        }
    }
}
