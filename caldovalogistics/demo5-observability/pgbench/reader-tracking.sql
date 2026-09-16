SELECT shipment.tracking_number,
       shipment.status,
       shipment.priority,
       latest_event.event_type,
       latest_event.event_time
FROM shipment
LEFT JOIN LATERAL (
    SELECT event_type, event_time
    FROM shipment_event
    WHERE shipment_event.shipment_id = shipment.shipment_id
    ORDER BY event_time DESC
    LIMIT 1
) AS latest_event ON true
ORDER BY shipment.created_at DESC;

\sleep 100 ms