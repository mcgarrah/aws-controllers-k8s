#!/usr/bin/env bash

# A script that builds a single ACK service controller, provisions a KinD
# Kubernetes cluster, installs the built ACK service controller into that
# Kubernetes cluster and runs a set of tests

set -Eo pipefail

SCRIPTS_DIR=$(cd "$(dirname "$0")" || exit 1; pwd)
ROOT_DIR="$SCRIPTS_DIR/.."
TEST_E2E_DIR="$ROOT_DIR/test/e2e"

OPTIND=1
CLUSTER_NAME_BASE="test"
AWS_ACCOUNT_ID=${AWS_ACCOUNT_ID:-""}
AWS_REGION=${AWS_REGION:-"us-west-2"}
AWS_ROLE_ARN=${AWS_ROLE_ARN:-""}
ACK_ENABLE_DEVELOPMENT_LOGGING="true"
ACK_LOG_LEVEL="debug"
DELETE_CLUSTER_ARGS=""
K8S_VERSION="1.16"
PRESERVE=false
START=$(date +%s)
TMP_DIR=""
# VERSION is the source revision that executables and images are built from.
VERSION=$(git describe --tags --always --dirty || echo "unknown")

source "$SCRIPTS_DIR/lib/common.sh"
source "$SCRIPTS_DIR/lib/aws.sh"
source "$SCRIPTS_DIR/lib/k8s.sh"

check_is_installed curl
check_is_installed docker
check_is_installed jq
check_is_installed uuidgen
check_is_installed wget
check_is_installed kind "You can install kind with the helper scripts/install-kind.sh"
check_is_installed kubectl "You can install kubectl with the helper scripts/install-kubectl.sh"
check_is_installed kustomize "You can install kustomize with the helper scripts/install-kustomize.sh"
check_is_installed controller-gen "You can install controller-gen with the helper scripts/install-controller-gen.sh"

if ! k8s_controller_gen_version_equals "$CONTROLLER_TOOLS_VERSION"; then
    echo "FATAL: Existing version of controller-gen "`controller-gen --version`", required version is $CONTROLLER_TOOLS_VERSION."
    echo "FATAL: Please uninstall controller-gen and install the required version with scripts/install-controller-gen.sh."
    exit 1
fi

aws_check_credentials

if [ "z$AWS_ACCOUNT_ID" == "z" ]; then
    AWS_ACCOUNT_ID=$( aws_account_id )
fi

function clean_up {
    if [[ "$PRESERVE" == false ]]; then
        "${SCRIPTS_DIR}"/delete-kind-cluster.sh -c "$TMP_DIR" || :
        return
    fi
    echo "To resume test with the same cluster use: \"-c $TMP_DIR\""""
}


USAGE="
Usage:
  $(basename "$0") -s <SERVICE> -r <ROLE> [-p] [-c <CLUSTER_CONTEXT_DIR>] [-i <AWS Docker image name>] [-v K8S_VERSION]

Builds the Docker image for an ACK service controller, loads the Docker image
into a KinD Kubernetes cluster, creates the Deployment artifact for the ACK
service controller and executes a set of tests.

Example: $(basename "$0") -p -s ecr -r \"\$ROLE_ARN\"

Options:
  -c          Cluster context directory, if operating on an existing cluster
  -p          Preserve kind k8s cluster for inspection
  -i          Provide AWS Service docker image
  -r          Provide AWS Role ARN for functional testing on local KinD Cluster
  -s          Provide AWS Service name (ecr, sns, sqs, etc)
  -v          Kubernetes Version (Default: 1.16) [1.14, 1.15, 1.16, 1.17, and 1.18]
"

# Process our input arguments
while getopts "ps:r:ic:v" opt; do
  case ${opt} in
    p ) # PRESERVE K8s Cluster
        PRESERVE=true
      ;;
    s ) # AWS Service name
        AWS_SERVICE=$(echo "${OPTARG}" | tr '[:upper:]' '[:lower:]')
      ;;
    r ) # AWS ROLE ARN
        AWS_ROLE_ARN="${OPTARG}"
      ;;
    i ) # AWS Service Docker Image
        AWS_SERVICE_DOCKER_IMG="${OPTARG}"
      ;;
    c ) # Cluster context directory to operate on existing cluster
        TMP_DIR="${OPTARG}"
      ;;
    b ) # Base cluster name
        CLUSTER_NAME_BASE="${OPTARG}"
      ;;
    v ) # K8s VERSION
        K8S_VERSION="${OPTARG}"
      ;;
    \? )
        echo "${USAGE}" 1>&2
        exit
      ;;
  esac
done

if [ -z "$AWS_SERVICE" ]; then
    echo "AWS_SERVICE is not defined. Use flag -s <AWS_SERVICE> to build that docker images of that service and load into Kind"
    echo "(Example: $(basename "$0") -p -s ecr -r \"\$ROLE_ARN\")"
    exit  1
fi

