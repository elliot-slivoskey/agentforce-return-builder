/**
 * @description Client-side submit backing for the Return Builder output CLT.
 *
 * DATA (orders/items/reasons) is NOT fetched here — the agent user owns that and
 * passes it into the CLT via ReturnBuilderAction / ReturnBuilderSeed. This class
 * exposes the interactive submit callbacks the rendered LWC needs.
 *
 * ---------------------------------------------------------------------------
 * WHY SUBMIT IS ASYNC (platform-event delegation)
 * ---------------------------------------------------------------------------
 * The LWC runs as the Enhanced Chat v2 site guest. ConnectApi.ReturnOrder
 * .createReturnOrder is gated by the Lightning Order Management User PSL, which
 * the Guest User license can NEVER hold (nor can the guest hold the equivalent
 * OM system permissions) — so the guest can't create the RMA directly, in any
 * sharing/system mode. A platform-event SUBSCRIBER, however, runs as the
 * Automated Process user, which is NOT bound by that PSL wall. So the flow is:
 *
 *   1. submitReturnFromForm (guest)  -> publish RB_Return_Request__e, return a
 *                                       correlationId immediately (pending).
 *   2. RB_ReturnRequestTrigger       -> runs as Automated Process, calls
 *                                       fulfill(), creates the RMA, writes the
 *                                       outcome to RB_Return_Result__c.
 *   3. pollReturnResult (guest)      -> LWC polls by correlationId until the
 *                                       result row appears (~1-2s).
 *
 * No callout, connected app, or stored credentials — the privileged write never
 * touches the guest's identity or a public endpoint.
 *
 * `without sharing` + system-mode: the guest license blocks OrderSummary/
 * ReturnOrder/RB_Return_Result__c object permissions; system mode is the
 * standard guest-controller pattern.
 *
 * BIND-FREE: the guest methods run in the ECv2 messaging Apex-proxy context,
 * where any SOQL bind variable (`WHERE x = :y`) throws "Variable does not exist:
 * tmpVar1". Queries here inline platform-validated / sanitized literals instead
 * of binding them.
 */
