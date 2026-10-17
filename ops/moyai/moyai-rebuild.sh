#!/usr/bin/env bash
# Rebuild the Moyai / Agent Substrate cluster after it was DELETED (data disks, snapshots, images and the
# static IP were retained on purpose). Run AFTER ~/Projects/moyai-stack/gcp-setup.sh has created the cluster.
#   ./moyai-rebuild.sh            full rebuild
#   ./moyai-rebuild.sh <stage>    one stage: labels pv substrate litellm edge workers netcup verify
# Idempotent: every stage checks before it changes anything. Prints no secret values.
# Cost while up: about Rs36/hour (2 x n2-standard-4). Stop again with ~/Projects/moyai-stack/moyai-down.sh.
set -euo pipefail

P=project-287c53a0-e18a-40e8-824; ZONE=us-east1-b; CLUSTER=moyai-substrate; REGION=us-east1
PN=$(gcloud projects describe "$P" --format='value(projectNumber)')
STACK=$HOME/Projects/moyai-stack
export KUBECONFIG=$HOME/.kube/moyai-substrate.yaml
SUB_VERSION=v0.3.0-118-g92b74c0e-dirty
# retained disks (see cluster-backup-2026-10-12/pv-map.txt): <disk> <namespace/claim> <size>
DISKS=("pvc-2d1793b8-351e-490e-9609-26f3de762f03 edge/caddy-data 1Gi"
       "pvc-908705ba-7259-4f75-87d1-61471793188a litellm/data-litellm-db-0 5Gi"
       "pvc-d7bc553d-401a-47fe-827b-c772ec449b13 ate-system/data-postgres-0 20Gi")

say() { printf '\n== %s\n' "$*"; }

stage_labels() {
  say "1 Stamp the node pool with ate.dev/substrate-version (new nodes need it)"
  gcloud container node-pools update default-pool --cluster "$CLUSTER" --zone "$ZONE" --project "$P" \
    --node-labels "ate.dev/substrate-version=$SUB_VERSION" --quiet
  kubectl wait --for=condition=Ready node --all --timeout=600s
}

stage_pv() {
  say "2 Bind the retained disks: pre-create PersistentVolumes whose claimRef names the PVC that will appear"
  for d in "${DISKS[@]}"; do
    set -- $d; disk=$1; ns=${2%%/*}; claim=${2##*/}; size=$3
    gcloud compute disks describe "$disk" --zone "$ZONE" --project "$P" >/dev/null   # fails loudly if the disk is gone
    kubectl get pv "$disk" >/dev/null 2>&1 && { echo "PV $disk exists"; continue; }
    kubectl apply -f - <<YAML
apiVersion: v1
kind: PersistentVolume
metadata: {name: $disk}
spec:
  capacity: {storage: $size}
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: standard-rwo
  claimRef: {namespace: $ns, name: $claim}
  csi: {driver: pd.csi.storage.gke.io, volumeHandle: projects/$P/zones/$ZONE/disks/$disk, fsType: ext4}
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions: [{key: topology.gke.io/zone, operator: In, values: [$ZONE]}]
YAML
  done
}

stage_substrate() {
  say "3 Install Agent Substrate (ko builds images into Artifact Registry; Postgres binds the retained 20Gi disk)"
  gcloud auth configure-docker "$REGION-docker.pkg.dev" --quiet >/dev/null
  cd "$STACK/src/substrate"
  git diff --quiet -- manifests/ate-install/postgres/postgres.yaml && { echo "ERROR: the 20Gi postgres patch is missing from the Substrate checkout"; exit 1; }
  export PATH=$HOME/Apps/go1.27.0/bin:$PATH NO_DEV_ENV=true PROJECT_ID=$P CLUSTER_LOCATION=$ZONE CLUSTER_NAME=$CLUSTER GCE_REGION=$REGION \
         BUCKET_NAME=moyai-substrate-snapshots-$PN KO_DOCKER_REPO=$REGION-docker.pkg.dev/$P/moyai/ate KO_DEFAULTPLATFORMS=linux/amd64 \
         KUBECTL_CONTEXT=$(kubectl config current-context) ATE_RECORD_DIR=$STACK/substrate-installs ATE_INSTALL_ROLLOUT_TIMEOUT=10m
  hack/install-ate.sh --deploy-ate-system --credential-provider='{"enabled":false}' 2>&1 | tee "$STACK/logs/substrate-rebuild.log" | tail -5
  kubectl -n ate-system rollout status statefulset/postgres --timeout=600s
  for d in ate-api-server ate-controller atenet-router atenet-egress; do kubectl -n ate-system rollout status deploy/$d --timeout=600s; done
}

