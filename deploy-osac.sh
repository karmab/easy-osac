#!/usr/bin/env bash

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
ok()   { echo -e "  ${GREEN}✅ $1${RESET}"; }
fail() { echo -e "  ${RED}❌ $1${RESET}" >&2; }
warn() { echo -e "  ${YELLOW}⚠️  $1${RESET}"; }
step() {
  echo ""
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo -e "  🔧 ${BOLD}[$1] $2${RESET}"
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
}

export DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
export NS=osac

# =====================================================================
step "1/7" "Pre-requisites (CRDs, repos, chart deps)"

if [[ -d osac ]]; then
  cd osac && git pull && cd osac-installer
else
  git clone https://github.com/osac-project/osac.git
  cd osac/osac-installer
fi

helm repo add topolvm https://topolvm.github.io/topolvm --force-update
helm repo add jetstack https://charts.jetstack.io --force-update
ok "Helm repos added"

helm template trust-manager jetstack/trust-manager --version v0.20.0 \
  --show-only templates/crd-trust.cert-manager.io_bundles.yaml | oc apply -f -
ok "trust-manager CRD installed"

helm template topolvm topolvm/topolvm \
  --show-only templates/crds/topolvm.io_logicalvolumes.yaml | oc apply -f -
ok "topolvm CRD installed"

helm dependency build charts/osac-deps
helm dependency build charts/osac-infra
helm dependency build charts/osac
ok "Chart dependencies built"

# =====================================================================
step "2/7" "Phase 1a: osac-deps (operators)"

helm upgrade --install osac-deps charts/osac-deps -n osac-deps --create-namespace \
  --set certManager.enabled=true \
  --set aapOperator.enabled=true \
  --set "aapOperator.channel=stable-2.6-cluster-scoped" \
  --set kafka.enabled=true \
  --set cnv.enabled=true \
  --set metallb.enabled=false \
  --set lvms.enabled=false \
  --set mce.enabled=true \
  --wait --timeout 20m
ok "osac-deps installed"

echo -e "  ${BOLD}⏳ Waiting for Kafka install plan...${RESET}"
until INSTALL_PLAN=$(oc get subscription amq-streams -n osac-kafka -o jsonpath='{.status.installPlanRef.name}' 2>/dev/null) && [[ -n "$INSTALL_PLAN" ]]; do
  sleep 10
done
oc patch installplan "$INSTALL_PLAN" -n osac-kafka --type merge -p '{"spec":{"approved":true}}'
ok "Kafka install plan approved ($INSTALL_PLAN)"

echo -e "  ${BOLD}⏳ Waiting for Kafka CSV...${RESET}"
until oc get csv -n osac-kafka -l operators.coreos.com/amq-streams.osac-kafka -o name 2>/dev/null | grep -q .; do
  sleep 10
done
oc wait csv -n osac-kafka -l operators.coreos.com/amq-streams.osac-kafka --for=jsonpath='{.status.phase}'=Succeeded --timeout=300s
ok "Kafka operator ready"

# =====================================================================
step "3/7" "Phase 1b: osac-infra (trust, keycloak, vault, postgres, kafka, MCE)"

helm upgrade --install osac-infra charts/osac-infra -n osac-infra --create-namespace \
  --set certManager.enabled=true \
  --set trustManager.enabled=true \
  --set caIssuer.enabled=true \
  --set keycloak.enabled=true \
  --set "keycloak.hostname=keycloak-keycloak.$DOMAIN" \
  --set "keycloak.route.hostname=keycloak-keycloak.$DOMAIN" \
  --set keycloak.devFixtures.enabled=true \
  --set aapOperator.enabled=false \
  --set cnv.enabled=true \
  --set lvms.enabled=false \
  --set metallb.enabled=false \
  --set mce.enabled=true \
  --set kafka.enabled=true \
  --set bundledPostgres.enabled=true \
  --set bundledVault.enabled=true \
  --set "bundledVault.keycloakIssuerUrl=https://keycloak-keycloak.$DOMAIN/realms/osac" \
  --timeout 30m
ok "osac-infra helm release submitted"

echo -e "  ${BOLD}⏳ Waiting for infra components...${RESET}"
oc wait deployment openbao -n osac-infra --for=condition=Available --timeout=600s
ok "OpenBao ready"
oc wait deployment postgres -n osac-infra --for=condition=Available --timeout=600s
ok "PostgreSQL ready"
until oc get route keycloak -n keycloak -o name 2>/dev/null | grep -q .; do
  sleep 10
done
ok "Keycloak route available"

echo -e "  ${BOLD}⏳ Waiting for MCE to be Available...${RESET}"
until [[ "$(oc get multiclusterengine multiclusterengine -n multicluster-engine -o jsonpath='{.status.phase}' 2>/dev/null)" == "Available" ]]; do
  sleep 15
done
ok "MCE Available"

