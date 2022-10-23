// SPDX-License-Identifier: UNLICENSED

pragma solidity 0.8.16;

import 'forge-std/Test.sol';

import 'src/MarketPlace.sol';

import 'src/mocks/Redeemer.sol' as mock_r;
import 'src/mocks/Lender.sol' as mock_l;
import 'src/mocks/ERC20.sol' as mock_erc20;
import 'src/mocks/Pool.sol' as mock_pool;
import 'src/mocks/PendleToken.sol' as mock_pt;
import 'src/mocks/APWineToken.sol' as mock_apwt;
import 'src/mocks/APWineFutureVault.sol' as mock_apfv;

contract MarketplaceTest is Test {
    MarketPlace mp;

    // Mocks
    mock_r.Redeemer r;
    mock_l.Lender l;

    // Helpers
    uint128 amount = 10000;
    uint128 slippage = 11111;
    address underlying = address(new mock_erc20.ERC20());
    uint256 maturity = block.timestamp + 10000;
    uint8 decimals = 6;
    uint128 preview = 12345;

    mock_erc20.ERC20 token0;
    mock_erc20.ERC20 token1;
    mock_erc20.ERC20 token2;
    mock_pt.PendleToken token3;
    mock_erc20.ERC20 token4;
    mock_erc20.ERC20 token5;
    mock_apwt.APWineToken token6;
    mock_erc20.ERC20 token7;
    mock_erc20.ERC20 token8;
    mock_erc20.ERC20 token9;

    mock_erc20.ERC20 elementVault;
    mock_erc20.ERC20 apwineRouter;

    mock_pool.Pool pool;

    mock_apfv.APWineFutureVault apwfv;

    function setUp() public {
        // deploy mocked redeemer
        r = new mock_r.Redeemer();
        // depoy mocked lender
        l = new mock_l.Lender();

        // deploy the real marketplace
        mp = new MarketPlace(address(r), address(l));

        // deploy a bunch of erc20 principal tokens
        token0 = new mock_erc20.ERC20();
        token1 = new mock_erc20.ERC20();
        token2 = new mock_erc20.ERC20();
        token3 = new mock_pt.PendleToken();
        token4 = new mock_erc20.ERC20();
        token5 = new mock_erc20.ERC20();
        token6 = new mock_apwt.APWineToken();
        token7 = new mock_apwt.ERC20();
        token8 = new mock_erc20.ERC20();
        token9 = new mock_erc20.ERC20();

        elementVault = new mock_erc20.ERC20();
        apwineRouter = new mock_erc20.ERC20();

        apwfv = new mock_apfv.APWineFutureVault();

        pool = new mock_pool.Pool();
    }

    function testCreateMarket() public {
        address[8] memory contracts;
        contracts[0] = address(token0); // Swivel
        contracts[1] = address(token1); // Yield
        contracts[2] = address(token2); // Element
        contracts[3] = address(token3); // Pendle
        contracts[4] = address(token4); // Tempus
        contracts[5] = address(token5); // Sense
        contracts[6] = address(token6); // APWine
        contracts[7] = address(token7); // Notional

        mock_erc20.ERC20(underlying).decimalsReturns(10);
        mock_erc20.ERC20 compounding = new mock_erc20.ERC20();
        token6.futureVaultReturns(address(apwfv));
        apwfv.getIBTAddressReturns(address(compounding));

        token3.underlyingYieldTokenReturns(address(compounding));

        mp.createMarket(
            address(underlying),
            maturity,
            contracts,
            'test-token',
            'tt',
            address(elementVault),
            address(apwineRouter)
        );

        // verify approvals
        assertEq(r.approveCalled(), address(compounding));

        (
            address approvedElement,
            address approvedApwine,
            address approvedNotional
        ) = l.approveCalled(address(underlying));
        assertEq(approvedElement, address(elementVault));
        assertEq(approvedApwine, address(apwineRouter));
        assertEq(approvedNotional, contracts[7]);
    }

    function testSetPrincipal() public {
        address[8] memory contracts;

        mock_erc20.ERC20 compounding = new mock_erc20.ERC20();
        token6.futureVaultReturns(address(apwfv));
        apwfv.getIBTAddressReturns(address(compounding));
        token3.underlyingYieldTokenReturns(address(compounding));

        mp.createMarket(
            underlying,
            maturity,
            contracts,
            'test-token',
            'tt',
            address(elementVault),
            address(apwineRouter)
        );

        // verify approvals
        assertEq(r.approveCalled(), contracts[3]);

        (
            address approvedElement,
            address approvedApwine,
            address approvedNotional
        ) = l.approveCalled(underlying);
        assertEq(approvedElement, address(elementVault));
        assertEq(approvedApwine, address(apwineRouter));
        assertEq(approvedNotional, contracts[7]);

        mp.setPrincipal(4, underlying, maturity, address(token3));
        assertEq(mp.token(underlying, maturity, 4), address(token3));

        mp.setPrincipal(7, underlying, maturity, address(token6));
        assertEq(mp.token(underlying, maturity, 7), address(token6));
    }

    function testSetPool() public {
        mp.setPool(underlying, maturity, address(token3));
        assertEq(mp.pools(underlying, maturity), address(token3));
    }

    function testSellPrincipalToken() public {
        pool.sellFYTokenPreviewReturns(preview);
        pool.sellFYTokenReturns(preview);

        mp.setPool(underlying, maturity, address(pool));
        mp.sellPrincipalToken(underlying, maturity, amount, slippage);

        uint256 amountSold = pool.sellFYTokenCalled(address(this));
        assertEq(amountSold, preview);
    }

    function testBuyPrincipalToken() public {
        pool.buyFYTokenReturns(preview);
        pool.buyFYTokenPreviewReturns(preview);

        mp.setPool(underlying, maturity, address(pool));
        mp.buyPrincipalToken(underlying, maturity, amount, type(uint128).max);

        (uint256 previewed, ) = pool.buyFYTokenCalled(address(this));
        assertEq(previewed, amount);
    }

    function testSellUnderlying() public {
        pool.sellBaseReturns(preview);
        pool.sellBasePreviewReturns(preview);

        mp.setPool(underlying, maturity, address(pool));
        mp.sellUnderlying(underlying, maturity, amount, slippage);

        uint256 previewed = pool.sellBaseCalled(address(this));
        assertEq(previewed, preview);
    }

    function testBuyUnderlying() public {
        pool.buyBaseReturns(preview);
        pool.sellFYTokenPreviewReturns(preview);

        mp.setPool(underlying, maturity, address(pool));
        mp.buyUnderlying(underlying, maturity, amount, type(uint128).max);

        (uint256 previewed, ) = pool.buyBaseCalled(address(this));
        assertEq(previewed, amount);
    }

    function testMint() public {
        mp.setPool(underlying, maturity, address(pool));
        pool.baseReturns(address(token1));
        pool.fyTokenReturns(address(token2));
        token1.transferFromReturns(true);
        token2.transferFromReturns(true);
        pool.mintReturns(1, 2, 3);

        uint256 uA = 100;
        uint256 ptA = 140;
        uint256 minRatio = 1;
        uint256 maxRatio = 2;
        mp.mint(underlying, maturity, uA, ptA, minRatio, maxRatio);

        (address recipient, uint256 transferAmount) = token1.transferFromCalled(
            address(this)
        );
        assertEq(recipient, address(pool));
        assertEq(transferAmount, uA);

        (recipient, transferAmount) = token2.transferFromCalled(address(this));
        assertEq(recipient, address(pool));
        assertEq(transferAmount, ptA);

        (address remainder, uint256 min, uint256 max) = pool.mintCalled(
            address(this)
        );
        assertEq(remainder, address(this));
        assertEq(min, minRatio);
        assertEq(max, maxRatio);
    }

    function testMintWithUnderlying() public {
        mp.setPool(underlying, maturity, address(pool));
        pool.baseReturns(address(token1));
        token1.transferFromReturns(true);
        pool.mintWithBaseReturns(7, 8, 9);

        uint128 ptBought = 1000;
        uint256 minRatio = 10;
        uint256 maxRatio = 20;
        mp.mintWithUnderlying(
            underlying,
            maturity,
            amount,
            ptBought,
            minRatio,
            maxRatio
        );

        (address recipient, uint256 transferAmount) = token1.transferFromCalled(
            address(this)
        );
        assertEq(recipient, address(pool));
        assertEq(transferAmount, amount);

        pool.mintWithBaseCalled(address(this));
        (
            address remainder,
            uint256 fyTokenToBuy,
            uint256 min,
            uint256 max
        ) = pool.mintWithBaseCalled(address(this));

        assertEq(remainder, address(this));
        assertEq(fyTokenToBuy, ptBought);
        assertEq(min, minRatio);
        assertEq(max, maxRatio);
    }

    function testBurn() public {
        mp.setPool(underlying, maturity, address(pool));
        pool.burnReturns(1, 1, 1);

        uint256 minRatio = 124;
        uint256 maxRatio = 893;
        mp.burn(underlying, maturity, amount, minRatio, maxRatio);

        (address remainder, uint256 min, uint256 max) = pool.burnCalled(
            address(this)
        );
        assertEq(remainder, address(this));
        assertEq(min, minRatio);
        assertEq(max, maxRatio);
    }

    function testBurnForUnderlying() public {
        mp.setPool(underlying, maturity, address(pool));
        pool.burnForBaseReturns(1, 1);

        uint256 minRatio = 124;
        uint256 maxRatio = 893;
        mp.burnForUnderlying(underlying, maturity, amount, minRatio, maxRatio);

        (uint256 min, uint256 max) = pool.burnForBaseCalled(address(this));
        assertEq(min, minRatio);
        assertEq(max, maxRatio);
    }

    function testFailSlippageExceeded() public {
        mp.setPool(underlying, maturity, address(pool));
        uint128 failingPreview = slippage - 1;

        pool.sellFYTokenPreviewReturns(failingPreview);
        vm.expectRevert(Exception.selector);
        mp.sellPrincipalToken(underlying, maturity, amount, slippage);

        pool.sellFYTokenPreviewReturns(failingPreview);
        vm.expectRevert(Exception.selector);
        mp.sellPrincipalToken(underlying, maturity, amount, slippage);

        pool.buyBasePreviewReturns(failingPreview);
        vm.expectRevert(Exception.selector);
        mp.buyPrincipalToken(underlying, maturity, amount, slippage);

        pool.sellBasePreviewReturns(failingPreview);
        vm.expectRevert(Exception.selector);
        mp.sellPrincipalToken(underlying, maturity, amount, slippage);
    }

    function testFailSetExistingPrincipal() public {
        mp.setPrincipal(1, address(0), 0, msg.sender);
        vm.expectRevert(Exception.selector);
        mp.setPrincipal(1, address(0), 0, msg.sender);
    }

    function testFailSetExistingPool() public {
        mp.setPool(address(0), 0, msg.sender);
        vm.expectRevert(Exception.selector);
        mp.setPool(address(0), 0, msg.sender);
    }
}
