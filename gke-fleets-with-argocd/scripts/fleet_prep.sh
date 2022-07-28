#!/usr/bin/env bash

set -Euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

while getopts p:r:t: flag
do
    case "${flag}" in
        p) PROJECT_ID=${OPTARG};;
        r) SYNC_REPO=${OPTARG};;
        t) PAT_TOKEN=${OPTARG};;
    esac
done

echo "::Variable set::"
echo "PROJECT_ID: ${PROJECT_ID}"
echo "SYNC_REPO: ${SYNC_REPO}"

### Download config repo ###
git clone git@github.com:GoogleCloudPlatform/gke-poc-toolkit-demos.git && cd gke-poc-toolkit-demos
git checkout remotes/origin/gke-fleets-with-argocd
cd -
cp -rf gke-fleets-with-argocd/argo-repo-sync ./
rm -rf gke-poc-toolkit-demos


### ArgoCD Install###
echo "Setting up ArgoCD on the mccp cluster including configure it for GKE Ingress."
gcloud compute addresses create argocd-ip --global --project ${GKE_PROJECT_ID}
export GCLB_IP=$(gcloud compute addresses describe argocd-ip --project ${GKE_PROJECT_ID} --global --format="value(address)")
echo -e "GCLB_IP is ${GCLB_IP}"

cat <<EOF > argocd-openapi.yaml
swagger: "2.0"
info:
  description: "Cloud Endpoints DNS"
  title: "Cloud Endpoints DNS"
  version: "1.0.0"
paths: {}
host: "argocd.endpoints.${PROJECT_ID}.cloud.goog"
x-google-endpoints:
- name: "argocd.endpoints.${PROJECT_ID}.cloud.goog"
  target: "${GCLB_IP}"
EOF
gcloud endpoints services deploy argocd-openapi.yaml --project ${GKE_PROJECT_ID}

cat <<EOF > ${script_dir}/../argo-cd-gke/argocd-managed-cert.yaml
apiVersion: networking.gke.io/v1
kind: ManagedCertificate
metadata:
  name: argocd-managed-cert
  namespace: argocd
spec:
  domains:
  - "argocd.endpoints.${GKE_PROJECT_ID}.cloud.goog"
EOF

cat <<EOF > ${script_dir}/../argo-cd-gke/argocd-server-ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd
  namespace: argocd
  annotations:
    kubernetes.io/ingress.global-static-ip-name: argocd-ip 
    networking.gke.io/v1beta1.FrontendConfig: argocd-frontend-config
    networking.gke.io/managed-certificates: argocd-managed-cert
spec:
  rules:
    - host: "argocd.endpoints.${GKE_PROJECT_ID}.cloud.goog"
      http:
        paths:
        - pathType: Prefix
          path: "/"
          backend:
            service:
              name: argocd-server
              port:
                number: 80
EOF

kubectl apply -k argo-cd-gke
ARGOCD_SECRET=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo)
argocd login "argocd.endpoints.${GKE_PROJECT_ID}.cloud.goog" --username admin --password ${ARGOCD_SECRET} --grpc-web

echo "Creating a global public IP for the ASM GW."
gcloud compute addresses create asm-gw-ip --global --project ${GKE_PROJECT_ID}
export ASM_GW_IP=`gcloud compute addresses describe asm-gw-ip --global --format="value(address)"`
echo -e "GCLB_IP is ${ASM_GW_IP}"

echo "Creating gcp endpoints for each demo app."
cat <<EOF > rollout-demo-openapi.yaml
swagger: "2.0"
info:
  description: "Cloud Endpoints DNS"
  title: "Cloud Endpoints DNS"
  version: "1.0.0"
paths: {}
host: "rollout-demo.endpoints.${GKE_PROJECT_ID}.cloud.goog"
x-google-endpoints:
- name: "rollout-demo.endpoints.${GKE_PROJECT_ID}.cloud.goog"
  target: "${ASM_GW_IP}"
EOF

gcloud endpoints services deploy rollout-demo-openapi.yaml --project ${GKE_PROJECT_ID}

cat <<EOF > whereami-openapi.yaml
swagger: "2.0"
info:
  description: "Cloud Endpoints DNS"
  title: "Cloud Endpoints DNS"
  version: "1.0.0"
paths: {}
host: "whereami.endpoints.${GKE_PROJECT_ID}.cloud.goog"
x-google-endpoints:
- name: "whereami.endpoints.${GKE_PROJECT_ID}.cloud.goog"
  target: "${ASM_GW_IP}"
EOF

gcloud endpoints services deploy whereami-openapi.yaml --project ${GKE_PROJECT_ID}

echo "Creating certificates for whereami and rollout demo apps."
gcloud compute ssl-certificates create whereami-cert \
    --domains=whereami.endpoints.${PROJECT_ID}.cloud.goog \
    --global
gcloud compute ssl-certificates create rollout-demo-cert \
    --domains=rollout-demo.endpoints.${PROJECT_ID}.cloud.goog \
    --global

cd $script_dir
SYNC_REPO_DIR=../argo-repo-sync
for file in ${SYNC_REPO_DIR}* ${SYNC_REPO_DIR}*/* ${SYNC_REPO_DIR}*/*/*; do
    [ -e "${file}" ]
    echo ${file}
    sed -i '' -e "s/{{GKE_PROJECT_ID}}/${PROJECT_ID}/g" ${file}
    sed -i '' -e "s/{{ASM_GW_IP}}/${ASM_GW_IP}/g" ${file}
    sed -i '' -e "s/{{SYNC_REPO}}/${SYNC_REPO}/g" ${file}
done

### Setup Sync Repo w/ Argocd ###
argocd cluster add mccp-central-01 --in-cluster --label=env="multi-cluster-controller" --grpc-web -y
cd argo-repo-sync && export SYNC_DIR=`pwd`
git init
gh repo create ${SYNC_REPO} --private --source=. --remote=upstream
git add . && git commit -m "Initial commit"
git push --set-upstream upstream main
REPO="https://github.com/"$(gh repo list | grep argo-repo-sync | awk '{print $1}')
argocd repo add ${REPO} --username doesnotmatter --password ${PAT_TOKEN} --grpc-web

### Setup mccp applicationset ###
kubectl apply -f generators/multi-cluster-controller-applicationset.yaml -n argocd --context mccp-central-01

echo "The Fleet has been configured, checkout the sync status here:"
echo "https://argocd.endpoints.${GKE_PROJECT_ID}.cloud.goog"