# Payment Pipeline Lab: a plain-English guide

A small, free, practice "payment system" that runs entirely on your Mac. No real money, no real bank, no cloud bill.

It exists to practice the skills in the Jack Henry / Payrailz posting: C#/.NET backend services, AWS-style queues and events, databases, retries, duplicate prevention, and monitoring.

---

## 1. What does it actually do?

You send a payment request. The system does **not** process it immediately. It puts the request in a waiting line, and a background program picks it up, checks it is not a duplicate, "processes" it, and records the result in a database. If processing keeps failing, the request is moved to a "needs a human" pile instead of being lost.

That pattern (accept fast, process in the background, never lose or double-process anything) is how real bill-pay and ACH platforms work.

### The post office analogy

| In the lab | Think of it as |
|---|---|
| **API** | The counter clerk. Takes your envelope, says "got it", and does not wait around. |
| **Queue (SQS)** | The tray of envelopes waiting to be handled. |
| **Worker** | The back-office employee who takes envelopes from the tray, one at a time. |
| **Database (MySQL)** | The ledger book. Records what was paid, and notes "already done" so nothing is paid twice. |
| **Dead-letter queue (DLQ)** | The "problem envelopes" tray. After 3 failed attempts, an envelope goes here for a human to inspect. |

### The flow

```
  You (curl / browser)
          |
          | 1. "Pay 99.50 to P-200"
          v
     +---------+   2. put a note in the line   +-----------------+
     |   API   | ----------------------------> |   SQS queue     |
     | (C#)    |   3. replies "Queued" at once |  payments-queue |
     +---------+                               +--------+--------+
                                                        |
                                    4. worker takes a note
                                                        v
                                               +-----------------+   5. "Seen this
                                               |     Worker      | <---> payment before?"
                                               |      (C#)       |      +------------+
                                               +--------+--------+      |   MySQL    |
                                                        |               |  payments  |
                              6. failed 3 times?        |               +------------+
                                                        v
                                               +-----------------+
                                               | Dead-letter     |
                                               | queue (DLQ)     |
                                               +-----------------+
```

---

## 2. The stack: what each tool is and why it is here

"Used now" means the app already uses it. "Installed, used later" means the setup script starts it, but nothing in the app uses it yet.

| Tool | What it is, in plain English | Why we need it | Status |
|---|---|---|---|
| **Homebrew** | An app store for the Terminal. One command installs a program. | The setup script uses it to install everything else. | Used now |
| **.NET SDK** | The toolkit that builds and runs C# programs. | The API and Worker are C# programs. | Used now |
| **VS Code** (+ extensions) | The editor where you read and write code. | Free, works on Mac, and has C#, Docker and SQL add-ons. | Used now |
| **Docker Desktop** | Runs ready-made "mini computers" called containers. | Lets you run databases and AWS look-alikes without installing each one by hand. | Used now |
| **Docker Compose** | A single file (`docker-compose.yml`) that lists all the containers. | `docker compose up -d` starts the whole lab; `docker compose down` stops it. | Used now |
| **LocalStack** | A pretend Amazon AWS that runs on your laptop. | Practice SQS, SNS, EventBridge, Lambda and Step Functions without an AWS account or bill. Needs a free token. | Used now (SQS) |
| **AWS CLI** | A command-line remote control for AWS (or LocalStack). | Create queues, peek at messages, check the DLQ. | Used now |
| **AWS SDK for .NET** (`AWSSDK.SQS`) | A C# library for talking to SQS. | Lets the API send messages and the Worker receive them. | Used now |
| **SQS** (Simple Queue Service) | A managed waiting line for messages. | Decouples "accepting" a payment from "processing" it, and gives retries and a DLQ for free. | Used now |
| **MySQL** | A database. | Stores every payment and its status. Its unique key stops duplicates. | Used now |
| **Dapper + MySqlConnector** | Small C# libraries that run SQL against MySQL. | The Worker uses them to claim and update payments. | Used now |
| **SQL Server** | Your core database skill, running as a container. | For comparing MySQL and SQL Server behavior later. The app does not use it yet. | Installed, used later |
| **DBeaver** | A visual database browser. | Look at tables without typing SQL in the terminal. | Used when you want |
| **Prometheus** | Collects numbers (metrics) from running programs. | Answers "how many payments per second, how many errors?" The apps do not expose metrics yet, so its targets show as down. | Installed, used later |
| **Grafana** | Draws graphs from Prometheus. | The dashboards you can show in an interview. | Installed, used later |
| **Jaeger** | Follows one request across several programs. | Shows where time is spent (distributed tracing). | Installed, used later |
| **Terraform** | Describes cloud resources in code files (Infrastructure as Code). | The posting lists it as nice-to-have. We will define the queues in Terraform. | Installed, used later |
| **k6** | A load-testing tool. | Fire thousands of requests at the API to see how it behaves. | Installed, used later |
| **Git + GitHub CLI** | Version control and GitHub from the terminal. | Keep this project as a portfolio repo. | Used when you want |
| **dotnet-ef** (optional) | The Entity Framework Core command-line tool. | Only if you later switch the data layer to EF Core. | Optional |

