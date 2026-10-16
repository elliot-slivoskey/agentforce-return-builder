# Agent instructions

Read `README.md` ("Readme for Agents") before deploying or changing org setup. Most failures here are silent: the deploy succeeds and the card just doesn't render.

Before you start:
- Check Enhanced Chat is v2 with the Tooling query in README Prerequisites. If it's v1, ask the human to upgrade in the Setup UI. Don't patch `clientVersion` by API.
- Install with `scripts/deploy.sh`, not one `sf project deploy start -d force-app`.
- Work out whether the agent's topics are global `GenAiPlugin`s or local topics in its `GenAiPlannerBundle` before wiring the action.

Before you call it done:
- Run `scripts/preflight.sh <org> <planner> <esd>` and fix every FAIL.
- Verify permission set changes with SOQL. A successful deploy doesn't prove they applied.
- Republish the ESD, then the ESW site.

When something breaks, look it up in README "Undocumented behaviors" before debugging. If you hit something new, add it there.
