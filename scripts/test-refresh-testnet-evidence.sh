#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/corner-store-evidence-refresh-test.XXXXXX")
trap 'rm -rf -- "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/bin" "$TMP_DIR/repo/scripts" "$TMP_DIR/repo/deployments"
cp "$ROOT/scripts/refresh-testnet-evidence.sh" "$TMP_DIR/repo/scripts/"

OPERATOR=0x0000000000000000000000000000000000000001
SUBJECT=0x0000000000000000000000000000000000000003
SOURCE_REF=0x1111111111111111111111111111111111111111111111111111111111111111

cat > "$TMP_DIR/repo/deployments/artifact.json" <<EOF
{
  "schemaVersion": 1,
  "activationMode": "public-testnet-reference-fixture",
  "productionDeployment": false,
  "chainId": 10143,
  "operator": "$OPERATOR",
  "maker": "0x0000000000000000000000000000000000000002",
  "investor": "$SUBJECT",
  "eligibleInvestorB": "0x0000000000000000000000000000000000000004",
  "ineligibleInvestor": "0x0000000000000000000000000000000000000005",
  "expiredInvestor": "0x0000000000000000000000000000000000000000"
}
EOF

cat > "$TMP_DIR/bin/cast" <<'EOF'
#!/bin/sh
if [ "$1" = "chain-id" ]; then
  printf '%s\n' "${MOCK_CHAIN_ID:-10143}"
elif [ "$1" = "wallet" ] && [ "$2" = "address" ]; then
  shift 2
  printf '%s\n' "$*" >> "$CAST_WALLET_LOG"
  printf '%s\n' "${MOCK_SIGNER_ADDRESS:-0x0000000000000000000000000000000000000001}"
else
  exit 98
fi
EOF

cat > "$TMP_DIR/bin/forge" <<'EOF'
#!/bin/sh
{
  printf '%s\n' "--- invocation ---"
  printf '%s\n' "$@"
  printf '%s\n' "env:qp=${CORNER_STORE_EVIDENCE_QP_ACTION-}"
  printf '%s\n' "env:status=${CORNER_STORE_EVIDENCE_ACQUISITION_STATUS-}"
  printf '%s\n' "env:clock=${CORNER_STORE_EVIDENCE_CLOCK_START-}"
  printf '%s\n' "env:expires=${CORNER_STORE_EVIDENCE_EXPIRES_AT-}"
  printf '%s\n' "env:source=${CORNER_STORE_EVIDENCE_SOURCE_REF-}"
} >> "$FORGE_LOG"
EOF

chmod +x "$TMP_DIR/bin/cast" "$TMP_DIR/bin/forge" "$TMP_DIR/repo/scripts/refresh-testnet-evidence.sh"

run_success() {
  local label=$1
  shift
  : > "$TMP_DIR/forge.log"
  : > "$TMP_DIR/cast-wallet.log"
  cp "$TMP_DIR/repo/deployments/artifact.json" "$TMP_DIR/$label.before"
  (
    cd "$TMP_DIR/repo"
    PATH="$TMP_DIR/bin:$PATH" FORGE_LOG="$TMP_DIR/forge.log" CAST_WALLET_LOG="$TMP_DIR/cast-wallet.log" \
      scripts/refresh-testnet-evidence.sh --rpc-url mock://rpc --artifact deployments/artifact.json \
      --subject "$SUBJECT" "$@"
  ) > "$TMP_DIR/$label.out" 2>&1
  cmp "$TMP_DIR/$label.before" "$TMP_DIR/repo/deployments/artifact.json"
}

run_failure() {
  local label=$1
  local expected=$2
  shift 2
  : > "$TMP_DIR/forge.log"
  : > "$TMP_DIR/cast-wallet.log"
  set +e
  (
    cd "$TMP_DIR/repo"
    PATH="$TMP_DIR/bin:$PATH" FORGE_LOG="$TMP_DIR/forge.log" CAST_WALLET_LOG="$TMP_DIR/cast-wallet.log" \
      scripts/refresh-testnet-evidence.sh --rpc-url mock://rpc --artifact deployments/artifact.json \
      --subject "$SUBJECT" "$@"
  ) > "$TMP_DIR/$label.out" 2>&1
  local status=$?
  set -e
  [[ "$status" -ne 0 ]] || { echo "ERROR: $label unexpectedly passed" >&2; exit 1; }
  grep -F -- "$expected" "$TMP_DIR/$label.out" >/dev/null || {
    cat "$TMP_DIR/$label.out" >&2
    echo "ERROR: $label did not report: $expected" >&2
    exit 1
  }
  [[ ! -s "$TMP_DIR/forge.log" ]] || { echo "ERROR: $label invoked forge" >&2; exit 1; }
}

