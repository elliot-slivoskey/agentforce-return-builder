/**
 * @description Tests for the Return Builder classes.
 *
 * OMS objects (OrderSummary / OrderItemSummary) can't be inserted directly in a
 * unit-test context, so the server-side builder is exercised for execution
 * safety while the deterministic branches (submit guards, image-resolver guard,
 * seed defaults, reason-code lookup) are asserted concretely.
 */
@IsTest
private class ReturnBuilderServiceTest {

    @IsTest
    static void submitReturn_guardsOnEmptyInput() {
        Test.startTest();
        ReturnBuilderService.SubmitResult res = ReturnBuilderService.submitReturnFromForm(
            JSON.serialize(new ReturnBuilderService.ReturnRequest()));
        Test.stopTest();

        System.assertEquals(false, res.success, 'Empty request must not succeed');
        System.assertNotEquals(null, res.message, 'A message should explain the failure');
    }

    @IsTest
    static void submitReturn_guardsOnNullData() {
        ReturnBuilderService.SubmitResult res = ReturnBuilderService.submitReturnFromForm(null);
        System.assertEquals(false, res.success, 'Null return data must not succeed');
    }

    @IsTest
    static void submitReturn_guardsOnGarbageJson() {
        ReturnBuilderService.SubmitResult res = ReturnBuilderService.submitReturnFromForm('not-json');
        System.assertEquals(false, res.success, 'Unparseable JSON must not succeed');
    }

    @IsTest
    static void submitReturn_parsesJsonPayload() {
        // A well-formed payload with no lines should still be guarded, proving
        // the JSON round-trips into a ReturnRequest (the proxy-safe path).
        String payload = JSON.serialize(new Map<String, Object>{
            'orderSummaryId' => '1Os000000000001AAA',
            'orderNumber' => 'ORD-TEST',
            'lines' => new List<Object>()
        });
        ReturnBuilderService.SubmitResult res = ReturnBuilderService.submitReturnFromForm(payload);
        System.assertEquals(false, res.success, 'Empty lines must not succeed');
    }

    @IsTest
    static void submitReturn_validPayloadPublishesAndFulfils() {
        // A well-formed payload should be accepted as PENDING (the guest can't
        // create the RMA synchronously) and publish a request event. On
        // stopTest the subscriber fires; createReturnOrder is unsupported in
        // test context, so fulfill captures the failure into a result row —
        // which proves the whole publish -> trigger -> fulfill -> result-row
        // pipeline runs end to end.
        String payload = JSON.serialize(new Map<String, Object>{
            'orderSummaryId' => '1Os000000000001AAA',
            'orderNumber' => 'ORD-TEST',
            'lines' => new List<Object>{
                new Map<String, Object>{
                    'orderItemSummaryId' => '10u000000000001AAA',
                    'productName' => 'Test Item',
                    'quantity' => 1,
                    'reasonCode' => 'Changed Mind',
                    'method' => 'Return'
                }
            }
        });

        Test.startTest();
        ReturnBuilderService.SubmitResult res = ReturnBuilderService.submitReturnFromForm(payload);
        Test.stopTest(); // delivers the platform event -> RB_ReturnRequestTrigger

        System.assertEquals(true, res.pending, 'Valid submit is accepted as pending');
        System.assertNotEquals(null, res.correlationId, 'A correlationId is returned to poll on');

        List<RB_Return_Result__c> rows = [
            SELECT CorrelationId__c, Success__c, Message__c
            FROM RB_Return_Result__c
            WHERE CorrelationId__c = :res.correlationId
        ];
        System.assertEquals(1, rows.size(), 'Subscriber wrote exactly one result row');
        System.assertNotEquals(null, rows[0].Message__c, 'Result row carries a message');
    }

    @IsTest
    static void pollReturnResult_guardsOnBlank() {
        ReturnBuilderService.SubmitResult res = ReturnBuilderService.pollReturnResult('   ');
        System.assertEquals(false, res.success, 'Blank correlationId cannot succeed');
        System.assertNotEquals(null, res.message, 'A message explains the blank reference');
    }

    @IsTest
    static void pollReturnResult_unknownIsPending() {
        ReturnBuilderService.SubmitResult res = ReturnBuilderService.pollReturnResult('deadbeefdeadbeefdeadbeefdeadbeef');
        System.assertEquals(true, res.pending, 'Unknown correlationId is still pending');
    }

    @IsTest
    static void pollReturnResult_returnsWrittenRow() {
        String cid = 'abc123abc123abc123abc123abc12300';
        insert new RB_Return_Result__c(
            CorrelationId__c = cid,
            Success__c = true,
            ReturnOrderNumber__c = 'RO-9999',
            Message__c = 'Return order RO-9999 created with 1 item(s).'
        );

        ReturnBuilderService.SubmitResult res = ReturnBuilderService.pollReturnResult(cid);
        System.assertEquals(false, res.pending, 'A written result is no longer pending');
        System.assertEquals(true, res.success, 'Success reflects the stored row');
        System.assertEquals('RO-9999', res.returnOrderNumber, 'RMA number reflects the stored row');
    }