if [ -z "$AWS_ROLE_ARN" ]; then
    echo "AWS_ROLE_ARN is not defined. Use flag -r <AWS_ROLE_ARN> to indicate the ARN of the IAM Role to use in testing"
    echo "(Example: $(basename "$0") -p -s ecr -r \"\$ROLE_ARN\")"
    exit  1
fi

if [ -z "$TMP_DIR" ]; then
    TEST_ID=$(uuidgen | cut -d'-' -f1 | tr '[:upper:]' '[:lower:]')
    CLUSTER_NAME_BASE=$(uuidgen | cut -d'-' -f1 | tr '[:upper:]' '[:lower:]')
    CLUSTER_NAME="ack-test-$CLUSTER_NAME_BASE"-"${TEST_ID}"
    TMP_DIR=$ROOT_DIR/build/tmp-$CLUSTER_NAME
    $SCRIPTS_DIR/provision-kind-cluster.sh "${CLUSTER_NAME}" -v "${K8S_VERSION}"
fi
export PATH=$TMP_DIR:$PATH

CLUSTER_NAME=$(cat "$TMP_DIR"/clustername)

## Build and Load Docker Images

if [ -z "$AWS_SERVICE_DOCKER_IMG" ]; then
    echo -n "building ack-${AWS_SERVICE}-controller docker image ... "
    DEFAULT_AWS_SERVICE_DOCKER_IMG="ack-${AWS_SERVICE}-controller:${VERSION}"
    ${SCRIPTS_DIR}/build-controller-image.sh -q -s ${AWS_SERVICE} -i ${DEFAULT_AWS_SERVICE_DOCKER_IMG} 1>/dev/null || exit 1
    echo "ok."
    AWS_SERVICE_DOCKER_IMG="${DEFAULT_AWS_SERVICE_DOCKER_IMG}"

else
    debug_msg "skipping building the ${AWS_SERVICE} docker image, since one was specified ${AWS_SERVICE_DOCKER_IMG}"
fi
echo "$AWS_SERVICE_DOCKER_IMG" > "${TMP_DIR}"/"${AWS_SERVICE}"_docker-img

echo -n "loading the images into the cluster ... "
kind load docker-image --quiet --name "${CLUSTER_NAME}" --nodes="${CLUSTER_NAME}"-worker,"${CLUSTER_NAME}"-control-plane "${AWS_SERVICE_DOCKER_IMG}" || exit 1
echo "ok."

export KUBECONFIG="${TMP_DIR}/kubeconfig"

trap "clean_up" EXIT

export AWS_ACCOUNT_ID
export AWS_REGION
export AWS_ROLE_ARN
export ACK_ENABLE_DEVELOPMENT_LOGGING
export ACK_LOG_LEVEL

service_config_dir="$ROOT_DIR/services/$AWS_SERVICE/config"

## Register the ACK service controller's CRDs in the target k8s cluster
echo -n "loading CRD manifests for $AWS_SERVICE into the cluster ... "
for crd_file in $service_config_dir/crd/bases; do
    kubectl apply -f "$crd_file" --validate=false 1>/dev/null
done
echo "ok."

echo -n "loading RBAC manifests for $AWS_SERVICE into the cluster ... "
kustomize build "$service_config_dir"/rbac | kubectl apply -f - 1>/dev/null
echo "ok."

## Create the ACK service controller Deployment in the target k8s cluster
test_config_dir=$TMP_DIR/config/test
mkdir -p "$test_config_dir"

cp "$service_config_dir"/controller/deployment.yaml "$test_config_dir"/deployment.yaml

cat <<EOF >"$test_config_dir"/kustomization.yaml
resources:
- deployment.yaml
EOF

echo -n "loading service controller Deployment for $AWS_SERVICE into the cluster ..."
cd "$test_config_dir"
kustomize edit set image controller="$AWS_SERVICE_DOCKER_IMG"
kustomize build "$test_config_dir" | kubectl apply -f - 1>/dev/null
echo "ok."

## Functional tests where we assume role and pass aws temporary credentials as env vars to deployment
echo -n "generating AWS temporary credentials and adding to env vars map ... "
aws_generate_temp_creds
kubectl -n ack-system set env deployment/ack-"$AWS_SERVICE"-controller \
    AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
    AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
    AWS_SESSION_TOKEN="$AWS_SESSION_TOKEN" \
    AWS_ACCOUNT_ID="$AWS_ACCOUNT_ID" \
    ACK_ENABLE_DEVELOPMENT_LOGGING="$ACK_ENABLE_DEVELOPMENT_LOGGING" \
    ACK_LOG_LEVEL="$ACK_LOG_LEVEL" \
    AWS_REGION="$AWS_REGION" 1>/dev/null
sleep 10
echo "ok."

echo "======================================================================================================"
echo "To poke around your test cluster manually:"
echo "export KUBECONFIG=$TMP_DIR/kubeconfig"
echo "kubectl get pods -A"
echo "======================================================================================================"

export KUBECONFIG

$TEST_E2E_DIR/run-tests.sh $AWS_SERVICE