echo -e "  ${BOLD}⏳ Waiting for assisted-service...${RESET}"
oc wait deployment assisted-service -n multicluster-engine --for=condition=Available --timeout=600s
ok "assisted-service ready"

# =====================================================================
step "4/7" "AAP manifest"

oc create namespace "$NS" --dry-run=client -o yaml | oc apply -f -
oc create secret generic config-as-code-manifest-ig \
  --from-file=license.zip=/root/manifest.zip \
  -n "$NS" --dry-run=client -o yaml | oc apply --server-side -f -
oc label secret config-as-code-manifest-ig osac.openshift.io/project=osac-aap -n "$NS" --overwrite
ok "AAP manifest configured in namespace $NS"

# =====================================================================
step "5/7" "Phase 2: osac platform"

oc delete job -n "$NS" -l app.kubernetes.io/managed-by=Helm --field-selector=status.successful=0 2>/dev/null || true
HELM_STATUS=$(helm status osac -n "$NS" -o json 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('info',{}).get('status',''))" 2>/dev/null || echo "")
if [[ "$HELM_STATUS" == "failed" ]]; then
  warn "Previous helm release is in 'failed' state, uninstalling to allow clean install"
  helm uninstall osac -n "$NS" --no-hooks 2>/dev/null || true
fi

helm upgrade --install osac charts/osac -n "$NS" --create-namespace --force-conflicts \
  -f values/vmaas-ci/instance.yaml \
  --set global.clusterDomain="$DOMAIN" \
  --set service.externalHostname="fulfillment-api-$NS.$DOMAIN" \
  --set service.internalHostname="fulfillment-internal-api-$NS.$DOMAIN" \
  --set "ui.auth.oidcIssuerURL=https://keycloak-keycloak.$DOMAIN/realms/osac" \
  --set lvms.enabled=false \
  --set global.services.bmaas.enabled=true \
  --set global.services.caas.enabled=true \
  --timeout 15m || warn "helm exited non-zero (AAP hook may have failed — non-blocking)"
ok "osac helm release submitted"

echo -e "  ${BOLD}⏳ Waiting for core OSAC services...${RESET}"
oc wait deployment fulfillment-grpc-server -n "$NS" --for=condition=Available --timeout=600s
ok "fulfillment-grpc-server ready"
oc wait deployment fulfillment-rest-gateway -n "$NS" --for=condition=Available --timeout=600s
ok "fulfillment-rest-gateway ready"
oc wait deployment osac-ui -n "$NS" --for=condition=Available --timeout=600s
ok "osac-ui ready"
oc wait deployment fulfillment-controller -n "$NS" --for=condition=Available --timeout=600s 2>/dev/null || warn "fulfillment-controller not ready (may need router restart)"

echo -e "  ${BOLD}🔄 Restarting ingress router (passthrough TLS fix)...${RESET}"
oc rollout restart deployment/router-default -n openshift-ingress
oc rollout status deployment/router-default -n openshift-ingress --timeout=120s
ok "Ingress router restarted"

