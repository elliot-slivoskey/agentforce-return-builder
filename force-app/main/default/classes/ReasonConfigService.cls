/**
 * @description Reason-code + resolution-behaviour lookup for the Return
 * Builder. See ReturnBuilderAction.reasons() for the design notes (Return/Exchange category rows drive choice vs.
 * forced refund/replacement; unmapped reasons fail gently to "customer may
 * choose, refund by default").
 */
public without sharing class ReasonConfigService {

    public static final String METHOD_RETURN = 'Return';       // refund path  -> Category 'Return'
    public static final String METHOD_REPLACE = 'Replacement'; // reship path  -> Category 'Exchange'

    /** Active OrderItemSummaryChange.Reason picklist values (via describe). */
    public static List<String> reasonCodes() {
        List<String> reasons = new List<String>();
        Schema.DescribeFieldResult dfr = Schema.SObjectType.OrderItemSummaryChange
            .fields.getMap().get('Reason').getDescribe();
        for (Schema.PicklistEntry pe : dfr.getPicklistValues()) {
            if (pe.isActive()) {
                reasons.add(pe.getValue());
            }
        }
        return reasons;
    }

    /** Active reason codes with per-reason resolution behaviour (see class doc). */
    public static List<ReturnBuilderSeed.RBReason> reasons() {
        Map<String, Boolean> returnByReason = new Map<String, Boolean>();
        Map<String, Boolean> exchangeByReason = new Map<String, Boolean>();
        try {
            for (OrderChgReasonCategMap m : [
                SELECT Reason, Category
                FROM OrderChgReasonCategMap
                WHERE IsActive = true AND Category IN ('Return', 'Exchange')
            ]) {
                if (m.Category == 'Return') {
                    returnByReason.put(m.Reason, true);
                } else if (m.Category == 'Exchange') {
                    exchangeByReason.put(m.Reason, true);
                }
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'OrderChgReasonCategMap read failed: ' + e.getMessage());
        }

        List<ReturnBuilderSeed.RBReason> out = new List<ReturnBuilderSeed.RBReason>();
        Schema.DescribeFieldResult dfr = Schema.SObjectType.OrderItemSummaryChange
            .fields.getMap().get('Reason').getDescribe();
        for (Schema.PicklistEntry pe : dfr.getPicklistValues()) {
            if (!pe.isActive()) {
                continue;
            }
            ReturnBuilderSeed.RBReason r = new ReturnBuilderSeed.RBReason();
            r.code = pe.getValue();
            r.label = pe.getLabel();

            Boolean hasReturn = returnByReason.containsKey(pe.getValue());
            Boolean hasExchange = exchangeByReason.containsKey(pe.getValue());
            if (!hasReturn && !hasExchange) {
                r.allowChoice = true;
                r.defaultMethod = METHOD_RETURN;
            } else {
                r.allowChoice = hasReturn && hasExchange;
                r.defaultMethod = (hasExchange && !hasReturn) ? METHOD_REPLACE : METHOD_RETURN;
            }
            out.add(r);
        }
        return out;
    }
}
