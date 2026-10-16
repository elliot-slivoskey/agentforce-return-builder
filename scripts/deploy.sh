#!/usr/bin/env bash
# First install of Return Builder, in dependency order. A single
# `sf project deploy start -d force-app` gacks (UNKNOWN_EXCEPTION) on a fresh org;
# after one layered install the single-shot deploy works.
#
#   scripts/deploy.sh <org-alias> [extra sf flags, e.g. --dry-run]
set -euo pipefail
ORG="${1:?usage: scripts/deploy.sh <org-alias> [--dry-run]}"; shift
D=force-app/main/default
cd "$(dirname "$0")/.."

step() { echo "==> $1"; shift; sf project deploy start -o "$ORG" --wait 30 "$@" ${EXTRA[@]+"${EXTRA[@]}"}; }
EXTRA=("$@")

step "objects"                 -d "$D/objects"
step "classes + trigger"       -d "$D/classes" -d "$D/triggers"
step "permission sets"         -d "$D/permissionsets"
step "flow"                    -d "$D/flows"
# The LWC and the Lightning Type reference each other; either alone fails.
step "lwc + lightning type"    -d "$D/lwc" -d "$D/lightningTypes"
step "agent action"            -d "$D/genAiFunctions"

echo "Done. Next: scripts/preflight.sh $ORG <planner-api-name> <esd-api-name>"