echo -e "  ${BOLD}🔑 Patching Keycloak osac-ui client redirect URIs...${RESET}"
KC_URL="https://keycloak-keycloak.$DOMAIN"
UI_URL="https://osac-ui-$NS.$DOMAIN"
KC_TOKEN=$(curl -sk "$KC_URL/realms/master/protocol/openid-connect/token" \
  -d "grant_type=password&client_id=admin-cli&username=admin&password=admin" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")
KC_CLIENT_UUID=$(curl -sk -H "Authorization: Bearer $KC_TOKEN" \
  "$KC_URL/admin/realms/osac/clients?clientId=osac-ui" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['id'])")
curl -sk -X PUT -H "Authorization: Bearer $KC_TOKEN" -H "Content-Type: application/json" \
  "$KC_URL/admin/realms/osac/clients/$KC_CLIENT_UUID" \
  -d "{\"clientId\":\"osac-ui\",\"redirectUris\":[\"${UI_URL}/*\"],\"webOrigins\":[\"${UI_URL}\"],\"rootUrl\":\"${UI_URL}\"}"
ok "Keycloak osac-ui redirect set to $UI_URL"

echo -e "  ${BOLD}🔑 Adding profile and email scopes to osac-ui client...${RESET}"
for SCOPE_NAME in profile email; do
  SCOPE_ID=$(curl -sk -H "Authorization: Bearer $KC_TOKEN" \
    "$KC_URL/admin/realms/osac/client-scopes" \
    | python3 -c "import sys,json; print([s['id'] for s in json.load(sys.stdin) if s['name']=='$SCOPE_NAME'][0])")
  curl -sk -X PUT -H "Authorization: Bearer $KC_TOKEN" \
    "$KC_URL/admin/realms/osac/clients/$KC_CLIENT_UUID/default-client-scopes/$SCOPE_ID"
done
ok "Keycloak osac-ui scopes configured (profile, email)"

echo -e "  ${BOLD}🔑 Resetting demo user passwords to 'admin'...${RESET}"
OSAC_USERS=$(curl -sk -H "Authorization: Bearer $KC_TOKEN" "$KC_URL/admin/realms/osac/users?max=50")
echo "$OSAC_USERS" | python3 -c "
import sys,json
for u in json.load(sys.stdin):
    print(u['id'], u['username'])
" | while read -r USER_ID UNAME; do
  curl -sk -X PUT -H "Authorization: Bearer $KC_TOKEN" -H "Content-Type: application/json" \
    "$KC_URL/admin/realms/osac/users/$USER_ID/reset-password" \
    -d '{"type":"password","value":"admin","temporary":false}'
done
ok "All demo user passwords set to 'admin'"

step "6/7" "Bootstrapping smoke-test tenant and catalog"

echo -e "  ${BOLD}🔑 Creating AAP API token for osac-operator...${RESET}"
AAP_ADMIN_PASS=$(oc get secret osac-aap-admin-password -n "$NS" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "")
if [[ -n "$AAP_ADMIN_PASS" ]]; then
  AAP_TOKEN=$(oc exec deploy/osac-operator -n "$NS" -- \
    curl -s -X POST http://osac-aap/api/controller/v2/tokens/ \
    -u "admin:$AAP_ADMIN_PASS" -H 'Content-Type: application/json' \
    -d '{"scope":"write"}' 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])" 2>/dev/null || echo "")
  if [[ -n "$AAP_TOKEN" ]]; then
    oc create secret generic osac-aap-api-token -n "$NS" \
      --from-literal=token="$AAP_TOKEN" --dry-run=client -o yaml | oc apply -f -
    oc rollout restart deployment/osac-operator -n "$NS"
    oc rollout status deployment/osac-operator -n "$NS" --timeout=60s 2>/dev/null || true
    ok "AAP API token created and operator restarted"

    # BMF operator needs explicit AAP URL to enable provisioning workflows
    oc set env deploy/bmf-operator-controller-manager -n "$NS" \
      OSAC_AAP_URL="https://osac-aap-controller-service.$NS.svc.cluster.local"
    oc rollout restart deployment/bmf-operator-controller-manager -n "$NS" 2>/dev/null || true
    oc rollout status deployment/bmf-operator-controller-manager -n "$NS" --timeout=120s 2>/dev/null || true
    ok "BMF operator configured with AAP URL"

    # AAP needs NETWORK_STEPS_COLLECTION to dispatch cluster network tasks.
    # Without it, osac.service.cluster_network include_role resolves to itself → infinite recursion.
    oc patch configmap cluster-fulfillment-ig -n "$NS" --type=merge \
      -p '{"data":{"NETWORK_STEPS_COLLECTION":"ci.steps"}}' 2>/dev/null || true
    ok "AAP network steps collection configured"
  else
    warn "Could not create AAP token (AAP may not be ready)"
  fi
else
  warn "AAP admin password not found, skipping token creation"
fi

# AAP EE workarounds: missing Ansible roles that break all tenant provisioning
echo -e "  ${BOLD}🔧 Patching AAP EE with missing Ansible roles...${RESET}"
AAP_TASK_POD=$(oc get pods -n "$NS" -l app.kubernetes.io/component=osac-aap-controller-task --no-headers 2>/dev/null | awk '{print $1}')
if [[ -n "$AAP_TASK_POD" ]]; then
  AAP_BASE="/var/lib/awx/projects/_8__osac/osac-aap/collections/ansible_collections/osac/templates/roles"

  # 1) Create odf_storage role — ODF storage provider has no Ansible role,
  #    causing ALL tenant storage onboarding to fail
  oc exec -n "$NS" "$AAP_TASK_POD" -c osac-aap-controller-task -- bash -c "
    mkdir -p $AAP_BASE/odf_storage/tasks $AAP_BASE/odf_storage/defaults
    cat > $AAP_BASE/odf_storage/defaults/main.yaml <<'ROLE_EOF'
odf_storage_tenant_config_secret_prefix: \"odf-tenant-config-\"
ROLE_EOF
    cat > $AAP_BASE/odf_storage/tasks/main.yaml <<'ROLE_EOF'
---
- name: ODF storage dispatch (no-op default)
  ansible.builtin.debug:
    msg: \"ODF storage action dispatched\"
ROLE_EOF
    cat > $AAP_BASE/odf_storage/tasks/setup.yaml <<'ROLE_EOF'
---
- name: Create hub lifecycle marker Secret for tenant
  kubernetes.core.k8s:
    state: present
    definition:
      apiVersion: v1
      kind: Secret
      metadata:
        name: \"odf-tenant-config-{{ tenant_name }}\"
        namespace: \"{{ lookup('env', 'OSAC_STORAGE_CONFIG_NAMESPACE') | default(lookup('file', '/var/run/secrets/kubernetes.io/serviceaccount/namespace', errors='ignore'), true) }}\"
        labels:
          osac.openshift.io/tenant: \"{{ tenant_name }}\"
          osac.openshift.io/storage-provider: odf
          app.kubernetes.io/managed-by: osac-aap
      stringData:
        provider: odf
