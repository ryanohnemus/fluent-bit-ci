#!/usr/bin/env bats

load "$HELPERS_ROOT/test-helpers.bash"

ensure_variables_set BATS_SUPPORT_ROOT BATS_ASSERT_ROOT BATS_DETIK_ROOT BATS_FILE_ROOT FLUENTBIT_IMAGE_REPOSITORY FLUENTBIT_IMAGE_TAG

load "$BATS_DETIK_ROOT/utils.bash"
load "$BATS_DETIK_ROOT/linter.bash"
load "$BATS_DETIK_ROOT/detik.bash"
load "$BATS_SUPPORT_ROOT/load.bash"
load "$BATS_ASSERT_ROOT/load.bash"
load "$BATS_FILE_ROOT/load.bash"

# These are required for bats-detik
# shellcheck disable=SC2034
DETIK_CLIENT_NAME="kubectl -n $TEST_NAMESPACE"
# shellcheck disable=SC2034
DETIK_CLIENT_NAMESPACE="${TEST_NAMESPACE}"
FLUENTBIT_POD_NAME=""
TEST_POD_NAME=""

setup_file() {
    export TEST_NAMESPACE=${TEST_NAMESPACE:-tail-rotate-basic}
    echo "recreating namespace $TEST_NAMESPACE"
    run kubectl delete namespace "$TEST_NAMESPACE"
    run kubectl create namespace "$TEST_NAMESPACE"
    create_helm_extra_values_file

    helm repo add fluent https://fluent.github.io/helm-charts/ || helm repo add fluent https://fluent.github.io/helm-charts
    helm repo update --fail-on-repo-update-fail

    FLUENTBIT_ENV_VARS="env[0].name=TEST_NAMESPACE,env[0].value=${TEST_NAMESPACE},env[1].name=NODE_IP,env[1].valueFrom.fieldRef.fieldPath=status.hostIP"
    helm upgrade --install --debug --create-namespace --namespace "$TEST_NAMESPACE" fluent-bit fluent/fluent-bit \
        --values ${BATS_TEST_DIRNAME}/resources/fluentbit-basic.yaml \
        --set image.repository=${FLUENTBIT_IMAGE_REPOSITORY},image.tag=${FLUENTBIT_IMAGE_TAG},${FLUENTBIT_ENV_VARS} \
        --values "$HELM_VALUES_EXTRA_FILE" \
        --timeout "${HELM_FB_TIMEOUT:-5m0s}" \
        --wait
}

teardown_file() {
    if [[ "${SKIP_TEARDOWN:-no}" != "yes" ]]; then
        helm uninstall fluent-bit -n $TEST_NAMESPACE
        run kubectl delete namespace "$TEST_NAMESPACE"
        rm -f ${HELM_VALUES_EXTRA_FILE}
    fi
}

setup() {
    FLUENTBIT_POD_NAME=""
    TEST_POD_NAME=""
}

teardown() {
     if [[ "${SKIP_TEARDOWN:-no}" != "yes" ]]; then
        if [[ ! -z "$TEST_POD_NAME" ]]; then
            run kubectl delete pod $TEST_POD_NAME -n $TEST_NAMESPACE --grace-period 1 --wait
        fi
    fi
}


function set_fluent_bit_pod_name() {
    try "at most 30 times every 2s " \
        "to find 1 pods named 'fluent-bit' " \
        "with 'status' being 'running'"

    FLUENTBIT_POD_NAME=$(kubectl get pods -n "$TEST_NAMESPACE" -l "app.kubernetes.io/name=fluent-bit" --no-headers | awk '{ print $1 }')
    if [ -z "$FLUENTBIT_POD_NAME" ]; then
        fail "Unable to get running fluent-bit pod's name"
    fi
}


function create_noisy_pod() {
    # The hello-world-1 container MUST be on the same node as the fluentbit worker, so we use a nodeSelector to specify the same node name
    run kubectl get pods $FLUENTBIT_POD_NAME -n $TEST_NAMESPACE -o jsonpath='{.spec.nodeName}'
    assert_success
    refute_output ""
    node_name=$output

    TEST_POD_NAME="noisylogger"
    LINE_COUNT="10000000"
    kubectl run -n $TEST_NAMESPACE $TEST_POD_NAME --image=docker.io/library/golang:1.19 --restart Never \
        --overrides="{\"apiVersion\":\"v1\",\"spec\":{\"nodeSelector\":{\"kubernetes.io/hostname\":\"$node_name\"}}}" \
        --command -- sh -c 'go install github.com/ryanohnemus/flog@95b57bdc77a436429ac5366ba19b60cbf6292721 > /dev/null 2>&1 && \
          ./bin/flog -t stdout -f json_sequential -n '${LINE_COUNT}
    
    # wait for noisy logger to complete
    try "at most 60 times every 2s " \
        "to find 1 pods named '${TEST_POD_NAME}' " \
        "with 'status' being 'succeeded'"

    FLUENTBIT_POD_IP=$(kubectl get pods $FLUENTBIT_POD_NAME -n $TEST_NAMESPACE -o jsonpath='{.status.podIP}')

    # give fluentbit time to process all logs (TODO: probably a better way to do this than just sleep)
    sleep 120

    kubectl run curler --image=docker.io/alpine/curl --restart Never --command -- sh -c "curl --silent http://${FLUENTBIT_POD_IP}:2020/api/v1/metrics"
    try "at most 30 times every 2s " \
        "to find 1 pods named 'curler' " \
        "with 'status' being 'succeeded'"

    run kubectl logs curler
    CURL_OUTPUT=$output
    INPUT_TAIL_COUNT=$(echo $output | jq '.input."tail.0".records')
    OUTPUT_COUNTER_COUNT=$(echo $output | jq '.output."counter.0".proc_records')
    assert test "$LINE_COUNT" -le "$INPUT_TAIL_COUNT"
    assert_equal "$INPUT_TAIL_COUNT" "$OUTPUT_COUNTER_COUNT" 

}

@test "test noisy pod 10 million records" {
    set_fluent_bit_pod_name
    create_noisy_pod
}
