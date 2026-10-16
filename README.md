# Readme for Humans - Agentforce Return Builder

An interactive return card that renders inside an Agentforce chat. The shopper picks an order, ticks the items, sets quantities, a reason and refund-or-replacement, and submits. That creates a real Salesforce Order Management return order (RMA) and, for replacements, a $0 reship fulfillment order. Whatever the shopper already said in chat ("return both batteries, they're broken") arrives pre-filled.

## Why this was built

Return configuration via chat takes six or more back-and-forth turns: which order, which item, how many, why, refund or replacement, confirm. Each turn is a chance for the agent to misread an answer. The transformation of customer intent to deterministic outcome happens after submittal with no chance to review which I didn't like. A Custom Lightning Type (CLT) lets the agent hand the shopper one card instead, while the agent still does the language work of pulling hints out of the conversation.

## Why this was published

There are few working examples of an *interactive* output CLT, one that writes data back and this ended up being quite difficult to get working. The README below lists each wall with its workaround.

## Video Preview

https://github.com/user-attachments/assets/accfe0a5-60fe-4318-b283-a58737e5c44f






---

# Readme for Agents - Agentforce Return Builder

## How it works

- **Render, as the agent user:** `Return_Builder` action → `Build_Return_Output` flow → `ReturnBuilderAction` builds a `ReturnBuilderSeed` (orders, items, images, reasons, chat pre-fill) → `returnBuilderCard` Lightning Type → `c/returnBuilder` renders `value`. The card makes no data calls of its own.
- **Submit, as the site guest:** `ReturnBuilderService.submitReturnFromForm` publishes `RB_Return_Request__e` → `RB_ReturnRequestTrigger` runs as Automated Process, creates the RMA plus a $0 reship for replacements, and writes and shares an `RB_Return_Result__c` row → the card polls `pollReturnResult`.
- **Reasons** are the active `OrderItemSummaryChange.Reason` picklist values. The shopper picks Refund or Replacement per item; refund is the default.

## Prerequisites

Order Management, Commerce WebStore (images only), and a Service Agent on **Enhanced Chat v2**. Tested on Legacy ReAct only.

Check v2 before anything else. The retrieved XML doesn't contain it, so look in Tooling:

```
sf data query --use-tooling-api -q "SELECT DeveloperName, ClientVersion FROM EmbeddedServiceConfig"
```

`ClientVersion` must be `WebV2`. If it's null (v1), **upgrade in the Setup UI**, not by API (see 11).

## Install

1. `scripts/deploy.sh <org>` deploys in dependency order. A single `sf project deploy start -d force-app` fails with `UNKNOWN_EXCEPTION` on a fresh org (see 10). Pass `--dry-run` to validate only.
2. Assign `Return_Builder_Admin` to yourself (and whoever runs the tests), `Return_Builder_Agent` to the agent user, and `Return_Builder_Guest` to the chat site's guest user. A source deploy grants no field-level security, so without the Admin permset `ReturnBuilderServiceTest` fails with "No such column" on `RB_Return_Result__c`.
3. Add the action to a topic with **no context-variable bindings** (see 7). Find out first whether the agent's topics are global `GenAiPlugin`s or local topics inside its `GenAiPlannerBundle` (`localTopics`). For local topics, edit the bundle: add a `localActions` entry for `Return_Builder` (invocationTarget `Build_Return_Output`, copy the input/output schemas) and link it in `localActionLinks`. Deactivate the agent, deploy, then reactivate (`sf agent deactivate` / `sf agent activate`). Unlink any action that collects return details by text, or the agent will use it instead.
4. Make sure the agent's planner has **both** `plannerSurfaces`: `SurfaceAction__Messaging` and `SurfaceAction__CustomerWebClient`. The second is the Enhanced Chat v2 connection; without it the card never renders. Add it to the bundle the same way as step 3.
5. Republish the ESD, then the ESW site, after any LWC change.
6. `scripts/preflight.sh <org> <planner> <esd>` checks steps 2–4 and the v2 setting. It changes nothing.
7. Test in the live chat or the ESD test page. Agent Builder Preview doesn't render CLTs for Service Agents.

### Sample topic instruction

Starting point for the returns instruction in an order-management topic:

> When the shopper wants to return an item, call the Return Builder action on this turn. Pass the order number, product, quantity, reason, and refund/replacement choice only if the shopper stated them. Never ask the shopper to type the item, quantity, reason, or refund/replacement choice, and never describe or summarize the component. Respond only with: "Please let me know what you'd like to return." If productHintUnmatched is true, say you couldn't find that item and they can pick it from the order instead.

The agent asking for an order number first is fine; the card opens straight to that order.

## Undocumented behaviors

1. **SOQL bind variables throw `tmpVar1` in card callbacks** (the Enhanced Chat Apex proxy), but not in tests. Query in the action, or inline validated literals.
2. **Guests can't hold Order Management permissions,** and `createReturnOrder` is license-gated regardless of sharing mode. That's why writes go through the platform event.
3. **Criteria guest sharing rules don't fire for rows inserted in platform-event context,** and guest profiles silently drop View All. That's why `fulfill()` writes the `__Share` row. Keep the external OWD Private.
4. **"The Apex request is invalid" (HTTP 400)** means the *live* site's guest lacks class access, or a stale LWC is calling a removed method. The request's Payload tab names the class and method.
5. **Only a flow wrapper renders.** An Apex-direct action degrades to text, and the seed must be a top-level `global` `@JsonAccess` class.
6. **`ConnectApi.CommerceCatalog` enforces the running user's CRUD,** even from `without sharing` code. Missing Commerce reads show up as placeholder images.
7. **A context-variable-bound input on a displayable action suppresses the render,** with no error.
8. **Action input schemas lock once the action is wired to a topic:** deploys no-op. Make a `_v2` action instead. Same-named actions created in the Agent Builder UI also make deploys silently land nowhere.
9. **Permission set edits can report success without applying** (for example Create without Read on a platform event). Verify with SOQL on `ObjectPermissions` / `FieldPermissions`.
10. **The LWC and the Lightning Type can't be deployed apart on first install.** Each references the other (`c__returnBuilderCard property type not found` / `Something's not right with the definition name c/returnBuilder`). Deploy them in one request. `deploy.sh` does this.
11. **Setting `clientVersion` to `WebV2` through the Tooling API breaks the hosted chat page.** The Setup UI upgrade also rewrites the ESW site's home view from `embeddedMessaging:container` to `cwcMessaging:container`; the API change doesn't. If you already did it by API, retrieve the ESW `DigitalExperienceBundle`, swap the home view component to `cwcMessaging:container`, deploy, and publish.
12. **`clientVersion` is missing from retrieved `EmbeddedServiceConfig` XML,** so diffing source can't tell v1 from v2. Use the Tooling query under Prerequisites.
13. **Planner bundle retrieves can hang.** Always pass `--wait`, or confirm wiring in Tooling: topic-scoped copies of the action show up as `GenAiFunctionDefinition` rows named `Return_Builder_<id>`.
14. **Headless browsers can't drive Enhanced Chat.** The chat runs in a cross-origin iframe: typing works, but clicking Send doesn't and Enter only adds a newline. Test the render by hand, or run `Build_Return_Output` as the agent user to check the data.

## Known limitations

- **No shopper scoping:** the card lists every returnable order in the org. Add identity before using it beyond a demo.
- Tests can't create Order Management records, so the RMA, reship and pre-fill paths are only exercised live.
