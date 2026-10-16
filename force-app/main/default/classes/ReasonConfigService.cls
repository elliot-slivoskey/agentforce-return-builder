/**
 * @description Reason-code lookup for the Return Builder. Reasons come straight
 * from the OrderItemSummaryChange.Reason picklist, so a new picklist value shows
 * up automatically. The shopper always chooses Refund or Replacement per item.
 */
public without sharing class ReasonConfigService {

    /** Active OrderItemSummaryChange.Reason picklist values (via describe). */
    public static List<String> reasonCodes() {
        List<String> reasons = new List<String>();
        for (Schema.PicklistEntry pe : activeEntries()) {
            reasons.add(pe.getValue());
        }
        return reasons;
    }

    /** Active reason codes with their display labels. */
    public static List<ReturnBuilderSeed.RBReason> reasons() {
        List<ReturnBuilderSeed.RBReason> out = new List<ReturnBuilderSeed.RBReason>();
        for (Schema.PicklistEntry pe : activeEntries()) {
            ReturnBuilderSeed.RBReason r = new ReturnBuilderSeed.RBReason();
            r.code = pe.getValue();
            r.label = pe.getLabel();
            out.add(r);
        }
        return out;
    }

    private static List<Schema.PicklistEntry> activeEntries() {
        List<Schema.PicklistEntry> out = new List<Schema.PicklistEntry>();
        Schema.DescribeFieldResult dfr = Schema.SObjectType.OrderItemSummaryChange
            .fields.getMap().get('Reason').getDescribe();
        for (Schema.PicklistEntry pe : dfr.getPicklistValues()) {
            if (pe.isActive()) {
                out.add(pe);
            }
        }
        return out;
    }
}
