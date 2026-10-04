using System.Text.Json;
using Amazon.Runtime;
using Amazon.SQS;
using Amazon.SQS.Model;

var builder = Host.CreateApplicationBuilder(args);

builder.Services.AddSingleton<IAmazonSQS>(_ => new AmazonSQSClient(
    new BasicAWSCredentials("test", "test"),
    new AmazonSQSConfig
    {
        ServiceURL = builder.Configuration["Aws:ServiceUrl"] ?? "http://localhost:4566",
        AuthenticationRegion = "us-east-1"
    }));

builder.Services.AddSingleton<PaymentStore>();
builder.Services.AddHostedService<PaymentWorker>();
builder.Build().Run();

class PaymentWorker(IAmazonSQS sqs, PaymentStore store, ILogger<PaymentWorker> log) : BackgroundService
{
    private const string QueueName = "payments-queue";

    protected override async Task ExecuteAsync(CancellationToken ct)
    {
        string queueUrl = "";
        while (!ct.IsCancellationRequested && queueUrl == "")
        {
            try { queueUrl = (await sqs.GetQueueUrlAsync(QueueName, ct)).QueueUrl; }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                log.LogWarning("Queue not available yet ({Msg}). Retrying in 5s.", ex.Message);
                await Task.Delay(TimeSpan.FromSeconds(5), ct);
            }
        }

        log.LogInformation("Polling {Queue}", queueUrl);

        while (!ct.IsCancellationRequested)
        {
            try
            {
                var response = await sqs.ReceiveMessageAsync(new ReceiveMessageRequest
                {
                    QueueUrl = queueUrl,
                    MaxNumberOfMessages = 10,
                    WaitTimeSeconds = 10,
                    MessageSystemAttributeNames = ["ApproximateReceiveCount"]
                }, ct);

                foreach (var msg in response.Messages ?? [])
                {
                    var attempt = msg.Attributes.GetValueOrDefault("ApproximateReceiveCount", "?");
                    try
                    {
                        // true  = finished (success or known duplicate) -> safe to delete
                        // false = someone else is working on it         -> leave it, SQS redelivers later
                        if (await HandleAsync(msg.Body, attempt))
                            await sqs.DeleteMessageAsync(queueUrl, msg.ReceiptHandle, ct);
                    }
                    catch (Exception ex) when (ex is not OperationCanceledException)
                    {
                        log.LogError("Failed (attempt {Attempt}): {Msg}", attempt, ex.Message);
                    }
                }
            }
            catch (OperationCanceledException) { break; }
            catch (Exception ex)
            {
                log.LogError(ex, "Receive failed. Backing off 5s.");
                await Task.Delay(TimeSpan.FromSeconds(5), ct);
            }
        }
    }

    private async Task<bool> HandleAsync(string body, string attempt)
    {
        var p = JsonSerializer.Deserialize<PaymentMessage>(body)
                ?? throw new InvalidOperationException("Unreadable message");

        switch (await store.ClaimAsync(p))
        {
            case ClaimResult.AlreadyCompleted:
                log.LogInformation("Duplicate {Key} skipped (already completed)", p.IdempotencyKey);
                return true;
            case ClaimResult.InProgressElsewhere:
                log.LogInformation("{Key} is being processed by another worker; leaving message", p.IdempotencyKey);
                return false;
        }

        try
        {
            // Test hook: payee "FAIL" simulates a downstream error so you can watch the DLQ work.
            if (p.PayeeId == "FAIL") throw new InvalidOperationException("Simulated processor failure");

            log.LogInformation("Processed payment {Id}: {Amount} {Cur} to {Payee} (attempt {Attempt})",
                p.PaymentId, p.Amount, p.Currency, p.PayeeId, attempt);

            await store.CompleteAsync(p.IdempotencyKey);
            return true;
        }
        catch (Exception ex)
        {
            await store.FailAsync(p.IdempotencyKey, ex.Message);
            throw; // not deleted -> SQS retries, then DLQ after maxReceiveCount
        }
    }
}

record PaymentMessage(
    Guid PaymentId,
    string IdempotencyKey,
    string PayeeId,
    decimal Amount,
    string Currency,
    DateTimeOffset CreatedUtc);
