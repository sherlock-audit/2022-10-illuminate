// SPDX-License-Identifier: UNLICENSED

pragma solidity 0.8.16;

import 'src/MarketPlace.sol';

import 'src/lib/Safe.sol';
import 'src/errors/Exception.sol';

import 'src/interfaces/IERC5095.sol';
import 'src/interfaces/IERC20.sol';
import 'src/interfaces/ITempus.sol';
import 'src/interfaces/ITempusPool.sol';
import 'src/interfaces/ITempusToken.sol';
import 'src/interfaces/IAPWine.sol';
import 'src/interfaces/IAPWineController.sol';
import 'src/interfaces/IAPWineFutureVault.sol';
import 'src/interfaces/IAPWineToken.sol';
import 'src/interfaces/IAPWineAMMPool.sol';
import 'src/interfaces/ISwivel.sol';
import 'src/interfaces/ISwivelToken.sol';
import 'src/interfaces/IElementToken.sol';
import 'src/interfaces/IYieldToken.sol';
import 'src/interfaces/INotional.sol';
import 'src/interfaces/IPendle.sol';
import 'src/interfaces/IPendleForge.sol';
import 'src/interfaces/IPendleToken.sol';
import 'src/interfaces/ISenseDivider.sol';
import 'src/interfaces/ISenseAdapter.sol';
import 'src/interfaces/IYield.sol';
import 'src/interfaces/IConverter.sol';

import 'forge-std/Test.sol';