- name: Set tenant config output (required by dispatcher)
  ansible.builtin.set_fact:
    storage_provider_tenant_config:
      provider: odf
ROLE_EOF
    cat > $AAP_BASE/odf_storage/tasks/ensure_storage_class.yaml <<'ROLE_EOF'
---
# ODF StorageClasses are pre-provisioned by the ODF operator and already
# resolved by osac-operator into tenant_storage_classes extra_vars.
# Returning empty avoids corrupting the typed list (strings vs dicts)
# in the playbook JIT append step.
- name: ODF StorageClasses are pre-provisioned (no JIT export)
  ansible.builtin.debug:
    msg: \"ODF StorageClasses managed by ODF operator\"
ROLE_EOF
    cat > $AAP_BASE/odf_storage/tasks/teardown_cluster_storage.yaml <<'ROLE_EOF'
---
- name: ODF teardown cluster storage (no-op)
  ansible.builtin.debug:
    msg: \"ODF cluster storage teardown (no-op)\"
ROLE_EOF
    cat > $AAP_BASE/odf_storage/tasks/teardown_backend.yaml <<'ROLE_EOF'
---
- name: ODF teardown backend (no-op)
  ansible.builtin.debug:
    msg: \"ODF backend teardown (no-op)\"
ROLE_EOF
  " 2>/dev/null
  ok "Created odf_storage Ansible role in AAP EE"

  # 2) Create smoke_fedora symlink to ocp_virt_vm — template ID is used as role name
  oc exec -n "$NS" "$AAP_TASK_POD" -c osac-aap-controller-task -- bash -c "
    cd $AAP_BASE && ln -sf ocp_virt_vm smoke_fedora
  " 2>/dev/null
  ok "Created smoke_fedora -> ocp_virt_vm symlink in AAP EE"
else
  warn "AAP task pod not found, skipping EE role patches"
fi

# Add ingress CA to cert-manager trust bundle so operators can verify TLS
INGRESS_CA=$(oc get cm default-ingress-cert -n openshift-config-managed \
  -o jsonpath='{.data.ca-bundle\.crt}' | awk 'BEGIN{n=0} /-----BEGIN CERTIFICATE-----/{n++} n==2{print} n==2 && /-----END CERTIFICATE-----/{exit}')
if [[ -n "$INGRESS_CA" ]]; then
  oc create secret generic ingress-ca --from-literal=ca.crt="$INGRESS_CA" \
    -n cert-manager --dry-run=client -o yaml | oc apply -f -
  BUNDLE_SOURCES=$(oc get bundle ca-bundle -o jsonpath='{.spec.sources}' 2>/dev/null)
  if ! echo "$BUNDLE_SOURCES" | grep -q ingress-ca; then
    oc patch bundle ca-bundle --type=json \
      -p='[{"op":"add","path":"/spec/sources/-","value":{"secret":{"key":"ca.crt","name":"ingress-ca"}}}]'
  fi
  sleep 3
  ok "Ingress CA added to trust bundle"
fi

# osac-operator needs SSL_CERT_FILE pointing to the CA bundle for TLS verification
oc set env deploy/osac-operator -n "$NS" SSL_CERT_FILE=/etc/ca-bundle/bundle.pem
oc rollout restart deploy/osac-operator -n "$NS"
oc rollout status deploy/osac-operator -n "$NS" --timeout=120s 2>/dev/null || true
ok "osac-operator configured with CA bundle"

curl -sL "https://github.com/fullstorydev/grpcurl/releases/download/v1.9.3/grpcurl_1.9.3_linux_x86_64.tar.gz" \
  | tar xz -C /usr/local/bin grpcurl
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
ok "grpcurl and osac CLI installed"

API_URL="fulfillment-api-$NS.$DOMAIN:443"
echo -e "  ${BOLD}⏳ Waiting for OSAC API to accept login (up to 2 min)...${RESET}"
for i in $(seq 1 12); do
  osac login "$API_URL" --user=admin --password=admin --insecure --flow=password 2>&1 && break
  sleep 10
done

oc label sc odf-storagecluster-ceph-rbd \
  osac.openshift.io/tenant=Default \
  osac.openshift.io/storage-tier=default \
  --overwrite 2>/dev/null \
  || warn "StorageClass odf-storagecluster-ceph-rbd not found"

oc create namespace smoke-test --dry-run=client -o yaml | oc apply -f -

cat <<'TENANT_EOF' | oc apply -f -
apiVersion: osac.openshift.io/v1alpha1
kind: Tenant
metadata:
  name: smoke-test
  namespace: osac
spec:
  namespaces:
    - smoke-test
TENANT_EOF
ok "Tenant CR created"

INT_API="fulfillment-internal-api-$NS.$DOMAIN:443"
SA_TOKEN=$(oc create token admin -n osac --duration=1h --as system:admin 2>/dev/null || echo "")

