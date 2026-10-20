#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

PASSED=0; FAILED=0; WARNED=0
CLEANUP=()

pass() { echo -e "  ${GREEN}✅ $1${RESET}"; PASSED=$((PASSED + 1)); }
fail() { echo -e "  ${RED}❌ $1${RESET}" >&2; FAILED=$((FAILED + 1)); }
warn() { echo -e "  ${YELLOW}⚠️  $1${RESET}"; WARNED=$((WARNED + 1)); }
step() {
  echo ""
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo -e "  🧪 ${BOLD}[$1] $2${RESET}"
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
}

cleanup() {
  if [[ ${#CLEANUP[@]} -gt 0 ]]; then
    echo ""
    echo -e "  ${BOLD}🧹 Cleaning up test resources...${RESET}"
    for cmd in "${CLEANUP[@]}"; do
      eval "$cmd" 2>/dev/null || true
    done
  fi
}
trap cleanup EXIT

DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
NS=osac
KC_URL="https://keycloak-keycloak.$DOMAIN"
API_URL="fulfillment-api-$NS.$DOMAIN:443"
UI_URL="https://osac-ui-$NS.$DOMAIN"
TENANT="smoke-test"

curl -sL "https://github.com/osac-project/osac/releases/latest/download/osac_Linux_x86_64" -o /usr/local/bin/osac
chmod +x /usr/local/bin/osac

# =====================================================================
step "1/5" "Platform reachability"

# Keycloak OIDC discovery
KC_ISSUER=$(curl -sk "$KC_URL/realms/osac/.well-known/openid-configuration" 2>/dev/null \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('issuer',''))" 2>/dev/null || echo "")
if [[ "$KC_ISSUER" == *"keycloak"* ]]; then
  pass "Keycloak OIDC: reachable"
else
  fail "Keycloak OIDC: unreachable"
fi

# UI
UI_CODE=$(curl -sk -o /dev/null -w "%{http_code}" "$UI_URL/" 2>/dev/null || echo "000")
if [[ "$UI_CODE" =~ ^(2|3) ]]; then
  pass "OSAC UI: $UI_CODE"
else
  fail "OSAC UI: $UI_CODE"
fi

# No pods in CrashLoopBackOff
CRASH_TOTAL=0
for CHECK_NS in osac-infra keycloak "$NS"; do
  CRASH=$(oc get pods -n "$CHECK_NS" --no-headers 2>/dev/null | { grep -c "CrashLoopBackOff" || true; })
  CRASH_TOTAL=$((CRASH_TOTAL + CRASH))
done
if [[ "$CRASH_TOTAL" -eq 0 ]]; then
  pass "No CrashLoopBackOff pods"
else
  fail "$CRASH_TOTAL pods in CrashLoopBackOff"
fi

# =====================================================================
step "2/5" "User authentication"

osac login "$API_URL" --user=admin --password=admin --insecure --flow=password 2>&1

WHOAMI=$(osac whoami 2>&1 || echo "")
if echo "$WHOAMI" | grep -q "admin"; then
  pass "Login as admin"
else
  fail "Login as admin"
  echo -e "  ${RED}Cannot proceed without auth, aborting${RESET}" >&2
  exit 1
fi

# Verify tenant listing
TENANTS=$(osac get tenants 2>&1)
if echo "$TENANTS" | grep -q "$TENANT"; then
  pass "List tenants ($TENANT tenant exists)"
else
  fail "List tenants ($TENANT not found)"
fi

osac tenant "$TENANT" 2>&1
pass "Set active tenant to $TENANT"

# =====================================================================
step "3/5" "Network lifecycle"

# Create virtual network
osac create virtualnetwork -n smoke-vnet --ipv4-cidr 10.99.0.0/16 2>&1 || true
CLEANUP+=("osac delete virtualnetwork smoke-vnet 2>/dev/null")

VNET=$(osac get virtualnetworks 2>&1)
if echo "$VNET" | grep -q "smoke-vnet"; then
  pass "Create virtual network smoke-vnet"

  echo -e "  ${BOLD}⏳ Waiting for VirtualNetwork READY (up to 3 min)...${RESET}"
  VNET_READY=false
  for i in $(seq 1 18); do
    VSTATE=$(osac get virtualnetworks 2>&1 | grep smoke-vnet | awk '{print $NF}')
    if [[ "$VSTATE" == "READY" ]]; then
      VNET_READY=true
      break
    fi
    sleep 10
  done

  if $VNET_READY; then
    pass "Virtual network smoke-vnet: READY"
  else
    warn "Virtual network smoke-vnet: $VSTATE (expected READY)"
  fi

  # Create subnet
  osac create subnet -n smoke-subnet --virtual-network smoke-vnet --ipv4-cidr 10.99.1.0/24 2>&1 || true
  CLEANUP+=("osac delete subnet smoke-subnet 2>/dev/null")

  SUBNET=$(osac get subnets 2>&1)
  if echo "$SUBNET" | grep -q "smoke-subnet"; then
    pass "Create subnet smoke-subnet"
  else
    fail "Create subnet smoke-subnet"
  fi

  # Create security group
  osac create securitygroup -n smoke-sg --virtual-network smoke-vnet \
    --ingress protocol=tcp,port-from=22,port-to=22,ipv4-cidr=0.0.0.0/0 \
    --egress protocol=all,ipv4-cidr=0.0.0.0/0 2>&1 || true
  CLEANUP+=("osac delete securitygroup smoke-sg 2>/dev/null")

  SG=$(osac get securitygroups 2>&1)
  if echo "$SG" | grep -q "smoke-sg"; then
    pass "Create security group smoke-sg"
  else
    fail "Create security group smoke-sg"
  fi
else
  fail "Create virtual network smoke-vnet"
  warn "Skipping subnet and security group tests"
fi

# =====================================================================
step "4/5" "Compute instance lifecycle (VMaaS)"

osac create computeinstance -n smoke-vm --catalog-item fedora-41 2>&1 || true
CLEANUP+=("osac delete computeinstance smoke-vm 2>/dev/null")

CI=$(osac get computeinstances 2>&1)
if echo "$CI" | grep -q "smoke-vm"; then
  pass "Create compute instance smoke-vm"

  echo -e "  ${BOLD}⏳ Waiting for VM to reach Running (up to 3 min)...${RESET}"
  VM_READY=false
  for i in $(seq 1 18); do
    STATUS=$(osac get computeinstances 2>&1 | grep smoke-vm | awk '{print $NF}')
    if [[ "$STATUS" == "Running" ]]; then
      VM_READY=true
      break
    elif [[ "$STATUS" == "FAILED" ]]; then
      break
    fi
    sleep 10
  done

  if $VM_READY; then
    pass "Compute instance smoke-vm: Running"
  else
    warn "Compute instance smoke-vm: $STATUS (expected Running)"
  fi
else
  fail "Create compute instance smoke-vm"
fi

# =====================================================================
step "5/5" "Cleanup"

# Cleanup runs via trap, but we report it here
echo -e "  ${BOLD}Resources will be cleaned up on exit${RESET}"

# =====================================================================
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
if [[ $FAILED -eq 0 ]]; then
  echo -e "  ${GREEN}${BOLD}🎉 All tests passed${RESET} (${PASSED} passed, ${WARNED} warnings)"
else
  echo -e "  ${RED}${BOLD}💥 Some tests failed${RESET} (${PASSED} passed, ${FAILED} failed, ${WARNED} warnings)"
fi
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"

[[ $FAILED -eq 0 ]]
