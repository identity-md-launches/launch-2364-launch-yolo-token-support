// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {DevPrices} from "src/DevPrices.sol";
import {ParamsRegistry} from "src/ParamsRegistry.sol";
import {Params, ParamsBounds} from "src/VaultParams.sol";

contract SupportPricePropertiesTest is Test {
    address internal constant DEV = 0x8Ad18E99F4C8d8406f9Ba8899CF308000518A981;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address internal yolo;
    DevPrices internal prices;

    function setUp() public {
        yolo = makeAddr("priced YOLO");
        prices = new DevPrices(DEV, USDC, IMD, yolo, 1e15, 2400e18, 5.5e18);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_ConversionsRespectWholeTokenPricesAndDecimalScales(uint256 raw) public view {
        uint256 amount = bound(raw, 0, 1e30);
        assertEq(prices.yoloValue(USDC, amount), amount * 1e15, "each micro-USDC buys 0.001 YOLO");
        assertEq(prices.yoloValue(address(0), amount), amount * 2_400_000, "ETH/YOLO whole-token ratio");
        // IMD first rounds to USD's 18-decimal unit; converting that unit to YOLO can lose
        // less than 1,000 YOLO wei. Requiring exact real-number equality for odd IMD wei is wrong.
        uint256 yoloForImd = prices.yoloValue(IMD, amount);
        assertLe(yoloForImd, amount * 5_500, "conversion cannot overvalue IMD");
        assertLt(amount * 5_500 - yoloForImd, 1_000, "loss is below one intermediate USD unit");
        assertEq(prices.imdValue(IMD, amount), amount);
        assertEq(prices.yoloValue(yolo, amount), amount);
        uint256 converted = prices.imdValue(USDC, amount);
        assertLe(converted * 11, amount * 2e12);
        assertLt(amount * 2e12, (converted + 1) * 11, "USDC/IMD rounds down by less than one IMD wei");
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_PriceChangeCannotAffectOtherCurrencies(uint256 next, uint8 which) public {
        uint256[3] memory initial = [uint256(1e15), uint256(2400e18), uint256(5.5e18)];
        uint256 i = which % 3;
        next = bound(next, initial[i] / 10, initial[i] * 10);
        vm.prank(DEV);
        if (i == 0) prices.setYoloPriceUsd(next);
        else if (i == 1) prices.setEthUsd(next);
        else prices.setImdUsd(next);
        assertEq(prices.yoloPriceUsd(), i == 0 ? next : initial[0]);
        assertEq(prices.ethUsd(), i == 1 ? next : initial[1]);
        assertEq(prices.imdUsd(), i == 2 ? next : initial[2]);
        assertEq(prices.priceOf(USDC), 1e18, "USDC peg is not an owner-set price");
    }

    function test_UnauthorizedSettersLeaveAllPricesIntact() public {
        bytes memory denied = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this));
        vm.expectRevert(denied);
        prices.setYoloPriceUsd(2e15);
        vm.expectRevert(denied);
        prices.setEthUsd(2500e18);
        vm.expectRevert(denied);
        prices.setImdUsd(6e18);
        assertEq(prices.yoloPriceUsd(), 1e15);
        assertEq(prices.ethUsd(), 2400e18);
        assertEq(prices.imdUsd(), 5.5e18);
    }

    function test_UnknownAssetIsRefusedEvenForZeroAndSupportedZeroConversionsAreZero() public {
        address unknown = makeAddr("unknown price asset");
        assertFalse(prices.hasPrice(unknown));
        assertEq(prices.priceOf(unknown), 0);
        vm.expectRevert(DevPrices.UnknownToken.selector);
        prices.usdValue(unknown, 0);
        vm.expectRevert(DevPrices.UnknownToken.selector);
        prices.imdValue(unknown, 1);
        vm.expectRevert(DevPrices.UnknownToken.selector);
        prices.yoloValue(unknown, 1);
        address[4] memory assets = [address(0), USDC, IMD, yolo];
        for (uint256 i; i < assets.length; ++i) {
            assertTrue(prices.hasPrice(assets[i]));
            assertEq(prices.usdValue(assets[i], 0), 0);
            assertEq(prices.imdValue(assets[i], 0), 0);
            assertEq(prices.yoloValue(assets[i], 0), 0);
        }
    }

    function test_NonDivisibleDownwardStepUsesCeiling() public {
        // Tiny prices are legal, and the 10x guard must not round a forbidden decrease into range.
        DevPrices tiny = new DevPrices(DEV, USDC, IMD, yolo, 11, 11, 11);
        vm.startPrank(DEV);
        vm.expectRevert(DevPrices.PriceSanity.selector);
        tiny.setYoloPriceUsd(1);
        vm.expectRevert(DevPrices.PriceSanity.selector);
        tiny.setEthUsd(1);
        vm.expectRevert(DevPrices.PriceSanity.selector);
        tiny.setImdUsd(1);
        tiny.setYoloPriceUsd(2);
        tiny.setEthUsd(2);
        tiny.setImdUsd(2);
        vm.stopPrank();
        assertEq(tiny.yoloPriceUsd(), 2);
        assertEq(tiny.ethUsd(), 2);
        assertEq(tiny.imdUsd(), 2);
    }
}

