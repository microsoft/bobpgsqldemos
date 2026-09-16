SET client_min_messages = warning;

CREATE TEMP TABLE IF NOT EXISTS demo5_observability_heartbeat (
    heartbeat_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tracking_number text NOT NULL,
    marker text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
) ON COMMIT PRESERVE ROWS;

INSERT INTO demo5_observability_heartbeat (tracking_number, marker)
VALUES ('CLD-2026-0911-001', 'CALDOVA-DEMO5');

\sleep 100 ms