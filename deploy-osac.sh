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
step "1/5" "Pre-requisites (CRDs, repos, chart deps)"

git clone https://github.com/osac-project/osac.git
cd osac/osac-installer

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
step "2/5" "Phase 1a: osac-deps (operators)"

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
step "3/5" "Phase 1b: osac-infra (trust, keycloak, vault, postgres, kafka)"

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
  --set mce.enabled=false \
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

# =====================================================================
step "4/5" "AAP manifest"

oc create namespace "$NS" --dry-run=client -o yaml | oc apply -f -
oc create secret generic config-as-code-manifest-ig \
  --from-file=license.zip=/root/manifest.zip \
  -n "$NS" --dry-run=client -o yaml | oc apply --server-side -f -
oc label secret config-as-code-manifest-ig osac.openshift.io/project=osac-aap -n "$NS" --overwrite
ok "AAP manifest configured in namespace $NS"

# =====================================================================
step "5/5" "Phase 2: osac platform"

helm upgrade --install osac charts/osac -n "$NS" --create-namespace \
  -f values/vmaas-ci/instance.yaml \
  --set global.clusterDomain="$DOMAIN" \
  --set service.externalHostname="fulfillment-api-$NS.$DOMAIN" \
  --set service.internalHostname="fulfillment-internal-api-$NS.$DOMAIN" \
  --set "ui.auth.oidcIssuerURL=https://keycloak-keycloak.$DOMAIN/realms/osac" \
  --set lvms.enabled=false \
  --wait --timeout 60m
ok "osac platform deployed"

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