contract SupportRegistryFailuresTest is Test {
    address internal constant OWNER = 0x3c587Eff6c96eAcF7E3dcC2CFf6416161386E48C;
    address internal constant FIRST_SIGNER = 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982;
    uint256 internal constant DELAY = 48 hours;
    ParamsRegistry internal registry;

    function setUp() public {
        vm.warp(1_792_584_000);
        // Artifact deployment avoids embedding a second copy of the large registry constructor in this test.
        registry = ParamsRegistry(
            deployCode(
                "ParamsRegistry.sol:ParamsRegistry",
                abi.encode(
                    OWNER,
                    0xa43e6F75ee006411F79Ac1C84120606C2330DE82,
                    makeAddr("registry DevPrices"),
                    makeAddr("registry swap adapter"),
                    0x0000eC93127BAA929E58E97dd0095A2BFb38ec1D,
                    0x00000000000000447e69651d841bD8D104Bed493,
                    OWNER,
                    FIRST_SIGNER
                )
            )
        );
    }

    function test_ReplacementRestartsFullDelayAndVersionsNeverChange() public {
        Params memory initial = registry.params(1);
        bytes32 initialHash = keccak256(abi.encode(initial));
        Params memory proposal = registry.params(1);
        proposal.minRewardUsdc = 6e6;
        vm.prank(OWNER);
        registry.proposeParams(proposal);
        uint256 oldEta = registry.pendingParamsEta();
        vm.warp(oldEta - 1);
        proposal.minRewardUsdc = 7e6;
        vm.prank(OWNER);
        registry.proposeParams(proposal);
        uint256 newEta = registry.pendingParamsEta();
        assertEq(newEta, oldEta - 1 + DELAY);
        vm.warp(oldEta);
        vm.expectRevert(ParamsRegistry.TimelockNotPassed.selector);
        registry.activateParams();
        vm.warp(newEta - 1);
        vm.expectRevert(ParamsRegistry.TimelockNotPassed.selector);
        registry.activateParams();
        vm.warp(newEta);
        registry.activateParams(); // unrelated caller, exact ETA
        assertEq(registry.currentVersion(), 2);
        assertEq(registry.pendingParamsEta(), 0);
        assertEq(registry.params(2).minRewardUsdc, 7e6);
        assertEq(keccak256(abi.encode(registry.params(1))), initialHash);
        vm.expectRevert(ParamsRegistry.NothingPending.selector);
        registry.activateParams();
    }

    function test_CancelledProposalCannotBeRevivedOrCancelAnActivatedVersion() public {
        Params memory p = registry.params(1);
        vm.prank(OWNER);
        registry.proposeParams(p);
        uint256 eta = registry.pendingParamsEta();
        vm.prank(OWNER);
        registry.cancelParams();
        vm.warp(eta);
        vm.expectRevert(ParamsRegistry.NothingPending.selector);
        registry.activateParams();
        vm.prank(OWNER);
        registry.proposeParams(p);
        vm.warp(registry.pendingParamsEta());
        registry.activateParams();
        vm.expectRevert(ParamsRegistry.NothingPending.selector);
        vm.prank(OWNER);
        registry.cancelParams();
        assertEq(registry.currentVersion(), 2);
    }

    function test_AllProposalCancellationAndPauseEntrypointsRequireOwner() public {
        Params memory p = registry.params(1);
        address second = makeAddr("second signer");
        vm.startPrank(OWNER);
        registry.proposeParams(p);
        registry.proposeAttester(second, true);
        vm.stopPrank();
        bytes memory denied = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this));
        vm.expectRevert(denied);
        registry.proposeParams(p);
        vm.expectRevert(denied);
        registry.cancelParams();
        vm.expectRevert(denied);
        registry.proposeAttester(second, false);
        vm.expectRevert(denied);
        registry.cancelAttester(second, true);
        vm.expectRevert(denied);
        registry.setNewTasksPaused(true);
        assertFalse(registry.newTasksPaused());
        assertFalse(registry.isAttester(second));
        assertEq(registry.currentVersion(), 1);
        assertGt(registry.pendingParamsEta(), 0);
    }

    function test_FailedLastRemovalKeepsProposalExecutableAfterAddition() public {
        address second = makeAddr("rotated signer");
        vm.startPrank(OWNER);
        registry.proposeAttester(FIRST_SIGNER, false);
        registry.proposeAttester(second, true);
        vm.stopPrank();
        bytes32 removal = keccak256(abi.encode(FIRST_SIGNER, false));
        uint256 eta = registry.attesterChangeEta(removal);
        vm.warp(eta - 1);
        vm.expectRevert(ParamsRegistry.TimelockNotPassed.selector);
        registry.executeAttester(second, true);
        vm.warp(eta);
        vm.expectRevert(ParamsRegistry.LastAttester.selector);
        registry.executeAttester(FIRST_SIGNER, false);
        assertEq(registry.attesterChangeEta(removal), eta, "failed execution must not consume proposal");
        assertEq(registry.attesterCount(), 1);
        registry.executeAttester(second, true);
        registry.executeAttester(FIRST_SIGNER, false);
        assertEq(registry.attesterCount(), 1);
        assertFalse(registry.isAttester(FIRST_SIGNER));
        assertTrue(registry.isAttester(second));
        vm.expectRevert(ParamsRegistry.NothingPending.selector);
        registry.executeAttester(FIRST_SIGNER, false);
    }

    function test_CancellationIsSpecificToSignerAndDirection() public {
        address signer = makeAddr("pending signer");
        vm.startPrank(OWNER);
        registry.proposeAttester(signer, true);
        registry.proposeAttester(signer, false);
        registry.cancelAttester(signer, true);
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + DELAY);
        vm.expectRevert(ParamsRegistry.NothingPending.selector);
        registry.executeAttester(signer, true);
        registry.executeAttester(signer, false); // no-op removal does not reduce count
        assertEq(registry.attesterCount(), 1);
        assertTrue(registry.isAttester(FIRST_SIGNER));
    }

    function test_DuplicateSignerAdditionCannotInflateCount() public {
        for (uint256 i; i < 3; ++i) {
            vm.prank(OWNER);
            registry.proposeAttester(FIRST_SIGNER, true);
            vm.warp(vm.getBlockTimestamp() + DELAY);
            registry.executeAttester(FIRST_SIGNER, true);
            assertEq(registry.attesterCount(), 1);
        }
        vm.prank(OWNER);
        registry.proposeAttester(FIRST_SIGNER, false);
        vm.warp(vm.getBlockTimestamp() + DELAY);
        vm.expectRevert(ParamsRegistry.LastAttester.selector);
        registry.executeAttester(FIRST_SIGNER, false);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_OutOfBoundsFeeCannotReplacePendingValidProposal(uint16 rawFee) public {
        Params memory p = registry.params(1);
        vm.prank(OWNER);
        registry.proposeParams(p);
        uint256 eta = registry.pendingParamsEta();
        bytes32 pendingHash = keccak256(abi.encode(registry.pendingParams()));
        p.feeBps = uint16(bound(rawFee, 1501, type(uint16).max));
        vm.expectRevert(abi.encodeWithSelector(ParamsBounds.ParamOutOfBounds.selector, "feeBps"));
        vm.prank(OWNER);
        registry.proposeParams(p);
        assertEq(registry.pendingParamsEta(), eta);
        assertEq(keccak256(abi.encode(registry.pendingParams())), pendingHash);
        assertEq(registry.currentVersion(), 1);
    }
}
