#!/bin/bash

set -euo pipefail

# Creates a clustermesh between two kind clusters running Cilium 1.10.3.
#
# Prerequisites:
#   * helm
#   * kind
#   * kubectl
#   * openssl
#
# Usage:
#   ./kind-cilium-clustermesh.sh up
#
# Cleanup:
#   ./kind-cilium-clustermesh.sh down

CLUSTER_NAME_PREFIX="cilium-clustermesh-"
CILIUM_NAMESPACE="kube-system"
CILIUM_CA_NAME="cilium-ca"
CILIUM_CA_CRT_FILENAME="${CILIUM_CA_NAME}-crt.pem"
CILIUM_CA_KEY_FILENAME="${CILIUM_CA_NAME}-key.pem"
CLUSTERMESH_APISERVER_REMOTE_NAME="remote"
CLUSTERMESH_APISERVER_REMOTE_CRT_FILENAME="${CLUSTERMESH_APISERVER_REMOTE_NAME}-crt.pem"
CLUSTERMESH_APISERVER_REMOTE_CSR_FILENAME="${CLUSTERMESH_APISERVER_REMOTE_NAME}-csr.pem"
CLUSTERMESH_APISERVER_REMOTE_KEY_FILENAME="${CLUSTERMESH_APISERVER_REMOTE_NAME}-key.pem"

function down() {
  # Delete the kind clusters.
  for CLUSTER_ID in 1 2;
  do
    kind delete cluster --name "${CLUSTER_NAME_PREFIX}${CLUSTER_ID}"
  done
  # Delete the certificates and private keys.
  rm -f "${CILIUM_CA_CRT_FILENAME}" "${CILIUM_CA_KEY_FILENAME}" "${CLUSTERMESH_APISERVER_REMOTE_CRT_FILENAME}" "${CLUSTERMESH_APISERVER_REMOTE_CSR_FILENAME}" "${CLUSTERMESH_APISERVER_REMOTE_KEY_FILENAME}"
}

function info() {
    echo "==> ${1}"
}

