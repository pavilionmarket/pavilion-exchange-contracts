// SPDX-License-Identifier: MIT

use openzeppelin_interfaces::token::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
use starknet::{ContractAddress, SyscallResultTrait};
use crate::market::interface::{Fee, Order};
use crate::market::order_checker::{is_erc721, is_sell_order};
use crate::utils::call::call_with_fallback;

pub mod Errors {
    pub const ERC20_TRANSFER_FAILED: felt252 = 'Exchange: erc20 transfer failed';
}

/// Moves the NFT: from the maker to the recipient for sell orders, from the caller to the maker
/// for buy orders. Calls camelCase first (OpenZeppelin and Cairo 0 collections) and falls back to
/// snake_case for collections that only expose snake_case.
pub fn transfer_nft(
    order: @Order,
    fill_id: u256,
    fill_amount: u128,
    caller: ContractAddress,
    recipient: ContractAddress,
) {
    let maker = *order.maker;
    let order_type = *order.order_type;
    let (from, to) = if is_sell_order(order_type) {
        (maker, recipient)
    } else {
        (caller, maker)
    };

    let mut calldata: Array<felt252> = array![from.into(), to.into()];
    fill_id.serialize(ref calldata);

    if is_erc721(order_type) {
        call_with_fallback(
            *order.nft_address,
            selector!("transferFrom"),
            selector!("transfer_from"),
            calldata.span(),
        )
            .unwrap_syscall();
    } else {
        let value: u256 = fill_amount.into();
        value.serialize(ref calldata);
        calldata.append(0); // data: empty Span<felt252>
        call_with_fallback(
            *order.nft_address,
            selector!("safeTransferFrom"),
            selector!("safe_transfer_from"),
            calldata.span(),
        )
            .unwrap_syscall();
    }
}

/// Pays for `fill_amount` units: each fee to its recipient, the rest to the payee. Amounts are
/// prorated with floor rounding, so the payee's share never underflows. Returns the total paid
/// and the fees actually paid.
pub fn transfer_erc20(
    order: @Order, fill_amount: u128, caller: ContractAddress, recipient: ContractAddress,
) -> (u128, Span<Fee>) {
    let nft_amount = *order.nft_amount;
    let erc20_amount = calculate_payable_amount(*order.erc20_amount, fill_amount, nft_amount);
    let token = IERC20Dispatcher { contract_address: *order.erc20_address };
    let (payer, payee) = if is_sell_order(*order.order_type) {
        (caller, *order.maker)
    } else {
        (*order.maker, recipient)
    };

    let mut paid_fees: Array<Fee> = array![];
    let mut amount_to_payee = erc20_amount;
    for fee in *order.fees {
        let amount = calculate_payable_amount(*fee.amount, fill_amount, nft_amount);
        if amount != 0 {
            erc20_transfer_from(token, payer, *fee.recipient, amount);
            amount_to_payee -= amount;
        }
        paid_fees.append(Fee { recipient: *fee.recipient, amount });
    }

    if amount_to_payee != 0 {
        erc20_transfer_from(token, payer, payee, amount_to_payee);
    }

    (erc20_amount, paid_fees.span())
}

/// floor(amount * fill_amount / nft_amount), computed in u256 so it cannot overflow. Exact
/// (`amount`) for a full fill. `fill_amount <= nft_amount` (checked before), so the result is at
/// most `amount` and always fits in u128.
pub fn calculate_payable_amount(amount: u128, fill_amount: u128, nft_amount: u128) -> u128 {
    let result: u256 = amount.into() * fill_amount.into() / nft_amount.into();
    result.try_into().unwrap()
}

fn erc20_transfer_from(
    token: IERC20Dispatcher, from: ContractAddress, to: ContractAddress, amount: u128,
) {
    assert(token.transfer_from(from, to, amount.into()), Errors::ERC20_TRANSFER_FAILED);
}
