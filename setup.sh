#!/bin/bash
#set -euo pipefail

export VAULT_TOKEN="deadbeef-dead-beef-dead-beefdeadbeef"
export VAULT_URL="http://localhost:8200/v1"
export VAULT_PKI_MOUNT="${VAULT_URL}/sys/mounts/pki"
export VAULT_PKI_BACKEND="${VAULT_URL}/pki"
export VAULT_PKI_INT_MOUNT="${VAULT_URL}/sys/mounts/pki_int"
export VAULT_PKI_INT_BACKEND="${VAULT_URL}/pki_int"
export MAX_ROOT_TTL="87600h"
export MAX_INT_TTL="43800h"
export DOMAIN="localhost"
export VERBOSE=""
export CURL="curl ${VERBOSE} -s"

# Delete
echo "Deleting any old stuff..."
${CURL} \
    -XDELETE \
    -L \
    -H "X-Vault-Token: ${VAULT_TOKEN}" \
    --data '{"type": "pki"}' \
    ${VAULT_PKI_MOUNT}
# Delete
${CURL} \
    -XDELETE \
    -L \
    -H "X-Vault-Token: ${VAULT_TOKEN}" \
    --data '{"type": "pki"}' \
    ${VAULT_PKI_INT_MOUNT}

rm -rf ./nginx/server
rm -rf ./client
mkdir -p ./nginx/server
mkdir -p ./client

## FOR THE ROOT CA
# First enable the backend
echo "Enable the PKI backend"
${CURL} \
    -XPOST \
    -L \
    -H "X-Vault-Token: ${VAULT_TOKEN}" \
    --data '{"type": "pki"}' \
    ${VAULT_PKI_MOUNT}

# Set the max TTL
${CURL} \
    -XPOST \
    -L \
    -H "X-Vault-Token: ${VAULT_TOKEN}" \
    --data '{"max_lease_ttl": "'"${MAX_ROOT_TTL}"'"}' \
    ${VAULT_PKI_MOUNT}/tune

# Generate the root self-signed CA certificatend private key
echo "Generate the root self-signed CA certificatend private key"
root_internal=$(\
    ${CURL} \
        -XPOST \
        -L \
        -H "X-Vault-Token: ${VAULT_TOKEN}" \
        --data '{"common_name": "'"${DOMAIN}"' Root Authority", "ttl": "'"${MAX_ROOT_TTL}"'"}' \
        ${VAULT_PKI_BACKEND}/root/generate/internal
    )

echo $root_internal | jq .

# Store the self-signed cert
echo "Store the self-signed CA certificate to ca_root.crt"
echo $root_internal | jq -r .data.certificate > ca_root.crt

# Configure CA and CRL URLs
${CURL} \
    -XPOST \
    -L \
    -H "X-Vault-Token: ${VAULT_TOKEN}" \
    --data '{"issuing_certificates": "'"${VAULT_PKI_BACKEND}"'/ca", "crl_distribution_points": "'"${VAULT_PKI_BACKEND}"'/crl"}' \
    ${VAULT_PKI_BACKEND}/config/urls

## FOR THE INTERMEDIATE CA
# First enable the backend
${CURL} \
    -XPOST \
    -L \
    -H "X-Vault-Token: ${VAULT_TOKEN}" \
    --data '{"type": "pki"}' \
    ${VAULT_PKI_INT_MOUNT}

# Set the max TTL
${CURL} \
    -XPOST \
    -L \
    -H "X-Vault-Token: ${VAULT_TOKEN}" \
    --data '{"max_lease_ttl": "'"${MAX_INT_TTL}"'"}' \
    ${VAULT_PKI_INT_MOUNT}/tune

# Generate the intermediate self-signed CA certificatend private key
echo "Generate the intermediate self-signed CA certificatend private key"
int_internal=$(\
    ${CURL} \
        -XPOST \
        -L \
        -H "X-Vault-Token: ${VAULT_TOKEN}" \
        --data '{"common_name": "'"${DOMAIN}"' Intermediate Authority", "ttl": "'"${MAX_INT_TTL}"'"}' \
        ${VAULT_PKI_INT_BACKEND}/intermediate/generate/internal
    )

echo $int_internal | jq .

# Store the self-signed cert, replace newlines with escaped newlines because http
CSR=$(echo $int_internal | jq -r .data.csr | sed ':a;N;$!ba;s/\n/\\n/g')
echo '{"csr": "'"${CSR}"'", "format": "pem_bundle"}'
# Configure CA and CRL URLs
signed_int_cert=$(
    ${CURL} \
        -H "Content-Type: application/json" \
        -XPOST \
        -L \
        -H "X-Vault-Token: ${VAULT_TOKEN}" \
        --data '{"csr": "'"${CSR}"'", "format": "pem_bundle"}' \
        ${VAULT_PKI_BACKEND}/root/sign-intermediate
    )

echo $signed_int_cert | jq .
CERT=$(echo $signed_int_cert | jq -r .data.certificate | sed ':a;N;$!ba;s/\n/\\n/g')

# Now import the signed certificate back into vault (??wat??)
${CURL} \
    -XPOST \
    -L \
    -H "X-Vault-Token: ${VAULT_TOKEN}" \
    --data '{"certificate": "'"${CERT}"'"}' \
    ${VAULT_PKI_INT_BACKEND}/intermediate/set-signed



####### CREATE ROLES #######
############################

# Create a role that allows subdomains
${CURL} \
    -XPOST \
    -L \
    -H "X-Vault-Token: ${VAULT_TOKEN}" \
    --data '{"allowed_domains": "'"${DOMAIN}"'", "allow_subdomains": true,"max_ttl": "720h"}' \
    ${VAULT_PKI_INT_BACKEND}/roles/example-dot-com


####### REQEUST CERTIFICATES #######
####################################

# Request a certificate
# Server certificate
echo "Create a server certificate, which creates a private key, public cert, and gives the CA cert"
user_cert=$(
    ${CURL} \
        -XPOST \
        -L \
        -H "X-Vault-Token: ${VAULT_TOKEN}" \
        --data '{"common_name": "'"${DOMAIN}"'", "ttl": "24h"}' \
        ${VAULT_PKI_INT_BACKEND}/issue/example-dot-com
    )

echo $user_cert | jq .
echo $user_cert | jq -r .data.private_key > ./nginx/server/server.key
echo $user_cert | jq -r .data.certificate > ./nginx/server/server.crt
echo $user_cert | jq -r .data.issuing_ca > ./nginx/server/ca.crt
cat ca_root.crt >> ./nginx/server/ca.crt


# Request a second certificate
# Client certificate
echo "Create a client certificate, which creates a private key, public cert, and gives the CA cert"
user_cert=$(
    ${CURL} \
        -XPOST \
        -L \
        -H "X-Vault-Token: ${VAULT_TOKEN}" \
        --data '{"common_name": "'"${DOMAIN}"'", "ttl": "24h"}' \
        ${VAULT_PKI_INT_BACKEND}/issue/example-dot-com
    )


echo $user_cert | jq .
echo $user_cert | jq -r .data.private_key > ./client/client.key
echo $user_cert | jq -r .data.certificate > ./client/client.crt
echo $user_cert | jq -r .data.issuing_ca > ./client/ca.crt
cat ca_root.crt >> ./client/ca.crt