---

## 3. Words you will hear

| Term | Plain meaning |
|---|---|
| **API** | A program other programs talk to over the web. Here: "send me a payment". |
| **Message** | One note in the queue. Here: one payment request in JSON form. |
| **Queue** | A line of messages waiting to be handled, usually oldest first. |
| **Worker / consumer** | A program that takes messages off the queue and does the work. |
| **Visibility timeout** | When a worker takes a message, it becomes invisible for a while (10 seconds here). If the worker does not delete it in that time, it reappears. That is how retries happen. |
| **Retry** | Trying again after a failure. |
| **Dead-letter queue (DLQ)** | Where a message goes after too many failed tries. Prevents one bad message from blocking everything. |
| **Idempotency** | Doing the same request twice has the same effect as doing it once. Critical in payments: a retry must not pay twice. |
| **Idempotency key** | A unique label on a request (like `abc-1`). The database remembers it, so a repeat is recognized. |
| **Container** | A packaged, isolated mini computer with one program inside it. |
| **Emulator** | A pretend version of a service (LocalStack pretends to be AWS). |
| **Event-driven** | Parts of the system react to messages and events instead of calling each other directly. |
| **Batch processing** | Handling a big file or a big pile of work in chunks rather than one at a time. |
| **Observability** | Being able to see what a running system is doing: metrics (numbers), logs (text), traces (request paths). |
| **Infrastructure as Code (IaC)** | Defining servers, queues and so on in text files instead of clicking in a console. |

---

## 4. What is in the folder

```
payment-pipeline/
  setup.sh                 # one-shot setup (this guide, section 5)
  README.md                # this file
  docker-compose.yml       # the list of containers
  prometheus.yml           # what Prometheus should scrape
  .env                     # your LocalStack token (secret, never commit)
  .gitignore
  PaymentPipeline.sln      # .NET solution
  infra/
    setup-queues.sh        # creates the queue + DLQ
    schema.sql             # creates the payments table
  src/
    Api/Program.cs         # accepts payments, puts them on the queue
    Worker/Program.cs      # takes payments off the queue
    Worker/PaymentStore.cs # database logic: claim, complete, fail
```

---

## 5. One-time setup