/// @title Redeemer
/// @author Sourabh Marathe, Julian Traversa, Rob Robbins
/// @notice The Redeemer contract is used to redeem the underlying lent capital of a loan.
/// @notice Users may redeem their ERC-5095 tokens for the underlying asset represented by that token after maturity.
contract Redeemer {
    /// @notice address that is allowed to set fees and contracts, etc. It is commonly used in the authorized modifier.
    address public admin;
    /// @notice address of the MarketPlace contract, used to access the markets mapping
    address public marketPlace;
    /// @notice address that custodies principal tokens for all markets
    address public lender;
    /// @notice address that converts compounding tokens to their underlying
    address public converter;

    /// @notice third party contract needed to redeem Swivel PTs
    address public immutable swivelAddr;
    /// @notice third party contract needed to redeem Pendle PTs
    address public immutable pendleAddr;
    /// @notice third party contract needed to redeem Tempus PTs
    address public immutable tempusAddr;

    /// @notice this value determines the amount of fees paid on auto redemptions
    uint256 public feenominator;
    /// @notice represents a point in time where the feenominator may change
    uint256 public feeChange;
    /// @notice represents a minimum that the feenominator must exceed
    uint256 public MIN_FEENOMINATOR = 500;

    /// @notice mapping that indicates how much underlying has been redeemed by a market
    mapping(address => mapping(uint256 => uint256)) public holdings;
    /// @notice mapping that determines if a market's iPT can be redeemed
    mapping(address => mapping(uint256 => bool)) public paused;

    /// @notice emitted upon redemption of a loan
    event Redeem(
        uint8 principal,
        address indexed underlying,
        uint256 indexed maturity,
        uint256 amount,
        address sender
    );
    /// @notice emitted upon changing the admin
    event SetAdmin(address indexed admin);
    /// @notice emitted upon changing the converter
    event SetConverter(address indexed converter);
    /// @notice emitted upon setting the fee rate
    event SetFee(uint256 indexed fee);

    /// @notice ensures that only a certain address can call the function
    /// @param a address that msg.sender must be to be authorized
    modifier authorized(address a) {
        if (msg.sender != a) {
            revert Exception(0, 0, 0, msg.sender, a);
        }
        _;
    }

    /// @notice reverts on all markets where the paused mapping returns true
    /// @param u address of an underlying asset
    /// @param m maturity (timestamp) of the market
    modifier unpaused(address u, uint256 m) {
        if (paused[u][m]) {
            revert Exception(17, m, 0, u, address(0));
        }
        _;
    }

    /// @notice Initializes the Redeemer contract
    /// @param l the lender contract
    /// @param s the Swivel contract
    /// @param p the Pendle contract
    /// @param t the Tempus contract
    constructor(
        address l,
        address s,
        address p,
        address t
    ) {
        admin = msg.sender;
        lender = l;
        swivelAddr = s;
        pendleAddr = p;
        tempusAddr = t;
        feenominator = 4000;
    }

    /// @notice sets the admin address
    /// @param a Address of a new admin
    /// @return bool true if successful
    function setAdmin(address a) external authorized(admin) returns (bool) {
        admin = a;
        emit SetAdmin(a);
        return true;
    }

    /// @notice sets the address of the marketplace contract which contains the addresses of all the fixed rate markets
    /// @param m the address of the marketplace contract
    /// @return bool true if the address was set
    function setMarketPlace(address m)
        external
        authorized(admin)
        returns (bool)
    {
        if (marketPlace != address(0)) {
            revert Exception(5, 0, 0, marketPlace, address(0));
        }
        marketPlace = m;
        return true;
    }

    /// @notice sets the converter address
    /// @param c address of the new converter
    /// @return bool true if successful
    function setConverter(address c) external authorized(admin) returns (bool) {
        converter = c;
        emit SetConverter(c);
        return true;
    }

    /// @notice sets the address of the lender contract which contains the addresses of all the fixed rate markets
    /// @param l the address of the lender contract
    /// @return bool true if the address was set
    function setLender(address l) external authorized(admin) returns (bool) {
        if (lender != address(0)) {
            revert Exception(8, 0, 0, address(lender), address(0));
        }
        lender = l;
        return true;
    }

    /// @notice sets the feenominator to the given value
    /// @param f the new value of the feenominator, fees are not collected when the feenominator is 0
    /// @return bool true if successful
    function setFee(uint256 f) external authorized(admin) returns (bool) {
        uint256 feeTime = feeChange;
        if (feeTime == 0) {
            revert Exception(23, 0, 0, address(0), address(0));
        } else if (feeTime < block.timestamp) {
            revert Exception(
                24,
                block.timestamp,
                feeTime,
                address(0),
                address(0)
            );
        } else if (f < MIN_FEENOMINATOR) {
            revert Exception(25, 0, 0, address(0), address(0));
        }
        feenominator = f;
        delete feeChange;
        emit SetFee(f);
        return true;
    }

    /// @notice allows admin to stop redemptions of Illuminate PTs for a given market
    /// @param u address of an underlying asset
    /// @param m maturity (timestamp) of the market
    /// @param b true to pause, false to unpause
    function pauseRedemptions(
        address u,
        uint256 m,
        bool b
    ) external authorized(admin) {
        paused[u][m] = b;
    }

    /// @notice approves the converter to spend the compounding asset
    /// @param i an interest bearing token that must be approved for conversion
    function approve(address i) external authorized(marketPlace) {
        if (i != address(0)) {
            Safe.approve(IERC20(i), address(converter), type(uint256).max);
        }
    }

    /// @notice redeem method for Swivel, Yield, Element, Pendle, APWine, Tempus and Notional protocols
    /// @param p principal value according to the MarketPlace's Principals Enum
    /// @param u address of an underlying asset
    /// @param m maturity (timestamp) of the market
    /// @return bool true if the redemption was successful
    function redeem(
        uint8 p,
        address u,
        uint256 m
    ) external returns (bool) {
        // Get the principal token that is being redeemed by the user
        address principal = IMarketPlace(marketPlace).token(u, m, p);

        // Get the maturity for the given principal token
        uint256 maturity;
        if (p == uint8(MarketPlace.Principals.Swivel)) {
            maturity = ISwivelToken(principal).maturity();
        } else if (p == uint8(MarketPlace.Principals.Yield)) {
            maturity = IYieldToken(principal).maturity();
        } else if (p == uint8(MarketPlace.Principals.Element)) {
            maturity = IElementToken(principal).unlockTimestamp();
        } else if (p == uint8(MarketPlace.Principals.Pendle)) {
            maturity = IPendleToken(principal).expiry();
        } else if (p == uint8(MarketPlace.Principals.Tempus)) {
            maturity = ITempusPool(ITempusToken(principal).pool())
                .maturityTime();
        } else if (p == uint8(MarketPlace.Principals.Apwine)) {
            // APWine's maturity is retrieved indirectly via the PT's
            // futureVault and Controller
            address futureVault = IAPWineToken(principal).futureVault();

            address controller = IAPWineFutureVault(futureVault)
                .getControllerAddress();

            uint256 duration = IAPWineFutureVault(futureVault)
                .PERIOD_DURATION();

            maturity = IAPWineController(controller).getNextPeriodStart(
                duration
            );
        } else if (p == uint8(MarketPlace.Principals.Notional)) {
            maturity = INotional(principal).getMaturity();
        } else {
            revert Exception(6, p, 0, address(0), address(0));
        }

        // Verify that the token has matured
        if (maturity > block.timestamp) {
            revert Exception(7, maturity, 0, address(0), address(0));
        }

        // Cache the lender to save gas on sload
        address cachedLender = lender;

        // Get the amount to be redeemed
        uint256 amount = IERC20(principal).balanceOf(cachedLender);

        // Receive the principal token from the lender contract
        Safe.transferFrom(
            IERC20(principal),
            cachedLender,
            address(this),
            amount
        );

        // Get the starting balance of the underlying held by the redeemer
        uint256 starting = IERC20(u).balanceOf(address(this));

        if (p == uint8(MarketPlace.Principals.Swivel)) {
            // Redeems principal tokens from Swivel
            if (!ISwivel(swivelAddr).redeemZcToken(u, maturity, amount)) {
                revert Exception(15, 0, 0, address(0), address(0));
            }
        } else if (p == uint8(MarketPlace.Principals.Yield)) {
            // Redeems principal tokens from Yield
            IYieldToken(principal).redeem(address(this), amount);
        } else if (p == uint8(MarketPlace.Principals.Element)) {
            // Redeems principal tokens from Element
            IElementToken(principal).withdrawPrincipal(amount, address(this));
        } else if (p == uint8(MarketPlace.Principals.Pendle)) {
            // Get the forge contract for the principal token
            address forge = IPendleToken(principal).forge();

            // Get the forge ID of the principal token
            bytes32 forgeId = IPendleForge(forge).forgeId();

            // Redeem the tokens from the Pendle contract
            IPendle(pendleAddr).redeemAfterExpiry(forgeId, u, maturity);

            // Get the compounding asset for this market
            address compounding = IPendleToken(principal)
                .underlyingYieldToken();

            // Redeem the compounding to token to the underlying
            IConverter(converter).convert(
                compounding,
                u,
                IERC20(compounding).balanceOf(address(this))
            );
        } else if (p == uint8(MarketPlace.Principals.Tempus)) {
            // Retrieve the pool for the principal token
            address pool = ITempusToken(principal).pool();

            // Redeems principal tokens from Tempus
            ITempus(tempusAddr).redeemToBacking(pool, amount, 0, address(this));
        } else if (p == uint8(MarketPlace.Principals.Apwine)) {
            apwineWithdraw(principal, u, amount);
        } else if (p == uint8(MarketPlace.Principals.Notional)) {
            // Redeems principal tokens from Notional
            INotional(principal).redeem(
                INotional(principal).maxRedeem(address(this)),
                address(this),
                address(this)
            );
        }

        // Calculate how much underlying was redeemed
        uint256 redeemed = IERC20(u).balanceOf(address(this)) - starting;

        // Update the holding for this market
        holdings[u][m] = holdings[u][m] + redeemed;

        emit Redeem(p, u, m, redeemed, msg.sender);
        return true;
    }

    /// @notice redeem method signature for Sense
    /// @param p principal value according to the MarketPlace's Principals Enum
    /// @param u address of an underlying asset
    /// @param m maturity (timestamp) of the market
    /// @param s Sense's maturity is needed to extract the pt address
    /// @param a Sense's adapter for this market
    /// @return bool true if the redemption was successful
    function redeem(
        uint8 p,
        address u,
        uint256 m,
        uint256 s,
        address a
    ) external returns (bool) {
        // Check the principal is Sense
        if (p != uint8(MarketPlace.Principals.Sense)) {
            revert Exception(6, p, 0, address(0), address(0));
        }

        // Get Sense's principal token for this market
        IERC20 token = IERC20(IMarketPlace(marketPlace).token(u, m, p));

        // Cache the lender to save on SLOAD operations
        address cachedLender = lender;

        // Get the balance of tokens to be redeemed by the user
        uint256 amount = token.balanceOf(cachedLender);

        // Transfer the user's tokens to the redeem contract
        Safe.transferFrom(token, cachedLender, address(this), amount);

        // Get the starting balance to verify the amount received afterwards
        uint256 starting = IERC20(u).balanceOf(address(this));

        // Get the divider from the adapter
        ISenseDivider divider = ISenseDivider(ISenseAdapter(a).divider());

        // Redeem the tokens from the Sense contract
        ISenseDivider(divider).redeem(a, s, amount);

        // Get the compounding token that is redeemed by Sense
        address compounding = ISenseAdapter(a).target();

        // Redeem the compounding token back to the underlying
        IConverter(converter).convert(
            compounding,
            u,
            IERC20(compounding).balanceOf(address(this))
        );

        // Get the amount received
        uint256 redeemed = IERC20(u).balanceOf(address(this)) - starting;

        // Verify that underlying are received 1:1 - cannot trust the adapter
        if (redeemed < amount) {
            revert Exception(13, 0, 0, address(0), address(0));
        }

        // Update the holdings for this market
        holdings[u][m] = holdings[u][m] + redeemed;

        emit Redeem(p, u, m, redeemed, msg.sender);
        return true;
    }

    /// @notice burns Illuminate principal tokens and sends underlying to user
    /// @param u address of an underlying asset
    /// @param m maturity (timestamp) of the market
    function redeem(address u, uint256 m) external unpaused(u, m) {
        // Get Illuminate's principal token for this market
        IERC5095 token = IERC5095(
            IMarketPlace(marketPlace).token(
                u,
                m,
                uint8(MarketPlace.Principals.Illuminate)
            )
        );

        // Verify the token has matured
        if (block.timestamp < token.maturity()) {
            revert Exception(7, block.timestamp, m, address(0), address(0));
        }

        // Get the amount of tokens to be redeemed from the sender
        uint256 amount = token.balanceOf(msg.sender);

        // Calculate how many tokens the user should receive
        uint256 redeemed = (amount * holdings[u][m]) / token.totalSupply();

        // Update holdings of underlying
        holdings[u][m] = holdings[u][m] - redeemed;

        // Burn the user's principal tokens
        token.authBurn(msg.sender, amount);

        // Transfer the original underlying token back to the user
        Safe.transfer(IERC20(u), msg.sender, redeemed);

        emit Redeem(0, u, m, redeemed, msg.sender);
    }

    /// @notice implements the redeem method for the contract to fulfill the ERC-5095 interface
    /// @param u address of an underlying asset
    /// @param m maturity (timestamp) of the market
    /// @param f address from where the underlying asset will be burned
    /// @param t address to where the underlying asset will be transferred
    /// @param a amount of the Illuminate PT to be burned and redeemed
    /// @return uint256 amount of the underlying asset that was burned
    function authRedeem(
        address u,
        uint256 m,
        address f,
        address t,
        uint256 a
    )
        external
        authorized(IMarketPlace(marketPlace).token(u, m, 0))
        returns (uint256)
    {
        // Get the principal token for the given market
        IERC5095 pt = IERC5095(IMarketPlace(marketPlace).token(u, m, 0));

        // Make sure the market has matured
        uint256 maturity = pt.maturity();
        if (block.timestamp < maturity) {
            revert Exception(7, maturity, 0, address(0), address(0));
        }

        // Calculate the amount redeemed
        uint256 redeemed = (a * holdings[u][m]) / pt.totalSupply();

        // Update holdings of underlying
        holdings[u][m] = holdings[u][m] - redeemed;

        // Burn the user's principal tokens
        pt.authBurn(f, a);

        // Transfer the original underlying token back to the user
        Safe.transfer(IERC20(u), t, redeemed);

        emit Redeem(0, u, m, redeemed, msg.sender);
        return a;
    }

    /// @notice implements a redeem method to enable third-party redemptions
    /// @dev expects approvals from owners to redeemer
    /// @param u address of the underlying asset
    /// @param m maturity of the market
    /// @param f address from where the principal token will be burned
    /// @return uint256 amount of underlying yielded as a fee
    function autoRedeem(
        address u,
        uint256 m,
        address[] calldata f
    ) external returns (uint256) {
        // Get the principal token for the given market
        IERC5095 pt = IERC5095(IMarketPlace(marketPlace).token(u, m, 0));

        // Make sure the market has matured
        uint256 maturity = pt.maturity();
        if (block.timestamp < maturity) {
            revert Exception(7, maturity, 0, address(0), address(0));
        }

        // Retrieve the underlying
        IERC20 uToken = IERC20(u);

        // Sum up the fees received by the caller
        uint256 incentiveFee;

        // Get the number of owners to loop through
        uint256 length = f.length;

        // Loop through the provided arrays and mature each individual position
        for (uint256 i; i != length; ) {
            // Fetch the allowance set by the holder of the principal tokens
            uint256 allowance = uToken.allowance(f[i], address(this));

            // Get the amount of tokens held by the owner
            uint256 amount = pt.balanceOf(f[i]);

            // Calculate how many tokens the user should receive
            uint256 redeemed = (amount * holdings[u][m]) / pt.totalSupply();

            // Calculate the fees to be received (currently .025%)
            uint256 fee = redeemed / feenominator;

            // Verify allowance
            if (allowance < amount) {
                revert Exception(20, allowance, amount, address(0), address(0));
            }

            // Burn the tokens from the user
            pt.authBurn(f[i], amount);

            // Update the holdings for this market
            holdings[u][m] = holdings[u][m] - redeemed;

            // Transfer the underlying to the user
            Safe.transfer(uToken, f[i], redeemed - fee);

            unchecked {
                // Track the fees gained by the caller
                incentiveFee += fee;

                ++i;
            }
        }

        // Transfer the fee to the caller
        Safe.transfer(uToken, msg.sender, incentiveFee);

        return incentiveFee;
    }

    /// @notice Execute the business logic for conducting an APWine redemption
    function apwineWithdraw(
        address p,
        address u,
        uint256 a
    ) internal {
        // Retrieve the vault which executes the redemption in APWine
        address futureVault = IAPWineToken(p).futureVault();

        // Retrieve the controller that will execute the withdrawal
        address controller = IAPWineFutureVault(futureVault)
            .getControllerAddress();

        // Retrieve the next period index
        uint256 index = IAPWineFutureVault(futureVault).getCurrentPeriodIndex();

        // Get the FYT address for the current period
        address fyt = IAPWineFutureVault(futureVault).getFYTofPeriod(index);

        // Trigger claim to FYTs by executing transfer
        // Safe.transferFrom(IERC20(fyt), address(lender), address(this), a);
        ILender(lender).transferFYTs(fyt, a);

        // Redeem the underlying token from APWine to Illuminate
        IAPWineController(controller).withdraw(futureVault, a);

        // Retrieve the interest bearing token
        address ibt = IAPWineFutureVault(futureVault).getIBTAddress();

        // Convert the interest bearing token to underlying
        IConverter(converter).convert(
            IAPWineFutureVault(futureVault).getIBTAddress(),
            u,
            IERC20(ibt).balanceOf(address(this))
        );
    }
}
