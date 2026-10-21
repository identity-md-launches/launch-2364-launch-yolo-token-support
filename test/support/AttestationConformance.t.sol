// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {OracleAttestation} from "src/OracleAttestation.sol";
import {AttestationChecker} from "src/helpers/AttestationChecker.sol";
import {ParamsRegistry} from "src/ParamsRegistry.sol";
import {ITaskVault} from "src/interfaces/ITaskVault.sol";

/// @dev Vector constants copied from the supplied oracle-consumer conformance reference.
/// The vector binds the digest to an independently generated protocol signature, not just vm.sign of our own hash.
contract SupportAttestationConformanceTest is Test {
    uint256 internal constant VECTOR_CHAIN = 11155111;
    address internal constant VECTOR_CONSUMER = 0x0000000000000000000000000000000000002748;
    bytes32 internal constant VECTOR_DIGEST = 0x95fefa8b7c529852f4e2b6aec888930eb2bf5078e6443a85808e36df19e1325c;
    bytes internal constant VECTOR_SIGNATURE =
        hex"a26b14918607eb565af126beb54d3c5d19e923c41506def500b3521a4f9aa6d603ab44fd22f15dd2191732961a7131e4641244add8b0f09f20e6ae64381be8481b";
    address internal constant SIGNER = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    // Public protocol test-vector key; not a deployment credential.
    uint256 internal constant SIGNER_KEY = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint64 internal constant ISSUED_AT = 1800000000;
    uint64 internal constant EXPIRES_AT = 1800003600;
    ParamsRegistry internal registry;
    AttestationChecker internal checker;

    function setUp() public {
        vm.chainId(VECTOR_CHAIN);
        vm.warp(ISSUED_AT);
        registry = ParamsRegistry(
            deployCode(
                "ParamsRegistry.sol:ParamsRegistry",
                abi.encode(
                    address(this),
                    makeAddr("intake"),
                    makeAddr("dev prices"),
                    makeAddr("adapter"),
                    makeAddr("nft"),
                    makeAddr("delegates"),
                    makeAddr("treasury"),
                    SIGNER
                )
            )
        );
        checker = new AttestationChecker(address(registry));
    }

    function _vector() internal pure returns (OracleAttestation.Attestation memory a) {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = bytes32(uint256(1));
        a = OracleAttestation.Attestation({
            requestId: 0x0000000000004000800000000000000100000000000000000000000000000000,
            chainId: 1,
            questionHash: 0x2117f4362ebfa37aa8a8c0fed548604fe09ac46faf8ae7559cd64780f26a46fb,
            answerType: 5, // protocol ANSWER_BYTES32_LIST; the project's library names only ANSWER_BOOL
            answer: abi.encode(ids),
            figure: 12345,
            fromBlock: 100,
            toBlock: 200,
            blockHash: bytes32(uint256(7)),
            panelJobId: 0x0000000000004000800000000000000200000000000000000000000000000000,
            panelSize: 5,
            quorum: 4,
            agreed: 5,
            issuedAt: ISSUED_AT,
            expiresAt: EXPIRES_AT
        });
    }

    function _boolAnswer(bool answer) internal pure returns (OracleAttestation.Attestation memory a) {
        a = _vector();
        a.answerType = 0;
        a.answer = abi.encode(answer);
        a.panelSize = 7;
        a.quorum = 5;
        a.agreed = 5;
    }

    function _sign(OracleAttestation.Attestation memory a) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, checker.digest(VECTOR_CONSUMER, a));
        return abi.encodePacked(r, s, v);
    }

    function test_DigestAndSignatureMatchIndependentProtocolVector() public view {
        bytes32 digest = checker.digest(VECTOR_CONSUMER, _vector());
        assertEq(digest, VECTOR_DIGEST, "struct, type hash and consumer domain must match the protocol");
        assertEq(ECDSA.recover(digest, VECTOR_SIGNATURE), SIGNER);
        assertEq(
            checker.check(VECTOR_CONSUMER, 3, 3, _vector(), VECTOR_SIGNATURE), 2, "this application accepts bool only"
        );
    }

    function test_CoreCallbackUsesTheCanonicalFifteenFieldStruct() public pure {
        assertEq(
            ITaskVault.onOracleResult.selector,
            bytes4(
                keccak256(
                    bytes(
                        "onOracleResult(bytes32,(bytes32,uint256,bytes32,uint8,bytes,uint256,uint64,uint64,bytes32,bytes32,uint16,uint16,uint16,uint64,uint64),bytes)"
                    )
                )
            )
        );
    }

    function test_BothYesAndNoAreValidSignedResultsWithinCallbackGasBudget() public {
        for (uint256 i; i < 2; ++i) {
            OracleAttestation.Attestation memory a = _boolAnswer(i == 1);
            bytes memory signature = _sign(a);
            (bool ok, bytes memory result) = address(checker).staticcall{gas: 200_000}(
                abi.encodeCall(checker.check, (VECTOR_CONSUMER, 7, 5, a, signature))
            );
            assertTrue(ok, "verification fits the oracle callback stipend");
            assertEq(abi.decode(result, (uint8)), 0);
        }
    }

    function test_SignatureIsBoundToConsumerAndConsumerChain() public {
        OracleAttestation.Attestation memory a = _boolAnswer(true);
        bytes memory signature = _sign(a);
        assertEq(checker.check(makeAddr("another consumer"), 7, 5, a, signature), 5);
        vm.chainId(1);
        assertEq(checker.check(VECTOR_CONSUMER, 7, 5, a, signature), 5);
        vm.chainId(VECTOR_CHAIN);
        assertEq(checker.check(VECTOR_CONSUMER, 7, 5, a, signature), 0);
    }

    function test_EveryAttestationFieldIsCoveredBySignature() public {
        bytes memory signature = _sign(_boolAnswer(true));
        for (uint256 i; i < 15; ++i) {
            OracleAttestation.Attestation memory a = _boolAnswer(true);
            if (i == 0) a.requestId ^= bytes32(uint256(1));
            else if (i == 1) ++a.chainId;
            else if (i == 2) a.questionHash ^= bytes32(uint256(1));
            else if (i == 3) a.answerType = 3;
            else if (i == 4) a.answer = abi.encode(false);
            else if (i == 5) ++a.figure;
            else if (i == 6) ++a.fromBlock;
            else if (i == 7) ++a.toBlock;
            else if (i == 8) a.blockHash ^= bytes32(uint256(1));
            else if (i == 9) a.panelJobId ^= bytes32(uint256(1));
            else if (i == 10) ++a.panelSize;
            else if (i == 11) --a.quorum;
            else if (i == 12) ++a.agreed;
            else if (i == 13) --a.issuedAt;
            else ++a.expiresAt;
            assertEq(checker.check(VECTOR_CONSUMER, 3, 3, a, signature), i == 3 ? 2 : 5, vm.toString(i));
        }
    }

    function test_NoncanonicalBoolEncodingAndLengthAreRejected() public view {
        OracleAttestation.Attestation memory a = _boolAnswer(true);
        a.answer = abi.encode(uint256(2));
        assertEq(checker.check(VECTOR_CONSUMER, 7, 5, a, _sign(a)), 2);
        a.answer = hex"01";
        assertEq(checker.check(VECTOR_CONSUMER, 7, 5, a, _sign(a)), 2);
        a.answer = bytes.concat(abi.encode(true), hex"00");
        assertEq(checker.check(VECTOR_CONSUMER, 7, 5, a, _sign(a)), 2);
        a.answer = "";
        assertEq(checker.check(VECTOR_CONSUMER, 7, 5, a, _sign(a)), 2);
    }

    function test_SignedButInvalidPanelCountsAreRefused() public view {
        for (uint256 i; i < 5; ++i) {
            OracleAttestation.Attestation memory a = _boolAnswer(true);
            if (i == 0) a.panelSize = 6;
            if (i == 1) a.quorum = 4;
            if (i == 2) a.quorum = 8;
            if (i == 3) a.agreed = 4;
            if (i == 4) a.agreed = 8;
            assertEq(checker.check(VECTOR_CONSUMER, 7, 5, a, _sign(a)), 4);
        }
    }

    function test_PositiveExpiryBoundaryAndMalformedSignatures() public {
        OracleAttestation.Attestation memory a = _boolAnswer(false);
        bytes memory signature = _sign(a);
        vm.warp(EXPIRES_AT);
        assertEq(checker.check(VECTOR_CONSUMER, 7, 5, a, signature), 0);
        assertEq(checker.check(VECTOR_CONSUMER, 7, 5, a, ""), 5);
        assertEq(checker.check(VECTOR_CONSUMER, 7, 5, a, new bytes(65)), 5);
        vm.warp(EXPIRES_AT + 1);
        assertEq(checker.check(VECTOR_CONSUMER, 7, 5, a, signature), 6);
    }

    function test_GlobalSignerRotationRejectsPreviouslyValidUnexpiredSignature() public {
        OracleAttestation.Attestation memory a = _boolAnswer(true);
        a.expiresAt = ISSUED_AT + 3 days;
        bytes memory signature = _sign(a);
        address replacement = makeAddr("replacement attester");
        registry.proposeAttester(replacement, true);
        registry.proposeAttester(SIGNER, false);
        vm.warp(ISSUED_AT + 48 hours - 1);
        assertEq(checker.check(VECTOR_CONSUMER, 7, 5, a, signature), 0);
        vm.warp(ISSUED_AT + 48 hours);
        registry.executeAttester(replacement, true);
        registry.executeAttester(SIGNER, false);
        assertEq(checker.check(VECTOR_CONSUMER, 7, 5, a, signature), 5);
    }
}
