#!/usr/bin/env bash
# Read-only checks for the setup steps that fail silently. Run after deploy.sh
# and after wiring the action into a topic. Changes nothing.
#
#   scripts/preflight.sh <org-alias> <planner-api-name> <esd-api-name>
#   planner = the agent's GenAiPlannerBundle, e.g. SDO_SCOM_Guided_Shopping_Agent
#   esd     = the Enhanced Chat deployment the store uses, e.g. Messaging_for_Commerce
set -uo pipefail
USAGE="usage: scripts/preflight.sh <org-alias> <planner-api-name> <esd-api-name>"
ORG="${1:?$USAGE}"; PLANNER="${2:?$USAGE}"; ESD="${3:?$USAGE}"
FAIL=0
q()  { sf data query -o "$ORG" -q "$1" --json 2>/dev/null | jq -r '.result.records'; }
qt() { sf data query -o "$ORG" --use-tooling-api -q "$1" --json 2>/dev/null | jq -r '.result.records'; }
ok()  { echo "  OK    $1"; }
bad() { echo "  FAIL  $1"; FAIL=1; }

echo "1. The deployment must be Enhanced Chat v2 (ClientVersion is not in retrieved XML)"
ver=$(qt "SELECT ClientVersion FROM EmbeddedServiceConfig WHERE DeveloperName='$ESD'" | jq -r '.[0].ClientVersion // "null"')
[ "$ver" = "WebV2" ] && ok "$ESD = WebV2" || bad "$ESD ClientVersion = $ver (upgrade in the Setup UI, not by API)"

echo "2. Agent needs the Enhanced Chat v2 connection (CustomerWebClient surface)"
# No Tooling object exposes planner surfaces, so retrieve the bundle.
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
sf project retrieve start -o "$ORG" -m "GenAiPlannerBundle:$PLANNER" --target-metadata-dir "$TMP" --unzip --wait 5 >/dev/null 2>&1
surfaces=$(grep -rhoE 'SurfaceAction__[A-Za-z]+' "$TMP" | sort -u | tr '\n' ' ')
echo "$surfaces" | grep -q CustomerWebClient && ok "CustomerWebClient surface present" ||
  bad "no CustomerWebClient surface on $PLANNER (found: ${surfaces:-none})"

echo "3. Return Builder action is wired into a topic"
fns=$(qt "SELECT DeveloperName FROM GenAiFunctionDefinition WHERE DeveloperName LIKE 'Return_Builder%'" | jq -r '.[].DeveloperName')
[ "$(echo "$fns" | grep -c .)" -gt 1 ] && ok "topic-scoped copies exist: $(echo $fns)" ||
  bad "only the repo action exists ($fns); add it to a topic"

echo "4. Permission sets are assigned"
for ps in Return_Builder_Admin Return_Builder_Agent Return_Builder_Guest; do
  who=$(q "SELECT Assignee.Name FROM PermissionSetAssignment WHERE PermissionSet.Name='$ps'" | jq -r '[.[].Assignee.Name] | join(", ")')
  [ -n "$who" ] && ok "$ps -> $who" || bad "$ps is not assigned"
done

echo "5. Guest permset actually grants Read+Create on the platform event"
pe=$(q "SELECT PermissionsRead, PermissionsCreate FROM ObjectPermissions WHERE Parent.Name='Return_Builder_Guest' AND SobjectType='RB_Return_Request__e'" | jq -r '.[0] | "\(.PermissionsRead) \(.PermissionsCreate)"')
[ "$pe" = "true true" ] && ok "RB_Return_Request__e Read+Create" || bad "RB_Return_Request__e perms: $pe"

echo
echo "Not checkable here, verify by hand:"
echo "  - The ESW site home view uses cwcMessaging:container (v2), not embeddedMessaging:container (v1)."
echo "  - The ESD and the ESW site were republished after the last LWC change."
exit $FAIL
