// All five deliveries share one transaction because the handler is called directly.
Orders_Configuration__c configuration = [
    SELECT Shared_Secret__c FROM Orders_Configuration__c
    WHERE Configuration_Key__c = 'default' LIMIT 1
];

// The duplicate uses the same body so its signature and digest stay the same.
String prefix = '{"subscriptionId":"sub_a1b2c3d4e5f67890abcdef12","event":';
String firstOrder = ',"data":{"orderId":"ord_77d1e9","orderFriendlyId":"OR-261001-017-2231",'
    + '"accountId":"acct_8f3c2a","accountFriendlyId":"AC-260914-017-2231"}}';
String secondOrder = ',"data":{"orderId":"ord_52ab10","orderFriendlyId":"OR-260922-017-1187",'
    + '"accountId":"acct_8f3c2a","accountFriendlyId":"AC-260914-017-2231"}}';
String firstEvent = prefix
    + '{"id":"evt_001","type":"order.inProgress","occurredAt":"2026-10-10T10:00:00Z","version":"1.0"}'
    + firstOrder;
List<String> payloads = new List<String>{
    firstEvent,
    prefix + '{"id":"evt_002","type":"order.waitingForParticipant","occurredAt":"2026-10-11T10:00:00Z","version":"1.0"}' + firstOrder,
    firstEvent,
    prefix + '{"id":"evt_004","type":"order.sent","occurredAt":"2026-10-12T14:03:11Z","version":"1.0"}' + firstOrder,
    prefix + '{"id":"evt_003","type":"order.cleared","occurredAt":"2026-10-09T09:41:27Z","version":"1.0"}' + secondOrder
};

for (String payload : payloads) {
    Blob body = Blob.valueOf(payload);
    RestRequest request = new RestRequest();
    request.requestUri = '/services/apexrest/orders/events';
    request.httpMethod = 'POST';
    request.requestBody = body;
    request.addHeader('Content-Type', 'application/json');
    request.addHeader('Orders-Signature', EncodingUtil.convertToHex(
        Crypto.generateMac('HmacSHA256', body, Blob.valueOf(configuration.Shared_Secret__c))));
    RestContext.request = request;
    RestContext.response = new RestResponse();
    OrdersWebhook.receive();

    String responseBody = RestContext.response.responseBody.toString();
    Assert.areEqual(200, RestContext.response.statusCode, responseBody);
    Map<String, Object> result = (Map<String, Object>) JSON.deserializeUntyped(responseBody);
    Assert.isTrue(new Set<String>{'applied', 'duplicate'}.contains((String) result.get('outcome')),
        responseBody);
    System.debug(LoggingLevel.INFO, 'Orders demo: ' + responseBody);
}

Set<String> orderIds = new Set<String>{'ord_77d1e9', 'ord_52ab10'};
Map<String, String> statuses = new Map<String, String>();
for (External_Order__c order : [SELECT External_Id__c, Status__c FROM External_Order__c
    WHERE External_Id__c IN :orderIds]) {
    statuses.put(order.External_Id__c, order.Status__c);
}
Assert.areEqual('sent', statuses.get('ord_77d1e9'));
Assert.areEqual('cleared', statuses.get('ord_52ab10'));
Set<String> eventIds = new Set<String>{'evt_001', 'evt_002', 'evt_003', 'evt_004'};
Assert.areEqual(4, [SELECT COUNT() FROM Order_Event_Receipt__c WHERE Event_Id__c IN :eventIds]);
Assert.areEqual(1, [SELECT COUNT() FROM Account WHERE Orders_Account_Id__c = 'acct_8f3c2a']);
System.debug(LoggingLevel.INFO, 'Orders demo verified: one Account, two orders, four unique receipts.');