public without sharing class ReturnBuilderService {

    // Reasons that do NOT qualify for a shipping refund. Edit to match your
    // OrderItemSummaryChange.Reason picklist.
    private static final Set<String> NO_SHIPPING_REFUND = new Set<String>{
        'Ordered Wrong Item', 'Ordered by Mistake', 'Found Better Price'
    };

    // ============================================================
    //  Submit payload shape  (LWC form -> submitReturnFromForm)
    // ============================================================
    public class ReturnRequest {
        @AuraEnabled public String orderSummaryId;
        @AuraEnabled public String orderNumber;
        @AuraEnabled public List<ReturnLine> lines;
    }

    public class ReturnLine {
        @AuraEnabled public String orderItemSummaryId;
        @AuraEnabled public String productName;
        @AuraEnabled public Decimal quantity;
        @AuraEnabled public String reasonCode;
        @AuraEnabled public String method; // 'Return' | 'Replacement'
    }

    public class SubmitResult {
        @AuraEnabled public Boolean success;
        @AuraEnabled public String returnOrderNumber;
        // Set only when one or more lines were resolved as 'Replacement': the
        // number of the $0 reship FulfillmentOrder created for them.
        @AuraEnabled public String replacementOrderNumber;
        @AuraEnabled public String message;
        // Async handshake: the LWC gets a correlationId back from submit and
        // polls pollReturnResult with it. pending=true means "still processing,
        // no result row yet"; success is null while pending.
        @AuraEnabled public String correlationId;
        @AuraEnabled public Boolean pending;
    }

    // ============================================================
    //  Submit — one consolidated RMA with N line items
    // ============================================================
    /**
     * Called imperatively by the Return Builder LWC (client-side), NOT by the
     * planner. Creates a single ReturnOrder (RMA) containing one line item per
     * selected product, via ConnectApi.ReturnOrder — so a multi-item
     * return yields ONE return order number rather than N separate ones.
     *
     * Takes a JSON STRING, not a typed ReturnRequest: the ECv2 messaging Apex
     * proxy does not reliably deserialize a complex Apex parameter (nested
     * `lines` arrive empty -> "No return details were provided"). A String
     * parameter always crosses the proxy intact; we deserialize it here.
     */
    @AuraEnabled
    public static SubmitResult submitReturnFromForm(String dataJson) {
        SubmitResult r = new SubmitResult();

        // Validate the payload up front so obvious problems surface synchronously
        // (before we spend a platform-event round-trip on them).
        ReturnRequest data;
        try {
            data = (ReturnRequest) JSON.deserialize(dataJson, ReturnRequest.class);
        } catch (Exception e) {
            r.success = false;
            r.message = 'Could not read the return details.';
            return r;
        }
        if (data == null || String.isBlank(data.orderSummaryId)
                || data.lines == null || data.lines.isEmpty()) {
            r.success = false;
            r.message = 'No return details were provided.';
            return r;
        }

        // Hand the privileged create off to the platform-event subscriber (which
        // runs as Automated Process, past the guest PSL wall). We can't create
        // the RMA here as the guest.
        String cid = newCorrelationId();
        Database.SaveResult sr = EventBus.publish(new RB_Return_Request__e(
            CorrelationId__c = cid,
            Payload__c = dataJson
        ));
        if (sr == null || !sr.isSuccess()) {
            r.success = false;
            r.message = 'Could not submit your return for processing. Please try again.';
            return r;
        }

        r.pending = true;
        r.correlationId = cid;
        r.message = 'Submitting your return…';
        return r;
    }

    /**
     * Polled by the LWC (client-side) with the correlationId from submit. Returns
     * pending=true until the subscriber has written the RB_Return_Result__c row,
     * then the final success/RMA/message. Bind-free: correlationId is sanitized
     * to [A-Za-z0-9] and inlined (a `WHERE x = :var` bind throws tmpVar1 in the
     * ECv2 proxy).
     */
    @AuraEnabled
    public static SubmitResult pollReturnResult(String correlationId) {
        SubmitResult r = new SubmitResult();
        r.correlationId = correlationId;
        String cid = (correlationId == null) ? '' : correlationId.replaceAll('[^A-Za-z0-9]', '');
        if (String.isBlank(cid)) {
            r.success = false;
            r.message = 'Missing return reference.';
            return r;
        }
        List<RB_Return_Result__c> rows = Database.query(
            'SELECT Success__c, ReturnOrderNumber__c, Message__c ' +
            'FROM RB_Return_Result__c ' +
            'WHERE CorrelationId__c = \'' + cid + '\' ' +
            'ORDER BY CreatedDate DESC LIMIT 1'
        );
        if (rows.isEmpty()) {
            r.pending = true;
            return r;
        }
        RB_Return_Result__c row = rows[0];
        r.pending = false;
        r.success = row.Success__c;
        r.returnOrderNumber = row.ReturnOrderNumber__c;
        r.message = row.Message__c;
        // The reship FO number is carried inside the outcome message rather than
        // in its own field, so the LWC can surface it without an extra custom
        // column. See createConsolidatedReturn for the phrase this parses.
        r.replacementOrderNumber = extractReplacementNumber(row.Message__c);
        return r;
    }

    /**
     * Invoked by RB_ReturnRequestTrigger as the Automated Process user. Creates
     * the RMA (past the guest PSL wall) and persists the outcome keyed by
     * correlationId for the guest to poll. Never throws — any failure is captured
     * into the result row so the poller sees a message rather than hanging.
     */
    public static void fulfill(String correlationId, String payloadJson) {
        SubmitResult sr;
        try {
            ReturnRequest data = (ReturnRequest) JSON.deserialize(payloadJson, ReturnRequest.class);
            sr = createConsolidatedReturn(data);
        } catch (Exception e) {
            sr = new SubmitResult();
            sr.success = false;
            sr.message = 'Could not create the return: ' + e.getMessage();
        }
        RB_Return_Result__c row = new RB_Return_Result__c(
            CorrelationId__c = correlationId,
            Success__c = (sr.success == true),
            ReturnOrderNumber__c = sr.returnOrderNumber,
            Message__c = sr.message
        );
        insert row;
        shareWithSiteGuests(row.Id);
    }

    /**
     * Grant the site guest(s) Read on the result row so the guest poll can see
     * it. The row is owned by the Automated Process user (this subscriber), and
     * a guest can't read a record it doesn't own under Secure Guest User Record
     * Access. The criteria-based guest sharing rule does NOT fire for rows
     * inserted in this platform-event/Automated-Process context (such rows get
     * no __Share row), so we create an explicit Apex managed share —
     * deterministic and immediate, with no async recalc race against the poll.
     */
    private static void shareWithSiteGuests(Id rowId) {
        try {
            List<RB_Return_Result__Share> shares = new List<RB_Return_Result__Share>();
            for (Group g : [SELECT Id FROM Group WHERE Type = 'GuestUserGroup']) {
                shares.add(new RB_Return_Result__Share(
                    ParentId = rowId,
                    UserOrGroupId = g.Id,
                    AccessLevel = 'Read',
                    RowCause = Schema.RB_Return_Result__Share.RowCause.Manual
                ));
            }
            if (!shares.isEmpty()) {
                Database.insert(shares, false); // best-effort; never block the result
            }
        } catch (Exception e) {
            // Sharing is a delivery optimization for the poll; if it fails the
            // result row still exists. Swallow so fulfill() never throws.
            System.debug(LoggingLevel.WARN, 'RB share failed: ' + e.getMessage());
        }
    }

    /**
     * Pulls the reship FO number out of the outcome message written by
     * createConsolidatedReturn ("...A $0 replacement order (FO-1234) was
     * created..."). Returns null when the message has no replacement clause.
     * Parsing our own controlled phrase avoids adding a custom column just to
     * ferry one string back to the poller.
     */
    private static String extractReplacementNumber(String message) {
        if (String.isBlank(message)) {
            return null;
        }
        Matcher m = Pattern.compile('replacement order \\(([^)]+)\\)').matcher(message);
        return m.find() ? m.group(1) : null;
    }

    /** Injection-safe (hex) correlation id for the async submit handshake. */
    private static String newCorrelationId() {
        return EncodingUtil.convertToHex(Crypto.generateAesKey(128)); // 32 hex chars
    }

    private static SubmitResult createConsolidatedReturn(ReturnRequest data) {
        SubmitResult r = new SubmitResult();
        if (data == null || String.isBlank(data.orderSummaryId) || data.lines == null || data.lines.isEmpty()) {
            r.success = false;
            r.message = 'No return details were provided.';
            return r;
        }
        try {
            ConnectApi.ReturnOrderInputRepresentation input = new ConnectApi.ReturnOrderInputRepresentation();
            input.orderSummaryId = data.orderSummaryId;
            input.returnOrderLifeCycleType = 'MANAGED';
            input.status = 'Submitted';
            input.returnOrderLineItems = new List<ConnectApi.ReturnOrderLineItemInputRepresentation>();

            Set<String> methods = new Set<String>();
            List<ReturnLine> replacementLines = new List<ReturnLine>();
            for (ReturnLine line : data.lines) {
                if (line == null || String.isBlank(line.orderItemSummaryId)) {
                    continue;
                }
                ConnectApi.ReturnOrderLineItemInputRepresentation li =
                    new ConnectApi.ReturnOrderLineItemInputRepresentation();
                li.orderItemSummaryId = line.orderItemSummaryId;
                li.quantityExpected = line.quantity;
                li.reasonForReturn = line.reasonCode;
                li.canReduceShipping = !NO_SHIPPING_REFUND.contains(line.reasonCode);
                input.returnOrderLineItems.add(li);
                if (String.isNotBlank(line.method)) {
                    methods.add(line.method);
                }
                if ('Replacement'.equalsIgnoreCase(line.method)) {
                    replacementLines.add(line);
                }
            }

            if (input.returnOrderLineItems.isEmpty()) {
                r.success = false;
                r.message = 'None of the selected items could be returned.';
                return r;
            }

            ConnectApi.ReturnOrderOutputRepresentation out = ConnectApi.ReturnOrder.createReturnOrder(input);
            Id returnOrderId = out.returnOrderId;

            // Description carries the resolution method(s).
            // NOTE: Id literal is inlined (not bound) — a `WHERE Id = :var` bind
            // throws "Variable does not exist: tmpVar1" in this ECv2 proxy
            // context. returnOrderId is a platform-validated Id, so inlining it
            // into the query string is injection-safe.
            String roQuery =
                'SELECT Id, ReturnOrderNumber, Description FROM ReturnOrder ' +
                'WHERE Id = \'' + String.valueOf(returnOrderId) + '\' LIMIT 1';
            ReturnOrder ro = (ReturnOrder) Database.query(roQuery);
            ro.Description = String.join(new List<String>(methods), ', ');
            update ro;

            r.success = true;
            r.returnOrderNumber = ro.ReturnOrderNumber;
            r.message = 'Return order ' + ro.ReturnOrderNumber + ' created with '
                + input.returnOrderLineItems.size() + ' item(s).';

            // For any 'Replacement' lines, create a $0 reship fulfillment order
            // (a reship FO linked back to the return order via
            // FulfillmentOrder.Reship_Return_Order__c). Best-effort — a reship
            // problem must never fail the return that already succeeded.
            if (!replacementLines.isEmpty()) {
                String reshipNumber = createReshipOrder(data.orderSummaryId, returnOrderId, replacementLines);
                if (String.isNotBlank(reshipNumber)) {
                    r.replacementOrderNumber = reshipNumber;
                    r.message += ' A $0 replacement order (' + reshipNumber + ') was created for '
                        + replacementLines.size() + ' item(s).';
                }
            }
        } catch (Exception e) {
            r.success = false;
            r.message = 'Could not create the return: ' + e.getMessage();
        }
        return r;
    }

    /**
     * Creates a $0 reship FulfillmentOrder for the given replacement lines and
     * returns its FulfillmentOrderNumber (or null if it could not be created).
     *
     * Reship is NOT a mode of ConnectApi.FulfillmentOrder.createFulfillmentOrders
     * — that API validates quantity against remaining-to-fulfill, which is 0 for
     * an already-fulfilled item ("Provide a valid Quantity") — and the standard reship
     * flows are interactive SCREEN flows that can't run from this subscriber.
     * So we build the reship records directly: a
     * FulfillmentOrder with IsReship=true (which makes the platform price it at
     * $0) plus one line item per replacement line, linked to the originating
     * return order via the Reship_Return_Order__c lookup (shipped in this repo).
     *
     * Never throws — the caller has already created the return; a reship failure
     * is swallowed so the customer still gets their RMA. Bind-free (validated Id
     * literals inlined), matching the rest of this class.
     */
    private static String createReshipOrder(String orderSummaryId, Id returnOrderId, List<ReturnLine> lines) {
        try {
            if (String.isBlank(orderSummaryId) || lines == null || lines.isEmpty()) {
                return null;
            }
            String osId = String.valueOf((Id) orderSummaryId); // cast validates it is an Id

            // Ship-from location + customer name: mirror the order's most recent
            // fulfillment order so the reship resembles the original shipment.
            String fromLocationId = null;
            String toName = null;
            List<FulfillmentOrder> origFos = Database.query(
                'SELECT FulfilledFromLocationId, FulfilledToName FROM FulfillmentOrder ' +
                'WHERE OrderSummaryId = \'' + osId + '\' ' +
                'ORDER BY CreatedDate DESC LIMIT 1'
            );
            if (!origFos.isEmpty()) {
                fromLocationId = origFos[0].FulfilledFromLocationId;
                toName = origFos[0].FulfilledToName;
            }

            FulfillmentOrder fo = new FulfillmentOrder(
                OrderSummaryId = osId,
                FulfilledFromLocationId = fromLocationId,
                IsReship = true,
                Status = 'Draft',
                FulfilledToName = String.isBlank(toName) ? 'Replacement' : toName,
                Reship_Return_Order__c = returnOrderId
            );
            insert fo;

            List<FulfillmentOrderLineItem> items = new List<FulfillmentOrderLineItem>();
            for (ReturnLine line : lines) {
                if (line == null || String.isBlank(line.orderItemSummaryId)) {
                    continue;
                }
                Decimal qty = (line.quantity == null || line.quantity <= 0) ? 1 : line.quantity;
                items.add(new FulfillmentOrderLineItem(
                    FulfillmentOrderId = fo.Id,
                    OrderItemSummaryId = line.orderItemSummaryId,
                    Quantity = qty,
                    OriginalQuantity = qty,
                    Type = 'Order Product',
                    TypeCode = 'Product'
                ));
            }
            if (!items.isEmpty()) {
                insert items;
            }

            List<FulfillmentOrder> created = Database.query(
                'SELECT FulfillmentOrderNumber FROM FulfillmentOrder ' +
                'WHERE Id = \'' + String.valueOf(fo.Id) + '\' LIMIT 1'
            );
            return created.isEmpty() ? null : created[0].FulfillmentOrderNumber;
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'RB reship failed: ' + e.getMessage());
            return null;
        }
    }
}
