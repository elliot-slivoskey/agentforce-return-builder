# Readme for Humans - Agentforce Return Builder

An interactive return card that renders inside an Agentforce chat. The shopper picks an order, ticks the items, sets quantities, a reason and refund-or-replacement, and submits. That creates a real Salesforce Order Management return order (RMA) and, for replacements, a $0 reship fulfillment order. Whatever the shopper already said in chat ("return both batteries, they're broken") arrives pre-filled.

## Why this was built

Return configuration via chat takes six or more back-and-forth turns: which order, which item, how many, why, refund or replacement, confirm. Each turn is a chance for the agent to misread an answer. The transformation of customer intent to deterministic outcome happens after submittal with no chance to review which I didn't like. A Custom Lightning Type (CLT) lets the agent hand the shopper one card instead, while the agent still does the language work of pulling hints out of the conversation.

## Why this was published

There are few working examples of an *interactive* output CLT, one that writes data back and this ended up being quite difficult to get working. The README below lists each wall with its workaround.

## Video Preview



---

# Readme for Agents - Agentforce Return Builder

## How it works

- **Render, as the agent user:** `Return_Builder` action → `Build_Return_Output` flow → `ReturnBuilderAction` builds a `ReturnBuilderSeed` (orders, items, images, reasons, chat pre-fill) → `returnBuilderCard` Lightning Type → `c/returnBuilder` renders `value`. The card makes no data calls of its own.
- **Submit, as the site guest:** `ReturnBuilderService.submitReturnFromForm` publishes `RB_Return_Request__e` → `RB_ReturnRequestTrigger` runs as Automated Process, creates the RMA plus a $0 reship for replacements, and writes and shares an `RB_Return_Result__c` row → the card polls `pollReturnResult`.
- **Refund vs replacement per reason** comes from `OrderChgReasonCategMap` (`Return` and/or `Exchange` rows).

## Prerequisites

Order Management, Commerce WebStore (images only), and a Service Agent on Enhanced Chat v2. Tested on Legacy ReAct only.

## Setup the code can't do

1. Assign `Return_Builder_Agent` to the agent user and `Return_Builder_Guest` to the chat site's guest user.
2. Add the action to a topic with **no context-variable bindings** (see 7). The topic instruction should tell the agent to pass the stated hints, not restate the card, and handle `productHintUnmatched`.
3. Republish the ESD, then the site, after any LWC change.
4. Test in the live chat or the ESD test page. Agent Builder Preview doesn't render CLTs for Service Agents.

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

## Known limitations

- **No shopper scoping:** the card lists every returnable order in the org. Add identity before using it beyond a demo.
- Tests can't create Order Management records, so the RMA, reship and pre-fill paths are only exercised live.
