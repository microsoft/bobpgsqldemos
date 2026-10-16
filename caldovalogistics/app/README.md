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

## AI Pipeline Debug View

The control tower opens in its normal layout. Select **Debug** in the top bar
to open a right-side debug view with two panes:

- **Pipeline definition** displays
  `demo3-ai-pipeline/sql/01-create-pipeline.sql`, read from disk when the page
  is rendered.
- **Pipeline in action** animates `operations_guide` -> `ai.chunk` ->
  `ai.embed` (Microsoft Foundry) -> `operations_guide_chunk` -> DiskANN.

As each animated step becomes active, the corresponding SQL lines are
highlighted and scrolled into view. DiskANN is the index over the output table,
not another pipeline processing step.

Opening the debug view starts a looping walkthrough. Use **Pause**, **Replay**,
or **Loop** while presenting. Select **Close debug**, the close button, or
press `Esc` within the view to return to the app-only layout. The open state
persists in the browser tab across app form submissions; append `?debug=1` or
`?debug=0` to force it open or closed. Playback is independent of searches,
briefings, and agent actions. It is not live telemetry and never changes the
database or invokes a model. For a real pipeline run, follow
[Demo 3](../demo3-ai-pipeline/README.md).

On screens wider than 1,100 pixels, the app remains visible beside the view.
On smaller screens, the debug view covers the app. Reduced-motion preferences
disable automatic playback and moving effects; manual playback remains
available. Switching browser tabs pauses playback. Set `CALDOVA_PIPELINE_SQL`
only if the app is installed somewhere that cannot reach the Demo 3 SQL file.