function up() {
  # Generate a private key and a certificate for the certificate authority.
  info "Creating a certificate authority..."
  if [[ ! -f "${CILIUM_CA_KEY_FILENAME}" ]];
  then
      openssl genrsa -out "${CILIUM_CA_KEY_FILENAME}" 4096
  fi
  if [[ ! -f "${CILIUM_CA_CRT_FILENAME}" ]];
  then
      openssl req -x509 \
          -days 3650 \
          -key "${CILIUM_CA_KEY_FILENAME}" \
          -new \
          -nodes \
          -out "${CILIUM_CA_CRT_FILENAME}" \
          -sha256 \
          -subj "/CN=${CILIUM_CA_NAME}"
  fi

  # Generate a private key and a certificate for the 'remote' client.
  # The certificate is signed by the certificate authority created above.
  # The common name of the certificate MUST be 'remote'.
  info "Creating a 'clustermesh-apiserver' client certificate..."
  if [[ ! -f "${CLUSTERMESH_APISERVER_REMOTE_KEY_FILENAME}" || ! -f "${CLUSTERMESH_APISERVER_REMOTE_CSR_FILENAME}" ]];
  then
      openssl req \
          -days 365000 \
          -keyout "${CLUSTERMESH_APISERVER_REMOTE_KEY_FILENAME}" \
          -newkey rsa:4096 \
          -nodes \
          -out "${CLUSTERMESH_APISERVER_REMOTE_CSR_FILENAME}" \
          -subj "/CN=${CLUSTERMESH_APISERVER_REMOTE_NAME}"
  fi
  if [[ ! -f "${CLUSTERMESH_APISERVER_REMOTE_CRT_FILENAME}" ]];
  then
      cat <<EOF | openssl x509 -req -days 365000 \
        -CA "${CILIUM_CA_CRT_FILENAME}" \
        -CAkey "${CILIUM_CA_KEY_FILENAME}" \
        -in "${CLUSTERMESH_APISERVER_REMOTE_CSR_FILENAME}" \
        -out "${CLUSTERMESH_APISERVER_REMOTE_CRT_FILENAME}" \
        -set_serial 01 \
        -extfile /dev/stdin \
        -extensions client
[client]
subjectKeyIdentifier=hash
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=clientAuth
EOF
  fi

  # Grab the certificates and private keys into environment variables.
  CILIUM_CA_CRT="$(openssl base64 -A < ${CILIUM_CA_CRT_FILENAME})"
  CILIUM_CA_KEY="$(openssl base64 -A < ${CILIUM_CA_KEY_FILENAME})"
  CLUSTERMESH_APISERVER_REMOTE_CRT="$(openssl base64 -A < ${CLUSTERMESH_APISERVER_REMOTE_CRT_FILENAME})"
  CLUSTERMESH_APISERVER_REMOTE_KEY="$(openssl base64 -A < ${CLUSTERMESH_APISERVER_REMOTE_KEY_FILENAME})"

  # Configure Helm repos.
  helm repo add cilium https://helm.cilium.io/
  helm repo add isovalent https://helm.isovalent.com
  helm repo update

  # Create the clusters and install Cilium Enterprise.
  for CLUSTER_ID in 1 2;
  do
  CLUSTER_NAME="${CLUSTER_NAME_PREFIX}${CLUSTER_ID}"
  info "Creating cluster ${CLUSTER_NAME}"
#  cat <<EOF | kind create cluster --config -
---
apiVersion: kind.x-k8s.io/v1alpha4
kind: Cluster
name: "${CLUSTER_NAME}"
networking:
  # Disable the default CNI plugin as Cilium will be used.
  disableDefaultCNI: true
nodes:
  # Create a control-plane node and a worker node.
  - image: kindest/node:v1.20.7
    role: control-plane
  - image: kindest/node:v1.20.7
    role: worker
EOF
  info "Installing Cilium in ${CLUSTER_NAME}"
  cat <<EOF | helm upgrade --install cilium-enterprise isovalent/cilium-enterprise --version 1.10.5 -n "${CILIUM_NAMESPACE}" -f -
cilium:
  certgen:
    image:
      tag: v0.1.6
  cluster:
    id: ${CLUSTER_ID}
    name: "${CLUSTER_NAME}"
  clustermesh:
    useAPIServer: true
    apiserver:
      tls:
        auto:
          method: cronJob
        ca:
          cert: "${CILIUM_CA_CRT}"
          key: "${CILIUM_CA_KEY}"
        remote:
          cert: "${CLUSTERMESH_APISERVER_REMOTE_CRT}"
          key: "${CLUSTERMESH_APISERVER_REMOTE_KEY}"
  hubble:
    relay:
      enabled: true
    tls:
      auto:
        method: cronJob
      ca:
        cert: "${CILIUM_CA_CRT}"
        key: "${CILIUM_CA_KEY}"
  ipam:
    operator:
      clusterPoolIPv4PodCIDR: "10.${CLUSTER_ID}.0.0/16"
hubble-enterprise:
  enabled: false
EOF
  done

  # Create the clustermesh configuration files and 'hostAliases' patch.
  CILIUM_DAEMONSET_PATCH_FILENAME="cilium.patch.yaml"
  cat <<EOF > "${CILIUM_DAEMONSET_PATCH_FILENAME}"
spec:
  template:
    spec:
      hostAliases:
EOF
  for CLUSTER_ID in 1 2;
  do
    CLUSTER_NAME="${CLUSTER_NAME_PREFIX}${CLUSTER_ID}"
    NODE_IP=$(kubectl --context "kind-${CLUSTER_NAME}" get node "${CLUSTER_NAME}-worker" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
    cat <<EOF >> "${CILIUM_DAEMONSET_PATCH_FILENAME}"
      - ip: "${NODE_IP}"
        hostnames:
        - "${CLUSTER_NAME}.mesh.cilium.io"
EOF
      cat <<EOF > "${CLUSTER_NAME}-config.yaml"
endpoints:
  - https://${CLUSTER_NAME}.mesh.cilium.io:32379
trusted-ca-file: /var/lib/cilium/clustermesh/${CLUSTER_NAME}-ca.crt
cert-file: /var/lib/cilium/clustermesh/${CLUSTER_NAME}.crt
key-file: /var/lib/cilium/clustermesh/${CLUSTER_NAME}.key
EOF
  done

  # Create the 'cilium-clustermesh' secret in each cluster and add host aliases.
  for CLUSTER_ID in 1 2;
  do
      CLUSTER_NAME="${CLUSTER_NAME_PREFIX}${CLUSTER_ID}"
      info "Creating the 'cilium-clustermesh' secret and configuring host aliases in ${CLUSTER_NAME}..."
      kubectl --context "kind-${CLUSTER_NAME}" -n "${CILIUM_NAMESPACE}" create secret generic cilium-clustermesh \
          --from-file "cilium-clustermesh-1=cilium-clustermesh-1-config.yaml" \
          --from-file "cilium-clustermesh-1-ca.crt=${CILIUM_CA_CRT_FILENAME}" \
          --from-file "cilium-clustermesh-1.crt=${CLUSTERMESH_APISERVER_REMOTE_CRT_FILENAME}" \
          --from-file "cilium-clustermesh-1.key=${CLUSTERMESH_APISERVER_REMOTE_KEY_FILENAME}" \
          --from-file "cilium-clustermesh-2=cilium-clustermesh-2-config.yaml" \
          --from-file "cilium-clustermesh-2-ca.crt=${CILIUM_CA_CRT_FILENAME}" \
          --from-file "cilium-clustermesh-2.crt=${CLUSTERMESH_APISERVER_REMOTE_CRT_FILENAME}" \
          --from-file "cilium-clustermesh-2.key=${CLUSTERMESH_APISERVER_REMOTE_KEY_FILENAME}"
      kubectl --context "kind-${CLUSTER_NAME}" -n kube-system patch ds/cilium -p "$(cat "${CILIUM_DAEMONSET_PATCH_FILENAME}")"
  done
}

function warn() {
  echo "(!) ${1}"
}

case "${1:-""}" in
  "down")
    down
    ;;
  "up")
    up
    ;;
  *)
    warn "Please specify one of 'up' or 'down'."
    exit 1
    ;;
esac
