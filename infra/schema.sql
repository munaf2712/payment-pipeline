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
