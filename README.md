# Orders status integration

An Apex REST integration that keeps order statuses in Salesforce. Orders remains the source of truth; Salesforce stores the identifiers and status needed to show orders on an Account.

I chose authenticated Apex REST, synchronous processing, and a standard related list to keep the exercise focused on signature verification, duplicate delivery, and event ordering. Account names, amounts, participants, and order lines are outside this version.

## Setup

Requirements: a personal Salesforce Developer Edition org supporting API 68.0, Salesforce CLI, and administrator access. The demo uses anonymous Apex; no additional runtime or package installation is needed.

Run from the repository root:

```sh
sf org login web --alias gap-dev --set-default
sf project deploy start --source-dir force-app --target-org gap-dev --wait 10
sf org assign permset --name Orders_Integration --target-org gap-dev
sf org assign permset --name Orders_Configuration_Admin --target-org gap-dev
sf apex run --file scripts/apex/configure-orders.apex --target-org gap-dev
sf apex run test --class-names OrdersWebhookTest --target-org gap-dev --result-format human --code-coverage --wait 10
```

Deploy first, then assign permissions and run tests. The code targets API 68.0 and uses `with sharing` and the version's default user-mode database operations.

The configuration script uses the published exercise secret `orders-takehome-2026` and subscription `sub_a1b2c3d4e5f67890abcdef12`. No outbound callouts are made, so no Named Credential, Remote Site Setting, or hosted mock service is needed.

| Permission set | Access |
| --- | --- |
| `Orders_Integration` | Endpoint, API, Account/order/receipt processing, and read access to configuration. Includes View Encrypted Data for HMAC verification. |
| `Orders_Configuration_Admin` | Create and update configuration; assign to the setup administrator. |
| `Orders_CX_Read` | Read Accounts, External Orders, and their integration fields. |

Configuration and receipts use private sharing. Use one stable integration user with ownership or sharing access to the configuration and integration records. If using a separate user, transfer configuration ownership to it. The demo uses the existing CLI-authorized administrator; production should use a dedicated OAuth integration user.

The secret is stored in an encrypted custom field. `View Encrypted Data` is a broad permission, so access to that principal must be restricted. Its runtime permission set cannot edit configuration. For a real secret, use an administrator-controlled configuration process rather than the fixture script, which can appear in Apex debug logs.

**Layout change:** deployment assigns the `Orders Account` layout to the System Administrator profile through a minimal `Admin` profile update. For another profile, assign that layout under **Setup > Object Manager > Account > Page Layouts > Page Layout Assignment**, and grant `Orders_CX_Read`.

## Run the demo

```sh
sf apex run --file scripts/apex/simulate-events.apex --target-org gap-dev
```

The anonymous Apex script signs the supplied sample bodies with HMAC-SHA256, sets `RestContext.request` and `RestContext.response`, and calls the deployed `OrdersWebhook.receive()` handler. It reads the configured secret without printing it and asserts the final order statuses and unique receipt count.

This exercises signature verification and processing directly. It does not make HTTP requests or test OAuth authentication and REST routing. External callers would use:

```text
POST https://<your-org-domain>/services/apexrest/orders/events
Authorization: Bearer <Salesforce OAuth access token>
Content-Type: application/json
Orders-Signature: <hex HMAC-SHA256>
```

On the first run, expect `applied`, `applied`, `duplicate`, `applied`, `applied` in the execution log. Running again returns five `duplicate` outcomes. All five simulated deliveries share one anonymous Apex transaction; an assertion failure rolls back that run. Real HTTP deliveries each have their own transaction.

To verify rejection of a body changed after signing, run this separate script:

```sh
sf apex run --file scripts/apex/simulate-invalid-signature.apex --target-org gap-dev
```

Expect `403 invalidSignature` and an unchanged receipt count. The request includes an extra space added after signing, demonstrating that verification uses the original body bytes.

Inspect the records:

```sh
sf data query --target-org gap-dev --file scripts/soql/accounts.soql
sf data query --target-org gap-dev --file scripts/soql/orders.soql
sf data query --target-org gap-dev --file scripts/soql/receipts.soql
sf org open --target-org gap-dev
```

The sample creates one Account, two orders, and four unique receipts:

| Order | Final status |
| --- | --- |
| `ord_77d1e9` | `sent` |
| `ord_52ab10` | `cleared` |

In **App Launcher > Orders Integration > Accounts**, open `Orders Account AC-260914-017-2231` and select **Related**. The External Orders list shows the friendly ID, status, and last applied event time. Administrators can inspect receipts and the **Conflicts** list view in the Event Receipts tab.

## Design decisions

| Component | Responsibility |
| --- | --- |
| `OrdersWebhook` | Request checks, configuration, signature, validation, rollback, and HTTP response. |
| `OrdersSignature` | Platform HMAC verification against the original request Blob. |
| `OrdersEvent` | Typed event contract and validation. |
| `OrdersEventService` | Duplicate detection, record locking, ordering, and persistence. |

### What Salesforce stores

- **Account:** unique external ID, friendly ID, and a placeholder name. Matching by external ID avoids unreliable name matching.
- **External Order:** unique external ID, friendly ID, Account lookup, status, and last applied event timestamp/ID. A custom object avoids introducing the standard Order activation and commercial lifecycle.
- **Event Receipt:** unique event ID, order ID, type, timestamp, body SHA256, outcome, and short diagnostic detail. This supports durable duplicate detection and inspection without storing complete payloads.
- **Configuration:** allowed subscription and encrypted shared secret.

