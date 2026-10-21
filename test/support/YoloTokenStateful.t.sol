// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {YoloToken} from "src/token/YoloToken.sol";
import {NftGate} from "src/token/NftGate.sol";

abstract contract YoloScheduleFixture is Test {
    uint256 internal constant OPEN = 1_792_584_000;
    uint256 internal constant SUPPLY = 1_000_000_000e18;
    uint256 internal constant PER_NFT = 500_000e18;
    address internal constant GATE = 0x97C8Fe82527F1a65A147bB0b425C717E4EC547C2;
    address internal constant TREASURY = 0x3c587Eff6c96eAcF7E3dcC2CFf6416161386E48C;
    address internal constant NFT = 0x0000eC93127BAA929E58E97dd0095A2BFb38ec1D;
    YoloToken internal token;
    NftGate internal gate;
    address internal pool;
    address[3] internal users;

    function setUp() public virtual {
        vm.warp(OPEN - 120);
        pool = makeAddr("schedule pool manager");
        users = [makeAddr("snapshot one NFT"), makeAddr("snapshot three NFTs"), makeAddr("outside snapshot")];
        // The real gate implementation, with the brief's immutable counterparties, at the fixed gate address.
        vm.etch(GATE, address(new NftGate(NFT, TREASURY)).code);
        gate = NftGate(GATE);
        address[] memory accounts = new address[](2);
        uint256[] memory counts = new uint256[](2);
        (accounts[0], accounts[1], counts[0], counts[1]) = (users[0], users[1], 1, 3);
        vm.prank(TREASURY);
        gate.record(accounts, counts);
        vm.prank(TREASURY);
        gate.seal(block.number);
        token = new YoloToken(pool, GATE, TREASURY, OPEN);
        token.transfer(pool, 150_000_000e18);
        for (uint256 i; i < users.length; ++i) {
            token.transfer(users[i], 1_000_000e18);
        }
    }
}

