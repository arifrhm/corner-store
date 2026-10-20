#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"

RPC_URL=""
ARTIFACT=""
SUBJECT=""
QP_ACTION=""
ACQUISITION_STATUS=""
CLOCK_START=""
EXPIRES_AT=""
SOURCE_REF=""
ACCOUNT=""
KEYSTORE=""
PASSWORD_FILE=""
USE_LEDGER=0
BROADCAST=0

usage() {
  cat <<'EOF'
Usage:
  scripts/refresh-testnet-evidence.sh --rpc-url URL --artifact FILE --subject ADDRESS \
    [--qp qualified|clear] \
    [--acquisition-status valid|lineage-broken --clock-start UNIX \
      --expires-at UNIX --source-ref 0xBYTES32] \
    [--broadcast (--account NAME | --keystore FILE [--password-file FILE] | --ledger)]

The command is a simulation unless --broadcast is explicitly supplied. It only
updates evidence for a participant already named in the deployment artifact.
Signer material is handled by Foundry. Raw private keys are not accepted.
EOF
}

require_value() {
  if [[ -z "${2-}" ]]; then
    echo "ERROR: $1 requires a value" >&2
    exit 2
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rpc-url) require_value "$1" "${2-}"; RPC_URL="$2"; shift 2 ;;
    --artifact) require_value "$1" "${2-}"; ARTIFACT="$2"; shift 2 ;;
    --subject) require_value "$1" "${2-}"; SUBJECT="$2"; shift 2 ;;
    --qp) require_value "$1" "${2-}"; QP_ACTION="$2"; shift 2 ;;
    --acquisition-status) require_value "$1" "${2-}"; ACQUISITION_STATUS="$2"; shift 2 ;;
    --clock-start) require_value "$1" "${2-}"; CLOCK_START="$2"; shift 2 ;;
    --expires-at) require_value "$1" "${2-}"; EXPIRES_AT="$2"; shift 2 ;;
    --source-ref) require_value "$1" "${2-}"; SOURCE_REF="$2"; shift 2 ;;
    --account) require_value "$1" "${2-}"; ACCOUNT="$2"; shift 2 ;;
    --keystore) require_value "$1" "${2-}"; KEYSTORE="$2"; shift 2 ;;
    --password-file) require_value "$1" "${2-}"; PASSWORD_FILE="$2"; shift 2 ;;
    --ledger) USE_LEDGER=1; shift ;;
    --broadcast) BROADCAST=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$RPC_URL" ]] || { echo "ERROR: --rpc-url is required" >&2; exit 2; }
[[ -n "$ARTIFACT" ]] || { echo "ERROR: --artifact is required" >&2; exit 2; }
[[ -n "$SUBJECT" ]] || { echo "ERROR: --subject is required" >&2; exit 2; }
[[ -f "$ARTIFACT" ]] || { echo "ERROR: artifact does not exist: $ARTIFACT" >&2; exit 2; }
[[ -n "$QP_ACTION" || -n "$ACQUISITION_STATUS" ]] || {
  echo "ERROR: at least one of --qp or --acquisition-status is required" >&2
  exit 2
}
if [[ -n "$QP_ACTION" && "$QP_ACTION" != "qualified" && "$QP_ACTION" != "clear" ]]; then
  echo "ERROR: --qp must be qualified or clear" >&2
  exit 2
fi
if [[ -n "$ACQUISITION_STATUS" ]]; then
  [[ "$ACQUISITION_STATUS" == "valid" || "$ACQUISITION_STATUS" == "lineage-broken" ]] || {
    echo "ERROR: --acquisition-status must be valid or lineage-broken" >&2
    exit 2
  }
  [[ "$CLOCK_START" =~ ^[0-9]+$ ]] || { echo "ERROR: --clock-start must be an unsigned integer" >&2; exit 2; }
  [[ "$EXPIRES_AT" =~ ^[0-9]+$ ]] || { echo "ERROR: --expires-at must be an unsigned integer" >&2; exit 2; }
  [[ "$SOURCE_REF" =~ ^0x[0-9A-Fa-f]{64}$ ]] || { echo "ERROR: --source-ref must be a bytes32 hex value" >&2; exit 2; }
else
  [[ -z "$CLOCK_START" && -z "$EXPIRES_AT" && -z "$SOURCE_REF" ]] || {
    echo "ERROR: acquisition fields require --acquisition-status" >&2
    exit 2
  }
fi

SIGNER_COUNT=0
[[ -n "$ACCOUNT" ]] && SIGNER_COUNT=$((SIGNER_COUNT + 1))
[[ -n "$KEYSTORE" ]] && SIGNER_COUNT=$((SIGNER_COUNT + 1))
[[ "$USE_LEDGER" -eq 1 ]] && SIGNER_COUNT=$((SIGNER_COUNT + 1))
if [[ "$BROADCAST" -eq 1 && "$SIGNER_COUNT" -ne 1 ]]; then
  echo "ERROR: --broadcast requires exactly one of --account, --keystore or --ledger" >&2
  exit 2
fi
if [[ "$BROADCAST" -eq 0 && "$SIGNER_COUNT" -ne 0 ]]; then
  echo "ERROR: signer options require --broadcast" >&2
  exit 2
