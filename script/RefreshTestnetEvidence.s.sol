// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.17;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {Governed} from "../src/auth/Governed.sol";
import {QualifiedPurchaser} from "../src/compliance/elements/QualifiedPurchaser.sol";
import {AttestedAcquisitionSource} from "../src/registry/AttestedAcquisitionSource.sol";
import {IAcquisitionSource} from "../src/interfaces/compliance/IAcquisitionSource.sol";
import {LookThroughStatus} from "../src/interfaces/compliance/ILookThroughSource.sol";

abstract contract TestnetEvidenceRefreshBase is Script {
    string internal constant ACTIVATION_MODE = "public-testnet-reference-fixture";

    struct Context {
        address operator;
        address subject;
        address rwaToken;
        address qualifiedPurchaser;
        address acquisitionSource;
    }

    struct Actions {
        bool qpSelected;
        bool qpQualified;
        bool acquisitionSelected;
        uint64 clockStart;
        uint64 expiresAt;
        bytes32 sourceRef;
        IAcquisitionSource.AcquisitionStatus status;
    }

    function _load() internal view returns (Context memory context, Actions memory actions) {
        string memory artifactPath = vm.envString("CORNER_STORE_ARTIFACT");
        string memory json = vm.readFile(artifactPath);
        address subject = vm.envAddress("CORNER_STORE_EVIDENCE_SUBJECT");
        string memory qpAction = vm.envOr("CORNER_STORE_EVIDENCE_QP_ACTION", string(""));
        string memory acquisitionStatus = vm.envOr("CORNER_STORE_EVIDENCE_ACQUISITION_STATUS", string(""));

        context = _loadContext(json, subject);
        _parseQpAction(qpAction, actions);

        if (bytes(acquisitionStatus).length != 0) {
            actions.acquisitionSelected = true;
            actions.clockStart = _envUint64("CORNER_STORE_EVIDENCE_CLOCK_START");
            actions.expiresAt = _envUint64("CORNER_STORE_EVIDENCE_EXPIRES_AT");
            actions.sourceRef = vm.envBytes32("CORNER_STORE_EVIDENCE_SOURCE_REF");
            if (_equals(acquisitionStatus, "valid")) {
                actions.status = IAcquisitionSource.AcquisitionStatus.VALID;
            } else {
                require(_equals(acquisitionStatus, "lineage-broken"), "acquisition status invalid");
                actions.status = IAcquisitionSource.AcquisitionStatus.LINEAGE_BROKEN;
            }
            _validateAcquisition(actions, block.timestamp);
        }

        _requireAction(actions);
        _validateTargets(context, actions);
    }

    function _loadContext(string memory json, address subject) internal view returns (Context memory context) {
        require(vm.parseJsonUint(json, ".schemaVersion") == 1, "artifact schema version invalid");
        require(
            keccak256(bytes(vm.parseJsonString(json, ".activationMode"))) == keccak256(bytes(ACTIVATION_MODE)),
            "artifact activation mode invalid"
        );
        require(!vm.parseJsonBool(json, ".productionDeployment"), "production artifact is not supported");
        require(vm.parseJsonUint(json, ".chainId") == block.chainid, "artifact chain id mismatch");

        context = Context({
            operator: vm.parseJsonAddress(json, ".operator"),
            subject: subject,
            rwaToken: vm.parseJsonAddress(json, ".rwaToken"),
            qualifiedPurchaser: vm.parseJsonAddress(json, ".qualifiedPurchaser"),
            acquisitionSource: vm.parseJsonAddress(json, ".acquisitionSource")
        });
        _requireFixtureSubject(json, subject);
    }

    function _parseQpAction(string memory qpAction, Actions memory actions) internal pure {
        if (bytes(qpAction).length != 0) {
            actions.qpSelected = true;
            if (_equals(qpAction, "qualified")) {
                actions.qpQualified = true;
            } else {
                require(_equals(qpAction, "clear"), "QP action must be qualified or clear");
            }
        }
    }

    function _requireAction(Actions memory actions) internal pure {
        require(actions.qpSelected || actions.acquisitionSelected, "at least one action is required");
    }

    function _requireFixtureSubject(string memory json, address subject) internal view {
        require(subject != address(0), "subject is zero");
        bool allowed = subject == vm.parseJsonAddress(json, ".maker")
            || subject == vm.parseJsonAddress(json, ".investor")
            || subject == vm.parseJsonAddress(json, ".eligibleInvestorB")
            || subject == vm.parseJsonAddress(json, ".ineligibleInvestor");
        if (vm.keyExistsJson(json, ".expiredInvestor")) {
            address expiredInvestor = vm.parseJsonAddress(json, ".expiredInvestor");
            allowed = allowed || (expiredInvestor != address(0) && subject == expiredInvestor);
        }
        require(allowed, "subject is not an artifact participant");
    }

    function _validateTargets(Context memory context, Actions memory actions) internal view {
        require(context.operator != address(0), "artifact operator is zero");
        require(context.rwaToken != address(0) && context.rwaToken.code.length > 0, "RWA token has no code");
        if (actions.qpSelected) {
            _requireAuthorized(context.qualifiedPurchaser, context.operator, "QP target");
        }
        if (actions.acquisitionSelected) {
            _requireAuthorized(context.acquisitionSource, context.operator, "acquisition target");
        }
    }

    function _requireAuthorized(address target, address operator, string memory label) internal view {
        require(target != address(0) && target.code.length > 0, string.concat(label, " has no code"));
        Governed governed = Governed(target);
        require(
            governed.owner() == operator || governed.isOperator(operator),
            string.concat(label, " operator unauthorized")
        );
    }

    function _validateAcquisition(Actions memory actions, uint256 timestamp) internal pure {
        require(actions.status != IAcquisitionSource.AcquisitionStatus.MISSING, "MISSING acquisition is not supported");
        require(actions.expiresAt > timestamp, "acquisition expiry must be in the future");
        require(actions.sourceRef != bytes32(0), "acquisition sourceRef is zero");
        if (actions.status == IAcquisitionSource.AcquisitionStatus.VALID) {
            require(actions.clockStart != 0 && actions.clockStart <= timestamp, "VALID acquisition clock invalid");
        } else {
            require(actions.clockStart == 0, "LINEAGE_BROKEN clock must be zero");
        }
    }

    function _equals(string memory left, string memory right) internal pure returns (bool) {
        return keccak256(bytes(left)) == keccak256(bytes(right));
    }

    function _envUint64(string memory name) internal view returns (uint64 value) {
        uint256 raw = vm.envUint(name);
        require(raw <= type(uint64).max, "evidence timestamp exceeds uint64");
        value = uint64(raw);
    }

    function _verifyEvidence(Context memory context, Actions memory actions) internal view {
        if (actions.qpSelected) {
            QualifiedPurchaser qp = QualifiedPurchaser(context.qualifiedPurchaser);
            (
                QualifiedPurchaser.QpBasis basis,
                bool signatureValid,
                bool issuerTrusted,
                uint64 verifiedAt,
                LookThroughStatus ltStatus,
                bytes32 coveredCompany
            ) = qp.claimOf(context.subject);
            if (actions.qpQualified) {
                require(qp.qp(context.subject), "QP result is not qualified");
                require(basis == QualifiedPurchaser.QpBasis.NATURAL, "QP basis mismatch");
                require(signatureValid && issuerTrusted, "QP attestation shape mismatch");
                require(verifiedAt != 0 && verifiedAt <= block.timestamp, "QP verifiedAt invalid");
                require(ltStatus == LookThroughStatus.NONE, "QP look-through status mismatch");
                require(coveredCompany == bytes32(0), "QP covered company mismatch");
            } else {
                require(!qp.qp(context.subject), "QP result was not cleared");
                require(basis == QualifiedPurchaser.QpBasis.NONE, "cleared QP basis mismatch");
                require(!signatureValid && !issuerTrusted && verifiedAt == 0, "cleared QP claim mismatch");
                require(ltStatus == LookThroughStatus.NONE && coveredCompany == bytes32(0), "cleared QP shape mismatch");
            }
        }

        if (actions.acquisitionSelected) {
            IAcquisitionSource.AcquisitionSnapshot memory snapshot =
                AttestedAcquisitionSource(context.acquisitionSource).acquisitionOf(context.subject, context.rwaToken);
            require(snapshot.clockStart == actions.clockStart, "acquisition clockStart mismatch");
            require(snapshot.expiresAt == actions.expiresAt, "acquisition expiresAt mismatch");
            require(snapshot.sourceRef == actions.sourceRef, "acquisition sourceRef mismatch");
            require(snapshot.status == actions.status, "acquisition status mismatch");
            require(
                snapshot.observedAt != 0 && snapshot.observedAt <= block.timestamp, "acquisition observedAt invalid"
            );
        }
    }
}

