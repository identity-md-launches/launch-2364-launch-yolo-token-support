// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {YoloToken} from "src/token/YoloToken.sol";
import {YoloSplitter} from "src/token/YoloSplitter.sol";
import {ProjectVesting} from "src/token/ProjectVesting.sol";
import {IncentivesVesting, DevVesting, TeamVesting, TreasuryVesting} from "src/token/Vestings.sol";

/// @dev All constructors run inside ONE call, as in launch #2292. A test deploying the vestings one
/// call at a time would lose their transient binding flags under Foundry 1.8 transaction isolation.
contract GenesisCustodyDeployer {
    function deploy(address[4] calldata beneficiaries, address stabilizer)
        external
        returns (YoloSplitter splitter, ProjectVesting[4] memory vestings)
    {
        vestings[0] = new IncentivesVesting(beneficiaries[0]);
        vestings[1] = new DevVesting(beneficiaries[1]);
        vestings[2] = new TeamVesting(beneficiaries[2]);
        vestings[3] = new TreasuryVesting(beneficiaries[3]);
        splitter = new YoloSplitter(
            address(vestings[0]), address(vestings[1]), address(vestings[2]), address(vestings[3]), stabilizer
        );
    }
}

contract GenesisCustodyHandler is Test {
    uint256 internal constant FIXED = 527_777_777e18;
    YoloToken public immutable token;
    YoloSplitter public immutable splitter;
    ProjectVesting[4] public vestings;
    uint256[4] public allocated;
    uint256 public funded;
    uint256 public firstSplitAt;
    bool public wasSplit;

    constructor(YoloToken t, YoloSplitter s, ProjectVesting[4] memory v) {
        token = t;
        splitter = s;
        vestings = v;
    }

    function fund(uint256 raw) public {
        uint256 amount = bound(raw, 0, token.balanceOf(address(this)));
        token.transfer(address(splitter), amount);
        funded += amount;
    }

    function split() public {
        uint256 balance = token.balanceOf(address(splitter));
        if (!wasSplit && balance <= FIXED) {
            vm.expectRevert(abi.encodeWithSelector(YoloSplitter.NotArrived.selector, balance));
            splitter.split(address(token));
            assertFalse(splitter.done(address(token)));
            assertEq(token.balanceOf(address(splitter)), balance);
            return;
        }
        splitter.split(address(token));
        if (!wasSplit) {
            wasSplit = true;
            firstSplitAt = vm.getBlockTimestamp();
            allocated[0] = 250_000_000e18;
            allocated[1] = 77_777_777e18;
            allocated[2] = 50_000_000e18;
            allocated[3] = balance - FIXED;
        } else {
            allocated[3] += balance;
        }
        assertEq(token.balanceOf(address(splitter)), 0);
    }

    function release(uint256 seed) public {
        ProjectVesting v = vestings[seed % 4];
        uint256 releasedBefore = v.released(address(token));
        uint256 beneficiaryBefore = token.balanceOf(v.beneficiary());
        uint256 due = v.releasable(address(token));
        v.release(address(token));
        assertEq(v.released(address(token)), releasedBefore + due);
        assertEq(token.balanceOf(v.beneficiary()), beneficiaryBefore + due);
        assertEq(v.releasable(address(token)), 0);
        v.release(address(token));
        assertEq(v.released(address(token)), releasedBefore + due, "same-time release cannot pay twice");
    }

    function advance(uint256 dt) external {
        vm.warp(vm.getBlockTimestamp() + bound(dt, 0, 60 days));
    }

    function attemptRebind(uint256 seed) external {
        ProjectVesting v = vestings[seed % 4];
        vm.expectRevert(ProjectVesting.BindingClosed.selector);
        v.bindStarter();
        assertEq(v.starter(), address(splitter));
    }
}