fi
if [[ -n "$PASSWORD_FILE" && -z "$KEYSTORE" ]]; then
  echo "ERROR: --password-file requires --keystore" >&2
  exit 2
fi

ARTIFACT_VALUES=$(node - "$ARTIFACT" "$SUBJECT" <<'NODE'
const fs = require("fs");
const [artifactPath, subjectInput] = process.argv.slice(2);
const fail = (message) => { throw new Error(message); };
const addressPattern = /^0x[0-9a-fA-F]{40}$/;
const artifact = JSON.parse(fs.readFileSync(artifactPath, "utf8"));
if (artifact.schemaVersion !== 1) fail("artifact schemaVersion must be 1");
if (artifact.activationMode !== "public-testnet-reference-fixture") fail("artifact activationMode is invalid");
if (artifact.productionDeployment !== false) fail("production artifacts are not supported");
if (!Number.isSafeInteger(artifact.chainId) || artifact.chainId <= 0) fail("artifact chainId is invalid");
if (!addressPattern.test(artifact.operator) || /^0x0{40}$/i.test(artifact.operator)) fail("artifact operator is invalid");
if (!addressPattern.test(subjectInput) || /^0x0{40}$/i.test(subjectInput)) fail("subject is invalid");
const participants = [artifact.maker, artifact.investor, artifact.eligibleInvestorB, artifact.ineligibleInvestor];
if (artifact.expiredInvestor && !/^0x0{40}$/i.test(artifact.expiredInvestor)) participants.push(artifact.expiredInvestor);
if (!participants.some((value) => typeof value === "string" && value.toLowerCase() === subjectInput.toLowerCase())) {
  fail("subject is not an artifact participant");
}
process.stdout.write(`${artifact.chainId}\t${artifact.operator}\t${subjectInput}`);
NODE
) || { echo "ERROR: artifact validation failed" >&2; exit 2; }
IFS=$'\t' read -r CHAIN_ID OPERATOR SUBJECT_CANONICAL <<< "$ARTIFACT_VALUES"

RPC_CHAIN_ID=$(cast chain-id --rpc-url "$RPC_URL")
if [[ "$RPC_CHAIN_ID" != "$CHAIN_ID" ]]; then
  echo "ERROR: RPC chain id $RPC_CHAIN_ID does not match artifact chain id $CHAIN_ID" >&2
  exit 1
fi

export CORNER_STORE_ARTIFACT="$ARTIFACT"
export CORNER_STORE_EVIDENCE_SUBJECT="$SUBJECT_CANONICAL"
export CORNER_STORE_EVIDENCE_QP_ACTION="$QP_ACTION"
export CORNER_STORE_EVIDENCE_ACQUISITION_STATUS="$ACQUISITION_STATUS"
if [[ -n "$ACQUISITION_STATUS" ]]; then
  export CORNER_STORE_EVIDENCE_CLOCK_START="$CLOCK_START"
  export CORNER_STORE_EVIDENCE_EXPIRES_AT="$EXPIRES_AT"
  export CORNER_STORE_EVIDENCE_SOURCE_REF="$SOURCE_REF"
fi

SIGNER_ARGS=()
if [[ "$BROADCAST" -eq 1 ]]; then
  if [[ "$USE_LEDGER" -eq 1 ]]; then
    SIGNER_ARGS+=(--ledger)
  elif [[ -n "$KEYSTORE" ]]; then
    SIGNER_ARGS+=(--keystore "$KEYSTORE")
    [[ -n "$PASSWORD_FILE" ]] && SIGNER_ARGS+=(--password-file "$PASSWORD_FILE")
  else
    SIGNER_ARGS+=(--account "$ACCOUNT")
  fi

  SIGNER_ADDRESS=$(cast wallet address "${SIGNER_ARGS[@]}")
  SIGNER_NORMALIZED=$(printf '%s' "$SIGNER_ADDRESS" | tr '[:upper:]' '[:lower:]')
  OPERATOR_NORMALIZED=$(printf '%s' "$OPERATOR" | tr '[:upper:]' '[:lower:]')
  if [[ "$SIGNER_NORMALIZED" != "$OPERATOR_NORMALIZED" ]]; then
    echo "ERROR: selected signer does not match artifact operator" >&2
    exit 1
  fi
fi

MUTATION_ARGS=()
if [[ "$BROADCAST" -eq 1 ]]; then
  MUTATION_ARGS+=(--broadcast --slow)
else
  echo "==> Simulation only. Add --broadcast with an operator signer after review."
fi

forge script script/RefreshTestnetEvidence.s.sol:RefreshTestnetEvidence \
  --rpc-url "$RPC_URL" \
  --chain-id "$CHAIN_ID" \
  --sender "$OPERATOR" \
  ${SIGNER_ARGS[@]+"${SIGNER_ARGS[@]}"} \
  ${MUTATION_ARGS[@]+"${MUTATION_ARGS[@]}"}

if [[ "$BROADCAST" -eq 1 ]]; then
  forge script script/RefreshTestnetEvidence.s.sol:VerifyTestnetEvidenceRefresh \
    --rpc-url "$RPC_URL" \
    --chain-id "$CHAIN_ID"
fi
