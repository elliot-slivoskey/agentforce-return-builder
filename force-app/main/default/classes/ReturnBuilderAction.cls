/**
 * @description Agent action that builds the Return Builder render DTO SERVER-SIDE.
 *
 * Invoked by the Build_Return_Output flow (the Return_Builder GenAiFunction).
 * Runs as the agent user in a normal Apex context — so unlike the rendered CLT's
 * @AuraEnabled calls, SOQL bind variables work here, and OrderSummary /
 * OrderItemSummary are fully readable (no Guest User license wall). This class
 * queries the returnable orders, their returnable line items, product images,
 * and the reason-code picklist, then hands a fully-populated ReturnBuilderSeed
 * to the CLT, which renders it with zero further data calls.
 *
 * `without sharing`: the agent user sees every returnable order in the org
 * regardless of record sharing; queries stay narrowly filtered to returnable
 * product lines. There is NO shopper scoping — add your own identity check
 * (e.g. filter on OrderSummary.BillingEmailAddress) before using this beyond
 * a demo.
 */
public without sharing class ReturnBuilderAction {

    // How many recent returnable orders to surface in the picker.
    private static final Integer MAX_ORDERS = 25;
    // Max returnable line items to nest per order.
    private static final Integer MAX_ITEMS_PER_ORDER = 200;

    public class Request {
        @InvocableVariable(
            label='Order Number'
            description='Optional order number the user referenced; leave blank to let the user pick.')
        public String orderNumber;

        @InvocableVariable(
            label='Product Hint'
            description='Optional. A product name/keyword or multiple products the user named to return (e.g. "batteries", "the shoes and shirts"). Matching returnable items on the resolved order are pre-selected. If the user means their whole order (e.g. "everything", "all items"), pass that phrase and every returnable item is pre-selected. Leave blank if the user did not name a product or the whole order.')
        public String productHint;

        @InvocableVariable(
            label='Reason Code'
            description='Optional. Pass ONLY if the user stated a reason you can map with high confidence to one of the active OrderItemSummaryChange.Reason picklist values. Otherwise leave blank.')
        public String reasonCode;

        @InvocableVariable(
            label='Method'
            description='Optional. Pass "Return" for a refund or "Replacement" for an exchange, only if the user clearly stated which. Otherwise leave blank.')
        public String method;

        @InvocableVariable(
            label='Quantity Hint'
            description='Optional. Pass ONLY if the user stated how many of the pre-selected product to return (e.g. "all of them", "half", "2", "three", "all but one"). Pass the phrase or number as stated. Leave blank if no quantity was mentioned; the builder then defaults to 1 per item.')
        public String quantityHint;
    }

    public class Response {
        @InvocableVariable(label='Return Builder' description='Seed to display in the Return Builder CLT.')
        public ReturnBuilderSeed seed;

        @InvocableVariable(
            label='Product Hint Unmatched'
            description='True when productHint named a specific item but it matched nothing on the resolved order. Tell the user you could not find that specific item and show them the order so they can pick manually - do not say the item was returned or selected.')
        public Boolean productHintUnmatched;
    }

    @InvocableMethod(
        label='Build Return Builder'
        description='Queries returnable orders, items, images and reason codes for the Return Builder CLT.'
        category='Return Builder')
    public static List<Response> build(List<Request> requests) {
        List<Response> results = new List<Response>();
        if (requests == null || requests.isEmpty()) {
            Response r = new Response();
            r.seed = buildSeed(null);
            results.add(r);
            return results;
        }
        for (Request req : requests) {
            Response r = new Response();
            r.seed = buildSeed(req);
            r.productHintUnmatched = r.seed.productHintUnmatched;
            results.add(r);
        }
        return results;
    }

    // ------------------------------------------------------------------
    private static ReturnBuilderSeed buildSeed(Request req) {
        String orderNumber = (req == null) ? null : req.orderNumber;
        ReturnBuilderSeed seed = new ReturnBuilderSeed(orderNumber);
        try {
            seed.reasons = reasons();
            seed.reasonCodes = reasonCodes();

            // Resolve the referenced order number (if any) to its Id.
            String resolvedId = resolveOrderSummaryId(orderNumber);
            seed.resolvedOrderSummaryId = resolvedId;

            // Build the returnable orders (each with items nested), so the LWC
            // can drive the picker AND the item step client-side.
            seed.orders = buildOrders();

            // Pre-fill from the planner-extracted hints (product/reason/method).
            // Only applies within a resolved order; anything that doesn't
            // confidently match is left unselected/blank.
            applyPrefill(seed, req, resolvedId);
        } catch (Exception e) {
            seed.errorMessage = 'Could not load your returnable orders: ' + e.getMessage();
        }
        return seed;
    }

    /**
     * Turns the planner's free-text hints into concrete pre-selection on the
     * resolved order's items. The LLM does the language understanding (which
     * product, which reason); this does the deterministic, safe application:
     * - productHint -> pre-select returnable items whose name matches; NO match
     *   leaves everything unselected (never guesses, never errors).
     * - reasonCode  -> applied to pre-selected items ONLY if it is a real active
     *   reason picklist value (validated here); otherwise left blank.
     * - method      -> carried as a preset; the LWC honours it only when the
     *   reason's config allows a choice.
     * Pre-fill requires a resolved single order — without one we can't know which
     * order's "batteries" the user meant, so we leave the picker untouched.
     */
    private static void applyPrefill(ReturnBuilderSeed seed, Request req, String resolvedId) {
        if (req == null || String.isBlank(resolvedId) || seed.orders == null) {
            return;
        }
        String productHint = (req.productHint == null) ? '' : req.productHint.trim();
        if (String.isBlank(productHint)) {
            return; // reason/method alone can't identify which items to pre-select
        }
        String validReason = validateReason(req.reasonCode);
        String validMethod = normalizeMethod(req.method);
        Boolean totality = isTotalityHint(productHint);
        Boolean anyMatched = false;

        for (ReturnBuilderSeed.RBOrder o : seed.orders) {
            if (o == null || o.id != resolvedId || o.items == null) {
                continue;
            }
            for (ReturnBuilderSeed.RBItem it : o.items) {
                if (totality || nameMatchesHint(it.name, productHint)) {
                    it.preSelected = true;
                    it.presetReasonCode = validReason;   // null-safe: blank when not confident
                    it.presetMethod = validMethod;       // null-safe
                    Integer cap = (it.quantityAvailableToReturn == null) ? null : it.quantityAvailableToReturn.intValue();
                    it.presetQuantity = resolveQuantity(req.quantityHint, cap); // null-safe
                    anyMatched = true;
                }
            }
        }

        // A specific (non-"everything") hint that matched nothing is worth
        // telling the planner about, so it can say so instead of silently
        // showing the order with nothing pre-selected.
        if (!totality && !anyMatched) {
            seed.productHintUnmatched = true;
        }
    }

    /**
     * True when the hint names no specific product but refers to the whole
     * order ("all items", "everything", "the entire order"). Bypasses
     * per-item name matching in applyPrefill and pre-selects every returnable
     * item on the resolved order instead.
     */
    private static Boolean isTotalityHint(String productHint) {
        String h = ' ' + productHint.trim().toLowerCase() + ' ';
        if (h.trim() == 'all') {
            return true;
        }
        return h.contains('everything')
            || h.contains('all items')
            || h.contains('all products')
            || h.contains('all of my items')
            || h.contains('entire order')
            || h.contains('whole order')
            || h.contains('entire purchase')
            || h.contains('whole purchase');
    }

    /**
     * Turns a free-text quantity hint into a concrete count, clamped to
     * [1, cap]. The LLM only classifies what the user said (handing back the
     * stated phrase/number); all arithmetic happens here, deterministically.
     * Unrecognised or blank input returns null, leaving the LWC's default of 1
     * untouched — this never guesses.
     */
    private static Integer resolveQuantity(String quantityHint, Integer cap) {
        if (String.isBlank(quantityHint) || cap == null || cap < 1) {
            return null;
        }
        String h = ' ' + quantityHint.trim().toLowerCase() + ' ';

        // Collective quantifiers: matched as substrings so filler words around
        // them ("of them", "of what I ordered", "of each") don't matter.
        if (h.contains('all but one') || h.contains('all except one') || h.contains('all minus one')) {
            return Math.max(1, cap - 1);
        }
        if (h.contains('all') || h.contains('everything') || h.contains('every one')) {
            // NOTE: deliberately NOT matching "both" here — "both" is normally
            // about which items ("return both of the batteries"), already
            // handled by productHint matching both line items, not a per-item
            // quantity of 2.
            return cap;
        }
        if (h.contains('half')) {
            return Math.max(1, cap / 2);
        }
        if (h.contains('couple')) {
            return Math.min(2, cap);
        }
        if (h.contains('few') || h.contains('several')) {
            return Math.min(3, cap);
        }

        // Otherwise pull the first explicit digit or number-word out of the
        // phrase regardless of what surrounds it ("two of each" -> 2,
        // "2 of them" -> 2, "just three" -> 3).
        Integer n = firstDigitRun(quantityHint);
        if (n == null) {
            n = firstWordNumber(quantityHint);
        }
        if (n != null && n >= 1) {
            return Math.min(n, cap);
        }
        return null;
    }

    /** First run of digits anywhere in the string, or null if there isn't one. */
    private static Integer firstDigitRun(String s) {
        Matcher m = Pattern.compile('\\d+').matcher(s);
        if (m.find()) {
            try {
                return Integer.valueOf(m.group());
            } catch (Exception e) {
                return null;
            }
        }
        return null;
    }

    /** First token that matches a small word-number vocabulary; deliberately
     * not a full NLP number parser. "a"/"single" only match here because the
     * input schema instructs the planner to pass quantityHint ONLY when a
     * quantity was actually stated, so a bare "a" reaching this point is
     * already a genuine quantity-of-one statement, not a stray article. */
    private static Integer firstWordNumber(String s) {
        Map<String, Integer> words = new Map<String, Integer>{
            'one' => 1, 'a' => 1, 'single' => 1,
            'two' => 2, 'three' => 3, 'four' => 4, 'five' => 5,
            'six' => 6, 'seven' => 7, 'eight' => 8, 'nine' => 9, 'ten' => 10
        };
        for (String token : s.toLowerCase().split('[^a-z]+')) {
            if (words.containsKey(token)) {
                return words.get(token);
            }
        }
        return null;
    }

    /**
     * True when the product name matches the hint, case-insensitive. Simple and
     * deliberately permissive: the hint is split into clauses on "and"/commas
     * (so "the shoes and shirts" can match two different items), and a name
     * matches a clause if it shares ANY significant word with it. This can
     * over-match a qualifier (e.g. "low capacity batteries" may also catch a
     * "High Capacity" item), but that tradeoff is intentional - natural phrasing
     * ("all of the X", "all the X") has filler words that broke a stricter
     * AND-every-token rule far more often than qualifier over-matching bit us.
     */
    private static Boolean nameMatchesHint(String name, String needle) {
        if (String.isBlank(name) || String.isBlank(needle)) {
            return false;
        }
        String n = name.toLowerCase();
        for (String clause : splitClauses(needle.toLowerCase())) {
            if (clauseMatches(n, clause)) {
                return true;
            }
        }
        return false;
    }

    /** Splits a hint like "the shoes and shirts" into ["the shoes", "shirts"]. */
    private static List<String> splitClauses(String needle) {
        List<String> clauses = new List<String>();
        for (String part : needle.split(',| and ')) {
            String trimmed = part.trim();
            if (String.isNotBlank(trimmed)) {
                clauses.add(trimmed);
            }
        }
        return clauses.isEmpty() ? new List<String>{ needle } : clauses;
    }

    /** True when ANY significant token of the clause matches the name. */
    private static Boolean clauseMatches(String name, String clause) {
        if (name.contains(clause)) {
            return true;
        }
        Set<String> clauseTokens = tokenize(clause);
        if (clauseTokens.isEmpty()) {
            return false;
        }
        Set<String> nameTokens = tokenize(name);
        for (String ct : clauseTokens) {
            if (name.contains(ct)) {
                return true;
            }
            for (String nt : nameTokens) {
                if (tokensRelated(ct, nt)) {
                    return true;
                }
            }
        }
        return false;
    }

    // Short connector/filler words that would otherwise false-positive match
    // product names containing them as a substring (e.g. "and" inside
    // "Sandals" or "Standard") when a multi-item hint like "the shoes and
    // shirts" is tokenized.
    private static final Set<String> STOPWORDS = new Set<String>{
        'the', 'and', 'for', 'with', 'from', 'that', 'this', 'they', 'you',
        'your', 'are', 'was', 'were', 'has', 'had', 'but', 'not'
    };

    /** Word tokens of length >= 3 (letters/digits only), minus stopwords. */
    private static Set<String> tokenize(String s) {
        Set<String> out = new Set<String>();
        for (String t : s.split('[^a-z0-9]+')) {
            if (t.length() >= 3 && !STOPWORDS.contains(t)) {
                out.add(t);
            }
        }
        return out;
    }

    /** Same word modulo a short plural/suffix difference (battery/batteries). */
    private static Boolean tokensRelated(String a, String b) {
        if (a == b) {
            return true;
        }
        if (a.length() >= 4 && b.length() >= 4 && (a.startsWith(b) || b.startsWith(a))) {
            return true;
        }
        return commonPrefixLen(a, b) >= 5;
    }

    private static Integer commonPrefixLen(String a, String b) {
        Integer max = Math.min(a.length(), b.length());
        Integer i = 0;
        while (i < max && a.substring(i, i + 1) == b.substring(i, i + 1)) {
            i++;
        }
        return i;
    }

    /** Returns the reason iff it exactly (case-insensitively) matches an active picklist value, else null. */
    private static String validateReason(String candidate) {
        if (String.isBlank(candidate)) {
            return null;
        }
        String c = candidate.trim().toLowerCase();
        for (String code : reasonCodes()) {
            if (code.toLowerCase() == c) {
                return code; // canonical casing from the picklist
            }
        }
        return null;
    }

    /** Normalises a stated preference to 'Return' | 'Replacement', or null. */
    private static String normalizeMethod(String candidate) {
        if (String.isBlank(candidate)) {
            return null;
        }
        String c = candidate.trim().toLowerCase();
        if (c == 'replacement' || c == 'replace' || c == 'exchange') {
            return METHOD_REPLACE;
        }
        if (c == 'return' || c == 'refund') {
            return METHOD_RETURN;
        }
        return null;
    }

    /** Active OrderItemSummaryChange.Reason picklist values (ReasonConfigService). */
    private static List<String> reasonCodes() {
        return ReasonConfigService.reasonCodes();
    }

    private static final String METHOD_RETURN = 'Return';      // refund path  -> Category 'Return'
    private static final String METHOD_REPLACE = 'Replacement'; // reship path  -> Category 'Exchange'

    /**
     * Active reason codes with per-reason resolution behaviour. The selectable
     * reasons come from the OrderItemSummaryChange.Reason picklist (so a new
     * picklist value shows up automatically); the behaviour (allow choice /
     * default method) is layered on from the OOTB **Order Change Reason Category
     * Mapping** object (`OrderChgReasonCategMap`), which maps a Reason to the
     * order-change Category it's valid for. We read two categories:
     *   - `Return`   -> a refund is offered for that reason
     *   - `Exchange` -> a replacement (reship) is offered for that reason
     * From there: both categories mapped => the customer may choose; only one =>
     * that method is forced (selector hidden); the default method is Replacement
     * only when Exchange is mapped without Return.
     *
     * **Graceful null handling:** a reason with NO mapping row for either
     * category falls back to "customer may choose, refund by default" — an
     * unmapped (Category, Reason) combination never errors or drops the reason.
     */
    private static List<ReturnBuilderSeed.RBReason> reasons() {
        return ReasonConfigService.reasons();
    }

    /** Resolves an order number to its OrderSummary Id, or null. */
    private static String resolveOrderSummaryId(String orderNumber) {
        if (String.isBlank(orderNumber)) {
            return null;
        }
        String wanted = orderNumber.trim();
        List<OrderSummary> found = [SELECT Id FROM OrderSummary WHERE OrderNumber = :wanted LIMIT 1];
        return found.isEmpty() ? null : found[0].Id;
    }

    /** Recent returnable orders, each with its returnable line items nested. */
    private static List<ReturnBuilderSeed.RBOrder> buildOrders() {
        // Returnable product-line count per order (aggregate).
        Map<Id, Integer> countByOrder = new Map<Id, Integer>();
        for (AggregateResult ar : [
            SELECT OrderSummaryId oid, COUNT(Id) c
            FROM OrderItemSummary
            WHERE QuantityAvailableToReturn > 0 AND TypeCode = 'Product'
            GROUP BY OrderSummaryId
        ]) {
            countByOrder.put((Id) ar.get('oid'), (Integer) ar.get('c'));
        }
        if (countByOrder.isEmpty()) {
            return new List<ReturnBuilderSeed.RBOrder>();
        }

        // Order headers, newest first.
        List<OrderSummary> summaries = [
            SELECT Id, OrderNumber, OrderedDate, Status, GrandTotalAmount, CurrencyIsoCode
            FROM OrderSummary
            WHERE Id IN :countByOrder.keySet()
            ORDER BY OrderedDate DESC
            LIMIT :MAX_ORDERS
        ];
        Set<Id> orderIds = new Map<Id, OrderSummary>(summaries).keySet();

        // All returnable line items for those orders in one query.
        Map<Id, List<ReturnBuilderSeed.RBItem>> itemsByOrder = new Map<Id, List<ReturnBuilderSeed.RBItem>>();
        Set<Id> productIds = new Set<Id>();
        for (OrderItemSummary ois : [
            SELECT Id, OrderSummaryId, Product2Id, ProductCode, Name,
                   UnitPrice, CurrencyIsoCode,
                   QuantityOrdered, QuantityReturned, QuantityAvailableToReturn
            FROM OrderItemSummary
            WHERE OrderSummaryId IN :orderIds
              AND QuantityAvailableToReturn > 0
              AND TypeCode = 'Product'
            ORDER BY Name
            LIMIT :(MAX_ORDERS * MAX_ITEMS_PER_ORDER)
        ]) {
            ReturnBuilderSeed.RBItem it = new ReturnBuilderSeed.RBItem();
            it.id = ois.Id;
            it.productId = ois.Product2Id;
            it.name = ois.Name;
            it.productCode = ois.ProductCode;
            it.unitPrice = ois.UnitPrice;
            it.currencyCode = ois.CurrencyIsoCode;
            it.quantityOrdered = ois.QuantityOrdered;
            it.quantityReturned = ois.QuantityReturned;
            it.quantityAvailableToReturn = ois.QuantityAvailableToReturn;
            if (!itemsByOrder.containsKey(ois.OrderSummaryId)) {
                itemsByOrder.put(ois.OrderSummaryId, new List<ReturnBuilderSeed.RBItem>());
            }
            itemsByOrder.get(ois.OrderSummaryId).add(it);
            if (ois.Product2Id != null) {
                productIds.add(ois.Product2Id);
            }
        }

        // Best-effort product images (never fails the build).
        Map<Id, String> imageByProduct = ReturnBuilderImageResolver.resolveImageUrls(productIds);

        List<ReturnBuilderSeed.RBOrder> out = new List<ReturnBuilderSeed.RBOrder>();
        for (OrderSummary os : summaries) {
            List<ReturnBuilderSeed.RBItem> items = itemsByOrder.get(os.Id);
            if (items == null || items.isEmpty()) {
                continue;
            }
            for (ReturnBuilderSeed.RBItem it : items) {
                if (it.productId != null && imageByProduct.containsKey(it.productId)) {
                    it.imageUrl = imageByProduct.get(it.productId);
                }
            }
            ReturnBuilderSeed.RBOrder o = new ReturnBuilderSeed.RBOrder();
            o.id = os.Id;
            o.orderNumber = os.OrderNumber;
            o.orderedDate = (os.OrderedDate == null)
                ? null
                : os.OrderedDate.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'');
            o.status = os.Status;
            o.grandTotal = os.GrandTotalAmount;
            o.currencyCode = os.CurrencyIsoCode;
            o.returnableItemCount = countByOrder.get(os.Id);
            o.items = items;
            out.add(o);
        }
        return out;
    }
}