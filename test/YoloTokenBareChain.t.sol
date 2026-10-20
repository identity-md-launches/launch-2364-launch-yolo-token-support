// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {YoloToken} from "../src/token/YoloToken.sol";
import {NftGate} from "../src/token/NftGate.sol";

/// @dev The token with and without the gate's code at deployment. Standalone on purpose: no setUp, the chain's own
///      clock (block.timestamp 1) and no code anywhere but what the test deploys, like a custom_token check on a bare
///      chain.
contract YoloTokenBareChainTest is Test {
    address constant PM = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant GATE = 0x97C8Fe82527F1a65A147bB0b425C717E4EC547C2; // no code on a bare chain
    address constant TREASURY = 0x3c587Eff6c96eAcF7E3dcC2CFf6416161386E48C;
    address constant TRADER = address(0xBEEF);
    uint256 constant OPEN_AT = 1_792_584_000;

    /// Seed, a buy from the PoolManager and a sell of everything bought, all at one timestamp.
    function _roundTrip(YoloToken t) internal {
        uint256 before = t.balanceOf(TRADER);
        vm.prank(PM);
        assertTrue(t.transfer(TRADER, 1_000e18));
        assertEq(t.balanceOf(TRADER), before + 1_000e18, "the buy arrived whole");
        uint256 all = t.balanceOf(TRADER);
        vm.prank(TRADER);
        assertTrue(t.transfer(PM, all));
        assertEq(t.balanceOf(TRADER), 0, "the trader sold everything");
        assertEq(t.balanceOf(TREASURY), 0, "no tax anywhere");
    }

    /// Without the gate's code the constructor takes any openAt and every transfer is a plain ERC-20 one: the
    /// round trip passes at timestamp 1, at openAt and at every point of the schedule.
    function test_BareChain_NoGateCode_PlainErc20() public {
        assertEq(GATE.code.length, 0, "bare chain");
        assertLt(block.timestamp, OPEN_AT - 30 days, "the chain's clock is far from openAt");
        YoloToken t = new YoloToken(PM, GATE, TREASURY, OPEN_AT);
        assertFalse(t.scheduled());
        assertEq(t.openAt(), OPEN_AT, "openAt is recorded as given");
        assertEq(t.balanceOf(address(this)), t.TOTAL_SUPPLY(), "minted to the deployer");
        assertTrue(t.tradingOpen());
        assertFalse(t.whitelistActive());
        assertEq(t.buyTaxBps(), 0);
        assertEq(t.sellTaxBps(), 0);
        assertEq(t.sellTax(100e18), 0);
        assertTrue(t.transfer(PM, 150_000_000e18)); // the seed
        _roundTrip(t);

        uint256[4] memory at = [OPEN_AT, OPEN_AT + 10 minutes, OPEN_AT + 45 minutes, OPEN_AT + 2 hours];
        for (uint256 i; i < at.length; ++i) {
            vm.warp(at[i]);
            _roundTrip(t);
            assertEq(t.buyTaxBps(), 0);
            assertEq(t.sellTaxBps(), 0);
            assertFalse(t.whitelistActive());
        }

        // deployed at openAt itself (the only timestamp both the old window and a buy allowed)
        vm.warp(OPEN_AT);
        YoloToken t2 = new YoloToken(PM, GATE, TREASURY, OPEN_AT);
        assertTrue(t2.transfer(PM, 150_000_000e18));
        _roundTrip(t2);
    }

    /// With the gate's code at deployment the schedule applies as before: openAt held to the deployment window,
    /// no buy before openAt, no buy in minutes 0-30 without a sealed snapshot, the sell tax of minute 0 and the
    /// taxes of minute 45 (test/YoloToken.t.sol has the whole first hour).
    function test_GateCode_ScheduleAsBefore() public {
        vm.warp(1_800_000_000);
        NftGate gate = new NftGate(address(0x1D), TREASURY);
        (bool ok, bytes memory ret) = _create(address(gate), block.timestamp - 1);
        assertFalse(ok, "openAt in the past");
        assertEq(ret, abi.encodeWithSelector(YoloToken.BadOpenAt.selector, block.timestamp - 1));
        (ok, ret) = _create(address(gate), block.timestamp + 30 days + 1);
        assertFalse(ok, "openAt too far");
        assertEq(ret, abi.encodeWithSelector(YoloToken.BadOpenAt.selector, block.timestamp + 30 days + 1));
        (ok, ret) = _create(address(gate), block.timestamp + 1 hours);
        assertTrue(ok);
        YoloToken t = YoloToken(abi.decode(ret, (address)));
        assertTrue(t.scheduled());
        assertFalse(t.tradingOpen());
        t.transfer(PM, 150_000_000e18);
        t.transfer(TRADER, 100e18); // a wallet holding YOLO before openAt
        uint256 openAt = t.openAt();
        vm.prank(PM);
        vm.expectRevert(abi.encodeWithSelector(YoloToken.TradingNotOpen.selector, openAt));
        t.transfer(TRADER, 1e18);

        vm.warp(openAt);
        // minutes 0-30 without a sealed snapshot: no buy
        vm.prank(PM);
        vm.expectRevert(YoloToken.SnapshotNotSealed.selector);
        t.transfer(TRADER, 1e18);
        // minute 0: a sell pays 30% on top (7 into the pool, 3 tax)
        assertEq(t.sellTaxBps(), 3_000);
        vm.prank(TRADER);
        t.transfer(PM, 7e18);
        assertEq(t.balanceOf(TREASURY), 3e18);
        assertEq(t.balanceOf(TRADER), 90e18);
        // the floor's sell of everything at minute 0 cannot pay the tax on top
        vm.prank(TRADER);
        vm.expectRevert();
        t.transfer(PM, 90e18);

        // minute 45: buy tax 15%, sell tax 15% on top
        vm.warp(openAt + 45 minutes);
        vm.prank(PM);
        t.transfer(TRADER, 100e18);
        assertEq(t.balanceOf(TRADER), 175e18);
        assertEq(t.balanceOf(TREASURY), 18e18);
        vm.prank(TRADER);
        t.transfer(PM, 85e17);
        assertEq(t.balanceOf(TREASURY), 18e18 + 15e17, "15% of 10 YOLO sold: 8.5 in, 1.5 tax");
    }

    /// @dev a raw CREATE of the token (no cheatcode in between), with the constructor's revert data if it reverts
    function _create(address gate, uint256 openAt) internal returns (bool ok, bytes memory ret) {
        bytes memory code = abi.encodePacked(type(YoloToken).creationCode, abi.encode(PM, gate, TREASURY, openAt));
        address a;
        assembly ("memory-safe") {
            a := create(0, add(code, 0x20), mload(code))
            let n := returndatasize()
            ret := mload(0x40)
            mstore(ret, n)
            returndatacopy(add(ret, 0x20), 0, n)
            mstore(0x40, add(add(ret, 0x20), n))
        }
        ok = a != address(0);
        if (ok) ret = abi.encode(a);
    }
}
