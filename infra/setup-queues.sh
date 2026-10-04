#!/usr/bin/env bash
# Creates payments-queue + payments-dlq in LocalStack.
# Failed messages are retried 3 times (10s apart), then moved to the DLQ.
# Safe to re-run.
set -euo pipefail

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
