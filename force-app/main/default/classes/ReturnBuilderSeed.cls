/**
 * @description Render DTO for the Return Builder output CLT.
 *
 * ARCHITECTURE:
 * the agent user OWNS the data. The agent action (Build_Return_Output flow ->
 * ReturnBuilderAction invocable) queries returnable orders/items/reason codes
 * SERVER-SIDE, running as the agent user in a normal Apex context, and hands the
 * fully-populated seed into this CLT. The returnBuilder LWC then just RENDERS
 * `this.value` — it makes no @AuraEnabled data calls of its own.
 *
 * Why server-side: a rendered CLT's @AuraEnabled calls run in the Enhanced
 * Chat v2 messaging Apex-proxy context, where ANY SOQL bind variable
 * (`WHERE x = :y`) throws "Variable does not exist: tmpVar1" — for guest AND
 * authenticated users. Moving
 * every query server-side sidesteps that entirely, and also sidesteps the Guest
 * User license wall on OrderSummary/OrderItemSummary object permissions.
 *
 * Top-level + `global` + @JsonAccess so it can be a Flow apex-defined output
 * variable (invocationTargetType=flow preserves the ECv2 renderable flag). A
 * Legacy Flow output variable cannot be typed as an inner class, so RBOrder /
 * RBItem are nested and only ever reached THROUGH this top-level type.
 */
@JsonAccess(serializable='always' deserializable='always')
global class ReturnBuilderSeed {

    // Optional order number the user referenced in chat (echoed back for context).
    @AuraEnabled global String orderNumber;

    // Set when `orderNumber` resolved to exactly one returnable order; the LWC
    // then opens straight to that order's items instead of the picker.
    @AuraEnabled global String resolvedOrderSummaryId;

    // Active return reason codes (OrderItemSummaryChange.Reason picklist).
    // Retained for backward compatibility; `reasons` is the richer source.
    @AuraEnabled global List<String> reasonCodes;

    // Return reasons WITH per-reason behaviour (from OrderChgReasonCategMap):
    // whether the customer may choose Refund vs Replacement, and the default
    // method. The LWC drives the resolution selector from this.
    @AuraEnabled global List<RBReason> reasons;

    // Returnable orders, each with its returnable line items nested. The LWC
    // renders the picker and the item step entirely from this — no round trips.
    @AuraEnabled global List<RBOrder> orders;

    // Populated only when the server-side build failed; surfaced on the card so
    // the user sees a graceful message instead of an empty component.
    @AuraEnabled global String errorMessage;

    // True when a non-"everything" productHint was given but matched zero
    // returnable items on the resolved order; lets the planner tell the user
    // it couldn't find that item instead of silently showing nothing selected.
    @AuraEnabled global Boolean productHintUnmatched;

    global ReturnBuilderSeed() {
        this.orderNumber = '';
        this.reasonCodes = new List<String>();
        this.reasons = new List<RBReason>();
        this.orders = new List<RBOrder>();
    }

    global ReturnBuilderSeed(String orderNumber) {
        this();
        this.orderNumber = (orderNumber == null) ? '' : orderNumber;
    }

    @JsonAccess(serializable='always' deserializable='always')
    global class RBReason {
        @AuraEnabled global String code;            // picklist value (= reasonCode sent on submit)
        @AuraEnabled global String label;           // display label
        @AuraEnabled global Boolean allowChoice;    // show the Refund/Replacement selector?
        @AuraEnabled global String defaultMethod;   // 'Return' (refund) | 'Replacement'
    }

    @JsonAccess(serializable='always' deserializable='always')
    global class RBOrder {
        @AuraEnabled global String id;                  // OrderSummary Id
        @AuraEnabled global String orderNumber;
        @AuraEnabled global String orderedDate;         // ISO-8601 GMT string
        @AuraEnabled global String status;
        @AuraEnabled global Decimal grandTotal;
        @AuraEnabled global String currencyCode;
        @AuraEnabled global Integer returnableItemCount;
        @AuraEnabled global List<RBItem> items;
    }

    @JsonAccess(serializable='always' deserializable='always')
    global class RBItem {
        @AuraEnabled global String id;                  // OrderItemSummary Id
        @AuraEnabled global String productId;           // Product2 Id
        @AuraEnabled global String name;
        @AuraEnabled global String productCode;
        @AuraEnabled global Decimal unitPrice;
        @AuraEnabled global String currencyCode;
        @AuraEnabled global Decimal quantityOrdered;
        @AuraEnabled global Decimal quantityReturned;
        @AuraEnabled global Decimal quantityAvailableToReturn;
        @AuraEnabled global String imageUrl;            // resolved CMS product image (nullable)

        // ---- Context pre-fill (from the planner-extracted hints) ----
        // Set true when the user's utterance named this product ("return the
        // batteries…"): the LWC opens with the item already checked. Items that
        // don't confidently match a product hint stay unselected.
        @AuraEnabled global Boolean preSelected;
        // A validated reason picklist value the planner extracted with high
        // confidence ("…because they're broken" -> Defective). Null when there
        // was no confident match; the LWC then leaves the reason blank.
        @AuraEnabled global String presetReasonCode;
        // 'Return' | 'Replacement' if the user stated a preference; the LWC only
        // honours it when the reason's config allows a choice, else config wins.
        @AuraEnabled global String presetMethod;
        // A quantity the planner's hint resolved to (e.g. "all" -> this item's
        // full quantityAvailableToReturn, "half" -> half of it), already clamped
        // to [1, quantityAvailableToReturn]. Null when no confident quantity was
        // stated; the LWC then defaults to 1 as before.
        @AuraEnabled global Integer presetQuantity;
    }
}