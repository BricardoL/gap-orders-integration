// This is the shared secret supplied for the exercise.
Orders_Configuration__c configuration = new Orders_Configuration__c(
    Configuration_Key__c='default',
    Shared_Secret__c='orders-takehome-2026',
    Subscription_Id__c='sub_a1b2c3d4e5f67890abcdef12'
);
upsert configuration Configuration_Key__c;
System.debug('Orders configuration saved. Secret intentionally omitted.');