/// @dev Every action either succeeds with checked deltas or asserts its exact expected rejection.
/// No catch-all suppression: fail_on_revert is enabled on the invariant campaign below.
contract YoloScheduleHandler is Test {
    uint256 internal constant OPEN = 1_792_584_000;
    uint256 internal constant PER_NFT = 500_000e18;
    YoloToken public immutable token;
    NftGate public immutable gate;
    address public immutable pool;
    address public immutable treasury;
    address public immutable launcher;
    address[3] public users;
    uint256[3] public boughtInSnapshot;
    uint256 public taxCollected;
    uint256 public successfulBuys;
    uint256 public rejectedBuys;
    uint256 public successfulSells;

    constructor(YoloToken token_, NftGate gate_, address[3] memory users_) {
        token = token_;
        gate = gate_;
        pool = token_.poolManager();
        treasury = token_.taxRecipient();
        launcher = token_.launcher();
        users = users_;
    }

    function advance(uint256 dt) external {
        vm.warp(vm.getBlockTimestamp() + bound(dt, 0, 180));
    }

    function nextBoundary() external {
        uint256 now_ = vm.getBlockTimestamp();
        uint256[7] memory edges = [OPEN - 1, OPEN, OPEN + 1799, OPEN + 1800, OPEN + 3599, OPEN + 3600, OPEN + 3601];
        for (uint256 i; i < edges.length; ++i) {
            if (now_ < edges[i]) {
                vm.warp(edges[i]);
                return;
            }
        }
    }

    function buy(uint256 who, uint256 rawAmount) public {
        uint256 index = who % 3;
        address buyer = users[index];
        uint256 poolBefore = token.balanceOf(pool);
        uint256 amount = bound(rawAmount, 0, poolBefore < 2_000_000e18 ? poolBefore : 2_000_000e18);
        uint256 buyerBefore = token.balanceOf(buyer);
        uint256 treasuryBefore = token.balanceOf(treasury);
        uint256 now_ = vm.getBlockTimestamp();
        bytes memory expected;
        if (amount != 0 && now_ < OPEN) {
            expected = abi.encodeWithSelector(YoloToken.TradingNotOpen.selector, OPEN);
        } else if (amount != 0 && now_ < OPEN + 1800) {
            if (index == 2) {
                expected = abi.encodeWithSelector(YoloToken.NotWhitelisted.selector, buyer);
            } else {
                uint256 quota = index == 0 ? PER_NFT : 3 * PER_NFT;
                uint256 left = quota - boughtInSnapshot[index];
                if (amount > left) {
                    expected = abi.encodeWithSelector(YoloToken.NftAllowanceExceeded.selector, buyer, left, amount);
                }
            }
        }
        if (expected.length != 0) vm.expectRevert(expected);
        vm.prank(pool);
        token.transfer(buyer, amount);
        if (expected.length != 0) {
            ++rejectedBuys;
            assertEq(token.balanceOf(pool), poolBefore);
            assertEq(token.balanceOf(buyer), buyerBefore);
            assertEq(token.balanceOf(treasury), treasuryBefore);
            assertEq(gate.used(address(token), buyer), boughtInSnapshot[index]);
            return;
        }
        ++successfulBuys;
        uint256 fee = token.balanceOf(treasury) - treasuryBefore;
        assertEq(token.balanceOf(pool), poolBefore - amount, "pool must pay exactly its transfer argument");
        assertEq(token.balanceOf(buyer) - buyerBefore + fee, amount, "buy conservation");
        if (now_ >= OPEN + 1800 && now_ < OPEN + 3600) {
            // Rational inequality independently checks both the slope and floor rounding (no tax getter oracle).
            uint256 numerator = amount * 3 * (OPEN + 3600 - now_);
            assertLe(fee * 18_000, numerator);
            assertLt(numerator, (fee + 1) * 18_000);
        } else {
            assertEq(fee, 0);
        }
        if (now_ >= OPEN && now_ < OPEN + 1800) boughtInSnapshot[index] += amount;
        taxCollected += fee;
    }

    function sell(uint256 who, uint256 rawAmount, bool throughAllowance, bool infinite) public {
        address seller = users[who % 3];
        uint256 before_ = token.balanceOf(seller);
        // A 70% input is affordable at every point of the schedule, including the 30% gross tax.
        uint256 amount = bound(rawAmount, 0, before_ * 7 / 10);
        uint256 poolBefore = token.balanceOf(pool);
        uint256 treasuryBefore = token.balanceOf(treasury);
        if (throughAllowance) {
            vm.prank(seller);
            token.approve(address(this), infinite ? type(uint256).max : amount);
            token.transferFrom(seller, pool, amount);
            assertEq(token.allowance(seller, address(this)), infinite ? type(uint256).max : 0);
        } else {
            vm.prank(seller);
            token.transfer(pool, amount);
        }
        ++successfulSells;
        uint256 fee = token.balanceOf(treasury) - treasuryBefore;
        assertEq(token.balanceOf(pool) - poolBefore, amount, "sell cannot short pool settlement");
        assertEq(before_ - token.balanceOf(seller), amount + fee, "tax must be paid on top");
        uint256 now_ = vm.getBlockTimestamp();
        if (now_ >= OPEN && now_ < OPEN + 3600) {
            uint256 remaining = now_ < OPEN + 1800 ? 1800 : OPEN + 3600 - now_;
            uint256 rate = 3 * remaining;
            // fee = floor(gross * rate / 18000), with gross = pool input + fee;
            // rearranged to avoid using the implementation's division or sellTax().
            assertLe(fee * 18_000, (amount + fee) * rate);
            assertLt((amount + fee + 1) * rate, (fee + 1) * 18_000);
        } else {
            assertEq(fee, 0);
        }
        taxCollected += fee;
    }

    function walletTransfer(uint256 fromSeed, uint256 toSeed, uint256 rawAmount) external {
        address from = users[fromSeed % 3];
        address to = users[toSeed % 3];
        uint256 fromBefore = token.balanceOf(from);
        uint256 toBefore = token.balanceOf(to);
        uint256 amount = bound(rawAmount, 0, fromBefore);
        vm.prank(from);
        token.transfer(to, amount);
        assertEq(token.balanceOf(from), from == to ? fromBefore : fromBefore - amount);
        assertEq(token.balanceOf(to), from == to ? toBefore : toBefore + amount);
    }

    function outsiderConsumes(uint256 who, uint256 rawAmount) external {
        address buyer = users[who % 3];
        gate.consume(buyer, bound(rawAmount, 0, 2_000_000e18));
        assertEq(gate.used(address(token), buyer), boughtInSnapshot[who % 3], "another caller cannot spend YOLO quota");
    }

    function factoryRoundTrip(uint256 rawAmount) external {
        uint256 amount = bound(rawAmount, 0, token.balanceOf(launcher));
        uint256 launcherBefore = token.balanceOf(launcher);
        uint256 poolBefore = token.balanceOf(pool);
        vm.prank(launcher);
        token.transfer(pool, amount);
        vm.prank(pool);
        token.transfer(launcher, amount);
        assertEq(token.balanceOf(launcher), launcherBefore, "factory seeding and fee claims are exempt");
        assertEq(token.balanceOf(pool), poolBefore);
    }
}