stage_litellm() {
  say "4 LiteLLM on its retained DB disk"
  cd "$STACK/k8s"
  kubectl apply -f litellm.yaml
  if ! kubectl -n litellm get secret litellm-secrets >/dev/null 2>&1; then
    kubectl -n litellm create secret generic litellm-secrets --from-literal=db-password="$(openssl rand -hex 24)" \
      --from-literal=master-key="sk-$(openssl rand -hex 24)" --from-literal=salt-key="sk-$(openssl rand -hex 24)" >/dev/null
    echo "created litellm-secrets (the old ones were never exported)"
  fi
  kubectl -n litellm rollout status statefulset/litellm-db --timeout=600s
  # The retained database keeps the OLD role password; the pod's local socket is trust-auth, so set it to the new secret.
  pw=$(kubectl -n litellm get secret litellm-secrets -o jsonpath='{.data.db-password}' | base64 -d)
  kubectl -n litellm exec litellm-db-0 -- psql -U litellm -d litellm -qc "ALTER ROLE litellm PASSWORD '$pw'" >/dev/null
  kubectl -n litellm rollout restart deploy/litellm >/dev/null
  kubectl -n litellm rollout status deploy/litellm --timeout=600s
}

stage_edge() {
  say "5 Public edge (Caddy) on the reserved IP 34.24.90.102, certificates from the retained disk"
  cd "$STACK/k8s"
  sed 's|ROUTER_UPSTREAM|atenet-router.ate-system.svc:80|' edge.yaml | kubectl apply -f -
  kubectl -n edge rollout status deploy/caddy --timeout=600s
}

stage_workers() {
  say "6 Worker pool (gVisor sandboxes). The ActorTemplate lives in the retained Substrate DB."
  kubectl apply -f "$STACK/k8s/moyai-workerpool.yaml"
  kubectl -n moyai wait --for=condition=Ready pod --all --timeout=600s
}

stage_netcup() {
  say "7 Fresh Substrate API token to Netcup (24 h, never printed), then start Moyai and the relay"
  kubectl -n ate-system create token ate-client --audience=api.ate-system.svc --duration=24h | \
    ssh jk-box 'umask 077; sudo tee ~/moyai-stack/substrate-token >/dev/null && sudo chown 10001:10001 ~/moyai-stack/substrate-token && sudo chmod 600 ~/moyai-stack/substrate-token'
  ssh jk-box 'cd ~/moyai-stack && docker compose up -d moyai gca-relay'
}

stage_verify() {
  say "8 Verify: the relay must report the Substrate cluster online"
  T=$(cat "$HOME/Projects/governed-cloud-agent/.relay-token")
  for i in $(seq 1 12); do
    out=$(curl -s -H "authorization: Bearer $T" https://moyai.ai-agentic-enterprises.com/gca-relay/health || true)
    echo "$out" | grep -q '"online"' && { echo "ONLINE: $out"; return 0; }
    echo "waiting ($i/12): $out"; sleep 15
  done
  echo "Relay still offline. If the detail mentions the ActorTemplate, recreate it from $STACK/k8s/moyai-template.json (see ops/moyai/README.md)."
  return 1
}

if [ $# -gt 0 ]; then "stage_$1"; else
  stage_labels; stage_pv; stage_substrate; stage_litellm; stage_edge; stage_workers; stage_netcup; stage_verify
fi
