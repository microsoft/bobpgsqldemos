# Demo 6: Caldova Knowledge Hub — Vector Search Kept Fresh by an AI Pipeline

A FastAPI app on Azure App Service. Operators search logistics procedures,
carrier notes, and facility runbooks **by meaning**. When they add, edit, or
delete an article, HorizonDB keeps the vectors current without any app code:

```text
article INSERT/UPDATE ──► on_change trigger ──► ai pipeline (pg_durable graph)
   changed rows ─► ai.chunk ─► ai.embed (Microsoft Foundry) ─► upsert chunk_embedding ─► DiskANN
pg_durable reconciler (every 10 s) ─► re-queues any change the trigger skipped, cleans stale vectors
```

The screen is split in two:

- **Left: the app.** Search with **Vector** (DiskANN cosine), **Keyword** (BM25 via
  `pg_textsearch`), or **Hybrid** (reciprocal rank fusion). Every article shows a
  live freshness badge: `Embedding 0/1` → `Searchable · 1 chunk`.
- **Right: the AI pipeline, live.** Top: the pipeline SQL, **rendered from the
  `ai.pipelines` catalog** (plus the DiskANN index from `pg_indexes`), and the
  pg_durable reconciler. Bottom: the run animation, driven by
  `ai.pipeline_runs` and the run's **pg_durable** steps (`df.nodes`). Runs take
  about 2 seconds, so a completed run is replayed using the step completion
  times pg_durable recorded; the matching SQL lines highlight as each step plays.
  **Hide pipeline** collapses the pane.

Nothing on the right is simulated: run numbers, rows, durations, step timings,
durable instance IDs, chunk counts, and reconciler iterations come from HorizonDB.

## Prerequisites

1. Parent Caldova preflight (`../scripts/00-preflight.ps1`): cluster, firewall,
   `.venv`, `.caldova-connection.json`, `pwd.env`.
2. Demo 3 preflight (`../demo3-ai-pipeline/scripts/00-preflight.ps1`): the
   `caldova-embedding` Foundry model alias and the `vector`, `pg_diskann`,
   `pg_textsearch`, `azure_ai`, and `pg_durable` extensions.
3. **`azure_ai` 2.3.2 or later.** With 2.2.2 SQL objects on a 2.3 library,
   every run fails in `ai._update_checkpoint` and stays `running`, which stops
   `on_change` triggers. Preflight checks this. Fix with
   `ALTER EXTENSION azure_ai UPDATE TO '2.3.2';` (no downgrade path).

## Build and run

```powershell
./demo6-vector-app/scripts/00-preflight.ps1            # schema, pipeline, reconciler, seed, app role
./demo6-vector-app/scripts/01-run-local.ps1 -Port 8020 # local run as knowledge_hub_app
./demo6-vector-app/scripts/02-deploy-appservice.ps1 -AppName <name>  # Azure App Service
```

Preflight is idempotent. It generates `KNOWLEDGE_HUB_APP_PASSWORD` in the
ignored `pwd.env` when missing and waits until every article is searchable.
Use `-ResetArticles` to restore the 12 seed articles.

The deployment script creates (when missing) a Linux **P0v3** plan and a
**Python 3.14** web app in `caldova-logistics-rg` / `westus3`, sets
`SCM_DO_BUILD_DURING_DEPLOYMENT=true`, the startup command
`python -m uvicorn main:app --host 0.0.0.0`, Always On, and the HorizonDB
settings, then zip-deploys `src/`. The plan is billable. App Service reaches
HorizonDB through the existing `0.0.0.0` Azure-services firewall rule; the
script stops if that rule is missing. The first request after a deploy can
take 2–3 minutes while the container warms up.

## Demo script (about 5 minutes)

1. Search **"our truck fridge died on the highway"** with **Keyword**: no results,
   because no article uses those words. Switch to **Vector**: *Reefer unit failure
   response* is first. Show **Hybrid** for RRF ranks.
2. Point at the right pane: this is the pipeline definition read live from
   `ai.pipelines`. `trigger => 'on_change'` and `incremental_column => 'updated_at'`
   are why edits are picked up automatically.
