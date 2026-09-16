-- Run through the primary endpoint, then through the reader endpoint.
-- Open several reader connections to observe endpoint connection balancing.
-- HorizonDB replicas use shared storage and stateless compute, so
-- pg_is_in_recovery() is diagnostic context, not the replica-role test.
SELECT current_database() AS database_name,
       current_user AS login_name,
       inet_server_addr() AS server_address,
       pg_backend_pid() AS backend_pid,
    pg_is_in_recovery() AS recovery_state_context,
       current_setting('transaction_read_only') AS transaction_read_only,
       clock_timestamp() AS observed_at;

SELECT status, count(*) AS shipment_count
FROM shipment
GROUP BY status
ORDER BY status;

SELECT shipment.tracking_number,
       shipment.status,
       event.event_type,
       event.event_time,
       event.details
FROM shipment
JOIN LATERAL (
    SELECT shipment_event.event_type,
           shipment_event.event_time,
           shipment_event.details
    FROM shipment_event
    WHERE shipment_event.shipment_id = shipment.shipment_id
    ORDER BY shipment_event.event_time DESC
    LIMIT 1
) AS event ON true
ORDER BY event.event_time DESC;
