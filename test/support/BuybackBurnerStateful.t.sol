// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BuybackBurner} from "src/BuybackBurner.sol";
import {DevPrices} from "src/DevPrices.sol";
import {YoloToken} from "src/token/YoloToken.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @dev Models TaskVault's withdraw-as-credit-owner interface. Funding and failure controls are harness-only.
contract BurnerCreditVault {
    address public immutable beneficiary;
    mapping(address => uint256) public credits;
    bool public fail;
    error WithdrawalUnavailable();

    constructor(address beneficiary_) {
        beneficiary = beneficiary_;
    }

    function setFail(bool fail_) external {
        fail = fail_;
    }

    function fund(address asset, uint256 amount) external payable {
        if (asset == address(0)) require(msg.value == amount);
        else require(IERC20(asset).transferFrom(msg.sender, address(this), amount));
        credits[asset] += amount;
    }

    function withdraw(address asset) external {
        require(msg.sender == beneficiary, "credit belongs to burner");
        if (fail) revert WithdrawalUnavailable();
        uint256 amount = credits[asset];
        credits[asset] = 0;
        if (asset == address(0)) {
            (bool ok,) = beneficiary.call{value: amount}("");
            require(ok);
        } else {
            require(IERC20(asset).transfer(beneficiary, amount));
        }
    }
}

contract BurnerRejectsEth {
    receive() external payable {
        revert("recipient refuses ETH");
    }
}

contract BurnerHandler is Test {
    BuybackBurner public immutable burner;
    BurnerCreditVault public immutable vault;
    address public immutable dev;
    address[4] public assets;
    address[3] public wallets;
    uint256[4] public donated;
    uint256 public burned;
    uint256 public pulls;
    uint256 public sends;

    constructor(BuybackBurner b, BurnerCreditVault v, address dev_, address otherWallet, address rejectingWallet) {
        burner = b;
        vault = v;
        dev = dev_;
        assets = [address(0), address(b.usdc()), address(b.imd()), address(b.yolo())];
        wallets = [b.buybackWallet(), otherWallet, rejectingWallet];
    }

    function deposit(uint256 assetSeed, uint256 raw, bool asCredit) public {
        uint256 i = assetSeed % 4;
        address asset = assets[i];
        uint256 cap =
            i == 0 ? 10 ether : i == 1 ? 10_000e6 : i == 2 ? 10_000e18 : IERC20(asset).balanceOf(address(this));
        uint256 amount = bound(raw, 0, cap);
        if (i == 0) {
            vm.deal(address(this), amount);
            if (asCredit) {
                vault.fund{value: amount}(asset, amount);
            } else {
                (bool ok,) = address(burner).call{value: amount}("");
                assertTrue(ok);
            }
        } else {
            if (i != 3) MockERC20(asset).mint(address(this), amount);
            if (asCredit) {
                IERC20(asset).approve(address(vault), amount);
                vault.fund(asset, amount);
            } else {
                IERC20(asset).transfer(address(burner), amount);
            }
        }
        donated[i] += amount;
    }

    function rotateWallet(uint256 seed) public {
        vm.prank(dev);
        burner.setBuybackWallet(wallets[seed % 3]);
    }

    function unauthorizedRotation(uint256 seed) external {
        address before_ = burner.buybackWallet();
        vm.expectRevert(BuybackBurner.NotDev.selector);
        burner.setBuybackWallet(wallets[seed % 3]);
        assertEq(burner.buybackWallet(), before_);
    }

    function pull(uint256 assetSeed, bool fail) public {
        uint256 i = assetSeed % 4;
        address asset = assets[i];
        uint256 credit = vault.credits(asset);
        uint256 before_ = _balance(asset, address(burner));
        vault.setFail(fail);
        if (fail) vm.expectRevert(BurnerCreditVault.WithdrawalUnavailable.selector);
        burner.pull(address(vault), asset);
        if (fail) {
            assertEq(vault.credits(asset), credit);
            assertEq(_balance(asset, address(burner)), before_);
        } else {
            ++pulls;
            assertEq(vault.credits(asset), 0);
            assertEq(_balance(asset, address(burner)), before_ + credit);
        }
    }

    function forward(uint256 assetSeed) public {
        address asset = assets[assetSeed % 3];
        address recipient = burner.buybackWallet();
        uint256 before_ = _balance(asset, address(burner));
        uint256 toBefore = _balance(asset, recipient);
        uint256 sentBefore = burner.forwarded(asset);
        if (before_ == 0) vm.expectRevert(BuybackBurner.Nothing.selector);
        else if (asset == address(0) && recipient == wallets[2]) vm.expectRevert(BuybackBurner.EthSendFailed.selector);
        burner.forward(asset);
        if (before_ == 0 || (asset == address(0) && recipient == wallets[2])) {
            assertEq(_balance(asset, address(burner)), before_);
            assertEq(_balance(asset, recipient), toBefore);
            assertEq(burner.forwarded(asset), sentBefore, "failed push cannot advance accounting");
        } else {
            ++sends;
            assertEq(_balance(asset, address(burner)), 0);
            assertEq(_balance(asset, recipient) - toBefore, before_);
            assertEq(burner.forwarded(asset) - sentBefore, before_);
        }
    }

    function burn() public {
        uint256 before_ = IERC20(assets[3]).balanceOf(address(burner));
        if (before_ == 0) vm.expectRevert(BuybackBurner.Nothing.selector);
        burner.burnYolo();
        burned += before_;
        assertEq(IERC20(assets[3]).balanceOf(address(burner)), 0);
    }

    function forbiddenYoloForward() external {
        vm.expectRevert(BuybackBurner.NotReserve.selector);
        burner.forward(assets[3]);
    }

    function _balance(address asset, address account) internal view returns (uint256) {
        return asset == address(0) ? account.balance : IERC20(asset).balanceOf(account);
    }
}

