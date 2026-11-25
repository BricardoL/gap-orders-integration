public with sharing class OrdersEvent {
    public String subscriptionId;
    public EventInfo event;
    public EventData data;
    public class EventInfo {
        public String id;
        public String type;
        public String occurredAt;
        public String version;
    }
    public class EventData {
        public String orderId;
        public String orderFriendlyId;
        public String accountId;
        public String accountFriendlyId;
    }
    public class InvalidEventException extends Exception {}
    public Datetime timestamp() {
        try {
            return (Datetime) JSON.deserialize(JSON.serialize(event.occurredAt), Datetime.class);
        } catch (Exception ex) {
            throw new InvalidEventException('occurredAt must be an ISO-8601 datetime.');
        }
    }
    public String status() {
        return event.type.substring(6);
    }
    public void validate(String subscription) {
        if (event == null || data == null || String.isBlank(subscriptionId)
            || subscriptionId != subscription || event.version != '1.0') {
            throw new InvalidEventException('Unsupported subscription, version, or envelope.');
        }
        for (String value : new List<String>{event.id, data.orderId, data.accountId,
            data.orderFriendlyId, data.accountFriendlyId}) {
            if (String.isBlank(value) || value.length() > 100) {
                throw new InvalidEventException('Identifiers must contain 1 to 100 characters.');
            }
        }
        if (!new Set<String>{'order.inProgress','order.waitingForParticipant',
            'order.sent','order.cleared','order.returned'}.contains(event.type)) {
            throw new InvalidEventException('Unsupported event type.');
        }
        if (String.isBlank(event.occurredAt) || timestamp() == null) {
            throw new InvalidEventException('occurredAt is required.');
        }
    }
}
