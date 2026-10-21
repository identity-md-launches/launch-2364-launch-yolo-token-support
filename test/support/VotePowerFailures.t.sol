// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {VotePower} from "src/VotePower.sol";
import {IDelegateRegistry} from "src/interfaces/IDelegateRegistry.sol";
import {MockNFT} from "../mocks/MockNFT.sol";
import {MockDelegateRegistry} from "../mocks/MockDelegateRegistry.sol";

contract VotePowerFailuresTest is Test {
    MockNFT internal nft;
    MockDelegateRegistry internal delegates;
    VotePower internal power;
    address internal holder;
    address internal delegate;
    address internal nextHolder;

    function setUp() public {
        holder = makeAddr("vote holder");
        delegate = makeAddr("vote delegate");
        nextHolder = makeAddr("next NFT owner");
        nft = new MockNFT();
        delegates = new MockDelegateRegistry();
        power = new VotePower(address(nft), address(delegates));
        nft.mint(holder, 1);
        nft.mint(holder, 2);
    }

    function test_MissingNftAndRevertingOwnerLookupFailClosed() public {
        assertFalse(power.mayVote(holder, 3));
        vm.mockCallRevert(address(nft), abi.encodeWithSelector(nft.ownerOf.selector, 1), bytes("NFT unavailable"));
        assertFalse(power.mayVote(holder, 1));
        assertFalse(power.mayVote(delegate, 1));
    }

    function test_RevertingDelegationLookupDoesNotBlockActualOwner() public {
        vm.mockCallRevert(
            address(delegates),
            abi.encodeWithSelector(IDelegateRegistry.checkDelegateForERC721.selector),
            bytes("registry unavailable")
        );
        assertTrue(power.mayVote(holder, 1));
        assertFalse(power.mayVote(delegate, 1));
    }

    function test_TransferAndRevocationTakeEffectImmediatelyWithoutRegistration() public {
        vm.prank(holder);
        delegates.delegateAll(delegate, true);
        assertTrue(power.mayVote(delegate, 1));
        vm.prank(holder);
        nft.transferFrom(holder, nextHolder, 1);
        assertFalse(power.mayVote(holder, 1));
        assertFalse(power.mayVote(delegate, 1), "old owner's delegation no longer authorizes this NFT");
        assertTrue(power.mayVote(nextHolder, 1));
        vm.prank(nextHolder);
        delegates.delegateERC721(delegate, address(nft), 1, true);
        assertTrue(power.mayVote(delegate, 1));
        vm.prank(nextHolder);
        delegates.delegateERC721(delegate, address(nft), 1, false);
        assertFalse(power.mayVote(delegate, 1));
    }

    function test_TokenDelegationCannotAuthorizeAnotherIdOrCollection() public {
        vm.prank(holder);
        delegates.delegateERC721(delegate, address(nft), 1, true);
        assertTrue(power.mayVote(delegate, 1));
        assertFalse(power.mayVote(delegate, 2));
        MockNFT other = new MockNFT();
        other.mint(holder, 1);
        VotePower otherPower = new VotePower(address(other), address(delegates));
        assertFalse(otherPower.mayVote(delegate, 1));
    }

    function test_DisabledRegistryAllowsOwnerOnly() public {
        VotePower ownersOnly = new VotePower(address(nft), address(0));
        vm.prank(holder);
        delegates.delegateAll(delegate, true);
        assertTrue(ownersOnly.mayVote(holder, 1));
        assertFalse(ownersOnly.mayVote(delegate, 1));
        assertFalse(ownersOnly.mayVote(holder, 3));
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_FirstNotHeldReportsTheFirstFailingIndex(uint8 sizeSeed, uint8 badSeed) public view {
        uint256 size = bound(sizeSeed, 1, 32);
        uint256 bad = bound(badSeed, 0, size - 1);
        uint256[] memory ids = new uint256[](size);
        for (uint256 i; i < size; ++i) {
            ids[i] = 1;
        }
        assertEq(power.firstNotHeld(holder, ids), 0);
        ids[bad] = 3; // nonexistent NFT
        if (bad + 1 < size) ids[bad + 1] = 4;
        assertEq(power.firstNotHeld(holder, ids), bad + 1);
        assertEq(power.firstNotHeld(holder, new uint256[](0)), 0);
    }
}