/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract GenesisCustodyStatefulTest is Test {
    uint256 internal constant REMAINDER = 750_000_000e18;
    YoloToken internal token;
    YoloSplitter internal splitter;
    ProjectVesting[4] internal vestings;
    GenesisCustodyHandler internal handler;
    address internal stabilizer;

    function setUp() public {
        vm.warp(1_792_584_000 - 1 days);
        address[4] memory beneficiaries = [
            makeAddr("incentives beneficiary"),
            makeAddr("dev beneficiary"),
            makeAddr("team beneficiary"),
            makeAddr("treasury beneficiary")
        ];
        stabilizer = makeAddr("stabilizer");
        (splitter, vestings) = new GenesisCustodyDeployer().deploy(beneficiaries, stabilizer);
        token = new YoloToken(makeAddr("genesis pool"), makeAddr("no gate code"), beneficiaries[3], 1_792_584_000);
        handler = new GenesisCustodyHandler(token, splitter, vestings);
        token.transfer(address(handler), REMAINDER);
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = handler.fund.selector;
        selectors[1] = handler.split.selector;
        selectors[2] = handler.release.selector;
        selectors[3] = handler.advance.selector;
        selectors[4] = handler.attemptRebind.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_EveryRemainderTokenIsAccountedFor() public view {
        uint256 accounted =
            token.balanceOf(address(handler)) + token.balanceOf(address(splitter)) + token.balanceOf(stabilizer);
        for (uint256 i; i < 4; ++i) {
            ProjectVesting v = vestings[i];
            uint256 paid = v.released(address(token));
            assertEq(token.balanceOf(address(v)) + paid, handler.allocated(i));
            assertEq(token.balanceOf(v.beneficiary()), paid, "releases pay only fixed beneficiaries");
            assertLe(paid, handler.allocated(i), "cannot release more than ever allocated");
            accounted += token.balanceOf(address(v)) + token.balanceOf(v.beneficiary());
        }
        assertEq(accounted, REMAINDER);
        assertEq(token.balanceOf(address(handler)) + handler.funded(), REMAINDER);
        assertEq(token.balanceOf(address(this)), 250_000_000e18);
        assertEq(token.totalSupply(), 1_000_000_000e18);
    }

    function invariant_SplitAndClocksCannotBeResetByLaterFundingOrRelease() public view {
        bool split = handler.wasSplit();
        assertEq(splitter.done(address(token)), split);
        assertEq(token.balanceOf(stabilizer), split ? 150_000_000e18 : 0);
        for (uint256 i; i < 4; ++i) {
            assertEq(vestings[i].starter(), address(splitter));
            assertEq(vestings[i].startOf(address(token)), handler.firstSplitAt());
        }
        if (split) {
            assertEq(handler.allocated(0), 250_000_000e18);
            assertEq(handler.allocated(1), 77_777_777e18);
            assertEq(handler.allocated(2), 50_000_000e18);
            assertEq(handler.allocated(3) + token.balanceOf(address(splitter)), handler.funded() - 527_777_777e18);
        }
    }

    function afterInvariant() public {
        // Complete funding, split if needed, then demonstrate that every last wei can leave custody.
        handler.fund(token.balanceOf(address(handler)));
        handler.split();
        vm.warp(vm.getBlockTimestamp() + 730 days);
        for (uint256 i; i < 4; ++i) {
            handler.release(i);
            assertEq(token.balanceOf(address(vestings[i])), 0);
            assertEq(token.balanceOf(vestings[i].beneficiary()), handler.allocated(i));
        }
        invariant_EveryRemainderTokenIsAccountedFor();
        invariant_SplitAndClocksCannotBeResetByLaterFundingOrRelease();
    }

    function test_ThresholdDustLateFundingAndEndOfVesting() public {
        handler.fund(527_777_777e18);
        handler.split(); // fixed shares alone are not enough: treasury must get something
        for (uint256 i; i < 4; ++i) {
            assertEq(vestings[i].startOf(address(token)), 0);
        }
        handler.fund(1);
        handler.split();
        uint256 start = vm.getBlockTimestamp();
        assertEq(token.balanceOf(vestings[0].beneficiary()), 62_500_000e18);
        assertEq(token.balanceOf(vestings[3].beneficiary()), 1);
        vm.warp(start + 365 days);
        for (uint256 i; i < 4; ++i) {
            handler.release(i);
        }
        assertEq(token.balanceOf(vestings[0].beneficiary()), 156_250_000e18);
        assertEq(token.balanceOf(vestings[1].beneficiary()), 77_777_777e18);
        assertEq(token.balanceOf(vestings[2].beneficiary()), 50_000_000e18);
        handler.fund(token.balanceOf(address(handler)));
        handler.split();
        handler.release(3);
        assertEq(token.balanceOf(vestings[3].beneficiary()), 222_222_223e18);
        assertEq(vestings[3].startOf(address(token)), start, "late funding uses the original clock");
        vm.warp(start + 730 days);
        handler.release(0);
        assertEq(token.balanceOf(vestings[0].beneficiary()), 250_000_000e18);
        invariant_EveryRemainderTokenIsAccountedFor();
        invariant_SplitAndClocksCannotBeResetByLaterFundingOrRelease();
    }
}
