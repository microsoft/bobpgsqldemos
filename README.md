# Azure PostgreSQL and HorizonDB Demos

Demo examples from Bob Ward for Azure PostgreSQL and HorizonDB.

## Repository Contents

### Caldova Logistics on Azure HorizonDB

[`caldovalogistics/`](caldovalogistics/) contains a working Python, FastAPI, and
PostgreSQL logistics control tower plus five Azure HorizonDB demonstrations:

1. **This Is PostgreSQL** - Standard SQL, psycopg, JSONB, transactions,
   full-text search, and query plans.
2. **Scale Reads with Explicit Routing** - Separate primary and reader
   endpoints with application-level workload routing.
3. **Native AI Pipeline** - Chunking, Microsoft Foundry embeddings, pgvector,
   and DiskANN indexing managed with HorizonDB.
4. **Approval-Gated Operations Agent** - A Microsoft Foundry Hosted Agent,
   remote MCP server, least-privilege PostgreSQL tools, and human approval.
5. **Production Evidence and Observability** - A controlled four-lane workload
   inspected through the VS Code PostgreSQL dashboards.

The folder includes the application, schema and seed data, deployment and
preflight automation, AI pipeline assets, MCP infrastructure, Foundry agent
source, observability workload, architecture diagrams, and presenter runbook.

Start with the [Caldova Logistics README](caldovalogistics/README.md) for setup,
verification, demo instructions, and teardown.
