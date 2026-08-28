# Populates team-alpha and team-beta task boards with sample data.

set -euo pipefail

echo "=================================================="
echo " Seeding demo data"
echo "=================================================="

seed_tenant() {
  local namespace=$1
  shift
  local tasks=("$@")

  echo ""
  echo "--- ${namespace} ---"

  # Make sure the postgres pod is ready before inserting any data
  if ! kubectl wait --for=condition=Ready pod -l app=postgres -n "$namespace" --timeout=30s >/dev/null 2>&1; then
    echo "  [SKIP] postgres not ready in ${namespace}"
    return
  fi

  for task in "${tasks[@]}"; do
    # Escape single quotes so they don't break the SQL statement
    escaped_task=$(echo "$task" | sed "s/'/''/g")
    kubectl exec -n "$namespace" deployment/postgres -- \
      psql -U appuser -d appdb -c "INSERT INTO tasks (content) VALUES ('${escaped_task}');" >/dev/null 2>&1
    if [ $? -eq 0 ]; then
      echo "  [OK] Added: ${task}"
    else
      echo "  [FAIL] Could not add: ${task}"
    fi
  done
}

seed_tenant "team-alpha" \
  "Set up OpenNebula VM templates" \
  "Configure security group rules" \
  "Bootstrap k3s control-plane" \
  "Review RBAC policies with the team"

seed_tenant "team-beta" \
  "Write final report draft" \
  "Prepare demo script for presentation" \
  "Test NetworkPolicy edge cases" \
  "Double check Gatekeeper constraints"

echo ""
echo "=================================================="
echo " Done. Open the webapp to see the seeded tasks."
echo "=================================================="