3. Search **"frozen CO2 on passenger flights"**: no good answer yet.
4. **New article** → *Dry ice in air shipments*, category *Handling procedure*:

   > Carbon dioxide solid (dry ice, UN1845) used to chill perishables or pharma is
   > limited to 200 kg per package on passenger aircraft. Mark the net weight on
   > each box, use packaging that vents gas, and declare it on the air waybill.

   **Save & embed.** Watch the run play: trigger → changed rows → chunk → embed →
   upsert → checkpoint → DiskANN, each with its recorded pg_durable time. The
   badge flips to *Searchable*. Select **Run the search again**: the new article
   is first for Vector and Hybrid, while Keyword still ranks *Northwind Air
   cargo cutoffs* first.
5. **Edit** the article. Only that row is re-embedded (`Rows 1`). **Delete** it:
   it disappears from search immediately.
6. Open the **pg_durable reconciler** tab: a durable `df.loop` running inside the
   database, with its iteration count and heartbeat shown below.
7. Optional: edit an article from SQL in VS Code; the app picks it up the same way.

**Reset demo** restores the seed articles; only changed rows are re-embedded.

## How it works

| Object | Purpose |
| --- | --- |
| `knowledge_hub.article` | Source of truth. `embedding_text = title + content` is what gets embedded. A trigger bumps `updated_at` when text changes. |
| `knowledge-hub-pipeline` | `ai.table_source(incremental_column => 'updated_at')` → `ai.chunk(256/32)` → `ai.embed(caldova-embedding, 1536)` → `ai.table_sink`, `trigger => 'on_change'`. |
| `knowledge_hub.chunk_embedding` | Pipeline sink with a DiskANN index. Upserts on `chunk_hash = md5(chunk_text)`. |
| `knowledge_hub.article_chunk_map` | Each article's expected chunk hashes, computed synchronously with the same `azure_ai.chunk` call and the live pipeline's chunk settings. |
| `knowledge_hub.article_freshness` | Expected vs embedded chunks per article; drives the badges. |
| `knowledge_hub.reconcile()` + `ensure_reconciler()` | pg_durable `df.loop(df.seq(df.sleep(10), reconcile))`, bounded to 12 hours to limit durable history; preflight restarts it. |
| `knowledge_hub.pipeline_status()` | One JSON snapshot for the right pane: definition, runs, latest run's `df.nodes`, reconciler, freshness. |

### Why the sink is content-addressed (preview behavior verified on this cluster)

- The sink's `doc_id` is `row_number() OVER ()` within each run's batch, **not**
  the source key, so upserting on `doc_id` overwrote other articles' chunks.
  Upserting on `chunk_hash` and mapping hashes back to articles is exact.
- Old chunks of an edited or deleted article are never returned, because search
  joins vectors to the **current** `article_chunk_map`. The reconciler deletes
  unused vectors after 10 minutes.
- `on_change` fires on `INSERT` and `UPDATE` only, at statement level, and skips
  starting a run while one is running; the checkpoint can then advance past an
  edit made during the run. The pg_durable reconciler re-touches any article
  whose chunks are missing once the pipeline is idle (verified: about 10 s).
- A zero-row `UPDATE` still starts a run, so the reconciler only updates when
  something is missing.
- `on_conflict_action` must be `DO NOTHING` or `DO UPDATE SET ...`.

### Security

The app connects as `knowledge_hub_app`: `SELECT` on the Knowledge Hub tables
and views, and `EXECUTE` on `save_article`, `delete_article`, `embed_query`,
`pipeline_status`, and `reset_demo`. These `SECURITY DEFINER` functions pin
`search_path`, so the app never writes tables, starts pipelines, or reads `df.*`
directly, and has no access to other Caldova tables. The Foundry key stays in the
HorizonDB model registry. Note that `azure_ai` grants `PUBLIC` read access to
`ai.pipelines` and `EXECUTE` on `azure_openai.create_embeddings` by default. The
database password is an App Service setting; for production, use a Key Vault
reference.

## Tests

```powershell
cd demo6-vector-app
../.venv/Scripts/python.exe -m pytest tests -q
```

The tests cover routes, all three search modes, graceful database outages,
SQL rendering from the catalog, classification of real pg_durable step SQL,
stage timing, and that the reconciler snippet matches `sql/03`.

## Teardown

```powershell
./demo6-vector-app/scripts/99-teardown.ps1 -AppName <name>
```

Cancels the reconciler, drops the pipeline, the `knowledge_hub` schema, and the
`knowledge_hub_app` role, then deletes the web app and plan. Other demos are not
affected.
