# Demo 3: Native AI Pipeline in Azure HorizonDB

This demo shows a real HorizonDB AI pipeline that converts Caldova's approved
handling guides into retrieval-ready vector chunks:

```text
operations_guide -> ai.chunk -> ai.embed -> operations_guide_chunk -> DiskANN
```

Microsoft Foundry hosts `text-embedding-3-small`. HorizonDB registers that
deployment as `caldova-embedding` and executes the pipeline inside PostgreSQL.
AI Model Management is not required.

## One Preflight

Run from this folder:

```powershell
.\scripts\00-preflight.ps1 -Subscription 'AzureSQL_bobward'
```

Preflight checks the Foundry account/model deployment, HorizonDB extension
configuration, database model registry, pipeline definition, output embeddings,
and DiskANN index. It repairs safe missing pieces. Creating billable Foundry
resources or changing the HorizonDB parameter group requires
`-ApproveProvisioning`.

Passwords and model keys are prompted or retrieved at runtime and never written
to this repository.

## Live Demo

1. Show eight source rows in `operations_guide`.
2. Open **Pipelines & Workflows** in the Microsoft PostgreSQL extension.
3. Show `caldova-guide-pipeline`: table source, chunk, embed, table sink.
4. Run `sql/03-replay-pipeline.sql` to clear only the derived sink and start a
    full durable backfill.
5. Watch the graph move from running to completed.
6. Query `operations_guide_chunk` and prove embeddings are populated.

The keynote tease should stop after the pipeline graph and populated sink. The
breakout continues into DiskANN and hybrid retrieval.

### App-side presentation

The Control Tower opens in its normal layout. Select **Debug** to open a
right-side view with the real `sql/01-create-pipeline.sql` definition above an
animated pipeline. Each animated step highlights its matching SQL. Use the
Play/Pause, Replay, and Loop controls to narrate ingestion while the app stays
visible on wide screens. This is a clearly labeled illustrative animation, not
execution telemetry: it does not start `caldova-guide-pipeline` or report live
counts or status. Use the steps above to prove the real pipeline execution.

## Validated Baseline

- Foundry resource: `caldova-logistics-ai` in `westus3`
- Embedding deployment: `caldova-embedding` (`text-embedding-3-small` v1,
  GlobalStandard, 10K TPM)
- Pipeline: `caldova-guide-pipeline`, manual trigger, two steps
- Last validated run: completed, 8 source guides processed
- Sink: 8 chunks, 8 embeddings, 1,536 dimensions
- Index: `operations_guide_chunk_diskann_idx`

The subscription currently has no real-time `gpt-4.1-mini` quota. This demo
therefore proves the native ingestion pipeline only; it does not claim live
briefing generation.
