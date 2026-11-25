@IsTest
private class OrdersWebhookTest {
    private static final String SECRET = 'orders-takehome-2026';
    @TestSetup
    static void setup() {
        PermissionSet integration = [SELECT Id FROM PermissionSet WHERE Name='Orders_Integration'];
        User principal = new User(Alias='ordertst', LastName='Orders Integration Test',
            Email='orders@example.invalid',
            Username=UserInfo.getOrganizationId() + '.' + Datetime.now().getTime() + '@orders.example.invalid',
            ProfileId=[SELECT Id FROM Profile WHERE Name='Minimum Access - Salesforce' LIMIT 1].Id,
            TimeZoneSidKey='America/El_Salvador', LocaleSidKey='en_US',
            EmailEncodingKey='UTF-8', LanguageLocaleKey='en_US');
        insert as system principal;
        insert as system new PermissionSetAssignment(AssigneeId=principal.Id, PermissionSetId=integration.Id);
        if ([SELECT COUNT() FROM PermissionSetAssignment
            WHERE AssigneeId=:UserInfo.getUserId() AND PermissionSetId=:integration.Id] == 0) {
            insert as system new PermissionSetAssignment(AssigneeId=UserInfo.getUserId(),
                PermissionSetId=integration.Id);
        }
        PermissionSet configurationAdmin=[SELECT Id FROM PermissionSet WHERE Name='Orders_Configuration_Admin'];
        if ([SELECT COUNT() FROM PermissionSetAssignment
            WHERE AssigneeId=:UserInfo.getUserId() AND PermissionSetId=:configurationAdmin.Id] == 0) {
            insert as system new PermissionSetAssignment(AssigneeId=UserInfo.getUserId(),
                PermissionSetId=configurationAdmin.Id);
        }
        System.runAs(new User(Id=UserInfo.getUserId())) {
            insert new Orders_Configuration__c(Configuration_Key__c='default',
                Shared_Secret__c=SECRET, Subscription_Id__c='sub_a1b2c3d4e5f67890abcdef12',
                OwnerId=principal.Id);
        }
    }
    private static String payload(String id, String status, String occurredAt, String orderId) {
        return JSON.serialize(new Map<String,Object>{
            'subscriptionId'=>'sub_a1b2c3d4e5f67890abcdef12',
            'event'=>new Map<String,Object>{'id'=>id,'type'=>'order.'+status,
                'occurredAt'=>occurredAt,'version'=>'1.0'},
            'data'=>new Map<String,Object>{'orderId'=>orderId,'orderFriendlyId'=>'OR-TEST',
                'accountId'=>'acct_8f3c2a','accountFriendlyId'=>'AC-TEST'}
        });
    }
    private static String deliver(String body, Boolean valid) {
        RestRequest req = new RestRequest();
        req.requestUri='/services/apexrest/orders/events';
        req.httpMethod='POST';
        req.requestBody=Blob.valueOf(body);
        req.addHeader('Orders-Signature', EncodingUtil.convertToHex(
            Crypto.generateMac('HmacSHA256', req.requestBody, Blob.valueOf(valid ? SECRET : 'wrong'))));
        RestContext.request=req;
        RestContext.response=new RestResponse();
        OrdersWebhook.receive();
        Assert.areNotEqual('readUnavailable', (String)((Map<String,Object>)JSON.deserializeUntyped(
            RestContext.response.responseBody.toString())).get('outcome'), RestContext.response.responseBody.toString());
        return (String)((Map<String,Object>)JSON.deserializeUntyped(
            RestContext.response.responseBody.toString())).get('outcome');
    }
    @IsTest static void sampleSequenceAndReplay() {
        String first=payload('evt_001','inProgress','2026-10-10T10:00:00Z','ord_77d1e9');
        Assert.areEqual('applied',deliver(first,true));
        Assert.areEqual('applied',deliver(payload('evt_002','waitingForParticipant','2026-10-11T10:00:00Z','ord_77d1e9'),true));
        Assert.areEqual('duplicate',deliver(first,true));
        Assert.areEqual('applied',deliver(payload('evt_004','sent','2026-10-12T14:03:11Z','ord_77d1e9'),true));
        Assert.areEqual('applied',deliver(payload('evt_003','cleared','2026-10-09T09:41:27Z','ord_52ab10'),true));
        Assert.areEqual(200,RestContext.response.statusCode);
        Assert.areEqual(4,[SELECT COUNT() FROM Order_Event_Receipt__c]);
        Assert.areEqual(1,[SELECT COUNT() FROM Account]);
        Map<String,String> statuses=new Map<String,String>();
        for(External_Order__c order : [SELECT External_Id__c,Status__c FROM External_Order__c]) {
            statuses.put(order.External_Id__c,order.Status__c);
        }
        Assert.areEqual('sent',statuses.get('ord_77d1e9'));
        Assert.areEqual('cleared',statuses.get('ord_52ab10'));
        Assert.areEqual('duplicate',deliver(first,true));
        Assert.areEqual(4,[SELECT COUNT() FROM Order_Event_Receipt__c]);
    }
    @IsTest static void orderingAndReturned() {
        deliver(payload('new','sent','2026-10-12T10:00:00Z','ord_1'),true);
        Assert.areEqual('stale',deliver(payload('old','inProgress','2026-10-10T10:00:00Z','ord_1'),true));
        Assert.areEqual('conflict',deliver(payload('equal','cleared','2026-10-12T10:00:00Z','ord_1'),true));
        Assert.areEqual('conflict',deliver(payload('regress','inProgress','2026-10-13T10:00:00Z','ord_1'),true));
        Assert.areEqual('applied',deliver(payload('returned','returned','2026-10-14T10:00:00Z','ord_1'),true));
        Assert.areEqual('returned',[SELECT Status__c FROM External_Order__c LIMIT 1].Status__c);
        Assert.areEqual('applied',deliver(payload('initial','returned','2026-10-14T10:00:00Z','ord_2'),true));
    }
    @IsTest static void invalidRequestsDoNotWrite() {
        Assert.areEqual('invalidSignature',deliver(payload('bad','sent','2026-10-12T10:00:00Z','ord_1'),false));
        Assert.areEqual(403,RestContext.response.statusCode);
        Assert.areEqual('invalidEvent',deliver('{broken',true));
        Assert.areEqual(400,RestContext.response.statusCode);
        Assert.areEqual('invalidEvent',deliver('null',true));
        Assert.areEqual('invalidEvent',deliver(payload('bad','unknown','2026-10-12T10:00:00Z','ord_1'),true));
        Assert.areEqual('invalidEvent',deliver(payload('date','sent','not-a-date','ord_1'),true));
        Assert.areEqual(0,[SELECT COUNT() FROM Order_Event_Receipt__c]);
        Assert.areEqual(0,[SELECT COUNT() FROM External_Order__c]);
        Assert.isFalse(OrdersSignature.isValid(Blob.valueOf('a'),'bad',SECRET));
        Assert.isFalse(OrdersSignature.isValid(null,null,SECRET));
    }
    @IsTest static void reusedIdAndAccountConflict() {
        String original=payload('same','sent','2026-10-12T10:00:00Z','ord_1');
        deliver(original,true);
        Assert.areEqual('eventIdConflict',deliver(payload('same','cleared','2026-10-13T10:00:00Z','ord_1'),true));
        Assert.areEqual(409,RestContext.response.statusCode);
        Assert.areEqual(1,[SELECT COUNT() FROM Order_Event_Receipt__c]);
        String moved=payload('move','cleared','2026-10-13T10:00:00Z','ord_1').replace('acct_8f3c2a','acct_other');
        Assert.areEqual('conflict',deliver(moved,true));
        Assert.areEqual('sent',[SELECT Status__c FROM External_Order__c LIMIT 1].Status__c);
        Assert.areEqual(1,[SELECT COUNT() FROM Account], 'Conflict must not create an unrelated Account.');
    }
    @IsTest static void missingConfigurationAndBody() {
        delete [SELECT Id FROM Orders_Configuration__c];
        Assert.areEqual('configurationMissing',deliver('{}',true));
        Assert.areEqual(503,RestContext.response.statusCode);
        RestContext.request=new RestRequest();
        RestContext.response=new RestResponse();
        OrdersWebhook.receive();
        Assert.areEqual(400,RestContext.response.statusCode);
    }
    @IsTest static void minimumAccessPrincipalCanProcess() {
        User principal=[SELECT Id FROM User WHERE Alias='ordertst' LIMIT 1];
        System.runAs(principal) {
            Assert.areEqual('applied',deliver(payload('leastPrivilege','sent','2026-10-12T10:00:00Z','ord_min'),true));
            Assert.areEqual(200,RestContext.response.statusCode);
            Assert.areEqual(1,[SELECT COUNT() FROM External_Order__c]);
            Assert.areEqual('duplicate',deliver(payload('leastPrivilege','sent','2026-10-12T10:00:00Z','ord_min'),true));
        }
    }
}