    @IsTest
    static void pollReturnResult_sanitizesCorrelationId() {
        // A correlationId is stripped to [A-Za-z0-9] before being inlined into
        // the query, so injection characters can't break out of the WHERE clause
        // and leak another row. A tampered id must NOT resolve the stored row and
        // must NOT throw.
        insert new RB_Return_Result__c(
            CorrelationId__c = 'cafebabe00000000cafebabe00000000',
            Success__c = true,
            ReturnOrderNumber__c = 'RO-1234',
            Message__c = 'ok'
        );

        ReturnBuilderService.SubmitResult injected =
            ReturnBuilderService.pollReturnResult('\' OR Id != null --');
        System.assertEquals(true, injected.pending,
            'An injection attempt is neutralized to a non-matching id (no row leaked)');
        System.assertEquals(null, injected.returnOrderNumber,
            'Injection must not surface any RMA number');
    }

    @IsTest
    static void fulfill_capturesFailureIntoResultRow() {
        String cid = 'feedface00000000feedface00000000';
        Test.startTest();
        ReturnBuilderService.fulfill(cid, 'not-json'); // deserialize throws -> captured
        Test.stopTest();

        List<RB_Return_Result__c> rows = [
            SELECT Success__c, Message__c FROM RB_Return_Result__c WHERE CorrelationId__c = :cid
        ];
        System.assertEquals(1, rows.size(), 'A failure still writes a result row to unblock the poller');
        System.assertEquals(false, rows[0].Success__c, 'Bad payload yields an unsuccessful result');
    }

    // NOTE: guest read of a subscriber-owned result row comes from the Apex
    // managed share created in ReturnBuilderService.shareWithSiteGuests (Read
    // for every GuestUserGroup). Not asserted here: test orgs may have no site
    // guest group.

    @IsTest
    static void seedClass_defaults() {
        // The output CLT backing class must construct cleanly both ways.
        ReturnBuilderSeed empty = new ReturnBuilderSeed();
        System.assertEquals('', empty.orderNumber, 'No-arg seed defaults to empty');
        System.assertNotEquals(null, empty.reasonCodes, 'reasonCodes initialised');
        System.assertNotEquals(null, empty.reasons, 'reasons initialised');
        System.assertNotEquals(null, empty.orders, 'orders initialised');

        ReturnBuilderSeed seeded = new ReturnBuilderSeed('ORD-1');
        System.assertEquals('ORD-1', seeded.orderNumber, 'Seed carries the order number');
    }

    @IsTest
    static void imageResolver_guardsOnEmptySet() {
        Map<Id, String> byEmpty = ReturnBuilderImageResolver.resolveImageUrls(new Set<Id>());
        System.assertEquals(0, byEmpty.size(), 'Empty input yields empty map');

        Map<Id, String> byNull = ReturnBuilderImageResolver.resolveImageUrls(null);
        System.assertEquals(0, byNull.size(), 'Null input yields empty map');
    }

    @IsTest
    static void action_buildRunsSafely() {
        // No OMS data in test context; assert the server-side builder executes,
        // returns a well-formed seed, and never throws (errors are captured on
        // the seed's errorMessage instead of bubbling up).
        ReturnBuilderAction.Request req = new ReturnBuilderAction.Request();
        req.orderNumber = 'DOES-NOT-EXIST';

        Test.startTest();
        List<ReturnBuilderAction.Response> withReq =
            ReturnBuilderAction.build(new List<ReturnBuilderAction.Request>{ req });
        List<ReturnBuilderAction.Response> emptyReq =
            ReturnBuilderAction.build(new List<ReturnBuilderAction.Request>());
        Test.stopTest();

        System.assertEquals(1, withReq.size(), 'One response per request');
        ReturnBuilderSeed seed = withReq[0].seed;
        System.assertNotEquals(null, seed, 'Seed must be returned');
        System.assertEquals('DOES-NOT-EXIST', seed.orderNumber, 'Order number echoed onto seed');
        System.assertNotEquals(null, seed.orders, 'Orders list should not be null');
        System.assertNotEquals(null, seed.reasonCodes, 'Reason list should not be null');
        System.assertNotEquals(null, seed.reasons, 'Rich reasons list should not be null');
        System.assert(!seed.reasons.isEmpty(), 'Reasons should be populated from the picklist');
        // Every reason must carry a usable resolution default.
        for (ReturnBuilderSeed.RBReason r : seed.reasons) {
            System.assertNotEquals(null, r.code, 'Reason code set');
            System.assertNotEquals(null, r.allowChoice, 'allowChoice set');
            System.assert(
                r.defaultMethod == 'Return' || r.defaultMethod == 'Replacement',
                'defaultMethod must be Return or Replacement, got: ' + r.defaultMethod);
        }
        System.assertEquals(null, seed.resolvedOrderSummaryId, 'Unknown order resolves to null');

        System.assertEquals(1, emptyReq.size(), 'Empty request list yields one default seed');
        System.assertNotEquals(null, emptyReq[0].seed, 'Default seed returned for empty input');
    }
}
