--- migration:up

DO $$
BEGIN
IF NOT EXISTS (
    SELECT 1 FROM pg_type WHERE typname = 'weft_job_state'
) THEN
    CREATE TYPE weft_job_state AS ENUM (
    'available',
    'suspended',
    'scheduled',
    'executing',
    'retryable',
    'completed',
    'discarded',
    'cancelled'
    );
END IF;

CREATE TABLE IF NOT EXISTS weft_jobs (
id            BIGSERIAL PRIMARY KEY,
state         weft_job_state NOT NULL DEFAULT 'available',
queue         TEXT NOT NULL DEFAULT 'default',
worker        TEXT NOT NULL,
args          JSONB NOT NULL DEFAULT '{}',
meta          JSONB NOT NULL DEFAULT '{}',
tags          TEXT[] NOT NULL DEFAULT '{}',
priority      SMALLINT NOT NULL DEFAULT 0,
attempt       INTEGER NOT NULL DEFAULT 0,
max_attempts  INTEGER NOT NULL DEFAULT 20,
errors        JSONB[] NOT NULL DEFAULT '{}',
unique_key    TEXT,
attempted_by  TEXT[] NOT NULL DEFAULT '{}',
inserted_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),
scheduled_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),
attempted_at  TIMESTAMPTZ,
completed_at  TIMESTAMPTZ,
discarded_at  TIMESTAMPTZ,
cancelled_at  TIMESTAMPTZ,
heartbeat_at  TIMESTAMPTZ,

CONSTRAINT non_negative_priority CHECK (priority >= 0),
CONSTRAINT positive_max_attempts CHECK (max_attempts > 0),
CONSTRAINT attempt_range         CHECK (attempt >= 0 AND attempt <= max_attempts),
CONSTRAINT worker_length         CHECK (char_length(worker) > 0 AND char_length(worker) < 128),
CONSTRAINT queue_length          CHECK (char_length(queue) > 0  AND char_length(queue) < 128)
);

CREATE INDEX IF NOT EXISTS idx_weft_jobs_fetch
ON weft_jobs (queue, priority, scheduled_at, id)
WHERE state = 'available';

CREATE INDEX IF NOT EXISTS idx_weft_jobs_scheduled
ON weft_jobs (scheduled_at)
WHERE state = 'scheduled';

CREATE INDEX IF NOT EXISTS idx_weft_jobs_heartbeat
ON weft_jobs (heartbeat_at)
WHERE state = 'executing';

CREATE UNIQUE INDEX IF NOT EXISTS idx_weft_jobs_unique
ON weft_jobs (queue, unique_key)
WHERE state NOT IN ('completed', 'discarded', 'cancelled')
    AND unique_key IS NOT NULL;
END$$;

--- migration:down
DO $$
BEGIN
DROP TABLE IF EXISTS weft_jobs;
DROP TYPE IF EXISTS weft_job_state;
END$$;

--- migration:end
