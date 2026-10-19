// SPDX-License-Identifier: MIT

use starknet::syscalls::call_contract_syscall;
use starknet::{ContractAddress, SyscallResult};

/// Calls `first` on `target`; if `target` has no such entry point, calls `second` instead.
///
/// Relies on Starknet returning a missing entry point to the caller as a catchable error whose
/// first felt is 'ENTRYPOINT_NOT_FOUND' (verified on starknet-devnet 0.9.0 / Starknet 0.14.3, see
/// the package README). Any other error is returned unchanged. A call to an address with no
/// deployed contract cannot be caught and reverts the whole transaction.
pub fn call_with_fallback(
    target: ContractAddress, first: felt252, second: felt252, calldata: Span<felt252>,
) -> SyscallResult<Span<felt252>> {
    match call_contract_syscall(target, first, calldata) {
        Result::Ok(ret) => Result::Ok(ret),
        Result::Err(error) => {
            if error.len() != 0 && *error.at(0) == 'ENTRYPOINT_NOT_FOUND' {
                call_contract_syscall(target, second, calldata)
            } else {
                Result::Err(error)
            }
        },
    }
}
