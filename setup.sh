#!/usr/bin/env bash
#
# setup.sh - one-shot setup for the payment-pipeline practice lab (macOS).
#
# What it does:
#   1. Installs the tools (Homebrew packages, VS Code + extensions, Docker Desktop if missing)
#   2. Writes the Docker Compose stack and config files
#   3. Starts LocalStack, MySQL, SQL Server, Prometheus, Grafana and Jaeger
#   4. Creates the SQS queues (with a dead-letter queue) and the MySQL table
#   5. Creates the .NET solution (Api + Worker projects) and builds it
#
# Usage:
#   chmod +x setup.sh
#   ./setup.sh                  # sets up in the folder that contains this script
#   ./setup.sh ~/some/folder    # sets up in a different folder
#   SKIP_TOOLS=1 ./setup.sh     # skip installing tools (you already have them)
#   FORCE=1 ./setup.sh          # overwrite config/source files this script manages
#
# Safe to re-run: files and projects that already exist are kept unless FORCE=1.
# LocalStack needs a free auth token (see README). Pass it as LOCALSTACK_AUTH_TOKEN,
# put it in .env, or paste it when asked.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${1:-$SCRIPT_DIR}"
FORCE="${FORCE:-0}"
SKIP_TOOLS="${SKIP_TOOLS:-0}"

# ---------------------------------------------------------------- helpers
if [[ -t 1 ]]; then
  B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; N=$'\033[0m'
else
  B=""; G=""; Y=""; R=""; N=""