/// @title RefreshTestnetEvidence
/// @notice Refreshes only QP and acquisition evidence for an existing public-testnet fixture participant.
contract RefreshTestnetEvidence is TestnetEvidenceRefreshBase {
    function run() external {
        (Context memory context, Actions memory actions) = _load();

        vm.startBroadcast();
        if (actions.qpSelected) {
            QualifiedPurchaser(context.qualifiedPurchaser).setQp(context.subject, actions.qpQualified);
        }
        if (actions.acquisitionSelected) {
            AttestedAcquisitionSource(context.acquisitionSource)
                .setSnapshot(
                    context.subject,
                    context.rwaToken,
                    actions.clockStart,
                    actions.expiresAt,
                    actions.sourceRef,
                    actions.status
                );
        }
        vm.stopBroadcast();

        console2.log("Corner Store public-testnet evidence refresh simulated or submitted");
        console2.log("subject:", context.subject);
    }
}

/// @title VerifyTestnetEvidenceRefresh
/// @notice Separately verifies the exact selected evidence after a broadcast.
contract VerifyTestnetEvidenceRefresh is TestnetEvidenceRefreshBase {
    function run() external view {
        (Context memory context, Actions memory actions) = _load();
        _verifyEvidence(context, actions);

        console2.log("Corner Store public-testnet evidence refresh verified");
        console2.log("subject:", context.subject);
    }
}