/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 128
/// forge-config: default.invariant.fail-on-revert = true
contract YoloTokenStatefulTest is YoloScheduleFixture {
    YoloScheduleHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new YoloScheduleHandler(token, gate, users);
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.advance.selector;
        selectors[1] = handler.nextBoundary.selector;
        selectors[2] = handler.buy.selector;
        selectors[3] = handler.sell.selector;
        selectors[4] = handler.walletTransfer.selector;
        selectors[5] = handler.outsiderConsumes.selector;
        selectors[6] = handler.factoryRoundTrip.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_FixedSupplyEqualsEveryTrackedBalance() public view {
        uint256 sum = token.balanceOf(address(this)) + token.balanceOf(pool) + token.balanceOf(TREASURY);
        for (uint256 i; i < users.length; ++i) {
            sum += token.balanceOf(users[i]);
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(sum, SUPPLY);
        assertEq(token.balanceOf(address(handler)), 0, "caller has no fee reward");
        assertEq(token.balanceOf(TREASURY), handler.taxCollected());
    }

    function invariant_SnapshotUsageEqualsOnlySuccessfulWindowBuys() public view {
        for (uint256 i; i < users.length; ++i) {
            uint256 used = gate.used(address(token), users[i]);
            assertEq(used, handler.boughtInSnapshot(i));
            assertLe(used, i == 0 ? PER_NFT : i == 1 ? 3 * PER_NFT : 0);
            assertEq(gate.left(address(token), users[i]) + used, gate.allowanceOf(users[i]));
        }
        assertEq(gate.sealedAt(), OPEN - 120);
        assertEq(gate.walletCount(), 2);
        assertEq(gate.totalNfts(), 4);
    }

    function test_HandlerExercisesAllPhasesIncludingRejections() public {
        handler.buy(0, 1);
        vm.warp(OPEN);
        handler.buy(0, PER_NFT);
        handler.buy(0, 1);
        handler.buy(2, 1);
        handler.sell(0, 70e18, true, false);
        vm.warp(OPEN + 1800);
        handler.buy(2, 100e18);
        handler.sell(1, 70e18, true, true);
        vm.warp(OPEN + 3599);
        handler.buy(2, 18_001);
        vm.warp(OPEN + 3600);
        handler.buy(2, 100e18);
        handler.sell(2, 100e18, false, false);
        assertEq(handler.successfulBuys(), 4);
        assertEq(handler.rejectedBuys(), 3);
        assertEq(handler.successfulSells(), 3);
        invariant_FixedSupplyEqualsEveryTrackedBalance();
        invariant_SnapshotUsageEqualsOnlySuccessfulWindowBuys();
    }
}

contract YoloTokenAtomicityTest is YoloScheduleFixture {
    function test_InsufficientPoolBalanceRollsBackGateConsumption() public {
        uint256 poolBalance = token.balanceOf(pool);
        vm.prank(pool);
        token.transfer(address(this), poolBalance);
        vm.warp(OPEN);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, pool, 0, 1));
        vm.prank(pool);
        token.transfer(users[0], 1);
        assertEq(gate.used(address(token), users[0]), 0);
        token.transfer(pool, 1);
        vm.prank(pool);
        token.transfer(users[0], 1);
        assertEq(gate.used(address(token), users[0]), 1, "failed buy must leave allowance available");
    }

    function test_FailedTaxedTransferFromRollsBackTaxAndAllowance() public {
        vm.warp(OPEN);
        uint256 amount = token.balanceOf(users[0]);
        uint256 fee = amount * 3 / 7;
        uint256 poolBefore = token.balanceOf(pool);
        vm.prank(users[0]);
        token.approve(users[2], amount);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, users[0], amount - fee, amount)
        );
        vm.prank(users[2]);
        token.transferFrom(users[0], pool, amount);
        assertEq(token.balanceOf(users[0]), amount);
        assertEq(token.balanceOf(pool), poolBefore);
        assertEq(token.balanceOf(TREASURY), 0);
        assertEq(token.allowance(users[0], users[2]), amount);
    }

    function test_ZeroTransferDoesNotConsumeQuotaOrChargeTaxAtEveryBoundary() public {
        uint256[7] memory times = [OPEN - 1, OPEN, OPEN + 1799, OPEN + 1800, OPEN + 3599, OPEN + 3600, OPEN + 1 days];
        for (uint256 i; i < times.length; ++i) {
            vm.warp(times[i]);
            vm.prank(pool);
            token.transfer(users[2], 0);
            vm.prank(users[2]);
            token.transfer(pool, 0);
            assertEq(gate.used(address(token), users[2]), 0);
            assertEq(token.balanceOf(TREASURY), 0);
        }
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_SellQuoteIsMonotoneAndRoundingBounded(uint256 amount, uint256 elapsed) public {
        amount = bound(amount, 0, SUPPLY);
        elapsed = bound(elapsed, 0, 3599);
        vm.warp(OPEN + elapsed);
        uint256 first = token.sellTax(amount);
        uint256 numerator = 3 * (elapsed < 1800 ? 1800 : 3600 - elapsed);
        assertLe(first * 18_000, (amount + first) * numerator);
        assertLt((amount + first + 1) * numerator, (first + 1) * 18_000);
        vm.warp(OPEN + elapsed + 1);
        assertLe(token.sellTax(amount), first, "tax never rises as time advances");
        vm.warp(OPEN + 3600);
        assertEq(token.sellTax(amount), 0);
    }

    function test_BareChainDecisionCannotBeActivatedByLaterGateDeployment() public {
        vm.etch(GATE, "");
        YoloToken plain = new YoloToken(pool, GATE, TREASURY, OPEN);
        vm.etch(GATE, address(new NftGate(NFT, TREASURY)).code);
        plain.transfer(pool, 100e18);
        vm.prank(pool);
        plain.transfer(users[2], 100e18); // before opening, despite gate code now existing
        vm.warp(OPEN);
        vm.prank(users[2]);
        plain.transfer(pool, 100e18); // whole balance remains sellable
        assertFalse(plain.scheduled());
        assertEq(plain.balanceOf(TREASURY), 0);
        assertEq(plain.balanceOf(pool), 100e18);
    }
}