run_success dry-run --qp qualified
grep -F 'script/RefreshTestnetEvidence.s.sol:RefreshTestnetEvidence' "$TMP_DIR/forge.log" >/dev/null
! grep -Fx -- '--broadcast' "$TMP_DIR/forge.log" >/dev/null
! grep -Fx -- '--account' "$TMP_DIR/forge.log" >/dev/null
[[ ! -s "$TMP_DIR/cast-wallet.log" ]]

run_success broadcast-account --qp clear --broadcast --account operator-account
[[ "$(grep -c '^--- invocation ---$' "$TMP_DIR/forge.log")" -eq 2 ]]
grep -F 'script/RefreshTestnetEvidence.s.sol:VerifyTestnetEvidenceRefresh' "$TMP_DIR/forge.log" >/dev/null
grep -Fx -- '--broadcast' "$TMP_DIR/forge.log" >/dev/null
grep -Fx -- '--slow' "$TMP_DIR/forge.log" >/dev/null
grep -Fx -- '--account operator-account' "$TMP_DIR/cast-wallet.log" >/dev/null
grep -F 'env:qp=clear' "$TMP_DIR/forge.log" >/dev/null

run_success broadcast-keystore --qp qualified --broadcast --keystore operator.json --password-file password.txt
grep -Fx -- '--keystore operator.json --password-file password.txt' "$TMP_DIR/cast-wallet.log" >/dev/null

run_success broadcast-ledger --qp qualified --broadcast --ledger
grep -Fx -- '--ledger' "$TMP_DIR/cast-wallet.log" >/dev/null

run_success acquisition --acquisition-status lineage-broken --clock-start 0 --expires-at 4102444800 \
  --source-ref "$SOURCE_REF"
grep -F 'env:status=lineage-broken' "$TMP_DIR/forge.log" >/dev/null
grep -F 'env:clock=0' "$TMP_DIR/forge.log" >/dev/null
grep -F 'env:expires=4102444800' "$TMP_DIR/forge.log" >/dev/null
grep -F "env:source=$SOURCE_REF" "$TMP_DIR/forge.log" >/dev/null

run_failure no-action 'at least one of --qp or --acquisition-status is required'
run_failure outsider 'subject is not an artifact participant' --qp qualified --subject 0x0000000000000000000000000000000000000099
run_failure malformed-source '--source-ref must be a bytes32 hex value' --acquisition-status valid --clock-start 1 \
  --expires-at 4102444800 --source-ref 0x12
run_failure orphan-fields 'acquisition fields require --acquisition-status' --qp qualified --clock-start 1
run_failure broadcast-no-signer '--broadcast requires exactly one' --qp qualified --broadcast
run_failure password-without-keystore '--password-file requires --keystore' --qp qualified --broadcast --account operator \
  --password-file password.txt
run_failure raw-key 'unknown argument: --private-key' --qp qualified --broadcast --private-key secret

set +e
(
  cd "$TMP_DIR/repo"
  PATH="$TMP_DIR/bin:$PATH" FORGE_LOG="$TMP_DIR/forge.log" CAST_WALLET_LOG="$TMP_DIR/cast-wallet.log" \
    MOCK_CHAIN_ID=1 scripts/refresh-testnet-evidence.sh --rpc-url mock://rpc --artifact deployments/artifact.json \
    --subject "$SUBJECT" --qp qualified
) > "$TMP_DIR/chain.out" 2>&1
CHAIN_STATUS=$?
set -e
[[ "$CHAIN_STATUS" -ne 0 ]]
grep -F 'does not match artifact chain id' "$TMP_DIR/chain.out" >/dev/null

set +e
(
  cd "$TMP_DIR/repo"
  PATH="$TMP_DIR/bin:$PATH" FORGE_LOG="$TMP_DIR/forge.log" CAST_WALLET_LOG="$TMP_DIR/cast-wallet.log" \
    MOCK_SIGNER_ADDRESS=0x0000000000000000000000000000000000000099 \
    scripts/refresh-testnet-evidence.sh --rpc-url mock://rpc --artifact deployments/artifact.json \
    --subject "$SUBJECT" --qp qualified --broadcast --account wrong
) > "$TMP_DIR/signer.out" 2>&1
SIGNER_STATUS=$?
set -e
[[ "$SIGNER_STATUS" -ne 0 ]]
grep -F 'selected signer does not match artifact operator' "$TMP_DIR/signer.out" >/dev/null

echo "refresh-testnet-evidence argument tests passed"
