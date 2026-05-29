#!/usr/bin/env bash
#
# Code-consistency proof for the sUSDat protocol implementation contracts.
#
# Confirms the source in this checkout is identical to the audited commit (a
# read-only `git diff` — nothing is checked out, moved, or modified), then
# compiles it, deploys each implementation in a local EVM with the production
# constructor arguments, and checks each code hash equals the code hash live on
# mainnet:
#
#   local code hash : the audited source, deployed locally with the prod args
#                     (and, for the two UUPS contracts, the original
#                     deployer/nonce so the `__self` immutable resolves to the
#                     on-chain implementation address)
#   prod  code hash : EXTCODEHASH of the live mainnet implementation
#
# Equal hashes  <=>  mainnet runs the audited code.
#
# Requires: foundry (forge, cast), git, and a .env.prod providing RPC_URL.
#
set -euo pipefail

# What we're verifying
NETWORK="Ethereum mainnet (chain id 1)"
AUDIT_COMMIT=49240e520408bc2d1d76351c557aa88f4fb9ef1a    # audited commit (PR #88)

ORACLE_IMPL=0x5f7eCD0D045c393da6cb6c933c671AC305A871BF   # StrcPriceOracle
WQ_IMPL=0x256fa0ba1b6dfb50ee883955c5a99d3c1b017fd5       # WithdrawalQueueERC721
SUSDAT_IMPL=0x2005e0ca201a37694125ff267ae57872bea0a0ce   # StakedUSDat

# Load RPC_URL (exported so forge/cast can read it)
set -a; source .env.prod; set +a

# 1. Read-only check: is the source here identical to the audited commit?
#    Only the files that affect the compiled bytecode are compared.
if ! git diff --quiet --ignore-submodules=dirty "$AUDIT_COMMIT" -- src lib foundry.toml remappings.txt; then
  echo "  ERROR: source differs from audited commit $AUDIT_COMMIT"
  echo "         inspect with: git diff $AUDIT_COMMIT -- src lib foundry.toml remappings.txt"
  exit 1
fi

# 2. LOCAL: compile + deploy the audited source with the prod args; the script
#    logs the three code hashes in this order:
#    StrcPriceOracle, WithdrawalQueueERC721, StakedUSDat
HASHES=$(forge script script/VerifyCodeHash.s.sol 2>/dev/null | grep -oiE '0x[0-9a-f]{64}')
ORACLE_LOCAL=$(echo "$HASHES" | sed -n 1p)
WQ_LOCAL=$(echo "$HASHES" | sed -n 2p)
SUSDAT_LOCAL=$(echo "$HASHES" | sed -n 3p)

# 3. PRODUCTION: read the live on-chain runtime code hashes
ORACLE_PROD=$(cast codehash "$ORACLE_IMPL" --rpc-url "$RPC_URL")
WQ_PROD=$(cast codehash "$WQ_IMPL" --rpc-url "$RPC_URL")
SUSDAT_PROD=$(cast codehash "$SUSDAT_IMPL" --rpc-url "$RPC_URL")

echo
echo "  network               : $NETWORK"
echo "  audited commit        : $AUDIT_COMMIT  (source verified identical)"
echo
echo "  StrcPriceOracle        $ORACLE_IMPL"
echo "    local  code hash    : $ORACLE_LOCAL"
echo "    production code hash : $ORACLE_PROD"
echo "  WithdrawalQueueERC721  $WQ_IMPL"
echo "    local  code hash    : $WQ_LOCAL"
echo "    production code hash : $WQ_PROD"
echo "  StakedUSDat            $SUSDAT_IMPL"
echo "    local  code hash    : $SUSDAT_LOCAL"
echo "    production code hash : $SUSDAT_PROD"
echo

if [ -z "$ORACLE_LOCAL" ] || [ -z "$WQ_LOCAL" ] || [ -z "$SUSDAT_LOCAL" ]; then
  echo "  ERROR: could not compute local code hash"; exit 1
fi

# The proof: does the locally built audited code equal the code live on-chain?
if [ "$ORACLE_LOCAL" = "$ORACLE_PROD" ] \
   && [ "$WQ_LOCAL" = "$WQ_PROD" ] \
   && [ "$SUSDAT_LOCAL" = "$SUSDAT_PROD" ]; then
  echo "  MATCH - mainnet implementations run the audited code (commit $AUDIT_COMMIT)"
else
  echo "  MISMATCH - deployed code does NOT match the audited commit"; exit 1
fi
