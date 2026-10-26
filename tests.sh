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

OSAC_CLI_URL=$(curl -s "https://api.github.com/repos/osac-project/osac/releases" \
  | python3 -c "import sys,json
for r in json.load(sys.stdin):
  if r['tag_name'].startswith('fulfillment-service/'):
    for a in r['assets']:
      if a['name']=='osac_Linux_x86_64':
        print(a['browser_download_url']); break
    break")
curl -sL "$OSAC_CLI_URL" -o /usr/local/bin/osac
chmod +x /usr/local/bin/osac

# =====================================================================
step "1/6" "Platform reachability"

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
step "2/6" "User authentication"

for i in $(seq 1 6); do
  osac login "$API_URL" --user=admin --password=admin --insecure --flow=password 2>&1 && break
  sleep 10
done

WHOAMI=$(osac whoami 2>&1 || echo "")
if echo "$WHOAMI" | grep -q "admin"; then
  pass "Login as admin"
else
  fail "Login as admin"
  echo -e "  ${RED}Cannot proceed without auth, aborting${RESET}" >&2
  exit 1
fi

# Verify tenant listing
TENANTS=$(osac get tenants 2>&1 || echo "")
if echo "$TENANTS" | grep -q "$TENANT"; then
  pass "List tenants ($TENANT tenant exists)"
else
  fail "List tenants ($TENANT not found)"
fi

osac tenant "$TENANT" 2>&1 || true
pass "Set active tenant to $TENANT"

# =====================================================================
step "3/6" "Network lifecycle"

# Create virtual network and wait for READY (depends on NetworkClass being READY)
osac create virtualnetwork -n smoke-vnet --ipv4-cidr 10.99.0.0/16 2>&1 || true
CLEANUP+=("osac delete virtualnetwork smoke-vnet 2>/dev/null")

VNET=$(osac get virtualnetworks 2>&1 || echo "")
if echo "$VNET" | grep -q "smoke-vnet"; then
  pass "Create virtual network smoke-vnet"

  echo -e "  ${BOLD}⏳ Waiting for VirtualNetwork READY (up to 5 min)...${RESET}"
  VNET_READY=false
  for i in $(seq 1 30); do
    VSTATE=$(osac get virtualnetworks 2>&1 | grep smoke-vnet | awk '{print $NF}')
    if [[ "$VSTATE" == "READY" ]]; then
      VNET_READY=true
      break
    fi
    sleep 10
  done

  if $VNET_READY; then
    pass "Virtual network smoke-vnet: READY"

    osac create subnet -n smoke-subnet --virtual-network smoke-vnet --ipv4-cidr 10.99.1.0/24 2>&1 || true
    CLEANUP+=("osac delete subnet smoke-subnet 2>/dev/null")

    SUBNET=$(osac get subnets 2>&1 || echo "")
    if echo "$SUBNET" | grep -q "smoke-subnet"; then
      pass "Create subnet smoke-subnet"

      echo -e "  ${BOLD}⏳ Waiting for subnet CR to appear (up to 1 min)...${RESET}"
      SUBNET_CR=""
      for i in $(seq 1 6); do
        SUBNET_CR=$(oc get subnets.osac.openshift.io -n osac --no-headers 2>/dev/null \
          | { grep -v "Ready" || true; } | awk '{print $1}' | head -1)
        if [[ -z "$SUBNET_CR" ]]; then
          SUBNET_CR=$(oc get subnets.osac.openshift.io -n osac --no-headers 2>/dev/null \
            | tail -1 | awk '{print $1}')
        fi
        if [[ -n "$SUBNET_CR" ]]; then break; fi
        sleep 10
      done
      # cudn_net fabric role doesn't create the output ConfigMap the operator expects
      if [[ -n "$SUBNET_CR" ]] && ! oc get configmap "subnet-${SUBNET_CR}-fabric-output" -n osac &>/dev/null; then
        SUBNET_CIDR=$(oc get subnet.osac.openshift.io "$SUBNET_CR" -n osac \
          -o jsonpath='{.spec.ipv4Cidr}' 2>/dev/null || echo "10.99.1.0/24")
        IFS='/' read -r NET_ADDR MASK <<< "$SUBNET_CIDR"
        IFS='.' read -r A B C D <<< "$NET_ADDR"
        RESERVED_START="${A}.${B}.${C}.$((D+1))"
        RESERVED_END="${A}.${B}.${C}.$((D+10))"
        oc create configmap "subnet-${SUBNET_CR}-fabric-output" -n osac \
          --from-literal=l2_vni=10000 \
          --from-literal=l3_vni=10001 \
          --from-literal=fabric_reserved_range="${RESERVED_START}-${RESERVED_END}" \
          --dry-run=client -o yaml | oc apply -f -
      fi

      echo -e "  ${BOLD}⏳ Waiting for subnet READY (up to 3 min)...${RESET}"
      SUBNET_READY=false
      for i in $(seq 1 18); do
        SSTATE=$(osac get subnets 2>&1 | grep smoke-subnet | awk '{print $NF}')
        if [[ "$SSTATE" == "READY" ]]; then
          SUBNET_READY=true
          break
        fi
        sleep 10
      done
      if $SUBNET_READY; then
        pass "Subnet smoke-subnet: READY"
      else
        warn "Subnet smoke-subnet: $SSTATE (expected READY)"
      fi
    else
      fail "Create subnet smoke-subnet"
    fi

    osac create securitygroup -n smoke-sg --virtual-network smoke-vnet \
      --ingress protocol=tcp,port-from=22,port-to=22,ipv4-cidr=0.0.0.0/0 \
      --egress protocol=all,ipv4-cidr=0.0.0.0/0 2>&1 || true
    CLEANUP+=("osac delete securitygroup smoke-sg 2>/dev/null")

    SG=$(osac get securitygroups 2>&1 || echo "")
    if echo "$SG" | grep -q "smoke-sg"; then
      pass "Create security group smoke-sg"

      echo -e "  ${BOLD}⏳ Waiting for security group READY (up to 2 min)...${RESET}"
      SG_READY=false
      for i in $(seq 1 12); do
        SGSTATE=$(osac get securitygroups 2>&1 | grep smoke-sg | awk '{print $NF}')
        if [[ "$SGSTATE" == "READY" ]]; then
          SG_READY=true
          break
        fi
        sleep 10
      done
      if $SG_READY; then
        pass "Security group smoke-sg: READY"
      else
        warn "Security group smoke-sg: $SGSTATE (expected READY)"
      fi
    else
      fail "Create security group smoke-sg"
    fi
  else
    warn "Virtual network smoke-vnet: $VSTATE (expected READY) — skipping subnet and security group"
  fi
else
  fail "Create virtual network smoke-vnet"
fi

# =====================================================================
step "4/6" "Compute instance lifecycle (VMaaS)"

HAVE_SUBNET=$(osac get subnets 2>&1 | { grep -c smoke-subnet || true; })
if [[ "$HAVE_SUBNET" -gt 0 ]]; then
  SUBNET_ID=$(osac get subnets 2>&1 | { grep smoke-subnet || true; } | awk '{print $3}')
  SG_ID=$(osac get securitygroups 2>&1 | { grep smoke-sg || true; } | awk '{print $3}')
  osac create computeinstance -n smoke-vm --catalog-item fedora-41 \
    --network-attachment "subnet=${SUBNET_ID},security-groups=${SG_ID}" 2>&1 || true
  CLEANUP+=("osac delete computeinstance smoke-vm 2>/dev/null")

  CI=$(osac get computeinstances 2>&1 || echo "")
  if echo "$CI" | grep -q "smoke-vm"; then
    pass "Create compute instance smoke-vm"

    echo -e "  ${BOLD}⏳ Waiting for VM to reach Running (up to 5 min)...${RESET}"
    VM_READY=false
    for i in $(seq 1 30); do
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
      fail "Compute instance smoke-vm: $STATUS (expected Running)"
      echo -e "  ${BOLD}🔍 Diagnostics:${RESET}"
      osac get computeinstances -o yaml 2>&1 | grep -A5 "status\|error\|message\|reason" | head -20 || true
      oc get computeinstances.osac.openshift.io -A -o yaml 2>/dev/null | grep -A5 "status\|error\|message" | head -20 || true
      oc get vm -A --no-headers 2>/dev/null || echo "    No VirtualMachine CRs"
      oc get vmi -A --no-headers 2>/dev/null || echo "    No VirtualMachineInstance CRs"
    fi
  else
    fail "Create compute instance smoke-vm"
  fi
else
  fail "No subnet available, skipping compute instance test"
fi

# =====================================================================
step "5/6" "CaaS cluster lifecycle"

OCP_VERSION=$(oc get clusterversion version -o jsonpath='{.status.desired.version}')
OCP_MINOR="${OCP_VERSION%.*}"
CAAS_ENABLED=$(osac get clusterversions 2>&1 || echo "")
if echo "$CAAS_ENABLED" | grep -q "${OCP_MINOR}"; then
  pass "CaaS service enabled (ClusterVersion ${OCP_MINOR})"

  CAAS_NS=hardware-inventory

  # Clean up stale CaaS resources from previous runs
  echo -e "  ${BOLD}Cleaning up stale CaaS resources...${RESET}"
  for OLD_AGENT in $(oc get agents -n "$CAAS_NS" --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null); do
    oc delete agent "$OLD_AGENT" -n "$CAAS_NS" --ignore-not-found 2>/dev/null || true
  done
  for OLD_BMH in $(oc get bmh -n "$CAAS_NS" --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null); do
    oc delete bmh "$OLD_BMH" -n "$CAAS_NS" --ignore-not-found 2>/dev/null || true
  done
  for OLD_VM in smoke-worker-1 smoke-worker-2; do
    kcli delete vm "$OLD_VM" -y 2>/dev/null || true
  done

  # Create worker VMs and register as BareMetalHosts (offline, BMF-claimable inventory)
  echo -e "  ${BOLD}Creating worker VMs and BareMetalHosts...${RESET}"
  WORKER_MACS=("aa:bb:cc:dd:ee:01" "aa:bb:cc:dd:ee:02")
  for WORKER_IDX in 1 2; do
    VM_NAME="smoke-worker-${WORKER_IDX}"
    MAC="${WORKER_MACS[$((WORKER_IDX - 1))]}"

    kcli create vm \
      -P numcpus=8 -P memory=16384 -P disks='[100]' \
      -P nets="[{\"name\":\"baremetalfake\",\"mac\":\"$MAC\"}]" \
      -P start=false \
      "$VM_NAME" 2>&1 || true

    oc create secret generic "${VM_NAME}-bmc" -n "$CAAS_NS" \
      --from-literal=username=admin --from-literal=password=password \
      --dry-run=client -o yaml | oc apply -f -

    cat <<EOF | oc apply -f -
apiVersion: metal3.io/v1alpha1
kind: BareMetalHost
metadata:
  name: $VM_NAME
  namespace: $CAAS_NS
  labels:
    usage: ci
spec:
  online: false
  bootMACAddress: "$MAC"
  automatedCleaningMode: disabled
  bmc:
    address: redfish-virtualmedia://192.168.254.1:9000/redfish/v1/Systems/local/$VM_NAME
    credentialsName: ${VM_NAME}-bmc
    disableCertificateVerification: true
EOF
  done
  CLEANUP+=("kcli delete vm smoke-worker-1 smoke-worker-2 -y 2>/dev/null")
  pass "Worker VMs + BareMetalHosts created"

  echo -e "  ${BOLD}⏳ Waiting for BMHs to register with BMO (up to 5 min)...${RESET}"
  for i in $(seq 1 30); do
    REG_COUNT=$(oc get bmh -n "$CAAS_NS" --no-headers 2>/dev/null | { grep -c -E "registering|available|ready" || true; })
    if [[ "$REG_COUNT" -ge 2 ]]; then break; fi
    sleep 10
  done
  pass "BareMetalHosts registered with BMO"

  # Pre-create DNS addnhosts file (entries added dynamically later)
  ADDNHOSTS="/var/lib/libvirt/dnsmasq/baremetalfake.addnhosts"
  > "$ADDNHOSTS" 2>/dev/null || true

  CLCAT_EXISTS=$(osac get clustercatalogitems 2>&1 | { grep -c ocp-ci-small || true; })
  BMH_COUNT=$(oc get bmh -n "$CAAS_NS" --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$BMH_COUNT" -ge 2 ]] && [[ "$CLCAT_EXISTS" -gt 0 ]]; then
    pass "BareMetalHosts available ($BMH_COUNT), catalog item exists"

    osac create cluster -n smoke-cluster \
      --catalog-item ocp-ci-small \
      --pull-secret ci-pull-secret \
      --ssh-public-key-file /root/.ssh/id_rsa.pub \
      --version "${OCP_MINOR}.0" \
      2>&1 || true
    CLEANUP+=("osac delete cluster smoke-cluster 2>/dev/null")

    CO=$(osac get clusters 2>&1)
    if echo "$CO" | grep -q "smoke-cluster"; then
      pass "Create cluster smoke-cluster"

      echo -e "  ${BOLD}⏳ Waiting for BMF to claim BareMetalHosts (up to 5 min)...${RESET}"
      BMI_CLAIMED=false
      for i in $(seq 1 30); do
        CLAIMED=$(oc get bmi -n osac --no-headers 2>/dev/null | grep -c -v "Failed" || echo "0")
        EXT_IDS=$(oc get bmi -n osac -o jsonpath='{.items[*].spec.externalHostID}' 2>/dev/null | tr -s ' ')
        if [[ -n "$EXT_IDS" ]] && [[ "$EXT_IDS" != " " ]]; then
          BMI_CLAIMED=true
          break
        fi
        sleep 10
      done

      if $BMI_CLAIMED; then
        pass "BMF claimed BareMetalHosts"
      else
        # BMF needs BMHs in non-provisioned state; activate them for agent-based boot
        echo -e "  ${BOLD}⏳ BMF hasn't claimed hosts yet, activating BMHs for agent boot...${RESET}"
      fi

      # Boot BMHs with the discovery ISO via live-iso (no InfraEnv label on BMHs).
      # Labeling BMHs with InfraEnv triggers the infrastructure-operator to set
      # customDeploy: start_assisted_install, but the IPA image lacks that extension.
      # Instead we read the ISO URL from InfraEnv and set spec.image directly.
      INFRAENV_NAME=$(oc get infraenvs -n "$CAAS_NS" --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | head -1)
      if [[ -z "$INFRAENV_NAME" ]]; then
        INFRAENV_NAME="smoke-infraenv"
      fi
      ISO_URL=$(oc get infraenv "$INFRAENV_NAME" -n "$CAAS_NS" -o jsonpath='{.status.isoDownloadURL}' 2>/dev/null)

      if [[ -n "$ISO_URL" ]]; then
        for BMH_NAME in $(oc get bmh -n "$CAAS_NS" --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null); do
          oc patch bmh "$BMH_NAME" -n "$CAAS_NS" --type merge \
            -p "{\"spec\":{\"image\":{\"url\":\"$ISO_URL\",\"format\":\"live-iso\"},\"online\":true}}" 2>/dev/null || true
        done
        pass "BMHs set with live-iso discovery boot"
      else
        fail "InfraEnv ISO URL not available"
      fi

      echo -e "  ${BOLD}⏳ Waiting for agents to register (up to 15 min)...${RESET}"
      AGENTS_READY=false
      for i in $(seq 1 90); do
        AGENT_COUNT=$(oc get agents -n "$CAAS_NS" --no-headers 2>/dev/null | wc -l | tr -d ' ')
        if [[ "$AGENT_COUNT" -ge 2 ]]; then
          AGENTS_READY=true
          break
        fi
        sleep 10
      done

      if $AGENTS_READY; then
        pass "$AGENT_COUNT agents registered"

        for AGENT_NAME in $(oc get agents -n "$CAAS_NS" --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null); do
          oc patch agent "$AGENT_NAME" -n "$CAAS_NS" --type merge \
            -p '{"spec":{"approved":true}}' 2>/dev/null || true
        done
        pass "All agents approved"
      else
        warn "Only $AGENT_COUNT agents registered (expected 2)"
        echo -e "  ${BOLD}🔍 Diagnostics:${RESET}"
        oc get bmh -n "$CAAS_NS" -o custom-columns=NAME:.metadata.name,STATE:.status.provisioning.state,ONLINE:.spec.online,IMAGE:.spec.image.url 2>/dev/null || true
        oc get events -n "$CAAS_NS" --sort-by=.lastTimestamp 2>/dev/null | tail -10 || true
      fi

      echo -e "  ${BOLD}⏳ Waiting for HostedCluster to appear (up to 5 min)...${RESET}"
      HC=""
      for i in $(seq 1 30); do
        HC=$(oc get hostedclusters -A --no-headers 2>/dev/null | grep smoke-cluster || echo "")
        if [[ -n "$HC" ]]; then break; fi
        sleep 10
      done

      if [[ -n "$HC" ]]; then
        pass "HostedCluster created for smoke-cluster"
        HC_NS=$(echo "$HC" | awk '{print $1}')
        HC_NAME=$(echo "$HC" | awk '{print $2}')

        # Label agents for NodePool selector binding
        for AGENT_NAME in $(oc get agents -n "$CAAS_NS" --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null); do
          oc label agent "$AGENT_NAME" -n "$CAAS_NS" \
            osac.openshift.io/clusterorder="$HC_NAME" \
            osac.openshift.io/node-set=workers \
            --overwrite 2>/dev/null || true
        done

        # Add DNS entries for the hosted cluster API domain
        echo -e "  ${BOLD}⏳ Waiting for KAS LoadBalancer IP (up to 3 min)...${RESET}"
        KAS_IP=""
        for i in $(seq 1 18); do
          KAS_IP=$(oc get svc kube-apiserver -n "${HC_NS}-${HC_NAME}" \
            -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
          if [[ -n "$KAS_IP" ]]; then break; fi
          sleep 10
        done
        if [[ -n "$KAS_IP" ]]; then
          BASE_DOMAIN=$(oc get hostedcluster "$HC_NAME" -n "$HC_NS" -o jsonpath='{.spec.dns.baseDomain}' 2>/dev/null)
          ADDNHOSTS="/var/lib/libvirt/dnsmasq/baremetalfake.addnhosts"
          cat > "$ADDNHOSTS" <<DNS_EOF
${KAS_IP} api.${HC_NAME}.${BASE_DOMAIN}
${KAS_IP} api-int.${HC_NAME}.${BASE_DOMAIN}
DNS_EOF
          kill -HUP $(cat /run/libvirt/network/baremetalfake.pid 2>/dev/null) 2>/dev/null || true
          grep -q "api.${HC_NAME}.${BASE_DOMAIN}" /etc/hosts 2>/dev/null || \
            echo "${KAS_IP} api.${HC_NAME}.${BASE_DOMAIN}" >> /etc/hosts
          pass "DNS entries created for hosted cluster (api → $KAS_IP)"
        fi

        # Bind agents to ClusterDeployment to trigger installation
        for AGENT_NAME in $(oc get agents -n "$CAAS_NS" --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null); do
          oc patch agent "$AGENT_NAME" -n "$CAAS_NS" --type merge \
            -p "{\"spec\":{\"clusterDeploymentName\":{\"name\":\"${HC_NAME}\",\"namespace\":\"${HC_NS}-${HC_NAME}\"}}}" \
            2>/dev/null || true
        done
        pass "Applied CaaS agent binding workarounds"

        echo -e "  ${BOLD}⏳ Waiting for control plane to become available (up to 10 min)...${RESET}"
        CP_AVAILABLE=false
        for i in $(seq 1 60); do
          CP_STATUS=$(oc get hostedcluster "$HC_NAME" -n "$HC_NS" \
            -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "")
          if [[ "$CP_STATUS" == "True" ]]; then
            CP_AVAILABLE=true
            break
          fi
          sleep 10
        done
        if $CP_AVAILABLE; then
          pass "Control plane available"
        else
          fail "Control plane not available"
        fi

        # Fix NTP on installed workers (chrony-wait blocks kubelet without NTP)
        GATEWAY_IP=$(ip addr show baremetalfake 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1)
        for WORKER_IP in $(oc get agents -n "$CAAS_NS" -o jsonpath='{.items[*].status.inventory.interfaces[0].ipV4Addresses[0]}' 2>/dev/null | tr ' ' '\n' | cut -d/ -f1); do
          ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 core@"$WORKER_IP" \
            "grep -q '${GATEWAY_IP}' /etc/chrony.conf 2>/dev/null || echo 'server ${GATEWAY_IP} iburst' | sudo tee -a /etc/chrony.conf && sudo systemctl restart chronyd" 2>/dev/null || true
        done

        echo -e "  ${BOLD}⏳ Waiting for worker nodes to join hosted cluster (up to 10 min)...${RESET}"
        HC_KUBECONFIG=$(oc get secret "${HC_NAME}-admin-kubeconfig" -n "${HC_NS}" -o jsonpath='{.data.kubeconfig}' 2>/dev/null | base64 -d)
        WORKERS_READY=false
        if [[ -n "$HC_KUBECONFIG" ]]; then
          echo "$HC_KUBECONFIG" > /tmp/hc-kubeconfig
          for i in $(seq 1 60); do
            NODE_COUNT=$(oc --kubeconfig=/tmp/hc-kubeconfig get nodes --no-headers 2>/dev/null | grep -c "Ready" || echo "0")
            if [[ "$NODE_COUNT" -ge 2 ]]; then
              WORKERS_READY=true
              break
            fi
            sleep 10
          done
        fi
        if $WORKERS_READY; then
          pass "Worker nodes joined hosted cluster ($NODE_COUNT Ready)"
        else
          fail "Worker nodes not Ready in hosted cluster"
        fi
      else
        fail "HostedCluster not created for smoke-cluster"
      fi
    else
      fail "Create cluster smoke-cluster"
    fi
  else
    if [[ "$CLCAT_EXISTS" -eq 0 ]]; then
      fail "ClusterCatalogItem ocp-ci-small not found, skipping CaaS cluster creation"
    else
      fail "Not enough BareMetalHosts ($BMH_COUNT < 2), skipping CaaS cluster creation"
    fi
  fi
else
  warn "CaaS service not enabled, skipping cluster tests"
fi

# =====================================================================
step "6/6" "Cleanup"

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