/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 128
/// forge-config: default.invariant.fail-on-revert = true
contract BuybackBurnerStatefulTest is Test {
    address internal constant DEV = 0x8Ad18E99F4C8d8406f9Ba8899CF308000518A981;
    address internal constant BUYBACK = 0x027E55f01e8Cf808E5D2a2Ad68E5e7f67fD6dF6E;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    YoloToken internal yolo;
    MockERC20 internal usdc;
    MockERC20 internal imd;
    DevPrices internal prices;
    BuybackBurner internal burner;
    BurnerCreditVault internal vault;
    BurnerHandler internal handler;

    function setUp() public {
        yolo =
            new YoloToken(makeAddr("burner pool"), makeAddr("absent gate"), makeAddr("token treasury"), 1_792_584_000);
        usdc = new MockERC20("USDC", "USDC", 6);
        imd = new MockERC20("IMD", "IMD", 18);
        prices = new DevPrices(DEV, address(usdc), address(imd), address(yolo), 1e15, 2400e18, 5.5e18);
        burner = new BuybackBurner(address(yolo), address(imd), address(usdc), address(prices), BUYBACK);
        vault = new BurnerCreditVault(address(burner));
        handler = new BurnerHandler(burner, vault, DEV, makeAddr("second buyback"), address(new BurnerRejectsEth()));
        yolo.transfer(address(handler), yolo.totalSupply());
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.rotateWallet.selector;
        selectors[2] = handler.unauthorizedRotation.selector;
        selectors[3] = handler.pull.selector;
        selectors[4] = handler.forward.selector;
        selectors[5] = handler.burn.selector;
        selectors[6] = handler.forbiddenYoloForward.selector;
        selectors[7] = handler.deposit.selector; // Exercise funding as frequently as draining.
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_ReservesAreHeldCreditedOrPaidOnlyToBuybackWallets() public view {
        for (uint256 i; i < 3; ++i) {
            address asset = handler.assets(i);
            uint256 paid;
            for (uint256 j; j < 3; ++j) {
                paid += _balance(asset, handler.wallets(j));
            }
            assertEq(burner.forwarded(asset), paid, "forwarded counter matches actual destination receipts");
            assertEq(handler.donated(i), _balance(asset, address(burner)) + vault.credits(asset) + paid);
            assertEq(_balance(asset, address(vault)), vault.credits(asset), "credit is backed");
            assertEq(_balance(asset, address(handler)), 0, "no caller reward or residual funding");
        }
    }

    function invariant_YoloCanOnlyWaitOrReachDeadWithoutChangingSupply() public view {
        assertEq(handler.donated(3), yolo.balanceOf(address(burner)) + vault.credits(address(yolo)) + handler.burned());
        assertEq(yolo.balanceOf(DEAD), handler.burned());
        assertEq(yolo.balanceOf(address(vault)), vault.credits(address(yolo)));
        assertEq(yolo.balanceOf(address(handler)) + handler.donated(3), 1_000_000_000e18);
        assertEq(yolo.totalSupply(), 1_000_000_000e18, "burning means transfer to DEAD, not a supply burn");
        assertEq(burner.forwarded(address(yolo)), 0);
        for (uint256 j; j < 3; ++j) {
            assertEq(yolo.balanceOf(handler.wallets(j)), 0);
        }
    }

    function test_HandlerRecoveryAfterFailedPushAndPull() public {
        handler.deposit(0, 1 ether, true);
        handler.pull(0, true);
        handler.pull(0, false);
        handler.rotateWallet(2);
        handler.forward(0);
        handler.rotateWallet(1);
        handler.forward(0);
        handler.deposit(1, 50e6, false);
        handler.forward(1);
        handler.deposit(2, 10e18, true);
        handler.pull(2, false);
        handler.forward(2);
        handler.deposit(3, 100e18, true);
        handler.pull(3, false);
        handler.burn();
        handler.burn(); // Nothing, checked by the handler.
        assertEq(handler.sends(), 3);
        assertEq(handler.pulls(), 3);
        invariant_ReservesAreHeldCreditedOrPaidOnlyToBuybackWallets();
        invariant_YoloCanOnlyWaitOrReachDeadWithoutChangingSupply();
    }

    function test_BlockedReserveTransferRestoresForwardedAndCanBeRetried() public {
        usdc.mint(address(burner), 100e6);
        usdc.setBlocked(BUYBACK, true);
        vm.expectRevert(bytes("blocked"));
        burner.forward(address(usdc));
        assertEq(burner.forwarded(address(usdc)), 0);
        assertEq(usdc.balanceOf(address(burner)), 100e6);
        usdc.setBlocked(BUYBACK, false);
        assertEq(burner.forward(address(usdc)), 100e6);
        assertEq(burner.forwarded(address(usdc)), 100e6);
        assertEq(usdc.balanceOf(BUYBACK), 100e6);
    }

    function test_ChangingDevRequiresAcceptedOwnershipAndRevokesOldDev() public {
        address nextDev = makeAddr("next price owner");
        vm.prank(DEV);
        prices.transferOwnership(nextDev);
        vm.expectRevert(BuybackBurner.NotDev.selector);
        vm.prank(nextDev);
        burner.setBuybackWallet(nextDev);
        vm.prank(nextDev);
        prices.acceptOwnership();
        vm.expectRevert(BuybackBurner.NotDev.selector);
        vm.prank(DEV);
        burner.setBuybackWallet(DEV);
        vm.prank(nextDev);
        burner.setBuybackWallet(nextDev);
        assertEq(burner.buybackWallet(), nextDev);
    }

    function _balance(address asset, address account) internal view returns (uint256) {
        return asset == address(0) ? account.balance : IERC20(asset).balanceOf(account);
    }
}
