// SPDX-License-Identifier: UNLICENSED

pragma solidity 0.8.16;

import 'src/interfaces/IConverter.sol';

import 'src/interfaces/IAaveAToken.sol';
import 'src/interfaces/IAaveLendingPool.sol';
import 'src/interfaces/ICompoundToken.sol';
import 'src/interfaces/ILido.sol';

import 'src/interfaces/IERC20.sol';
import 'src/lib/Safe.sol';

contract Converter is IConverter {
    /// @notice converts the compounding asset to the underlying asset for msg.sender
    /// @dev currently supports Compound, Aave and Lido conversions
    /// @param c address of the compounding token
    /// @param u address of the underlying token
    /// @param a amount of tokens to convert
    function convert(
        address c,
        address u,
        uint256 a
    ) external {
        // first receive the tokens from msg.sender
        Safe.transferFrom(IERC20(c), msg.sender, address(this), a);

        // get Aave pool
        try IAaveAToken(c).POOL() returns (address pool) {
            // Allow the pool to spend the funds
            Safe.approve(IERC20(u), pool, a);
            // withdraw from Aave
            IAaveLendingPool(pool).withdraw(u, a, msg.sender);
        } catch {
            // attempt to redeem compound tokens to the underlying asset
            try ICompoundToken(c).redeem(a) {
                // get the balance of underlying assets redeemed
                uint256 balance = IERC20(u).balanceOf(address(this));
                // transfer the underlying back to the user
                Safe.transfer(IERC20(u), msg.sender, balance);
            } catch {
                // get the current balance of wstETH
                uint256 balance = IERC20(c).balanceOf(address(this));
                // unwrap wrapped staked eth
                uint256 unwrapped = ILido(c).unwrap(balance);
                // Send the unwrapped staked ETH to the caller
                Safe.transfer(IERC20(u), msg.sender, unwrapped);
            }
        }
    }
}
