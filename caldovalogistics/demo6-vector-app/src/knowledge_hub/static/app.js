(() => {
    const STAGE_ORDER = ['trigger', 'source', 'chunk', 'embed', 'sink', 'checkpoint', 'index'];
    const pane = document.querySelector('[data-pipeline]');
    const toggle = document.querySelector('[data-debug-toggle]');
    const reducedMotion = matchMedia('(prefers-reduced-motion: reduce)');
    const stages = Object.fromEntries([...document.querySelectorAll('[data-stage]')].map((node) => [node.dataset.stage, node]));
    const codeView = document.querySelector('[data-code]');
    const codeLines = [...document.querySelectorAll('[data-code-stage]')];
    const caption = document.querySelector('[data-caption]');
    const pill = document.querySelector('[data-run-pill]');
    const history = document.querySelector('[data-history]');
    const facts = Object.fromEntries([...document.querySelectorAll('[data-fact]')].map((node) => [node.dataset.fact, node]));
    const watch = document.querySelector('[data-watch]');
    const storageKey = 'kh-pipeline-open';

    let lastRunId = null;
    let lastStatus = null;
    let replayTimer = null;
    let replaying = false;
    let pollTimer = null;

    function setPaneOpen(open) {
        document.body.classList.toggle('debug-open', open);
        toggle.setAttribute('aria-expanded', String(open));
        toggle.textContent = open ? 'Hide pipeline' : 'Show pipeline';
        sessionStorage.setItem(storageKey, open ? 'true' : 'false');
    }
    toggle.addEventListener('click', () => setPaneOpen(!document.body.classList.contains('debug-open')));
    setPaneOpen(sessionStorage.getItem(storageKey) !== 'false');

    const tabs = [...document.querySelectorAll('[data-code-tab]')];
    function selectTab(tab) {
        tabs.forEach((other) => {
            const selected = other === tab;
            other.setAttribute('aria-selected', String(selected));
            other.tabIndex = selected ? 0 : -1;
            document.getElementById(other.getAttribute('aria-controls')).hidden = !selected;
        });
    }
    tabs.forEach((tab, index) => {
        tab.addEventListener('click', () => selectTab(tab));
        tab.addEventListener('keydown', (event) => {
            if (event.key !== 'ArrowRight' && event.key !== 'ArrowLeft') return;
            const next = tabs[(index + (event.key === 'ArrowRight' ? 1 : tabs.length - 1)) % tabs.length];
            selectTab(next);
            next.focus();
        });
    });

    const editor = document.querySelector('#editor');
    if (editor && editor.hasAttribute('data-open')) {
        editor.showModal();
        editor.addEventListener('cancel', (event) => {
            event.preventDefault();
            location.href = editor.querySelector('.close').href;
        });
    }

    function highlightCode(activeStage, doneStages) {
        codeLines.forEach((line) => {
            line.classList.toggle('is-active', line.dataset.codeStage === activeStage);
            line.classList.toggle('is-done', doneStages.has(line.dataset.codeStage) && line.dataset.codeStage !== activeStage);
        });
        const first = codeLines.find((line) => line.dataset.codeStage === activeStage);
        if (first && codeView && !codeView.hidden) {
            codeView.scrollTo({ top: Math.max(0, first.offsetTop - codeView.offsetTop - 30), behavior: reducedMotion.matches ? 'auto' : 'smooth' });
        }
    }

    function paintStages(states, times = {}) {
        const done = new Set();
        let active = null;
        STAGE_ORDER.forEach((key) => {
            const state = states[key] || 'pending';
            const node = stages[key];
            node.classList.toggle('is-done', state === 'done');
            node.classList.toggle('is-active', state === 'active');
            node.classList.toggle('is-failed', state === 'failed');
            if (state === 'active') {
                node.setAttribute('aria-current', 'step');
                active = active || key;
            } else {
                node.removeAttribute('aria-current');
            }
            if (state === 'done') done.add(key);
            node.querySelector('[data-stage-time]').textContent = times[key] ?? '';
        });
        highlightCode(active, done);
    }

    function stageTimes(snapshot) {
        const times = {};
        Object.entries(snapshot.stages || {}).forEach(([key, value]) => {
            if (value.finished_ms != null) times[key] = `+${value.finished_ms} ms`;
        });
        return times;
    }

    function runDuration(run) {
        if (!run || !run.started_at || !run.completed_at) return null;
        return Math.round(new Date(run.completed_at) - new Date(run.started_at));
    }

    function finalStates(snapshot) {
        const states = { trigger: 'done' };
        let failed = false;
        ['source', 'chunk', 'embed', 'sink', 'checkpoint'].forEach((key) => {
            const state = snapshot.stages?.[key]?.state;
            if (state === 'failed') { states[key] = 'failed'; failed = true; }
            else states[key] = failed ? 'pending' : 'done';
        });
        states.index = failed ? 'pending' : snapshot.searchable ? 'done' : 'active';
        return states;
    }

    function showFinal(snapshot) {
        replaying = false;
        const run = snapshot.run;
        if (!run) {
            paintStages({});
            caption.textContent = 'Waiting for the first change…';
            return;
        }
        paintStages(finalStates(snapshot), stageTimes(snapshot));
        const duration = runDuration(run);
        if (run.status === 'failed' || run.status === 'cancelled') {
            caption.textContent = `Run #${run.id} ${run.status}${run.error ? `: ${run.error.slice(0, 140)}` : ''}`;
        } else if (!snapshot.searchable) {
            caption.textContent = 'Waiting for the reconciler to re-queue a change…';
        } else {
            caption.textContent = `Run #${run.id} embedded ${run.rows_processed ?? 0} row(s)${duration != null ? ` in ${duration} ms` : ''}. Everything is searchable.`;
        }
    }

    function showLive(snapshot) {
        const states = { trigger: 'done' };
        let activeSet = false;
        ['source', 'chunk', 'embed', 'sink', 'checkpoint'].forEach((key) => {
            const state = snapshot.stages?.[key]?.state;
            if (state === 'completed') states[key] = 'done';
            else if (state === 'failed') states[key] = 'failed';
            else if (!activeSet) { states[key] = 'active'; activeSet = true; }
        });
        paintStages(states, stageTimes(snapshot));
        caption.textContent = `Run #${snapshot.run.id} is running now in pg_durable…`;
    }

    // Runs usually finish in 2-3 seconds, between polls. Replay each new run
    // using the step completion times pg_durable recorded.
    function replay(snapshot) {
        clearTimeout(replayTimer);
        if (reducedMotion.matches) { showFinal(snapshot); return; }
        replaying = true;
        const times = stageTimes(snapshot);
        const steps = [{ key: 'trigger', wait: 650 }];
        let previous = 0;
        ['source', 'chunk', 'embed', 'sink', 'checkpoint'].forEach((key) => {
            const finished = snapshot.stages?.[key]?.finished_ms;
            const gap = finished != null ? finished - previous : 600;
            if (finished != null) previous = finished;
            steps.push({ key, wait: Math.min(1700, Math.max(550, gap)) });
        });
        steps.push({ key: 'index', wait: 900 });
        const failedAt = ['source', 'chunk', 'embed', 'sink', 'checkpoint'].find((key) => snapshot.stages?.[key]?.state === 'failed');
        caption.textContent = `Replaying run #${snapshot.run.id} from recorded pg_durable step timings…`;
        let index = 0;
        const shown = {};
        const advance = () => {
            if (index >= steps.length || (failedAt && steps[index - 1]?.key === failedAt)) { showFinal(latest || snapshot); return; }
            const states = {};
            steps.forEach((step, position) => {
                if (position < index) states[step.key] = 'done';
                if (position === index) states[step.key] = step.key === failedAt ? 'failed' : 'active';
            });
            if (times[steps[index].key]) shown[steps[index].key] = times[steps[index].key];
            paintStages(states, shown);
            replayTimer = setTimeout(advance, steps[index].wait);
            index += 1;
        };
        advance();
    }

    let latest = null;

    function updatePanel(snapshot) {
        const run = snapshot.run;
        const status = run?.status || 'idle';
        pill.className = `run-pill is-${status}`;
        pill.textContent = run ? `Run #${run.id} · ${status}` : 'No runs yet';
        facts.run.textContent = run ? `#${run.id}` : '—';
        facts.rows.textContent = run?.rows_processed ?? '—';
        const duration = runDuration(run);
        facts.duration.textContent = duration != null ? `${duration} ms` : status === 'running' ? 'running…' : '—';
        facts.instance.textContent = run?.instance_id || '—';
        const fresh = snapshot.freshness || {};
        facts.articles.textContent = `${fresh.searchable_articles ?? 0} / ${fresh.articles ?? 0}`;
        facts.chunks.textContent = `${fresh.embedded_chunks ?? 0} / ${fresh.expected_chunks ?? 0}`;
        const reconciler = snapshot.reconciler || {};
        facts.reconciler.textContent = reconciler.status === 'running'
            ? `iteration ${reconciler.iteration ?? '?'} · ${reconciler.seconds_since_tick ?? '?'}s ago`
            : reconciler.status || 'not started';

        const runs = [...(snapshot.runs || [])].reverse();
        const maxRows = Math.max(1, ...runs.map((item) => item.rows_processed || 0));
        history.replaceChildren(...runs.map((item, position) => {
            const bar = document.createElement('span');
            bar.style.height = `${Math.max(12, ((item.rows_processed || 0) / maxRows) * 100)}%`;
            bar.className = `${position === runs.length - 1 ? 'is-latest' : ''} ${item.status === 'failed' ? 'is-failed' : ''}`;
            bar.title = `Run #${item.id} · ${item.status} · ${item.rows_processed ?? 0} row(s)`;
            return bar;
        }));
    }

    function updateArticles(snapshot) {
        const byId = new Map((snapshot.articles || []).map((article) => [String(article.article_id), article]));
        document.querySelectorAll('[data-article-id]').forEach((row) => {
            const article = byId.get(row.dataset.articleId);
            if (!article) return;
            const chip = row.querySelector('[data-freshness]');
            chip.className = `freshness ${article.searchable ? 'is-ready' : 'is-pending'}`;
            chip.textContent = article.searchable
                ? `Searchable · ${article.embedded_chunks} chunk${article.embedded_chunks === 1 ? '' : 's'}`
                : `Embedding ${article.embedded_chunks}/${article.expected_chunks}`;
        });
        if (watch) {
            const watched = byId.get(watch.dataset.watch);
            if (watched?.searchable && !watch.classList.contains('is-ready')) {
                watch.classList.add('is-ready');
                const params = new URLSearchParams(location.search);
                params.delete('watch');
                if (params.get('q')) {
                    watch.textContent = 'Searchable now. ';
                    const again = document.createElement('a');
                    again.href = `/?${params}`;
                    again.textContent = 'Run the search again';
                    watch.append(again, ' to see it ranked by meaning.');
                } else {
                    watch.textContent = 'Searchable now. Try a search that describes it in your own words.';
                }
            }
        }
    }

    function handle(snapshot) {
        latest = snapshot;
        updatePanel(snapshot);
        updateArticles(snapshot);
        const run = snapshot.run;
        if (!run) { showFinal(snapshot); return; }
        if (lastRunId === null) {
            lastRunId = run.id;
            lastStatus = run.status;
            if (run.status === 'running') showLive(snapshot);
            else showFinal(snapshot);
            return;
        }
        if (run.id !== lastRunId) {
            lastRunId = run.id;
            lastStatus = run.status;
            if (run.status === 'running') { clearTimeout(replayTimer); replaying = false; showLive(snapshot); }
            else replay(snapshot);
            return;
        }
        if (run.status === 'running') { lastStatus = 'running'; showLive(snapshot); return; }
        if (lastStatus === 'running') { lastStatus = run.status; replay(snapshot); return; }
        lastStatus = run.status;
        if (!replaying) showFinal(snapshot);
    }

    async function poll() {
        clearTimeout(pollTimer);
        let delay = 1000;
        try {
            const response = await fetch('/api/status', { cache: 'no-store' });
            if (!response.ok) throw new Error(String(response.status));
            handle(await response.json());
            if (latest?.run?.status === 'running') delay = 350;
        } catch {
            pill.className = 'run-pill is-failed';
            pill.textContent = 'HorizonDB unavailable';
            delay = 5000;
        }
        if (!document.hidden) pollTimer = setTimeout(poll, delay);
    }

    document.addEventListener('visibilitychange', () => { if (!document.hidden) poll(); });

    const initial = JSON.parse(document.getElementById('initial-status').textContent || 'null');
    // After a save, the run it triggered has often finished during the
    // redirect; treat it as new so the presenter still sees it play.
    if (watch) lastRunId = -1;
    if (initial) handle(initial);
    if (pane) poll();
})();
