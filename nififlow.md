## What each piece does

**GetSQS** polls `https://sqs.us-east-1.amazonaws.com/123456789012/my-queue` in us-east-1, batch size 10, with `Auto Delete Messages = true`. Critically, it has **no outgoing connection** — its `success` relationship goes nowhere. The flow's own label admits this: it "runs independently" as a pseudo-trigger, and the actual copying happens via polling.

**ListS3** lists `my-source-bucket` every 60 seconds on the **primary node only** (correct for a stateful list processor). It tracks state so only keys added or modified since the last listing are emitted, and if the primary node changes, the new node picks up where the previous one left off without duplicating data. Each new key becomes a FlowFile with attributes like `s3.bucket` and `filename`.

**FetchS3Object** downloads the actual bytes using `Bucket = ${s3.bucket}` and `Object Key = ${filename}` — this is exactly the expression-language pairing the official docs recommend for the ListS3 → FetchS3Object pattern, so the attribute wiring is correct.

**PutFile** writes content to `/opt/nifi/nifi-current/s3-downloads`, creating missing directories and replacing files on name conflict. Its `success` relationship is auto-terminated (end of the line).

**AWSCredentialsProviderControllerService** is shared by all three AWS processors and uses the default credentials chain (env vars / instance profile).

## Verification against NiFi 2.10.0

NiFi 2.10.0 is the current latest release (June 2026), a feature-improvement and bug-fix release with over 160 issues resolved. Findings when holding this flow against it:

**Compatible.** All five component types — GetSQS, ListS3, FetchS3Object, PutFile, and the AWS credentials service — still exist in the current NiFi component set. The JSON pins bundle version `2.0.0`; on import into 2.10.0, NiFi will resolve components to the installed NAR version and run its property-migration logic automatically, so the version pin itself isn't a blocker.

**But the flow is invalid as exported.** Three processors will show validation errors the moment you import it, because NiFi requires every relationship to be either connected or auto-terminated:

1. **GetSQS `success`** is neither connected nor auto-terminated → processor won't start. Worse, with auto-delete on, once you "fix" it by auto-terminating, you're consuming and destroying SQS messages for zero effect — pure cost and data loss.
2. **FetchS3Object `failure`** is unhandled → invalid. A transient S3 error would have nowhere to go.
3. **PutFile `failure`** is unhandled → invalid. Disk-full or permission errors would strand FlowFiles.

There's also a **latent duplicate-fetch risk**: PutFile keys purely on `filename`, so two S3 keys `a/data.csv` and `b/data.csv` collide and silently overwrite each other under `Conflict Resolution = replace`.

Notably, the official FetchS3Object docs point out that the SQS-notification pattern (GetSQS → parse message → FetchS3Object) is more efficient and more cost-effective than ListS3 polling, and is the pattern recommended by AWS — this flow has the SQS half wired up but never uses it, which is the biggest design smell.

## Converting to AWS Step Functions

The good news: this flow maps very cleanly to AWS-native services, and the conversion fixes the design flaws for free. The event-driven variant that the NiFi label only hints at becomes the natural architecture:Here's how each NiFi concept translates:

| NiFi component / setting | AWS equivalent |
|---|---|
| GetSQS (polling, batch 10) | EventBridge Pipes (SQS source, batching built in) or Lambda SQS event-source mapping — no polling code to write |
| ListS3 + cluster state | Not needed. S3 event notifications make it event-driven; use an S3 Inventory or a one-time `ListObjectsV2` backfill job for existing objects |
| FetchS3Object | Step Functions SDK integration (`s3:getObject`/`copyObject`) or a small Lambda task |
| PutFile → local dir | Lambda with an **EFS mount** if you need a filesystem; a destination **S3 bucket** if consumers can read S3; **AWS DataSync** if "local" means on-prem storage |
| `retryCount: 10`, penalize, 10-min max backoff | Step Functions `Retry` blocks with `BackoffRate` and `MaxAttempts` per state |
| Unhandled `failure` relationships | `Catch` blocks routing to a DLQ or failure state — enforced by design rather than forgotten |
| Back pressure (10k objects / 1 GB) | SQS acts as the buffer; Lambda concurrency limits throttle downstream |
| AWSCredentialsProviderControllerService | IAM execution roles — no credential env vars on containers |
| `Conflict Resolution = replace` | Overwrite semantics at the destination; consider preserving the full S3 key path to avoid the filename-collision bug |

A few migration recommendations. Use an **Express workflow** rather than Standard — this is a short, high-volume, idempotent copy job, and Express is dramatically cheaper at per-object invocation rates. Keep the **full object key** (prefix included) as the destination path to eliminate the collision risk in the current flow. And decide early what "local" really means in the AWS world, because that choice (EFS vs. S3 vs. DataSync to on-prem) shapes the whole design — it's the only part of this flow without a one-line AWS equivalent.

If you'd like, I can draft the actual Amazon States Language (ASL) definition for the Express workflow, or a CDK/Terraform skeleton for the whole pipeline.
