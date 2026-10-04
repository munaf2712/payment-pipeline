using Dapper;
using MySqlConnector;

enum ClaimResult { Claimed, AlreadyCompleted, InProgressElsewhere }

class PaymentStore(IConfiguration config)
{
    // Local lab credentials from docker-compose.yml. Override with ConnectionStrings__Payments.
    private readonly string _cs = config.GetConnectionString("Payments")
        ?? "Server=localhost;Port=3306;Database=payments;User ID=root;Password=RootPass123!;";

    private const int LeaseSeconds = 60;

    /// <summary>
    /// Decides whether this worker may process the payment.
    /// 1) First time seen: INSERT wins (unique key makes this safe across workers).
    /// 2) Previously FAILED, or PROCESSING with an expired lease (crashed worker): take it over.
    /// 3) Otherwise it is either done or being handled by someone else.
    /// </summary>
    public async Task<ClaimResult> ClaimAsync(PaymentMessage p)
    {
        await using var db = new MySqlConnection(_cs);

        var inserted = await db.ExecuteAsync(@"
            INSERT IGNORE INTO payments
              (payment_id, idempotency_key, payee_id, amount, currency, status, attempts, created_utc, updated_utc)
            VALUES
              (@Id, @Key, @Payee, @Amount, @Currency, 'PROCESSING', 1, UTC_TIMESTAMP(3), UTC_TIMESTAMP(3))",
            new { Id = p.PaymentId.ToString(), Key = p.IdempotencyKey, Payee = p.PayeeId, p.Amount, p.Currency });

        if (inserted == 1) return ClaimResult.Claimed;

        var reclaimed = await db.ExecuteAsync($@"
            UPDATE payments
               SET status = 'PROCESSING', attempts = attempts + 1, updated_utc = UTC_TIMESTAMP(3)
             WHERE idempotency_key = @Key
               AND (status = 'FAILED'
                    OR (status = 'PROCESSING' AND updated_utc < UTC_TIMESTAMP(3) - INTERVAL {LeaseSeconds} SECOND))",
            new { Key = p.IdempotencyKey });

        if (reclaimed == 1) return ClaimResult.Claimed;

        var status = await db.ExecuteScalarAsync<string>(
            "SELECT status FROM payments WHERE idempotency_key = @Key", new { Key = p.IdempotencyKey });

        return status == "COMPLETED" ? ClaimResult.AlreadyCompleted : ClaimResult.InProgressElsewhere;
    }

    public async Task CompleteAsync(string key)
    {
        await using var db = new MySqlConnection(_cs);
        await db.ExecuteAsync(
            "UPDATE payments SET status='COMPLETED', last_error=NULL, updated_utc=UTC_TIMESTAMP(3) WHERE idempotency_key=@key",
            new { key });
    }

    public async Task FailAsync(string key, string error)
    {
        await using var db = new MySqlConnection(_cs);
        await db.ExecuteAsync(
            "UPDATE payments SET status='FAILED', last_error=@err, updated_utc=UTC_TIMESTAMP(3) WHERE idempotency_key=@key",
            new { key, err = error.Length > 500 ? error[..500] : error });
    }
}