grpcurl -insecure -H "Authorization: Bearer $SA_TOKEN" \
  -d '{"object":{"metadata":{"name":"system"}}}' \
  "$INT_API" osac.private.v1.Users/Create 2>&1 || true
grpcurl -insecure -H "Authorization: Bearer $SA_TOKEN" \
  -d '{"object":{"metadata":{"name":"admin"}}}' \
  "$INT_API" osac.private.v1.Users/Create 2>&1 || true
ok "Users 'system' and 'admin' seeded"

grpcurl -insecure -H "Authorization: Bearer $SA_TOKEN" \
  -d '{"object":{"metadata":{"name":"smoke-test"}}}' \
  "$INT_API" osac.private.v1.Tenants/Create 2>&1 || true
ok "Tenant registered via private API"

# Label ODF StorageClass for the smoke-test tenant so the operator resolves it
oc label sc odf-storagecluster-ceph-rbd \
  osac.openshift.io/tenant=smoke-test \
  osac.openshift.io/storage-tier=default \
  --overwrite 2>/dev/null || true

BACKEND_ID=$(grpcurl -insecure -H "Authorization: Bearer $SA_TOKEN" \
  -d '{"object":{"metadata":{"name":"odf"},"spec":{"provider":"odf","endpoint":"n/a","credentials":{"username":"n/a","password":"n/a"}}}}' \
  "$INT_API" osac.private.v1.StorageBackends/Create 2>&1 \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['object']['id'])" 2>/dev/null || echo "")
if [[ -z "$BACKEND_ID" ]]; then
  BACKEND_ID=$(grpcurl -insecure -H "Authorization: Bearer $SA_TOKEN" \
    -d '{}' "$INT_API" osac.private.v1.StorageBackends/List 2>&1 \
    | python3 -c "import sys,json; items=json.load(sys.stdin).get('items',[]); print(next((i['id'] for i in items if i.get('metadata',{}).get('name')=='odf'), ''))" 2>/dev/null || echo "")
fi
ok "StorageBackend 'odf' ($BACKEND_ID)"

# Hub Secret is required by the storage controller's hubSecretExists() check
for TENANT_HUB in smoke-test shared system; do
  oc create secret generic "odf-tenant-config-${TENANT_HUB}" -n "$NS" \
    --from-literal=provider=odf --dry-run=client -o yaml | oc apply -f -
  oc label secret "odf-tenant-config-${TENANT_HUB}" -n "$NS" \
    "osac.openshift.io/tenant=${TENANT_HUB}" \
    "osac.openshift.io/storage-provider=odf" \
    --overwrite 2>/dev/null || true
done
ok "Hub Secrets created for ODF storage backend"

grpcurl -insecure -H "Authorization: Bearer $SA_TOKEN" \
  -d "{\"object\":{\"metadata\":{\"name\":\"default\"},\"spec\":{\"protocol\":\"STORAGE_PROTOCOL_BLOCK\",\"backends\":[{\"backend_id\":\"$BACKEND_ID\"}]}}}" \
  "$INT_API" osac.private.v1.StorageTiers/Create 2>&1 || true
ok "StorageTier 'default'"

grpcurl -insecure -H "Authorization: Bearer $SA_TOKEN" \
  -d '{"object":{"metadata":{"name":"default"},"title":"K8s-only networking","description":"VMaaS overlay with CUDN fabric","k8s_manager":"k8s_only","fabric_manager":"cudn_net","capabilities":{"supports_ipv4":true},"spec":{"defaults":{"virtual_network_ipv4_cidr":"10.128.0.0/14","subnet_ipv4_cidr":"10.128.0.0/23"}}}}' \
  "$INT_API" osac.private.v1.NetworkClasses/Create 2>&1 || true
ok "NetworkClass 'default'"

echo -e "  ${BOLD}⏳ Waiting for hub-access secret (up to 3 min)...${RESET}"
for i in $(seq 1 18); do
  oc get secret hub-access -n "$NS" &>/dev/null && break
  sleep 10
