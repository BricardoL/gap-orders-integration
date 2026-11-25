Orders_Configuration__c configuration = [
    SELECT Shared_Secret__c FROM Orders_Configuration__c
    WHERE Configuration_Key__c = 'default' LIMIT 1
];
String payload = '{"subscriptionId":"sub_a1b2c3d4e5f67890abcdef12",'
    + '"event":{"id":"evt_signature_check","type":"order.sent",'
    + '"occurredAt":"2026-10-12T14:03:11Z","version":"1.0"},'
    + '"data":{"orderId":"ord_77d1e9","orderFriendlyId":"OR-261001-017-2231",'
    + '"accountId":"acct_8f3c2a","accountFriendlyId":"AC-260914-017-2231"}}';
String signature = EncodingUtil.convertToHex(Crypto.generateMac(
    'HmacSHA256', Blob.valueOf(payload), Blob.valueOf(configuration.Shared_Secret__c)));
Integer receiptsBefore = [SELECT COUNT() FROM Order_Event_Receipt__c];
RestRequest request = new RestRequest();
request.requestUri = '/services/apexrest/orders/events';
request.httpMethod = 'POST';
// The extra space changes the signed bytes without changing the JSON data.
request.requestBody = Blob.valueOf(payload + ' ');
request.addHeader('Content-Type', 'application/json');
request.addHeader('Orders-Signature', signature);
RestContext.request = request;
RestContext.response = new RestResponse();
OrdersWebhook.receive();
String responseBody = RestContext.response.responseBody.toString();
Assert.areEqual(403, RestContext.response.statusCode, responseBody);
Assert.areEqual('invalidSignature',
    (String) ((Map<String, Object>) JSON.deserializeUntyped(responseBody)).get('outcome'));
Assert.areEqual(receiptsBefore, [SELECT COUNT() FROM Order_Event_Receipt__c]);
System.debug(LoggingLevel.INFO, 'Orders demo: 403 invalidSignature; receipt count unchanged.');
