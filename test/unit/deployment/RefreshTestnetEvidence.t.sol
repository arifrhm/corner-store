// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.17;

import {Test} from "forge-std/Test.sol";
import {TestnetEvidenceRefreshBase} from "../../../script/RefreshTestnetEvidence.s.sol";
import {QualifiedPurchaser} from "../../../src/compliance/elements/QualifiedPurchaser.sol";
import {AttestedAcquisitionSource} from "../../../src/registry/AttestedAcquisitionSource.sol";
import {IAcquisitionSource} from "../../../src/interfaces/compliance/IAcquisitionSource.sol";

contract EvidenceRefreshHarness is TestnetEvidenceRefreshBase {
    function loadQp(string memory json, address subject, string memory qpAction)
        external
        view
        returns (Context memory context, Actions memory actions)
    {
        context = _loadContext(json, subject);
        _parseQpAction(qpAction, actions);
        _requireAction(actions);
        _validateTargets(context, actions);
    }

    function loadAcquisition(string memory json, address subject)
        external
        view
        returns (Context memory context, Actions memory actions)
    {
        context = _loadContext(json, subject);
        actions.acquisitionSelected = true;
        _validateTargets(context, actions);
    }

    function validateAcquisition(Actions memory actions, uint256 timestamp) external pure {
        _validateAcquisition(actions, timestamp);
    }

    function verifyEvidence(Context memory context, Actions memory actions) external view {
        _verifyEvidence(context, actions);
    }
}

