#!/usr/bin/env bash

set -euo pipefail


export DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}')
export NS=osac
git clone https://github.com/osac-project/osac.git
cd osac/osac-installer

# Step 1 -- Pre-requisites (CRDs and repos)
# Helm repos needed for dependency build
helm repo add topolvm https://topolvm.github.io/topolvm --force-update
helm repo add jetstack https://charts.jetstack.io --force-update

# Trust-manager CRD (cert-manager operator doesn't ship it)
helm template trust-manager jetstack/trust-manager --version v0.20.0 \
  --show-only templates/crd-trust.cert-manager.io_bundles.yaml | oc apply -f -

# Topolvm CRD (osac-operator binary requires it even if you don't use LVMS)
helm template topolvm topolvm/topolvm \
  --show-only templates/crds/topolvm.io_logicalvolumes.yaml | oc apply -f -

# Build chart dependencies
helm dependency build charts/osac-deps
helm dependency build charts/osac-infra
helm dependency build charts/osac

# Step 2 -- Phase 1a: osac-deps (installs operators in the right namespaces)
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

# Approve the Kafka install plan (retry until installPlanRef appears)
until INSTALL_PLAN=$(oc get subscription amq-streams -n osac-kafka -o jsonpath='{.status.installPlanRef.name}' 2>/dev/null) && [[ -n "$INSTALL_PLAN" ]]; do
  echo "Waiting for Kafka install plan..."
  sleep 10
done
oc patch installplan "$INSTALL_PLAN" -n osac-kafka --type merge -p '{"spec":{"approved":true}}'

# Wait for CSV to appear, then wait for it to succeed
until oc get csv -n osac-kafka -l operators.coreos.com/amq-streams.osac-kafka -o name 2>/dev/null | grep -q .; do
  echo "Waiting for Kafka CSV..."
  sleep 10
done
oc wait csv -n osac-kafka -l operators.coreos.com/amq-streams.osac-kafka --for=jsonpath='{.status.phase}'=Succeeded --timeout=300s

# handle ca-bundle
oc apply -f - <<'EOF'
apiVersion: trust.cert-manager.io/v1alpha1
kind: Bundle
metadata:
  name: ca-bundle
spec:
  sources:
  - secret:
      name: "default-ca"
      key: "ca.crt"
  target:
    configMap:
      key: bundle.pem
    namespaceSelector:
      matchExpressions:
      - key: kubernetes.io/metadata.name
        operator: In
        values: ["osac-infra","osac","keycloak","osac-kafka"]
EOF

# Step 3 -- Phase 1b: osac-infra
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
  --wait --timeout 30m

# Step 4 -- Prepare the AAP manifest
oc create namespace "$NS" --dry-run=client -o yaml | oc apply -f -
oc create secret generic config-as-code-manifest-ig \
  --from-file=license.zip=/root/manifest.zip \
  -n "$NS" --dry-run=client -o yaml | oc apply --server-side -f -
oc label secret config-as-code-manifest-ig osac.openshift.io/project=osac-aap -n "$NS" --overwrite

# Step 5 -- Phase 2: osac
helm upgrade --install osac charts/osac -n "$NS" --create-namespace \
  -f values/vmaas-ci/instance.yaml \
  --set global.clusterDomain="$DOMAIN" \
  --set service.externalHostname="fulfillment-api-$NS.$DOMAIN" \
  --set service.internalHostname="fulfillment-internal-api-$NS.$DOMAIN" \
  --set "ui.auth.oidcIssuerURL=https://keycloak-keycloak.$DOMAIN/realms/osac" \
  --set lvms.enabled=false \
  --wait --timeout 60m
