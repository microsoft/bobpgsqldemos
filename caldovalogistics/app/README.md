# Caldova Control Tower Application

The FastAPI application uses two standard PostgreSQL connection pools:

- `WRITE_DATABASE_URL` targets the HorizonDB primary endpoint.
- `READ_DATABASE_URL` targets the HorizonDB reader endpoint.

Shipment creation uses the write pool. Dashboards and operations-guide searches use the read pool. If `READ_DATABASE_URL` is omitted, the application uses the write connection for both paths, which is useful for local development but does not demonstrate read scale-out.

Demo 4 calls the active Microsoft Foundry Hosted Agent Responses endpoint from
`CALDOVA_HOSTED_AGENT_ENDPOINT`. The app authenticates with
`DefaultAzureCredential` and does not receive the model key, MCP Function key,
or MCP database credential. The app still owns operator approval and passes the
short-lived approval token only in the approved execution turn.

Use the scripts in the repository-level `scripts` folder to install, test, and run the application.