contract RefreshTestnetEvidenceTest is Test {
    address internal constant OPERATOR = address(0xA11CE);
    address internal constant MAKER = address(0x1001);
    address internal constant INVESTOR = address(0x1002);
    address internal constant INVESTOR_B = address(0x1003);
    address internal constant INELIGIBLE = address(0x1004);
    address internal constant EXPIRED = address(0x1005);
    address internal constant OUTSIDER = address(0x9999);

    EvidenceRefreshHarness internal harness;
    QualifiedPurchaser internal qp;
    AttestedAcquisitionSource internal acquisition;

    function setUp() public {
        harness = new EvidenceRefreshHarness();
        qp = new QualifiedPurchaser();
        acquisition = new AttestedAcquisitionSource();
        qp.setOperator(OPERATOR, true);
        acquisition.setOperator(OPERATOR, true);
    }

    function test_load_acceptsEveryNamedNonzeroFixtureParticipant() public {
        string memory json = _validArtifact(EXPIRED);
        address[5] memory participants = [MAKER, INVESTOR, INVESTOR_B, INELIGIBLE, EXPIRED];
        for (uint256 i = 0; i < participants.length; i++) {
            (TestnetEvidenceRefreshBase.Context memory context,) = harness.loadQp(json, participants[i], "qualified");
            assertEq(context.subject, participants[i]);
        }
    }

    function test_load_rejectsAbsentOrZeroOptionalExpiredInvestor() public {
        vm.expectRevert("subject is not an artifact participant");
        harness.loadQp(_validArtifact(address(0)), EXPIRED, "qualified");
    }

    function test_load_rejectsOutsider() public {
        vm.expectRevert("subject is not an artifact participant");
        harness.loadQp(_validArtifact(EXPIRED), OUTSIDER, "qualified");
    }

    function test_load_rejectsArtifactBoundaryMismatches() public {
        vm.expectRevert("artifact schema version invalid");
        harness.loadQp(
            _artifact(2, "public-testnet-reference-fixture", false, block.chainid, address(qp)), INVESTOR, "qualified"
        );
        vm.expectRevert("artifact activation mode invalid");
        harness.loadQp(_artifact(1, "other", false, block.chainid, address(qp)), INVESTOR, "qualified");
        vm.expectRevert("production artifact is not supported");
        harness.loadQp(
            _artifact(1, "public-testnet-reference-fixture", true, block.chainid, address(qp)), INVESTOR, "qualified"
        );
        vm.expectRevert("artifact chain id mismatch");
        harness.loadQp(
            _artifact(1, "public-testnet-reference-fixture", false, block.chainid + 1, address(qp)),
            INVESTOR,
            "qualified"
        );
    }

    function test_load_rejectsMissingCodeAndOperatorAuthorization() public {
        vm.expectRevert("QP target has no code");
        harness.loadQp(
            _artifact(1, "public-testnet-reference-fixture", false, block.chainid, address(0xBEEF)),
            INVESTOR,
            "qualified"
        );
        QualifiedPurchaser unauthorized = new QualifiedPurchaser();
        vm.expectRevert("QP target operator unauthorized");
        harness.loadQp(
            _artifact(1, "public-testnet-reference-fixture", false, block.chainid, address(unauthorized)),
            INVESTOR,
            "qualified"
        );
    }

    function test_load_rejectsAcquisitionMissingCodeAndOperatorAuthorization() public {
        AttestedAcquisitionSource unauthorized = new AttestedAcquisitionSource();
        vm.expectRevert("acquisition target operator unauthorized");
        harness.loadAcquisition(_artifactWithAcquisition(address(unauthorized)), INVESTOR);

        vm.expectRevert("acquisition target has no code");
        harness.loadAcquisition(_artifactWithAcquisition(address(0xBEEF)), INVESTOR);
    }

    function test_load_rejectsNoActionAndMalformedAction() public {
        string memory json = _validArtifact(EXPIRED);
        vm.expectRevert("at least one action is required");
        harness.loadQp(json, INVESTOR, "");
        vm.expectRevert("QP action must be qualified or clear");
        harness.loadQp(json, INVESTOR, "yes");
    }

    function test_validateAcquisition_acceptsExistingValidSemantics() public view {
        harness.validateAcquisition(
            _actions(900, 1_100, bytes32(uint256(1)), IAcquisitionSource.AcquisitionStatus.VALID), 1_000
        );
        harness.validateAcquisition(
            _actions(0, 1_100, bytes32(uint256(1)), IAcquisitionSource.AcquisitionStatus.LINEAGE_BROKEN), 1_000
        );
    }

    function test_validateAcquisition_rejectsInvalidSemantics() public {
        vm.expectRevert("MISSING acquisition is not supported");
        harness.validateAcquisition(
            _actions(0, 1_100, bytes32(uint256(1)), IAcquisitionSource.AcquisitionStatus.MISSING), 1_000
        );
        vm.expectRevert("acquisition expiry must be in the future");
        harness.validateAcquisition(
            _actions(900, 1_000, bytes32(uint256(1)), IAcquisitionSource.AcquisitionStatus.VALID), 1_000
        );
        vm.expectRevert("acquisition sourceRef is zero");
        harness.validateAcquisition(_actions(900, 1_100, bytes32(0), IAcquisitionSource.AcquisitionStatus.VALID), 1_000);
        vm.expectRevert("VALID acquisition clock invalid");
        harness.validateAcquisition(
            _actions(0, 1_100, bytes32(uint256(1)), IAcquisitionSource.AcquisitionStatus.VALID), 1_000
        );
        vm.expectRevert("VALID acquisition clock invalid");
        harness.validateAcquisition(
            _actions(1_001, 1_100, bytes32(uint256(1)), IAcquisitionSource.AcquisitionStatus.VALID), 1_000
        );
        vm.expectRevert("LINEAGE_BROKEN clock must be zero");
        harness.validateAcquisition(
            _actions(900, 1_100, bytes32(uint256(1)), IAcquisitionSource.AcquisitionStatus.LINEAGE_BROKEN), 1_000
        );
    }

    function test_setQpQualifiedAndClear_preserveLegacyApiShape() public {
        vm.startPrank(OPERATOR);
        qp.setQp(INVESTOR, true);
        assertTrue(qp.qp(INVESTOR));
        (QualifiedPurchaser.QpBasis basis, bool signatureValid, bool issuerTrusted, uint64 verifiedAt,,) =
            qp.claimOf(INVESTOR);
        assertEq(uint256(basis), uint256(QualifiedPurchaser.QpBasis.NATURAL));
        assertTrue(signatureValid);
        assertTrue(issuerTrusted);
        assertEq(verifiedAt, block.timestamp);
        qp.setQp(INVESTOR, false);
        vm.stopPrank();
        assertFalse(qp.qp(INVESTOR));
        (basis, signatureValid, issuerTrusted, verifiedAt,,) = qp.claimOf(INVESTOR);
        assertEq(uint256(basis), uint256(QualifiedPurchaser.QpBasis.NONE));
        assertFalse(signatureValid);
        assertFalse(issuerTrusted);
        assertEq(verifiedAt, 0);
    }

    function test_verifyEvidence_checksExactQpAndAcquisitionResults() public {
        vm.warp(1_000);
        bytes32 sourceRef = bytes32(uint256(123));
        vm.startPrank(OPERATOR);
        qp.setQp(INVESTOR, true);
        acquisition.setSnapshot(
            INVESTOR, address(qp), 900, 2_000, sourceRef, IAcquisitionSource.AcquisitionStatus.VALID
        );
        vm.stopPrank();

        TestnetEvidenceRefreshBase.Context memory context = TestnetEvidenceRefreshBase.Context({
            operator: OPERATOR,
            subject: INVESTOR,
            rwaToken: address(qp),
            qualifiedPurchaser: address(qp),
            acquisitionSource: address(acquisition)
        });
        TestnetEvidenceRefreshBase.Actions memory actions =
            _actions(900, 2_000, sourceRef, IAcquisitionSource.AcquisitionStatus.VALID);
        actions.qpSelected = true;
        actions.qpQualified = true;
        harness.verifyEvidence(context, actions);

        actions.sourceRef = bytes32(uint256(456));
        vm.expectRevert("acquisition sourceRef mismatch");
        harness.verifyEvidence(context, actions);

        actions.sourceRef = sourceRef;
        actions.qpQualified = false;
        vm.expectRevert("QP result was not cleared");
        harness.verifyEvidence(context, actions);
    }

    function _actions(
        uint64 clockStart,
        uint64 expiresAt,
        bytes32 sourceRef,
        IAcquisitionSource.AcquisitionStatus status
    ) private pure returns (TestnetEvidenceRefreshBase.Actions memory actions) {
        actions.acquisitionSelected = true;
        actions.clockStart = clockStart;
        actions.expiresAt = expiresAt;
        actions.sourceRef = sourceRef;
        actions.status = status;
    }

    function _validArtifact(address expiredInvestor) private returns (string memory) {
        return
            _artifactWithExpired(
                1, "public-testnet-reference-fixture", false, block.chainid, address(qp), expiredInvestor
            );
    }

    function _artifact(
        uint256 schemaVersion,
        string memory activationMode,
        bool productionDeployment,
        uint256 chainId,
        address qpAddress
    ) private returns (string memory) {
        return _artifactWithExpired(schemaVersion, activationMode, productionDeployment, chainId, qpAddress, EXPIRED);
    }

    function _artifactWithExpired(
        uint256 schemaVersion,
        string memory activationMode,
        bool productionDeployment,
        uint256 chainId,
        address qpAddress,
        address expiredInvestor
    ) private returns (string memory json) {
        string memory key = "evidence-refresh-test";
        vm.serializeUint(key, "schemaVersion", schemaVersion);
        vm.serializeString(key, "activationMode", activationMode);
        vm.serializeBool(key, "productionDeployment", productionDeployment);
        vm.serializeUint(key, "chainId", chainId);
        vm.serializeAddress(key, "operator", OPERATOR);
        vm.serializeAddress(key, "maker", MAKER);
        vm.serializeAddress(key, "investor", INVESTOR);
        vm.serializeAddress(key, "eligibleInvestorB", INVESTOR_B);
        vm.serializeAddress(key, "ineligibleInvestor", INELIGIBLE);
        if (expiredInvestor != address(0)) vm.serializeAddress(key, "expiredInvestor", expiredInvestor);
        vm.serializeAddress(key, "rwaToken", address(qp));
        vm.serializeAddress(key, "qualifiedPurchaser", qpAddress);
        json = vm.serializeAddress(key, "acquisitionSource", address(acquisition));
    }

    function _artifactWithAcquisition(address acquisitionAddress) private returns (string memory json) {
        string memory key = "evidence-refresh-acquisition-test";
        vm.serializeUint(key, "schemaVersion", 1);
        vm.serializeString(key, "activationMode", "public-testnet-reference-fixture");
        vm.serializeBool(key, "productionDeployment", false);
        vm.serializeUint(key, "chainId", block.chainid);
        vm.serializeAddress(key, "operator", OPERATOR);
        vm.serializeAddress(key, "maker", MAKER);
        vm.serializeAddress(key, "investor", INVESTOR);
        vm.serializeAddress(key, "eligibleInvestorB", INVESTOR_B);
        vm.serializeAddress(key, "ineligibleInvestor", INELIGIBLE);
        vm.serializeAddress(key, "rwaToken", address(qp));
        vm.serializeAddress(key, "qualifiedPurchaser", address(qp));
        json = vm.serializeAddress(key, "acquisitionSource", acquisitionAddress);
    }
}