done
HUB_TOKEN=$(oc get secret hub-access -n "$NS" -o jsonpath='{.data.token}' 2>/dev/null | base64 -d || echo "")
if [[ -n "$HUB_TOKEN" ]]; then
  HUB_KUBECONFIG=$(python3 -c "
import json, base64, subprocess
r = subprocess.run(['oc','config','view','--raw','--minify','-o','json'], capture_output=True, text=True)
kc = json.loads(r.stdout)
kc['users'][0]['user'] = {'token': '$HUB_TOKEN'}
print(base64.b64encode(json.dumps(kc).encode()).decode())
")
  grpcurl -insecure -H "Authorization: Bearer $SA_TOKEN" \
    -d "{\"object\":{\"metadata\":{\"name\":\"local\"},\"spec\":{\"kubeconfig\":\"$HUB_KUBECONFIG\",\"namespace\":\"$NS\"}}}" \
    "$INT_API" osac.private.v1.Hubs/Create 2>&1 || true
  ok "Hub 'local' registered"
else
  warn "hub-access secret not found, skipping Hub registration (NetworkClass may stay PENDING)"
fi

OCP_VERSION=$(oc get clusterversion version -o jsonpath='{.status.desired.version}')
OCP_MINOR="${OCP_VERSION%.*}"
CV_NAME="${OCP_MINOR//./-}-0"
grpcurl -insecure -H "Authorization: Bearer $SA_TOKEN" \
  -d "{\"object\":{\"metadata\":{\"name\":\"$CV_NAME\"},\"spec\":{\"version\":\"${OCP_MINOR}.0\",\"image\":\"quay.io/openshift-release-dev/ocp-release:${OCP_MINOR}.0-multi\",\"enabled\":true}}}" \
  "$INT_API" osac.private.v1.ClusterVersions/Create 2>&1 || true
ok "ClusterVersion '${OCP_MINOR}.0' (shared tenant)"

echo -e "  ${BOLD}⏳ Waiting for NetworkClass to become READY (up to 5 min)...${RESET}"
for i in $(seq 1 30); do
  NC_STATE=$(grpcurl -insecure -H "Authorization: Bearer $SA_TOKEN" \
    -d '{}' "$INT_API" osac.private.v1.NetworkClasses/List 2>&1 \
    | python3 -c "import sys,json; items=json.load(sys.stdin).get('items',[]); print(items[0]['status']['state'] if items else 'NONE')" 2>/dev/null)
  if [[ "$NC_STATE" == "NETWORK_CLASS_STATE_READY" ]]; then break; fi
  sleep 10
done
if [[ "$NC_STATE" == "NETWORK_CLASS_STATE_READY" ]]; then
  ok "NetworkClass READY"
else
  warn "NetworkClass state: $NC_STATE (expected READY)"
fi

# cudn_net fabric role doesn't create the output ConfigMap the osac-operator expects.
# Wait for the default subnet CR, then create the ConfigMap so the k8s target can proceed.
echo -e "  ${BOLD}⏳ Waiting for default subnet CR (up to 3 min)...${RESET}"
SUBNET_CR=""
for i in $(seq 1 18); do
  SUBNET_CR=$(oc get subnets.osac.openshift.io -n "$NS" --no-headers 2>/dev/null | awk '{print $1}' | head -1)
  if [[ -n "$SUBNET_CR" ]]; then break; fi
  sleep 10
done
if [[ -n "$SUBNET_CR" ]]; then
  sleep 15
  if ! oc get configmap "subnet-${SUBNET_CR}-fabric-output" -n "$NS" &>/dev/null; then
    SUBNET_CIDR=$(oc get subnet.osac.openshift.io "$SUBNET_CR" -n "$NS" \
      -o jsonpath='{.spec.ipv4CIDR}' 2>/dev/null || echo "10.128.0.0/23")
    IFS='/' read -r NET_ADDR MASK <<< "$SUBNET_CIDR"
    IFS='.' read -r A B C D <<< "$NET_ADDR"
    RESERVED_START="${A}.${B}.${C}.$((D+1))"
    RESERVED_END="${A}.${B}.${C}.$((D+10))"
    oc create configmap "subnet-${SUBNET_CR}-fabric-output" -n "$NS" \
      --from-literal=l2_vni=10000 \
      --from-literal=l3_vni=10001 \
      --from-literal=fabric_reserved_range="${RESERVED_START}-${RESERVED_END}" \
      --dry-run=client -o yaml | oc apply -f -
    ok "Created fabric-output ConfigMap for ${SUBNET_CR}"
  else
    ok "Fabric-output ConfigMap already exists for ${SUBNET_CR}"
  fi
else
  warn "No subnet CR found, fabric-output ConfigMap not created"
fi

grpcurl -insecure -H "Authorization: Bearer $SA_TOKEN" \
  -d '{"object":{"metadata":{"name":"smoke-2c4g"},"spec":{"vcpus":2,"memory_gib":4,"description":"Smoke test 2 vCPU 4 GiB","state":"INSTANCE_TYPE_STATE_ACTIVE"}}}' \
  "$INT_API" osac.private.v1.InstanceTypes/Create 2>&1 || true
ok "InstanceType 'smoke-2c4g'"

grpcurl -insecure -H "Authorization: Bearer $SA_TOKEN" \
  -d '{"object":{"metadata":{"name":"ci-worker-bm"},"spec":{"hardware":{"cpu":{"cores":8,"architecture":"amd64","threads_per_core":1},"memory":{"total_gb":16},"network_ports":[{"name":"eth0","role":"fabric","type":"ethernet","speed":"10G"}]},"description":"CI worker 8 cores 16 GB","host_label_selector":{"match_labels":{"usage":"ci"}}}}}' \
  "$INT_API" osac.private.v1.BareMetalInstanceTypes/Create 2>&1 || true
ok "BareMetalInstanceType 'ci-worker-bm'"

osac tenant shared 2>&1
osac create diskimage --name fedora-41 --source-ref quay.io/containerdisks/fedora:41 --architecture amd64 2>&1 || true
ok "DiskImage 'fedora-41'"

cat <<'TMPL_EOF' | osac create -f - 2>&1 || true
"@type": type.googleapis.com/osac.public.v1.ComputeInstanceTemplate
metadata:
  name: smoke-fedora
title: Smoke Fedora
description: Fedora 41 for smoke tests
spec_defaults:
  instance_type:
    name: smoke-2c4g
  disk_image:
    name: fedora-41
  boot_disk:
    size_gib: 20
    storage_tier:
      name: default
  run_strategy: COMPUTE_INSTANCE_RUN_STRATEGY_ALWAYS
TMPL_EOF
ok "ComputeInstanceTemplate 'smoke-fedora'"

osac create computeinstancecatalogitem -n fedora-41 --title "Fedora 41" --description "Fedora 41 VM" \
  --template smoke-fedora --published 2>&1 || true
ok "CatalogItem 'fedora-41' published"

osac tenant smoke-test 2>&1
osac create secret -n ci-pull-secret --type=pull-secret \
  --from-file=.dockerconfigjson=/root/openshift_pull.json 2>&1 || true
ok "Pull secret 'ci-pull-secret' in smoke-test tenant"

RHCOS_DI_NAME="rhcos-${OCP_MINOR//./-}"
grpcurl -insecure -H "Authorization: Bearer $SA_TOKEN" \
  -H "x-osac-tenant: smoke-test" \
  -d "{\"object\":{\"metadata\":{\"name\":\"$RHCOS_DI_NAME\",\"tenant\":\"smoke-test\"},\"spec\":{\"source_type\":\"SOURCE_TYPE_REGISTRY\",\"source_ref\":\"quay.io/openshift-release-dev/ocp-release:${OCP_MINOR}.0-multi\",\"guest_os_family\":\"GUEST_OS_FAMILY_LINUX\",\"architecture\":[\"ARCHITECTURE_AMD64\"],\"lifecycle\":\"DISK_IMAGE_LIFECYCLE_AVAILABLE\"}}}" \
  "$INT_API" osac.private.v1.DiskImages/Create 2>&1 || true
ok "DiskImage '$RHCOS_DI_NAME' for CaaS (smoke-test tenant)"

CV_NAME_LOCAL="${OCP_MINOR//./-}-0"
CV_RESULT=$(grpcurl -insecure -H "Authorization: Bearer $SA_TOKEN" \
  -H "x-osac-tenant: smoke-test" \
  -d "{\"object\":{\"metadata\":{\"name\":\"$CV_NAME_LOCAL\",\"tenant\":\"smoke-test\"},\"spec\":{\"version\":\"${OCP_MINOR}.0\",\"image\":\"quay.io/openshift-release-dev/ocp-release:${OCP_MINOR}.0-multi\",\"enabled\":true,\"is_default\":true,\"disk_image\":{\"name\":\"$RHCOS_DI_NAME\"}}}}" \
  "$INT_API" osac.private.v1.ClusterVersions/Create 2>&1 || true)
ok "ClusterVersion '${OCP_MINOR}.0' in smoke-test tenant (with disk image, default)"

cat <<CLCAT_EOF | osac create -f - 2>&1 || true
"@type": type.googleapis.com/osac.public.v1.ClusterCatalogItem
metadata:
  name: ocp-ci-small
title: CI OpenShift Cluster
description: "OpenShift ${OCP_MINOR} cluster for CI with 2 BM workers"
template:
  name: ocp-ci-small
  shared: true
published: true
fields:
  node_sets:
    editable:
      default_value:
        items:
          workers:
            size: 2
            baremetal_instance_type:
              name: ci-worker-bm
              shared: true
CLCAT_EOF
ok "ClusterCatalogItem 'ocp-ci-small' published (using shared template)"

CLCAT_CHECK=$(osac get clustercatalogitems 2>&1 || echo "")
if echo "$CLCAT_CHECK" | grep -q "ocp-ci-small"; then
  ok "ClusterCatalogItem verified"
else
  warn "ClusterCatalogItem creation may have failed — CaaS cluster test will be skipped"
fi

# =====================================================================
step "7/7" "CaaS: InfraEnv + BMH agents"

CAAS_NS=hardware-inventory
oc create namespace "$CAAS_NS" --dry-run=client -o yaml | oc apply -f -
ok "$CAAS_NS namespace"

cat <<'BMF_EOF' | oc apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: osac-inventory-config
  namespace: osac
stringData:
  inventory.yaml: |
    name: metal3-inventory
    type: metal3
    hostClass: metal3
    options:
      metal3:
        namespace: "hardware-inventory"
---
apiVersion: v1
kind: Secret
metadata:
  name: osac-management-config
  namespace: osac
stringData:
  management.yaml: |
    name: metal3-management
    type: metal3
    options:
      metal3:
        namespace: "hardware-inventory"
BMF_EOF
ok "BMF operator secrets (inventory + management config)"

oc rollout restart deployment/bmf-operator-controller-manager -n osac 2>/dev/null || true
oc rollout status deployment/bmf-operator-controller-manager -n osac --timeout=120s 2>/dev/null || warn "BMF operator not ready"

oc create secret generic caas-pull-secret -n "$CAAS_NS" \
  --from-file=.dockerconfigjson=/root/openshift_pull.json \
  --type=kubernetes.io/dockerconfigjson \
  --dry-run=client -o yaml | oc apply -f -
ok "Pull secret in $CAAS_NS"

# Enable chronyd to serve NTP to the baremetal network (agents need NTP sync)
sed -i 's/#allow 192.168.0.0\/16/allow 192.168.0.0\/16/' /etc/chrony.conf 2>/dev/null || true
systemctl restart chronyd 2>/dev/null || true

# Fix NTP on cluster control plane nodes (chrony-wait blocks kubelet boot)
for NODE_IP in $(oc get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null); do
  ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 core@"$NODE_IP" \
    "grep -q '192.168.254.1' /etc/chrony.conf 2>/dev/null || echo 'server 192.168.254.1 iburst' | sudo tee -a /etc/chrony.conf && sudo systemctl restart chronyd" 2>/dev/null || true
done

GATEWAY_IP=$(ip addr show baremetalfake 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1)
cat <<INFRAENV_EOF | oc apply -f -
apiVersion: agent-install.openshift.io/v1beta1
kind: InfraEnv
metadata:
  name: smoke-infraenv
  namespace: $CAAS_NS
  labels:
    osac.openshift.io/infra: smoke
spec:
  pullSecretRef:
    name: caas-pull-secret
  additionalNTPSources:
    - "${GATEWAY_IP:-192.168.254.1}"
INFRAENV_EOF
ok "InfraEnv 'smoke-infraenv' created (with NTP source)"

echo -e "  ${BOLD}⏳ Waiting for discovery ISO URL (up to 5 min)...${RESET}"
ISO_URL=""
for i in $(seq 1 30); do
  ISO_URL=$(oc get infraenv smoke-infraenv -n "$CAAS_NS" -o jsonpath='{.status.isoDownloadURL}' 2>/dev/null || echo "")
  if [[ -n "$ISO_URL" ]]; then break; fi
  sleep 10
done

if [[ -z "$ISO_URL" ]]; then
  warn "InfraEnv ISO URL not available, skipping CaaS agent provisioning"
else
  ok "Discovery ISO ready"

  echo -e "  ${BOLD}🖥️  Creating worker VMs and registering as BareMetalHosts...${RESET}"
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
    infraenvs.agent-install.openshift.io: smoke-infraenv
    usage: ci
spec:
  online: true
  bootMACAddress: "$MAC"
  automatedCleaningMode: disabled
  bmc:
    address: redfish-virtualmedia://192.168.254.1:9000/redfish/v1/Systems/local/$VM_NAME
    credentialsName: ${VM_NAME}-bmc
    disableCertificateVerification: true
EOF
  done
  ok "Worker VMs + BareMetalHosts created (smoke-worker-1, smoke-worker-2)"

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
    ok "$AGENT_COUNT agents registered"

    for AGENT_NAME in $(oc get agents -n "$CAAS_NS" --no-headers -o custom-columns=NAME:.metadata.name); do
      oc patch agent "$AGENT_NAME" -n "$CAAS_NS" --type merge \
        -p '{"spec":{"approved":true}}' 2>/dev/null || true
    done
    ok "All agents approved"

    # Pre-create DNS entries for the CaaS hosted cluster API/apps
    # The HostedCluster uses KAS LoadBalancer on the baremetal network and sslip.io ingress
    ADDNHOSTS="/var/lib/libvirt/dnsmasq/baremetalfake.addnhosts"
    VIP=$(ip addr show baremetalfake 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1)
    if [[ -n "$VIP" ]]; then
      > "$ADDNHOSTS"
      ok "DNS addnhosts file prepared (entries added dynamically by tests.sh)"
    fi
  else
    warn "Only $AGENT_COUNT agents registered (expected 2)"
  fi
fi

# =====================================================================
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "  ${GREEN}${BOLD}🎉 OSAC deployment complete${RESET}"
echo ""
echo -e "  ${BOLD}Domain:${RESET}    $DOMAIN"
echo -e "  ${BOLD}Keycloak:${RESET}  https://keycloak-keycloak.$DOMAIN"
echo -e "  ${BOLD}API:${RESET}       https://fulfillment-api-$NS.$DOMAIN"
echo -e "  ${BOLD}UI:${RESET}        https://osac-ui-$NS.$DOMAIN"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