Nothing is read live from Orders. Placeholder account names are explicit; the integration does not claim to know the real name. The Account lookup restricts deletion while related integration orders exist.

### Duplicate delivery, ordering, and transactions

The service inserts a receipt to reserve the unique event ID, then processes the Account and order in the same transaction. A caught processing failure rolls back to a savepoint before returning an error. Database uniqueness constraints protect concurrent first deliveries; an initial existence query alone would not.

An existing event ID with the same body digest is a duplicate. The same ID with different bytes returns `409`, preserving the original receipt and order. This assumes byte-identical redelivery, including JSON formatting.

Ordering is per order using `occurredAt`:

- Timestamps must include a full time and an explicit timezone, such as `2026-10-12T14:00:00Z` or `2026-10-12T08:00:00-06:00`. Optional fractional seconds support up to three digits. Date-only values and timestamps without a timezone are rejected.
- Older event: record `stale` and preserve the order.
- Equal timestamp: record `unchanged` for the same status or `conflict` for a different status.
- Newer event: accept forward movement or the same status; record regressions as conflicts.
- `returned` is terminal. It can be the first observed state, and missing intermediate events do not prevent accepting it.
- Account reassignment is a conflict; the order stays on its original Account.

Existing Account and Order rows are locked in that order with `FOR UPDATE`. Status comparisons use the refreshed record after locking. A creation race or lock failure returns a retryable error. Salesforce can wait up to ten seconds for locks, which overlaps the sender's timeout; a retry can therefore arrive after the original transaction committed. Durable receipts make that safe.

The endpoint accepts one event per POST, as specified. Processing uses a bounded number of queries/writes with no database operations in collection loops. No asynchronous job or callout is needed for this small transaction.

### Responses

| HTTP | Meaning |
| --- | --- |
| 200 | Applied, duplicate, stale, unchanged, or a durably recorded business conflict. |
| 400 | Invalid/missing body, unsupported subscription/version/type, or invalid fields. Body limit: 16 KB. |
| 403 | Missing, malformed, or incorrect signature. |
| 409 | Event ID reused with different body bytes. |
| 503 | Missing configuration, read/permission failure, row lock, or concurrent uniqueness collision. |
| 500 | Other processing failure; processing changes rolled back. |

Business conflicts receive 200 because replaying the same contradictory event will not resolve them; their receipts require administrator review. Missing configuration or permissions require repair. Non-2xx responses can exhaust the sender's three retries and suspend the subscription. Salesforce OAuth failures occur before the handler.

## Questions I would have asked

| Question | Assumption and reason |
| --- | --- |
| Does "all order data" include amounts, lines, participants, and real account names? | Deliver identifiers and current status first. Defer enrichment to prioritize reliable processing within four hours; show placeholder names explicitly. |
| How should external Accounts match existing Salesforce Accounts? | Match only by unique external ID. Create a placeholder otherwise to avoid linking unrelated entities. |
| Is occurredAt authoritative, and is there an order sequence number? | Use occurredAt per order; record equal-time conflicts because no total-order sequence is supplied. |
| Can notifications skip intermediate statuses or start at a terminal state? | Yes. Accept forward jumps and initial cleared/returned because not every transition may be observed. |
| Can an order move Accounts? | No; record a conflict rather than silently moving it. |
| Are IDs globally unique and case-sensitive? | Yes; use unique case-sensitive external IDs, consistent with the event uniqueness contract. |
| Are redeliveries byte-identical? | Yes. Raw-body digests detect ID reuse; otherwise an agreed semantic digest/canonicalization would be needed. |
| Which subscriptions are allowed? | One configured subscription, matched exactly including case, so a valid signature alone does not authorize another subscription. |
| Is historical backfill required? | No initial backfill. Event-only ingestion cannot discover orders that never emit another event. |
| Who handles failed deliveries and suspended subscriptions? | An operator for this version, using sender/Salesforce logs and receipt inspection before resubmission. |
| How long should receipts remain? | Keep them for the exercise. Production retention must cover the replay window; deleting receipts weakens replay protection. |
| How should secret rotation work? | One active key for this version; production needs key identification and a rotation overlap policy. |
| Should old events be rejected by age? | No arbitrary cutoff because delayed delivery is allowed and no separate delivery timestamp exists. |
| Public or authenticated endpoint? | Authenticated Apex REST, as permitted, to avoid public Site configuration in the exercise. |

## Testing and scope

Apex tests cover the sample and replay, stale events, equivalent timezone offsets, timestamp conflicts, regressions, returned states, malformed input, unsupported subscriptions/versions, signature failures, oversized bodies, event-ID reuse, Account reassignment, and a Minimum Access integration user. HMAC verification is also checked against the independent [RFC 4231 test case 2](https://www.rfc-editor.org/rfc/rfc4231.txt).

A restricted-user test allows Account and receipt creation but denies order creation. It verifies that the failed request leaves no Account, order, or receipt, and that the same event can then succeed with the proper permissions. Tests use isolated data. Sequential tests do not prove simultaneous-request behavior, so concurrency testing remains follow-up work.

Deliberately left out:

- Historical backfill and periodic reconciliation for completeness and missed-event recovery.
- Account/order enrichment. If added, use mocked callouts, Named/External Credentials, durable retries, the 60 requests/minute budget, and `429 Retry-After`. Fetch outside locked transactions.
- An asynchronous inbox/worker, automated alerts, dead-letter handling, and recovery UI.
- Receipt archival/retention, production load/security testing, multiple subscriptions, and secret rotation.
- Custom UI; the standard Account related list meets the demonstration requirement.

AI assisted implementation and review.
