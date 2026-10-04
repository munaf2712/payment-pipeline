using System.Text.Json;
using Amazon.Runtime;
using Amazon.SQS;
using Amazon.SQS.Model;

var builder = WebApplication.CreateBuilder(args);

// Points the AWS SDK at LocalStack. For real AWS, drop ServiceURL and the dummy credentials.
builder.Services.AddSingleton<IAmazonSQS>(_ => new AmazonSQSClient(
    new BasicAWSCredentials("test", "test"),
    new AmazonSQSConfig
    {
        ServiceURL = builder.Configuration["Aws:ServiceUrl"] ?? "http://localhost:4566",
        AuthenticationRegion = "us-east-1"
    }));

var app = builder.Build();

const string QueueName = "payments-queue";
string? queueUrl = null;

app.MapGet("/health", () => Results.Ok(new { status = "ok" }));

app.MapPost("/payments", async (PaymentRequest req, IAmazonSQS sqs) =>
{
    if (req.Amount <= 0)
        return Results.BadRequest(new { error = "Amount must be positive" });

    queueUrl ??= (await sqs.GetQueueUrlAsync(QueueName)).QueueUrl;

    var message = new PaymentMessage(
        PaymentId: Guid.NewGuid(),
        IdempotencyKey: req.IdempotencyKey ?? Guid.NewGuid().ToString(),
        PayeeId: req.PayeeId,
        Amount: req.Amount,
        Currency: req.Currency ?? "USD",
        CreatedUtc: DateTimeOffset.UtcNow);

    await sqs.SendMessageAsync(new SendMessageRequest
    {
        QueueUrl = queueUrl,
        MessageBody = JsonSerializer.Serialize(message)
    });

    return Results.Accepted($"/payments/{message.PaymentId}",
        new { message.PaymentId, status = "Queued" });
});

app.Run();

record PaymentRequest(string PayeeId, decimal Amount, string? Currency, string? IdempotencyKey);

record PaymentMessage(
    Guid PaymentId,
    string IdempotencyKey,
    string PayeeId,
    decimal Amount,
    string Currency,
    DateTimeOffset CreatedUtc);