fi
step() { printf '\n%s==> %s%s\n' "$B" "$*" "$N"; }
ok()   { printf '  %s[ok]%s %s\n' "$G" "$N" "$*"; }
warn() { printf '  %s[!!]%s %s\n' "$Y" "$N" "$*"; }
die()  { printf '  %s[error] %s%s\n' "$R" "$*" "$N" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# wait_for <description> <timeout-seconds> <command...>
wait_for() {
  local desc="$1" timeout="$2" waited=0
  shift 2
  printf '  waiting for %s ' "$desc"
  until "$@" >/dev/null 2>&1; do
    waited=$((waited + 2))
    if [[ $waited -ge $timeout ]]; then printf '\n'; return 1; fi
    printf '.'
    sleep 2
  done
  printf ' ready\n'
}

# _write <path> <overwrite 0|1>   (content comes from stdin)
_write() {
  local path="$1" overwrite="$2"
  if [[ -e "$path" && "$overwrite" != "1" ]]; then
    warn "kept existing ${path#"$PROJECT_DIR"/}"
    cat >/dev/null
    return 0
  fi
  mkdir -p "$(dirname "$path")"
  cat >"$path"
  ok "wrote ${path#"$PROJECT_DIR"/}"
}
write_file() { _write "$1" "$FORCE"; }  # skip if it exists (unless FORCE=1)
put_file()   { _write "$1" 1; }         # always overwrite

# ---------------------------------------------------------------- 0. sanity checks
step "Checking your machine"
[[ "$(uname -s)" == "Darwin" ]] || die "This script is for macOS."
ARCH="$(uname -m)"
ok "macOS on $ARCH"
if [[ "$ARCH" == "arm64" ]]; then
  warn "Apple Silicon: SQL Server runs under emulation. In Docker Desktop > Settings > General, enable 'Use Rosetta for x86/amd64 emulation'."
fi
ok "Project folder: $PROJECT_DIR"
mkdir -p "$PROJECT_DIR"

# ---------------------------------------------------------------- 1. tools
if [[ "$SKIP_TOOLS" != "1" ]]; then
  step "Installing tools (Homebrew)"
  if ! have brew; then
    for p in /opt/homebrew/bin/brew /usr/local/bin/brew; do
      if [[ -x "$p" ]]; then eval "$("$p" shellenv)"; break; fi
    done
  fi
  have brew || die 'Homebrew is not installed. Install it first, then re-run:
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
  ok "Homebrew found"

  brew_formula() {
    if brew list --formula "$1" >/dev/null 2>&1; then ok "$1 already installed"
    else warn "installing $1"; brew install "$1"; fi
  }

  if have dotnet; then ok "dotnet $(dotnet --version) already installed"
  else warn "installing .NET SDK"; brew install --cask dotnet-sdk; hash -r; fi

  have git || brew_formula git
  have gh  || brew_formula gh
  have aws || brew_formula awscli
  have k6  || brew_formula k6
  if have terraform; then ok "terraform already installed"
  else warn "installing terraform"; brew tap hashicorp/tap; brew install hashicorp/tap/terraform; fi

  if [[ -d "/Applications/Visual Studio Code.app" ]] || have code; then ok "VS Code already installed"
  else warn "installing VS Code"; brew install --cask visual-studio-code; fi

  if [[ -d "/Applications/DBeaver.app" ]]; then ok "DBeaver already installed"
  else warn "installing DBeaver Community"; brew install --cask dbeaver-community; fi

  CODE_BIN=""
  if have code; then CODE_BIN="code"
  elif [[ -x "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code" ]]; then
    CODE_BIN="/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
  fi
  if [[ -n "$CODE_BIN" ]]; then
    step "Installing VS Code extensions"
    for ext in ms-dotnettools.csdevkit ms-dotnettools.csharp ms-azuretools.vscode-docker \
               ms-mssql.mssql hashicorp.terraform amazonwebservices.aws-toolkit-vscode humao.rest-client; do
      "$CODE_BIN" --install-extension "$ext" --force >/dev/null 2>&1 && ok "$ext" || warn "could not install $ext"
    done
  else
    warn "VS Code command line not found; skipping extensions"
  fi

  if ! have docker; then
    warn "installing Docker Desktop"
    brew install --cask docker
    open -a Docker || true
    die "Docker Desktop installed. Open it, finish the first-run prompts, wait until it says the engine is running, then run ./setup.sh again."
  fi
else
  step "Skipping tool installation (SKIP_TOOLS=1)"
fi

have dotnet || die "dotnet not found. Install the .NET SDK (brew install --cask dotnet-sdk) or open a new terminal."
have docker || die "docker not found. Install Docker Desktop first."
have aws    || die "aws CLI not found (brew install awscli)."
have curl   || die "curl not found."

step "Checking Docker"
if ! docker info >/dev/null 2>&1; then
  warn "Docker is not running; starting Docker Desktop"
  open -a Docker || true
  wait_for "Docker engine" 180 docker info || die "Docker did not start. Open Docker Desktop manually and re-run."
fi
docker compose version >/dev/null 2>&1 || die "'docker compose' is missing. Update Docker Desktop."
ok "Docker is running"

# ---------------------------------------------------------------- 2. project files
step "Writing stack files"
cd "$PROJECT_DIR"

write_file "$PROJECT_DIR/docker-compose.yml" <<'__COMPOSE__'
name: payment-pipeline

services:
  localstack:
    image: localstack/localstack:latest
    ports:
      - "4566:4566"
    environment:
      - SERVICES=sqs,sns,events,lambda,stepfunctions,logs,cloudwatch,s3,iam,sts
      - DEBUG=0
      - LOCALSTACK_AUTH_TOKEN=${LOCALSTACK_AUTH_TOKEN}
    volumes:
      - localstack-data:/var/lib/localstack
      - /var/run/docker.sock:/var/run/docker.sock

  mysql:
    image: mysql:8.4
    ports:
      - "3306:3306"
    environment:
      MYSQL_ROOT_PASSWORD: RootPass123!
      MYSQL_DATABASE: payments
    volumes:
      - mysql-data:/var/lib/mysql

  sqlserver:
    image: mcr.microsoft.com/mssql/server:2022-latest
    platform: linux/amd64   # needed on Apple Silicon (runs under emulation); harmless on Intel
    ports:
      - "1433:1433"
    environment:
      ACCEPT_EULA: "Y"
      MSSQL_SA_PASSWORD: "YourStrong!Passw0rd"
      MSSQL_MEMORY_LIMIT_MB: "2048"
    volumes:
      - sqlserver-data:/var/opt/mssql

  prometheus:
    image: prom/prometheus:latest
    ports:
      - "9090:9090"
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml:ro

  grafana:
    image: grafana/grafana:latest
    ports:
      - "3000:3000"
    environment:
      GF_SECURITY_ADMIN_USER: admin
      GF_SECURITY_ADMIN_PASSWORD: admin
    volumes:
      - grafana-data:/var/lib/grafana
    depends_on:
      - prometheus

  jaeger:
    image: jaegertracing/all-in-one:latest
    ports:
      - "16686:16686"   # UI
      - "4317:4317"     # OTLP gRPC
      - "4318:4318"     # OTLP HTTP
    environment:
      COLLECTOR_OTLP_ENABLED: "true"

volumes:
  localstack-data:
  mysql-data:
  sqlserver-data:
  grafana-data:
__COMPOSE__

write_file "$PROJECT_DIR/prometheus.yml" <<'__PROM__'
global:
  scrape_interval: 5s

scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: ["localhost:9090"]

  # The apps do not expose /metrics yet; these show as DOWN until the observability step.
  - job_name: payment-api
    metrics_path: /metrics
    static_configs:
      - targets: ["host.docker.internal:5080"]

  - job_name: payment-worker
    metrics_path: /metrics
    static_configs:
      - targets: ["host.docker.internal:5081"]
__PROM__

write_file "$PROJECT_DIR/.gitignore" <<'__GITIGNORE__'
.env
bin/
obj/
.vs/
.idea/
*.user
__GITIGNORE__

write_file "$PROJECT_DIR/infra/schema.sql" <<'__SCHEMA__'
CREATE TABLE IF NOT EXISTS payments (
  payment_id       CHAR(36)      NOT NULL,
  idempotency_key  VARCHAR(100)  NOT NULL,
  payee_id         VARCHAR(50)   NOT NULL,
  amount           DECIMAL(18,2) NOT NULL,
  currency         CHAR(3)       NOT NULL,
  status           ENUM('PROCESSING','COMPLETED','FAILED') NOT NULL DEFAULT 'PROCESSING',
  attempts         INT           NOT NULL DEFAULT 1,
  last_error       VARCHAR(500)  NULL,
  created_utc      DATETIME(3)   NOT NULL,
  updated_utc      DATETIME(3)   NOT NULL,
  PRIMARY KEY (payment_id),
  -- The unique key is the real duplicate-prevention mechanism:
  -- the database arbitrates between concurrent workers.
  UNIQUE KEY uq_payments_idempotency (idempotency_key),
  KEY ix_payments_status_updated (status, updated_utc)
) ENGINE=InnoDB;
__SCHEMA__

write_file "$PROJECT_DIR/infra/setup-queues.sh" <<'__QUEUES__'
#!/usr/bin/env bash
# Creates payments-queue + payments-dlq in LocalStack.
# Failed messages are retried 3 times (10s apart), then moved to the DLQ.
# Safe to re-run.
set -euo pipefail

export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
EP="--endpoint-url=http://localhost:4566"

DLQ_URL=$(aws $EP sqs create-queue --queue-name payments-dlq --query QueueUrl --output text)
MAIN_URL=$(aws $EP sqs create-queue --queue-name payments-queue --query QueueUrl --output text)

DLQ_ARN=$(aws $EP sqs get-queue-attributes --queue-url "$DLQ_URL" \
  --attribute-names QueueArn --query Attributes.QueueArn --output text)

cat > /tmp/payments-queue-attrs.json <<EOF
{
  "QueueUrl": "$MAIN_URL",
  "Attributes": {
    "VisibilityTimeout": "10",
    "RedrivePolicy": "{\"deadLetterTargetArn\":\"$DLQ_ARN\",\"maxReceiveCount\":\"3\"}"
  }
}
EOF

aws $EP sqs set-queue-attributes --cli-input-json file:///tmp/payments-queue-attrs.json

echo "payments-queue: $MAIN_URL"
echo "payments-dlq:   $DLQ_URL ($DLQ_ARN)"
__QUEUES__
chmod +x "$PROJECT_DIR/infra/setup-queues.sh"

# ---------------------------------------------------------------- 3. LocalStack token
step "LocalStack auth token"
ENV_FILE="$PROJECT_DIR/.env"
TOKEN="${LOCALSTACK_AUTH_TOKEN:-}"
if [[ -z "$TOKEN" && -f "$ENV_FILE" ]]; then
  TOKEN="$(grep -E '^LOCALSTACK_AUTH_TOKEN=' "$ENV_FILE" | head -1 | cut -d= -f2- || true)"
fi
if [[ -z "$TOKEN" ]]; then
  echo "  LocalStack needs a free auth token (Hobby plan, non-commercial use)."
  echo "  Create an account at https://app.localstack.cloud and copy the token from the Auth Tokens page."
  if [[ -t 0 ]]; then
    read -r -s -p "  Paste token (input is hidden): " TOKEN
    echo
  fi
fi
[[ -n "$TOKEN" ]] || die "No LocalStack token. Set LOCALSTACK_AUTH_TOKEN or add it to .env, then re-run."
if [[ ! -f "$ENV_FILE" ]] || ! grep -q '^LOCALSTACK_AUTH_TOKEN=' "$ENV_FILE"; then
  printf 'LOCALSTACK_AUTH_TOKEN=%s\n' "$TOKEN" >>"$ENV_FILE"
  chmod 600 "$ENV_FILE"
  ok "saved token to .env (git-ignored)"
else
  ok "token already in .env"
fi

# ---------------------------------------------------------------- 4. start the stack
step "Starting containers (first run downloads several GB; be patient)"
docker compose up -d
ok "containers started"

step "Waiting for services"
if ! wait_for "LocalStack" 180 curl -sf http://localhost:4566/_localstack/health; then
  docker compose logs --tail 25 localstack || true
  die "LocalStack did not come up. If the log mentions a license or token (exit code 55), check the token in .env."
fi

step "Creating SQS queues and DLQ"
bash "$PROJECT_DIR/infra/setup-queues.sh" >/dev/null
ok "payments-queue and payments-dlq ready (3 tries, then dead-letter)"

step "Creating MySQL table"
apply_schema() {
  docker compose exec -T mysql mysql -uroot -pRootPass123! payments <"$PROJECT_DIR/infra/schema.sql"
}
wait_for "MySQL + schema" 180 apply_schema || die "Could not apply infra/schema.sql. Check: docker compose logs mysql"
ok "table 'payments' ready"

# ---------------------------------------------------------------- 5. .NET projects
step "Creating .NET projects"

create_project() {   # create_project <name> <template>; returns 1 if it already exists
  local name="$1" tmpl="$2"
  if [[ -f "src/$name/$name.csproj" ]]; then
    warn "src/$name already exists, keeping it"
    return 1
  fi
  dotnet new "$tmpl" -n "$name" -o "src/$name" >/dev/null
  ok "created src/$name ($tmpl template)"
}

NEW_API=0; NEW_WORKER=0
if create_project Api web;      then NEW_API=1; fi
if create_project Worker worker; then NEW_WORKER=1; rm -f src/Worker/Worker.cs; fi

step "Adding NuGet packages"
dotnet add src/Api package AWSSDK.SQS >/dev/null
dotnet add src/Worker package AWSSDK.SQS >/dev/null
dotnet add src/Worker package MySqlConnector >/dev/null
dotnet add src/Worker package Dapper >/dev/null
ok "AWSSDK.SQS, MySqlConnector, Dapper"

if compgen -G "*.sln" >/dev/null || compgen -G "*.slnx" >/dev/null; then :; else
  dotnet new sln -n PaymentPipeline >/dev/null
fi
dotnet sln add src/Api/Api.csproj src/Worker/Worker.csproj >/dev/null 2>&1 || true

if [[ "$NEW_API" == "1" || "$FORCE" == "1" ]]; then
put_file "$PROJECT_DIR/src/Api/Program.cs" <<'__API__'
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
__API__
fi

if [[ "$NEW_WORKER" == "1" || "$FORCE" == "1" ]]; then
put_file "$PROJECT_DIR/src/Worker/Program.cs" <<'__WORKER__'
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
__WORKER__

put_file "$PROJECT_DIR/src/Worker/PaymentStore.cs" <<'__STORE__'
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
__STORE__
fi

step "Building (this proves the code compiles)"
dotnet build src/Api -nologo -v q || die "Api failed to build. Scroll up for the compiler error."
dotnet build src/Worker -nologo -v q || die "Worker failed to build. Scroll up for the compiler error."
ok "Api and Worker build cleanly"

# ---------------------------------------------------------------- done
step "All done"
cat <<DONE

  Services
    LocalStack (AWS)   http://localhost:4566
    MySQL              localhost:3306   root / RootPass123!   db: payments
    SQL Server         localhost:1433   sa   / YourStrong!Passw0rd
    Prometheus         http://localhost:9090
    Grafana            http://localhost:3000   admin / admin
    Jaeger             http://localhost:16686

  Run the app (two terminals, from $PROJECT_DIR):
    dotnet run --project src/Worker
    dotnet run --project src/Api --urls http://localhost:5080

  Send a test payment (third terminal):
    curl -X POST http://localhost:5080/payments -H "Content-Type: application/json" \\
      -d '{"payeeId":"P-100","amount":250.00,"idempotencyKey":"demo-1"}'

  Stop everything:   docker compose down
  Read the README.md for what each piece does and more tests to try.
DONE
