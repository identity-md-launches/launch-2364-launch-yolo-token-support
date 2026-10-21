// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {UniswapV3SwapAdapter, ISwapRouter02} from "src/adapters/UniswapV3SwapAdapter.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @dev Offline model of exactInput's payment, minimum-output and recipient semantics.
/// Does not model pool pricing, WETH wrapping, zero-input router-balance semantics, or live liquidity.
contract ExactInputPaymentProbe is ISwapRouter02 {
    uint256 public calls;
    uint256 public quote = 55e18;
    bytes public lastPath;
    address public lastRecipient;
    uint256 public lastInput;
    uint256 public lastMinimum;
    uint256 public lastValue;
    error TooLittleReceived();

    function exactInput(ExactInputParams calldata p) external payable returns (uint256) {
        ++calls;
        lastPath = p.path;
        lastRecipient = p.recipient;
        lastInput = p.amountIn;
        lastMinimum = p.amountOutMinimum;
        lastValue = msg.value;
        if (msg.value == 0) {
            address input = address(bytes20(p.path[0:20]));
            require(IERC20(input).transferFrom(msg.sender, address(this), p.amountIn));
        } else {
            require(msg.value == p.amountIn);
        }
        // Check after payment to exercise rollback through the whole adapter/router call stack.
        if (quote < p.amountOutMinimum) revert TooLittleReceived();
        address output = address(bytes20(p.path[p.path.length - 20:]));
        require(IERC20(output).transfer(p.recipient, quote));
        return quote;
    }
}

