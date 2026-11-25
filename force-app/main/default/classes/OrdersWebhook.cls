@RestResource(urlMapping='/orders/events')
global with sharing class OrdersWebhook {
    private static final Integer MAX_BODY_BYTES = 16384;
    @HttpPost
    global static void receive() {
        RestRequest request = RestContext.request;
        if (request.requestBody == null || request.requestBody.size() > MAX_BODY_BYTES) {
            respond(400, 'invalidBody', 'A JSON event of at most 16 KB is required.');
            return;
        }
        Savepoint checkpoint;
        try {
            List<Orders_Configuration__c> configs = [SELECT Shared_Secret__c, Subscription_Id__c
                FROM Orders_Configuration__c WHERE Configuration_Key__c = 'default' LIMIT 1];
            if (configs.isEmpty() || String.isBlank(configs[0].Shared_Secret__c)
                || String.isBlank(configs[0].Subscription_Id__c)) {
                respond(503, 'configurationMissing', 'Integration configuration is unavailable.');
                return;
            }
            if (!OrdersSignature.isValid(request.requestBody,
                request.headers.get('Orders-Signature'), configs[0].Shared_Secret__c)) {
                respond(403, 'invalidSignature', 'Signature verification failed.');
                return;
            }
            OrdersEvent message;
            try {
                message = (OrdersEvent) JSON.deserialize(request.requestBody.toString(), OrdersEvent.class);
            } catch (Exception invalidJson) {
                respond(400, 'invalidEvent', 'Body must be a valid JSON event.');
                return;
            }
            if (message == null) {
                respond(400, 'invalidEvent', 'Event is required.');
                return;
            }
            message.validate(configs[0].Subscription_Id__c);
            checkpoint = Database.setSavepoint();
            String digest = EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', request.requestBody));
            OrdersEventService.Result result = OrdersEventService.process(message, digest);
            // A reused event ID with a different body is a conflict.
            if (result.outcome == 'eventIdConflict') {
                respond(409, result.outcome, 'Event ID was previously received with a different body.');
            } else {
                RestContext.response.statusCode = 200;
                RestContext.response.addHeader('Content-Type', 'application/json');
                RestContext.response.responseBody = Blob.valueOf(JSON.serialize(result));
            }
        } catch (OrdersEvent.InvalidEventException invalidEvent) {
            if (checkpoint != null) Database.rollback(checkpoint);
            respond(400, 'invalidEvent', invalidEvent.getMessage());
        } catch (DmlException failedWrite) {
            if (checkpoint != null) Database.rollback(checkpoint);
            Boolean retryable = String.valueOf(failedWrite.getDmlStatusCode(0)) == 'DUPLICATE_VALUE'
                || String.valueOf(failedWrite.getDmlStatusCode(0)) == 'UNABLE_TO_LOCK_ROW';
            respond(retryable ? 503 : 500, retryable ? 'retryableConflict' : 'processingFailed',
                'Event was not committed. Retry delivery; contact an administrator if persistent.');
        } catch (QueryException failedRead) {
            if (checkpoint != null) Database.rollback(checkpoint);
            System.debug(LoggingLevel.ERROR, 'Orders query failed: ' + failedRead.getMessage());
            respond(503, 'readUnavailable', 'Event was not committed. Check permissions or retry delivery.');
        } catch (Exception failure) {
            if (checkpoint != null) Database.rollback(checkpoint);
            respond(500, 'processingFailed', 'Event was not committed. Contact an administrator.');
        }
    }
    private static void respond(Integer code, String outcome, String detail) {
        RestContext.response.statusCode = code;
        RestContext.response.addHeader('Content-Type', 'application/json');
        RestContext.response.responseBody = Blob.valueOf(JSON.serialize(
            new Map<String,String>{'outcome'=>outcome, 'detail'=>detail}));
    }
}
