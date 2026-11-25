public with sharing class OrdersEventService {
    public class Result {
        public String outcome;
        public String eventId;
        public Result(String outcome, String eventId) {
            this.outcome = outcome;
            this.eventId = eventId;
        }
    }
    private static final Map<String, Integer> RANK = new Map<String, Integer>{
        'created'=>0, 'inProgress'=>1, 'waitingForParticipant'=>2,
        'sent'=>3, 'cleared'=>4, 'returned'=>5
    };
    public static Result process(OrdersEvent message, String digest) {
        List<Order_Event_Receipt__c> existing = [
            SELECT Id, Body_Digest__c FROM Order_Event_Receipt__c
            WHERE Event_Id__c = :message.event.id LIMIT 1
        ];
        if (!existing.isEmpty()) {
            return new Result(existing[0].Body_Digest__c == digest ? 'duplicate' : 'eventIdConflict', message.event.id);
        }
        // The unique receipt prevents two requests from processing the same event.
        Order_Event_Receipt__c receipt = new Order_Event_Receipt__c(
            Event_Id__c=message.event.id, Order_Id__c=message.data.orderId,
            Event_Type__c=message.event.type, Occurred_At__c=message.timestamp(),
            Body_Digest__c=digest
        );
        insert receipt;
        List<Account> accounts = [SELECT Id FROM Account
            WHERE Orders_Account_Id__c = :message.data.accountId LIMIT 1 FOR UPDATE];
        List<External_Order__c> orders = [SELECT Id, Account__c, Status__c,
            Last_Event_At__c, Last_Event_Id__c FROM External_Order__c
            WHERE External_Id__c = :message.data.orderId LIMIT 1 FOR UPDATE];
        String outcome = 'applied';
        External_Order__c order;
        if (orders.isEmpty()) {
            Account account;
            if (accounts.isEmpty()) {
                account = new Account(Name='Orders Account ' + message.data.accountFriendlyId,
                    Orders_Account_Id__c=message.data.accountId,
                    Orders_Friendly_Id__c=message.data.accountFriendlyId);
                insert account;
            } else {
                account = accounts[0];
            }
            order = new External_Order__c(External_Id__c=message.data.orderId,
                Friendly_Id__c=message.data.orderFriendlyId, Account__c=account.Id);
        } else {
            order = orders[0];
            if (accounts.isEmpty() || order.Account__c != accounts[0].Id) {
                outcome = 'conflict';
                receipt.Detail__c = 'Order account reassignment is not allowed.';
            } else if (message.timestamp() < order.Last_Event_At__c) {
                outcome = 'stale';
            } else if (message.timestamp() == order.Last_Event_At__c) {
                outcome = message.status() == order.Status__c ? 'unchanged' : 'conflict';
                receipt.Detail__c = 'Equal event timestamps; current state preserved.';
            } else if (RANK.get(message.status()) < RANK.get(order.Status__c)) {
                outcome = 'conflict';
                receipt.Detail__c = 'Status regression; current state preserved.';
            } else if (message.status() == 'returned'
                && order.Status__c != 'sent' && order.Status__c != 'cleared'
                && order.Status__c != 'returned') {
                // An intermediate status may be missing, so the later returned event is accepted.
                receipt.Detail__c = 'Intermediate sent/cleared event not observed.';
            }
        }
        if (outcome == 'applied') {
            order.Status__c = message.status();
            order.Last_Event_At__c = message.timestamp();
            order.Last_Event_Id__c = message.event.id;
            upsert order;
        }
        receipt.Outcome__c = outcome;
        update receipt;
        return new Result(outcome, message.event.id);
    }
}
