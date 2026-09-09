# SCRUM-81: sourced by the staged SSM runner after common functions are defined.
# The MSA source is current; only controller bootstrap compatibility is shared.
normalize_dev_eks_workload_compatibility() { :; }

verify_secret_postcondition() {
  python3 "$BUNDLE_DIR/scripts/eks/msa-runtime.py" verify-secrets "$CONTRACT_FILE" >>"$LOG_FILE" 2>&1 || die "MSA Secret key-set verification failed"
}

apply_namespace_and_secret() {
  require_prepared
  kubectl apply -f "$RENDER_DIR/overlays/dev-eks/workload/namespace.yaml" -f "$RENDER_DIR/base/monitoring/namespace.yaml" >"$LOG_FILE" 2>&1 || die "namespace apply failed"
  python3 "$BUNDLE_DIR/scripts/eks/msa-runtime.py" secrets "$CONTRACT_FILE" >>"$LOG_FILE" 2>&1 || die "MSA Secret bootstrap failed"
  write_state success "$(jq -r '.render_sha256' "$STATE_FILE")"
}

verify_workload_postcondition() {
  local service
  for service in identity community maps travel; do
    wait_rollout travel-planner "deployment/$service"
  done
  wait_rollout travel-planner-monitoring deployment/kube-state-metrics
  wait_rollout travel-planner-monitoring deployment/alloy-common
  wait_rollout travel-planner-monitoring daemonset/alloy
  python3 "$BUNDLE_DIR/scripts/eks/msa-runtime.py" workload "$CONTRACT_FILE" "$VALUES_FILE" >>"$LOG_FILE" 2>&1 || die "MSA rollout/image/HPA verification failed"
}

apply_workload() {
  require_prepared
  require_completed_stage namespace-secret
  require_completed_stage platform
  python3 "$BUNDLE_DIR/scripts/eks/msa-runtime.py" images "$CONTRACT_FILE" "$VALUES_FILE" >>"$LOG_FILE" 2>&1 || die "MSA images not available as linux/amd64"
  kubectl_diff_and_apply "$RENDER_DIR/overlays/dev-eks/workload"
  verify_workload_postcondition
  write_state success "$(jq -r '.render_sha256' "$STATE_FILE")"
  # Metadata-only immutable release evidence; retain bundle and values for rollback.
  local release_dir="$WORK_DIR/releases/$EXPECTED_BUNDLE_REVISION/$(sha256sum "$VALUES_FILE" | awk '{print $1}')"
  mkdir -p "$release_dir"
  cp "$VALUES_FILE" "$release_dir/values.json"
  cp "$CONTRACT_FILE" "$release_dir/contract.json"
  cp "$STATE_FILE" "$release_dir/runner-state.json"
  cp -R "$BUNDLE_DIR" "$release_dir/"
  printf 'stage=workload status=success services=4 initial_replicas_identity=1 initial_replicas_community=2 initial_replicas_maps=2 initial_replicas_travel=2\n' >&2
}