contract SwapAdapterFailuresTest is Test {
    MockERC20 internal usdc;
    MockERC20 internal imd;
    ExactInputPaymentProbe internal router;
    UniswapV3SwapAdapter internal adapter;
    address internal weth;
    address internal recipient;
    bytes internal route;

    function setUp() public {
        vm.warp(1_792_584_000);
        usdc = new MockERC20("USDC", "USDC", 6);
        imd = new MockERC20("IMD", "IMD", 18);
        weth = makeAddr("router WETH");
        recipient = makeAddr("swap recipient");
        router = new ExactInputPaymentProbe();
        adapter = new UniswapV3SwapAdapter(router, weth);
        route = abi.encodePacked(address(usdc), uint24(3000), address(imd));
        usdc.mint(address(this), 1_000e6);
        imd.mint(address(router), 1_000e18);
        usdc.approve(address(adapter), type(uint256).max);
        vm.deal(address(this), 10 ether);
    }

    function test_ExactDeadlinePassesAndOnlySpecifiedRecipientReceivesOutput() public {
        uint256 returned =
            adapter.swapExactIn(address(usdc), address(imd), 100e6, 55e18, vm.getBlockTimestamp(), route, recipient);
        assertEq(returned, 55e18);
        assertEq(imd.balanceOf(recipient), 55e18);
        assertEq(imd.balanceOf(address(adapter)), 0);
        assertEq(imd.balanceOf(address(this)), 0);
        assertEq(usdc.balanceOf(address(this)), 900e6);
        assertEq(usdc.balanceOf(address(router)), 100e6);
        assertEq(usdc.balanceOf(address(adapter)), 0);
        assertEq(usdc.allowance(address(adapter), address(router)), 0, "router allowance is cleared");
        assertEq(router.lastPath(), route);
        assertEq(router.lastRecipient(), recipient);
        assertEq(router.lastInput(), 100e6);
        assertEq(router.lastMinimum(), 55e18);
        assertEq(router.lastValue(), 0);
    }

    function test_MultihopEthForwardsExactValueAndMinimum() public {
        bytes memory path = abi.encodePacked(weth, uint24(500), address(usdc), uint24(3000), address(imd));
        uint256 before_ = address(this).balance;
        adapter.swapExactIn{value: 0.1 ether}(
            address(0), address(imd), 0.1 ether, 54e18, vm.getBlockTimestamp(), path, recipient
        );
        assertEq(address(this).balance, before_ - 0.1 ether);
        assertEq(address(adapter).balance, 0);
        assertEq(address(router).balance, 0.1 ether);
        assertEq(router.lastValue(), 0.1 ether);
        assertEq(router.lastMinimum(), 54e18);
        assertEq(router.lastPath(), path);
        assertEq(imd.balanceOf(recipient), 55e18);
    }

    function test_ExpiredCallDoesNotTouchTokensOrRouter() public {
        vm.expectRevert(UniswapV3SwapAdapter.Expired.selector);
        adapter.swapExactIn(address(usdc), address(imd), 100e6, 1, vm.getBlockTimestamp() - 1, route, recipient);
        _unchanged();
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_MalformedPathLengthRejectsBeforePayment(uint256 seed) public {
        uint256 len = bound(seed, 0, 256);
        if (len >= 43 && (len - 20) % 23 == 0) ++len;
        vm.expectRevert(UniswapV3SwapAdapter.BadRoute.selector);
        adapter.swapExactIn(address(usdc), address(imd), 100e6, 1, vm.getBlockTimestamp(), new bytes(len), recipient);
        _unchanged();
    }

    function test_RouteEndpointsMustMatchBothDeclaredAssets() public {
        bytes memory wrongFirst = abi.encodePacked(weth, uint24(3000), address(imd));
        vm.expectRevert(UniswapV3SwapAdapter.BadRoute.selector);
        adapter.swapExactIn(address(usdc), address(imd), 100e6, 1, vm.getBlockTimestamp(), wrongFirst, recipient);
        bytes memory wrongLast = abi.encodePacked(address(usdc), uint24(3000), weth);
        vm.expectRevert(UniswapV3SwapAdapter.BadRoute.selector);
        adapter.swapExactIn(address(usdc), address(imd), 100e6, 1, vm.getBlockTimestamp(), wrongLast, recipient);
        vm.expectRevert(UniswapV3SwapAdapter.BadRoute.selector);
        adapter.swapExactIn{value: 1 ether}(
            address(0), address(imd), 1 ether, 1, vm.getBlockTimestamp(), route, recipient
        );
        _unchanged();
    }

    function test_Erc20InputRefusesUnexpectedEth() public {
        vm.expectRevert(UniswapV3SwapAdapter.BadValue.selector);
        adapter.swapExactIn{value: 1}(address(usdc), address(imd), 100e6, 1, vm.getBlockTimestamp(), route, recipient);
        _unchanged();
        assertEq(address(adapter).balance, 0);
    }

    function test_EthInputRefusesBothUnderpaymentAndOverpayment() public {
        bytes memory path = abi.encodePacked(weth, uint24(3000), address(imd));
        vm.expectRevert(UniswapV3SwapAdapter.BadValue.selector);
        adapter.swapExactIn{value: 1 ether - 1}(
            address(0), address(imd), 1 ether, 1, vm.getBlockTimestamp(), path, recipient
        );
        vm.expectRevert(UniswapV3SwapAdapter.BadValue.selector);
        adapter.swapExactIn{value: 1 ether + 1}(
            address(0), address(imd), 1 ether, 1, vm.getBlockTimestamp(), path, recipient
        );
        assertEq(address(this).balance, 10 ether);
        assertEq(address(adapter).balance, 0);
        assertEq(address(router).balance, 0);
        _unchanged();
    }

    function test_SlippageFailureRestoresUserFundsAndApprovalsThenRetryWorks() public {
        vm.expectRevert(ExactInputPaymentProbe.TooLittleReceived.selector);
        adapter.swapExactIn(address(usdc), address(imd), 100e6, 55e18 + 1, vm.getBlockTimestamp(), route, recipient);
        _unchanged();
        assertEq(usdc.allowance(address(this), address(adapter)), type(uint256).max);
        adapter.swapExactIn(address(usdc), address(imd), 100e6, 55e18, vm.getBlockTimestamp(), route, recipient);
        assertEq(usdc.balanceOf(address(this)), 900e6);
        assertEq(imd.balanceOf(recipient), 55e18);
        assertEq(usdc.allowance(address(adapter), address(router)), 0);
    }

    function test_PausedInputLeavesNoStrandedBalanceOrApproval() public {
        usdc.setBlocked(address(adapter), true);
        vm.expectRevert(bytes("blocked"));
        adapter.swapExactIn(address(usdc), address(imd), 100e6, 1, vm.getBlockTimestamp(), route, recipient);
        _unchanged();
        usdc.setBlocked(address(adapter), false);
        adapter.swapExactIn(address(usdc), address(imd), 100e6, 1, vm.getBlockTimestamp(), route, recipient);
        assertEq(imd.balanceOf(recipient), 55e18);
    }

    function _unchanged() internal view {
        assertEq(router.calls(), 0);
        assertEq(usdc.balanceOf(address(this)), 1_000e6);
        assertEq(usdc.balanceOf(address(adapter)), 0);
        assertEq(usdc.balanceOf(address(router)), 0);
        assertEq(imd.balanceOf(recipient), 0);
        assertEq(usdc.allowance(address(adapter), address(router)), 0);
    }
}
