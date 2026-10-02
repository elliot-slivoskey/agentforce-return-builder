/**
 * @description Fulfils Return Builder submissions off the guest's identity.
 *
 * WHY THIS EXISTS: the Return Builder LWC runs as the Enhanced Chat v2 site
 * guest, and ConnectApi.ReturnOrder.createReturnOrder is gated by the Lightning
 * Order Management User PSL, which the Guest User license can NEVER hold. A
 * platform-event subscriber, however, runs as the Automated Process user, which
 * is NOT bound by that PSL wall. So
 * the guest publishes RB_Return_Request__e and this subscriber creates the RMA
 * as Automated Process, then writes the outcome to RB_Return_Result__c for the
 * LWC to poll. No callout, connected app, or stored credentials required.
 */
trigger RB_ReturnRequestTrigger on RB_Return_Request__e (after insert) {
    for (RB_Return_Request__e evt : Trigger.new) {
        ReturnBuilderService.fulfill(evt.CorrelationId__c, evt.Payload__c);
    }
}
