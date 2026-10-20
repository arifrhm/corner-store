#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/corner-store-testnet-deploy-test.XXXXXX")
trap 'rm -rf -- "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/bin" "$TMP_DIR/repo/scripts"
cp "$ROOT/scripts/deploy-testnet-rfq.sh" "$TMP_DIR/repo/scripts/"

cat > "$TMP_DIR/bin/cast" <<'EOF'
#!/bin/sh
printf '%s\n' 10143
EOF

cat > "$TMP_DIR/bin/forge" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" > "$FORGE_LOG"
exit 97
EOF

chmod +x "$TMP_DIR/bin/cast" "$TMP_DIR/bin/forge"

git -C "$TMP_DIR/repo" init -q
git -C "$TMP_DIR/repo" config user.name "Corner Store Test"
git -C "$TMP_DIR/repo" config user.email "corner-store-test@example.invalid"
git -C "$TMP_DIR/repo" add scripts/deploy-testnet-rfq.sh
git -C "$TMP_DIR/repo" commit -qm "test fixture"

run_wrapper() {
  local label=$1
  shift

  : > "$TMP_DIR/forge.log"
  set +e
  (
    cd "$TMP_DIR/repo"
    PATH="$TMP_DIR/bin:$PATH" \
      FORGE_LOG="$TMP_DIR/forge.log" \
      CORNER_STORE_TESTNET_DEPLOYER=0x0000000000000000000000000000000000000001 \
      CORNER_STORE_TESTNET_MAKER=0x0000000000000000000000000000000000000002 \
      CORNER_STORE_TESTNET_INVESTOR=0x0000000000000000000000000000000000000003 \
      CORNER_STORE_TESTNET_INVESTOR_B=0x0000000000000000000000000000000000000004 \
      CORNER_STORE_TESTNET_INELIGIBLE_INVESTOR=0x0000000000000000000000000000000000000005 \
      CORNER_STORE_TESTNET_ISSUER_KEY=test-only-value \
      /bin/bash scripts/deploy-testnet-rfq.sh \
        --rpc-url mock://rpc \
        --chain-id 10143 \
        --account test-account \
        "$@"
  ) > "$TMP_DIR/$label.out" 2>&1
  local status=$?
  set -e

  if [[ "$status" -ne 97 ]]; then
    cat "$TMP_DIR/$label.out" >&2
    echo "ERROR: $label exited with $status instead of the forge stub status 97" >&2
    exit 1
  fi
}

assert_forge_args() {
  local label=$1
  shift

  printf '%s\n' "$@" > "$TMP_DIR/$label.expected"
  diff -u "$TMP_DIR/$label.expected" "$TMP_DIR/forge.log"
}

run_wrapper simulation
assert_forge_args simulation \
  script \
  script/DeployTestnetRFQ.s.sol:DeployTestnetRFQ \
  --rpc-url mock://rpc \
  --chain-id 10143 \
  --sender 0x0000000000000000000000000000000000000001 \
  --account test-account

run_wrapper broadcast --broadcast
assert_forge_args broadcast \
  script \
  script/DeployTestnetRFQ.s.sol:DeployTestnetRFQ \
  --rpc-url mock://rpc \
  --chain-id 10143 \
  --sender 0x0000000000000000000000000000000000000001 \
  --account test-account \
  --broadcast \
  --slow

run_wrapper broadcast-verify \
  --broadcast \
  --verify \
  --verifier blockscout \
  --verifier-url https://explorer.example.invalid/api
assert_forge_args broadcast-verify \
  script \
  script/DeployTestnetRFQ.s.sol:DeployTestnetRFQ \
  --rpc-url mock://rpc \
  --chain-id 10143 \
  --sender 0x0000000000000000000000000000000000000001 \
  --account test-account \
  --broadcast \
  --slow \
  --verify \
  --verifier blockscout \
  --verifier-url https://explorer.example.invalid/api

echo "deploy-testnet-rfq argument tests passed"
