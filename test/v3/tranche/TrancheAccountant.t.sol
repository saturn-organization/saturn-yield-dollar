// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import {TrancheAccountant} from "../../../src/v3/TrancheAccountant.sol";
import {IStakedUSDat} from "../../../src/v2/interfaces/IStakedUSDat.sol";
import {IEligibleIncomeAccounting} from "../../../src/v3/interfaces/IEligibleIncomeAccounting.sol";
import {TrancheAccountantFixture} from "./helpers/TrancheAccountantFixture.sol";
import {TrancheShare} from "../../../src/v3/TrancheShare.sol";

contract TrancheAccountantTest is TrancheAccountantFixture {
    // ============ Bootstrap and Capacity ============

    function test_independentBootstrapReachesPreferredCoverageWithoutPairedMint() public {
        (uint256 juniorAssets, uint256 seniorAssets) = _bootstrap();

        assertEq(accountant.backingAssets(), juniorAssets + seniorAssets);
        assertEq(accountant.coverageWad(), 1.5e18);
        assertGt(senior.totalSupply(), 0);
        assertGt(junior.totalSupply(), 0);
        assertEq(accountant.seniorDepositCapacityValue(), 0);
        assertEq(accountant.juniorRedemptionCapacityValue(), 0);
    }

    function test_immutableBackingCapClosesInflowsButNotHealthyExits() public {
        uint256 classAssets = vault.balanceOf(address(this)) / 20;
        uint256 cap = vault.convertToAssets(classAssets) * 2;
        TrancheAccountant capped =
            new TrancheAccountant(vault, incomeModule, 5_000, 1.5e18, cap, address(this), address(this));
        vault.approve(address(capped), type(uint256).max);

        capped.depositJunior(classAssets, address(this), 0, block.timestamp);
        capped.depositSenior(classAssets, address(this), 0, block.timestamp);
        assertGe(capped.coverageWad(), 2e18 - 1);
        assertEq(capped.maxDepositSenior(address(this)), 0);
        assertEq(capped.maxDepositJunior(address(this)), 0);

        vm.expectRevert(TrancheAccountant.CapacityExceeded.selector);
        capped.depositSenior(classAssets / 10, address(this), 0, block.timestamp);
        vm.expectRevert(TrancheAccountant.CapacityExceeded.selector);
        capped.depositJunior(classAssets / 10, address(this), 0, block.timestamp);
        vm.expectRevert(TrancheAccountant.CapacityExceeded.selector);
        capped.mintSenior(1, address(this), type(uint256).max, block.timestamp);
        vm.expectRevert(TrancheAccountant.CapacityExceeded.selector);
        capped.mintJunior(1, address(this), type(uint256).max, block.timestamp);

        uint256 seniorShares = capped.SENIOR_TOKEN().balanceOf(address(this)) / 10;
        capped.redeemSenior(seniorShares, address(this), address(this), 0, block.timestamp);
        assertGt(capped.maxDepositJunior(address(this)), 0);
    }

    // ============ Income Accounting ============

    function test_incomeCapitalizesAtAlphaWithoutHistoricalCapture() public {
        adapter.setIndex(1.1e18);
        priceOracle.setPrice(110e8);
        incomeModule.materializeSTRConEligibleIncome();

        TrancheAccountant later =
            new TrancheAccountant(vault, incomeModule, 5_000, 1.5e18, MAX_BACKING_VALUE, address(this), address(this));
        vault.approve(address(later), type(uint256).max);
        uint256 juniorAssets = vault.balanceOf(address(this)) / 20;
        later.depositJunior(juniorAssets, alice, 0, block.timestamp);
        assertEq(later.seniorClaimValue(), 0);

        uint256 seniorAssets = juniorAssets * 2;
        later.depositSenior(seniorAssets, alice, 0, block.timestamp);
        uint256 claimAfterEntry = later.seniorClaimValue();
        later.syncIncome();
        assertEq(later.seniorClaimValue(), claimAfterEntry);

        adapter.setIndex(1.2e18);
        priceOracle.setPrice(120e8);
        later.syncIncome();
        assertGt(later.seniorLiveUnitsWad(), 0);
        assertGt(later.seniorClaimValue(), claimAfterEntry);
    }

    function test_unsolicitedBackingCannotCaptureHistoricalIncome() public {
        _bootstrap();
        uint256 cohortBacking = accountant.incomeBearingBackingAssets();
        adapter.setIndex(1.1e18);
        priceOracle.setPrice(110e8);
        uint256 relativeUnitsPerShare = incomeModule.previewSTRConEligibleUnitsPerShareWad();

        uint256 donation = vault.balanceOf(address(this)) / 20;
        assertTrue(vault.transfer(address(accountant), donation));
        assertEq(accountant.incomeBearingBackingAssets(), cohortBacking);
        assertEq(accountant.backingAssets(), cohortBacking + donation);

        accountant.syncIncome();

        uint256 expectedLive = Math.mulDiv(Math.mulDiv(cohortBacking, relativeUnitsPerShare, WAD), 5_000, 10_000);
        assertEq(accountant.seniorLiveUnitsWad(), expectedLive);
        assertEq(accountant.incomeBearingBackingAssets(), cohortBacking + donation);

        uint256 oldLive = accountant.seniorLiveUnitsWad();
        uint256 oldCumulative = incomeModule.eligibleIncomeState().eligibleUnitsPerSUSDatShareWad;
        adapter.setIndex(1.2e18);
        priceOracle.setPrice(120e8);
        uint256 newCumulative = incomeModule.previewSTRConEligibleUnitsPerShareWad();
        uint256 nextRelative = newCumulative - oldCumulative;
        accountant.syncIncome();

        uint256 expectedNext = Math.mulDiv(Math.mulDiv(cohortBacking + donation, nextRelative, WAD), 5_000, 10_000);
        assertEq(accountant.seniorLiveUnitsWad() - oldLive, expectedNext);
    }

    // ============ Class Accounting and Exits ============

    function test_fullStackExitScalesUncheckpointedDonationAndIncomeCohortSeparately() public {
        _bootstrap();
        uint256 trackedBefore = accountant.incomeBearingBackingAssets();
        uint256 donation = vault.balanceOf(address(this)) / 20;
        assertTrue(vault.transfer(address(accountant), donation));
        uint256 custodyBefore = accountant.backingAssets();

        (uint256 assets,,) = accountant.exitFullStack(
            0.25e18, address(this), address(this), type(uint256).max, type(uint256).max, 0, block.timestamp
        );

        assertEq(assets, Math.mulDiv(custodyBefore, 0.25e18, WAD));
        assertEq(accountant.incomeBearingBackingAssets(), Math.mulDiv(trackedBefore, 0.75e18, WAD));
        assertLe(accountant.incomeBearingBackingAssets(), accountant.backingAssets());
    }

    function test_sameClassEntryAndExitPreserveNavWithinRounding() public {
        _bootstrap();
        uint256 seniorNavBefore = Math.mulDiv(accountant.markedSeniorValue(), WAD, senior.totalSupply());

        uint256 extraJuniorAssets = vault.balanceOf(address(this)) / 20;
        accountant.depositJunior(extraJuniorAssets, alice, 0, block.timestamp);
        uint256 seniorAssets = accountant.maxDepositSenior(address(this)) / 2;
        uint256 minted = accountant.depositSenior(seniorAssets, address(this), 0, block.timestamp);
        uint256 seniorNavAfterDeposit = Math.mulDiv(accountant.markedSeniorValue(), WAD, senior.totalSupply());
        assertApproxEqAbs(seniorNavAfterDeposit, seniorNavBefore, 2);

        uint256 assetsOut = accountant.redeemSenior(minted, address(this), address(this), 0, block.timestamp);
        assertGt(assetsOut, 0);
        uint256 seniorNavAfterRedeem = Math.mulDiv(accountant.markedSeniorValue(), WAD, senior.totalSupply());
        assertApproxEqAbs(seniorNavAfterRedeem, seniorNavBefore, 2);
    }

    function test_juniorRedemptionCannotCrossPreferredCoverage() public {
        _bootstrap();
        uint256 extraJuniorAssets = vault.balanceOf(address(this)) / 20;
        accountant.depositJunior(extraJuniorAssets, address(this), 0, block.timestamp);
        uint256 capacity = accountant.juniorRedemptionCapacityValue();
        assertGt(capacity, 0);

        uint256 tooManyAssets = vault.convertToShares(capacity + 1) + 1;
        vm.expectRevert(TrancheAccountant.CapacityExceeded.selector);
        accountant.withdrawJunior(tooManyAssets, address(this), address(this), type(uint256).max, block.timestamp);

        uint256 allowedAssets = vault.convertToShares(capacity);
        accountant.withdrawJunior(allowedAssets, address(this), address(this), type(uint256).max, block.timestamp);
        assertGe(accountant.coverageWad(), 1.5e18);
    }

    function test_partialSTRConSaleCrystallizesSeniorUnits() public {
        _bootstrap();
        adapter.setIndex(1.1e18);
        priceOracle.setPrice(110e8);
        accountant.syncIncome();
        uint256 liveBefore = accountant.seniorLiveUnitsWad();
        assertGt(liveBefore, 0);

        uint256 delivered = POSITION / 4;
        vault.sell(delivered, 300_000e6, vehicle, block.timestamp);
        accountant.syncIncome();

        assertLt(accountant.seniorLiveUnitsWad(), liveBefore);
        assertGt(accountant.crystallizedSeniorValue(), 0);
        assertEq(accountant.checkpointCrystallizationNonce(), 1);
    }

    function test_recognizedFundedUSDatCapitalizesIntoSeniorClaim() public {
        _bootstrap();
        uint256 claimBefore = accountant.seniorClaimValue();
        uint256 funded = 100e6;
        usdat.mint(address(this), funded);
        vault.transferInSurplus(funded);
        vm.warp(block.timestamp + vault.surplusVestingPeriod());

        accountant.syncIncome();

        assertGt(accountant.crystallizedSeniorValue(), 0);
        assertGt(accountant.seniorClaimValue(), claimBefore);
        IEligibleIncomeAccounting.EligibleIncomeState memory state = incomeModule.eligibleIncomeState();
        assertEq(state.recognizedUSDat, funded);
        assertEq(state.pendingFundedUSDat, 0);
    }

    // ============ Failure States ============

    function test_impairmentClosesOneSidedActionsButPreservesProportionalExit() public {
        _bootstrap();
        priceOracle.setPrice(50e8);
        assertEq(uint256(accountant.operatingState()), uint256(TrancheAccountant.OperatingState.Impaired));

        vm.expectRevert(TrancheAccountant.SeniorImpaired.selector);
        accountant.redeemSenior(1e18, address(this), address(this), 0, block.timestamp);
        vm.expectRevert(TrancheAccountant.SeniorImpaired.selector);
        accountant.depositJunior(1e18, address(this), 0, block.timestamp);

        (uint256 assets,,) = accountant.exitFullStack(
            0.1e18, address(this), address(this), type(uint256).max, type(uint256).max, 0, block.timestamp
        );
        assertGt(assets, 0);
    }

    function test_oneSidedActionsFailClosedButFullStackExitSurvivesSourceFailure() public {
        _bootstrap();
        adapter.setUnhealthy(true);

        vm.expectRevert(TrancheAccountant.SourceUnhealthy.selector);
        accountant.depositJunior(1e18, address(this), 0, block.timestamp);

        uint256 balanceBefore = vault.balanceOf(address(this));
        (uint256 assets,,) = accountant.exitFullStack(
            0.1e18, address(this), address(this), type(uint256).max, type(uint256).max, 0, block.timestamp
        );
        assertGt(assets, 0);
        assertEq(vault.balanceOf(address(this)), balanceBefore + assets);
    }

    function test_maxViewsReturnZeroWhenSourceIsUnhealthy() public {
        _bootstrap();
        adapter.setUnhealthy(true);

        assertEq(accountant.maxDepositSenior(address(this)), 0);
        assertEq(accountant.maxMintSenior(address(this)), 0);
        assertEq(accountant.maxRedeemSenior(address(this)), 0);
        assertEq(accountant.maxWithdrawSenior(address(this)), 0);
        assertEq(accountant.maxDepositJunior(address(this)), 0);
        assertEq(accountant.maxMintJunior(address(this)), 0);
        assertEq(accountant.maxRedeemJunior(address(this)), 0);
        assertEq(accountant.maxWithdrawJunior(address(this)), 0);
    }

    function test_restrictedMarketClosesOneSidedActionsButPreservesFullStackExit() public {
        _bootstrap();
        vault.setMarketMode(IStakedUSDat.MarketMode.Restricted);

        assertEq(accountant.maxDepositSenior(address(this)), 0);
        assertEq(accountant.maxRedeemJunior(address(this)), 0);
        vm.expectRevert(TrancheAccountant.SourceUnhealthy.selector);
        accountant.depositJunior(1e18, address(this), 0, block.timestamp);

        uint256 balanceBefore = vault.balanceOf(address(this));
        (uint256 assets,,) = accountant.exitFullStack(
            0.1e18, address(this), address(this), type(uint256).max, type(uint256).max, 0, block.timestamp
        );
        assertEq(vault.balanceOf(address(this)), balanceBefore + assets);
    }

    function test_maxViewsRejectZeroAddressAndJuniorlessSeniorMarket() public {
        assertEq(accountant.maxDepositSenior(address(0)), 0);
        assertEq(accountant.maxDepositJunior(address(0)), 0);

        uint256 juniorAssets = vault.balanceOf(address(this)) / 10;
        accountant.depositJunior(juniorAssets, address(this), 0, block.timestamp);
        accountant.depositSenior(juniorAssets, address(this), 0, block.timestamp);

        uint256 juniorSupply = junior.totalSupply();
        accountant.exitFullStack(
            WAD, address(this), address(this), type(uint256).max, type(uint256).max, 0, block.timestamp
        );
        assertGt(juniorSupply, 0);
        assertEq(senior.totalSupply(), 0);
        assertEq(junior.totalSupply(), 0);
    }

    // ============ Epochs, Paths, and Transfers ============

    function test_newSeniorEpochCannotCaptureIncomeFromZeroSeniorInterval() public {
        _bootstrap();
        accountant.redeemSenior(senior.balanceOf(address(this)), address(this), address(this), 0, block.timestamp);
        assertEq(senior.totalSupply(), 0);
        assertEq(accountant.seniorClaimValue(), 0);

        adapter.setIndex(1.1e18);
        priceOracle.setPrice(110e8);
        accountant.syncIncome();
        assertEq(accountant.seniorClaimValue(), 0);

        uint256 capacity = accountant.maxDepositSenior(address(this));
        uint256 assets = Math.min(capacity, vault.balanceOf(address(this)) / 20);
        accountant.depositSenior(assets, address(this), 0, block.timestamp);
        uint256 entryClaim = accountant.seniorClaimValue();
        accountant.syncIncome();
        assertEq(accountant.seniorClaimValue(), entryClaim);
    }

    function test_mintAndWithdrawPathsPreserveClassNavWithinRounding() public {
        _bootstrap();
        uint256 seniorNavBefore = Math.mulDiv(accountant.seniorClaimValue(), WAD, senior.totalSupply());
        uint256 juniorNavBefore = Math.mulDiv(accountant.juniorResidualValue(), WAD, junior.totalSupply());

        uint256 juniorShares = accountant.previewDepositJunior(vault.balanceOf(address(this)) / 100);
        accountant.mintJunior(juniorShares, alice, type(uint256).max, block.timestamp);
        uint256 seniorShares = accountant.maxMintSenior(address(this)) / 2;
        accountant.mintSenior(seniorShares, alice, type(uint256).max, block.timestamp);

        vm.startPrank(alice);
        senior.approve(address(accountant), type(uint256).max);
        junior.approve(address(accountant), type(uint256).max);
        vm.stopPrank();

        uint256 seniorAssets = accountant.maxWithdrawSenior(alice) / 2;
        accountant.withdrawSenior(seniorAssets, alice, alice, type(uint256).max, block.timestamp);
        uint256 juniorAssets = accountant.maxWithdrawJunior(alice) / 2;
        if (juniorAssets != 0) {
            accountant.withdrawJunior(juniorAssets, alice, alice, type(uint256).max, block.timestamp);
        }

        uint256 seniorNavAfter = Math.mulDiv(accountant.seniorClaimValue(), WAD, senior.totalSupply());
        uint256 juniorNavAfter = Math.mulDiv(accountant.juniorResidualValue(), WAD, junior.totalSupply());
        assertApproxEqAbs(seniorNavAfter, seniorNavBefore, 2);
        assertApproxEqAbs(juniorNavAfter, juniorNavBefore, 2);
    }

    function test_hardPauseBlocksClassTransfersAndFullStackExit() public {
        _bootstrap();
        accountant.pause();

        vm.expectRevert(TrancheShare.TransfersPaused.selector);
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        senior.transfer(alice, 1);
        vm.expectRevert(TrancheAccountant.SourceUnhealthy.selector);
        accountant.exitFullStack(
            0.1e18, address(this), address(this), type(uint256).max, type(uint256).max, 0, block.timestamp
        );

        accountant.unpause();
        assertTrue(senior.transfer(alice, 1));
    }

    function test_classTransfersDoNotChangeAccountingOrCheckpoints() public {
        _bootstrap();
        uint256 claimBefore = accountant.seniorClaimValue();
        uint256 liveOffsetBefore = accountant.checkpointLiveOffsetWad();
        uint256 crystallizedOffsetBefore = accountant.checkpointCrystallizedOffsetWad();
        uint256 seniorSupplyBefore = senior.totalSupply();
        uint256 juniorSupplyBefore = junior.totalSupply();

        assertTrue(senior.transfer(alice, senior.balanceOf(address(this)) / 10));
        assertTrue(junior.transfer(alice, junior.balanceOf(address(this)) / 10));

        assertEq(accountant.seniorClaimValue(), claimBefore);
        assertEq(accountant.checkpointLiveOffsetWad(), liveOffsetBefore);
        assertEq(accountant.checkpointCrystallizedOffsetWad(), crystallizedOffsetBefore);
        assertEq(senior.totalSupply(), seniorSupplyBefore);
        assertEq(junior.totalSupply(), juniorSupplyBefore);
    }

    function test_thirdPartyRedemptionRequiresAllowanceToAccountant() public {
        _bootstrap();
        uint256 shares = senior.balanceOf(address(this)) / 10;

        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(accountant), 0, shares)
        );
        accountant.redeemSenior(shares, bob, address(this), 0, block.timestamp);

        senior.approve(address(accountant), shares);
        vm.prank(bob);
        uint256 assets = accountant.redeemSenior(shares, bob, address(this), 0, block.timestamp);
        assertGt(assets, 0);
        assertEq(vault.balanceOf(bob), assets);
    }

    // ============ Fuzz Properties ============

    function testFuzz_fullStackExitNeverOverpaysCustodyFraction(uint96 rawFraction) public {
        _bootstrap();
        uint256 fraction = bound(uint256(rawFraction), 1, WAD);
        uint256 custody = accountant.backingAssets();
        (uint256 previewAssets,,) = accountant.previewFullStackExit(fraction);
        assertLe(previewAssets, Math.mulDiv(custody, fraction, WAD));

        (uint256 assets,,) = accountant.exitFullStack(
            fraction, address(this), address(this), type(uint256).max, type(uint256).max, 0, block.timestamp
        );
        assertEq(assets, previewAssets);
    }

    function testFuzz_incomeAndPartialSalePreserveSeniorClaim(uint16 rawGrowthBps, uint16 rawSaleBps) public {
        _bootstrap();
        uint256 growthBps = bound(uint256(rawGrowthBps), 1, 2_000);
        uint256 saleBps = bound(uint256(rawSaleBps), 1, 5_000);
        adapter.setIndex(Math.mulDiv(1e18, 10_000 + growthBps, 10_000));
        priceOracle.setPrice(Math.mulDiv(100e8, 10_000 + growthBps, 10_000));
        accountant.syncIncome();

        uint256 delivered = Math.mulDiv(strconModule.balance(), saleBps, 10_000);
        uint256 received = Math.mulDiv(delivered, priceOracle.price(), 1e20);
        vault.sell(delivered, received, vehicle, block.timestamp);
        uint256 claimBefore = accountant.seniorClaimValue();
        accountant.syncIncome();

        assertApproxEqAbs(accountant.seniorClaimValue(), claimBefore, 3);
        assertEq(accountant.markedSeniorValue() + accountant.juniorResidualValue(), accountant.backingValue());
    }
}