**Before you start**
1. A Mac with [Homebrew](https://brew.sh) installed. The script stops with instructions if it is missing.
2. A free LocalStack account: sign up at https://app.localstack.cloud and copy your token from the **Auth Tokens** page. The free Hobby plan is for non-commercial use, which covers personal practice. LocalStack will not start without a token.
3. Docker Desktop. The script installs it if missing, but you then have to open it once and finish its first-run prompts.
4. About 15 to 20 GB free disk and 6 to 8 GB of memory given to Docker (Docker Desktop > Settings > Resources).

**Run it**
```bash
cd payment-pipeline          # the folder that contains setup.sh
chmod +x setup.sh
./setup.sh
```

It will ask you to paste your LocalStack token once (the input is hidden) and save it in `.env`. The first run downloads several GB of images, so expect it to take a while.

When it finishes you will see "All done" with the URLs and the commands to run the app.

**Useful options**
```bash
SKIP_TOOLS=1 ./setup.sh     # you already have the tools; skip installing
FORCE=1 ./setup.sh          # overwrite config and source files with the originals
./setup.sh ~/other/folder   # set up somewhere else
```
The script is safe to re-run: anything that already exists is kept.

**If you already followed the manual steps:** you do not need this script. It is for a fresh machine or a clean rebuild. If you run it in your existing folder, your existing files are kept. If you run it in a different folder, stop the old stack first (`docker compose down` in the old folder), because both use the same ports.

---

## 6. Running the app

Open two terminals in the project folder.

```bash
# Terminal 1: the worker
dotnet run --project src/Worker

# Terminal 2: the API
dotnet run --project src/Api --urls http://localhost:5080
```

Port 5080 is used because macOS reserves port 5000 for AirPlay Receiver.

Stop an app with **Ctrl+C** (Control key, not Cmd).

**Start and stop the containers**
```bash
docker compose up -d      # start everything in the background
docker compose ps         # see what is running
docker compose down       # stop everything, keep your data
docker compose logs --tail 30 localstack   # last 30 log lines, then return
```

---

## 7. Try it: four tests

Run these in a third terminal while the worker and API are running.

**1. Happy path**
```bash
curl -X POST http://localhost:5080/payments -H "Content-Type: application/json" \
  -d '{"payeeId":"P-100","amount":250.00,"idempotencyKey":"demo-1"}'
```
The API replies "Queued" immediately. The worker log shows "Processed payment ...".

**2. Duplicate**: send the exact same command again. The worker logs "Duplicate demo-1 skipped". Now stop and restart the worker and send it a third time. It is still skipped, because the memory of what was processed lives in the database, not in the worker.

**3. Race between two workers**: start a second worker in another terminal, then send the same key five times at once.
```bash
for i in 1 2 3 4 5; do
  curl -s -X POST http://localhost:5080/payments -H "Content-Type: application/json" \
    -d '{"payeeId":"P-300","amount":5,"idempotencyKey":"k-race"}' &
done; wait
```
Exactly one "Processed payment" line should appear across both workers.

**4. Failure and the dead-letter queue**: a payee named `FAIL` makes the worker throw an error on purpose.
```bash
curl -X POST http://localhost:5080/payments -H "Content-Type: application/json" \
  -d '{"payeeId":"FAIL","amount":10,"idempotencyKey":"fail-1"}'
```
The worker logs three failed attempts about 10 seconds apart. After roughly a minute:
```bash
docker compose exec mysql mysql -uroot -pRootPass123! payments \
  -e "SELECT idempotency_key, status, attempts, last_error FROM payments;"

aws --endpoint-url=http://localhost:4566 sqs get-queue-attributes \
  --queue-url $(aws --endpoint-url=http://localhost:4566 sqs get-queue-url --queue-name payments-dlq --query QueueUrl --output text) \
  --attribute-names ApproximateNumberOfMessages
```
You should see `fail-1` as `FAILED` with 3 attempts, and a DLQ count of 1. The count can read 0 for the first 30 to 45 seconds because the move to the DLQ happens only after the third failed receive.

(The AWS commands use dummy credentials. If the CLI complains about credentials, run `aws configure` and enter `test`, `test`, `us-east-1`, `json`.)

---

## 8. Addresses and logins

These passwords are for this local lab only. Do not reuse them anywhere real.

| Service | Address | Login |
|---|---|---|
| API | http://localhost:5080 | none |
| LocalStack (AWS) | http://localhost:4566 | any dummy credentials |
| MySQL | localhost:3306, database `payments` | root / `RootPass123!` |
| SQL Server | localhost:1433 | sa / `YourStrong!Passw0rd` |
| Prometheus | http://localhost:9090 | none |
| Grafana | http://localhost:3000 | admin / admin |
| Jaeger | http://localhost:16686 | none |

---

## 9. How this maps to the job posting

| Posting asks for | Where you practice it here |
|---|---|
| C#/.NET backend services and REST APIs | `src/Api` |
| Event-driven, asynchronous processing | API to SQS to Worker |
| AWS: SQS, SNS, EventBridge, Lambda, Step Functions, ECS, CloudWatch | LocalStack. SQS is built; the rest come in later steps. |
| Large batch processing | Next step (see section 11) |
| Payment integrations, ACH, reliability | Idempotency, retries, dead-letter handling |
| MySQL and SQL Server: schema design, indexing, tuning | `infra/schema.sql`, plus the SQL Server container |
| Terraform / IaC | Later step |
| Observability: CloudWatch, OpenTelemetry, Grafana | Prometheus, Grafana and Jaeger containers; metrics wiring comes later |
| CI/CD | GitHub Actions, once the repo is on GitHub |

---

## 10. When something goes wrong

| Symptom | Likely cause | Fix |
|---|---|---|
| LocalStack container exits with code 55 | Missing or invalid LocalStack token | Check `.env` has `LOCALSTACK_AUTH_TOKEN=...`, then `docker compose up -d localstack` |
| "Could not connect to the endpoint URL" | LocalStack is not running | `docker compose ps`, then `docker compose logs --tail 30 localstack` |
| Port already in use | Another program uses 3306, 3000, 9090 or similar | Stop it, or change the left-hand number in `docker-compose.yml` |
| API will not start on port 5000 | macOS AirPlay Receiver uses it | Use `--urls http://localhost:5080` as shown |
| SQL Server keeps restarting | Not enough memory or Rosetta is off | Docker Desktop: give 6 to 8 GB and enable Rosetta emulation (Apple Silicon) |
| DLQ count is 0 right after the FAIL test | Retries take about 30 to 45 seconds | Wait a minute and check again |
| `payments` table is empty | The old worker is still running, or no payment was sent since the restart | Stop all workers, start one new worker, send a payment |
| Worker cannot resolve a `...localhost.localstack.cloud` hostname | LocalStack returns that style of queue URL | Check your internet/DNS, and ask for a fix that uses plain `localhost:4566` |
| Build error mentioning `["ApproximateReceiveCount"]` or `?? []` | .NET SDK older than 8 | Run `dotnet --version` and upgrade |

---

## 11. Clean up and start over

```bash
docker compose down        # stop containers, KEEP data (queues, tables)
docker compose down -v     # stop containers and DELETE all data
./setup.sh                 # rebuild everything (add FORCE=1 to reset the code files too)
```

---

## 12. Honest limits

- **It is a practice system, not production.** Passwords are hard-coded, there is no authentication on the API, and the "processing" step just logs a line.
- **At-least-once delivery.** SQS can deliver a message more than once. The database claim prevents double-processing inside this app. In a real system that also calls a bank or processor, a crash between "call the bank" and "mark completed" can still cause a double send. Real systems close that gap with the processor's own idempotency support, the outbox pattern and reconciliation. Be ready to explain this in an interview.
- **LocalStack is an imitation.** Behavior is close to AWS but not identical, so check anything important against real AWS or its documentation.
- **The setup script has been syntax-checked and dry-run with stand-in tools, but not on a real fresh Mac.** If a step fails, send the last 20 lines of output.

---

## 13. What comes next

1. **Batch processor:** a restartable job that reads a payment file in chunks and feeds this queue.
2. **Terraform:** define the queues and DLQ as code.
3. **Observability:** expose metrics from the API and Worker, build a Grafana dashboard, add tracing with OpenTelemetry and Jaeger.
4. **More AWS pieces:** SNS fan-out, EventBridge rules, a Step Functions workflow, a Lambda.
5. **Optional:** Microsoft Orleans for per-account state, and a load test with k6.
