(() => {
    const drawer = document.querySelector('[data-pipeline]');
    const toggle = document.querySelector('[data-debug-toggle]');
    if (!drawer || !toggle) return;

    const closeButton = drawer.querySelector('[data-debug-close]');
    const heading = drawer.querySelector('#debug-heading');
    const stages = [...drawer.querySelectorAll('[data-pipeline-stage]')];
    const codeView = drawer.querySelector('[data-pipeline-code]');
    const codeLines = [...drawer.querySelectorAll('[data-code-stage]')];
    const play = drawer.querySelector('[data-pipeline-play]');
    const replay = drawer.querySelector('[data-pipeline-replay]');
    const loop = drawer.querySelector('[data-pipeline-loop]');
    const caption = drawer.querySelector('[data-pipeline-caption]');
    const detail = drawer.querySelector('[data-pipeline-detail]');
    const progress = drawer.querySelector('[data-pipeline-progress]');
    const progressbar = drawer.querySelector('[role="progressbar"]');
    const reducedMotion = matchMedia('(prefers-reduced-motion: reduce)');
    const storageKey = 'caldova-debug-open';
    const narration = [
        ['Reading approved source content', 'ai.table_source reads operations_guide, the authoritative handling guidance.'],
        ['Breaking guidance into useful passages', 'ai.chunk creates 256-token passages with 32 tokens of overlap to preserve context.'],
        ['Turning text into vectors', 'ai.embed calls the caldova-embedding model in Microsoft Foundry for 1,536-dimensional vectors.'],
        ['Keeping knowledge beside the data', 'ai.table_sink writes chunk text, embeddings, and metadata to operations_guide_chunk.'],
        ['Making guidance searchable by meaning', 'The DiskANN index accelerates vector similarity search over the sink table.'],
    ];
    let current = -1;
    let playing = false;
    let timer;

    function revealCode(stage) {
        const firstLine = codeLines.find((line) => line.dataset.codeStage === stage);
        if (!codeView || !firstLine) return;
        const top = firstLine.offsetTop - codeView.offsetTop - 24;
        codeView.scrollTo({ top: Math.max(0, top), behavior: reducedMotion.matches ? 'auto' : 'smooth' });
    }

    function render() {
        drawer.dataset.state = playing ? 'playing' : current === stages.length ? 'complete' : 'paused';
        play.textContent = playing ? 'Pause' : current === stages.length ? 'Play again' : current < 0 ? 'Play' : 'Resume';
        const activeStage = stages[current]?.dataset.pipelineStage;
        const completedStages = new Set(stages.slice(0, Math.max(0, current)).map((stage) => stage.dataset.pipelineStage));
        stages.forEach((stage, index) => {
            const complete = index < current;
            const active = index === current;
            stage.classList.toggle('is-complete', complete);
            stage.classList.toggle('is-active', active);
            stage.querySelector('.pipeline-stage-state').textContent = complete ? 'Done' : active ? 'Running' : 'Ready';
            if (active) stage.setAttribute('aria-current', 'step');
            else stage.removeAttribute('aria-current');
        });
        codeLines.forEach((line) => {
            line.classList.toggle('is-active', line.dataset.codeStage === activeStage);
            line.classList.toggle('is-complete', completedStages.has(line.dataset.codeStage) && line.dataset.codeStage !== activeStage);
        });
        const completed = Math.max(0, current);
        progress.style.width = `${completed / stages.length * 100}%`;
        progressbar.setAttribute('aria-valuenow', String(completed));
        if (current === stages.length) {
            caption.textContent = 'Retrieval-ready knowledge';
            detail.textContent = 'Walkthrough complete. Operators can now search approved guidance by meaning; no live pipeline run was performed.';
        } else if (current >= 0) {
            [caption.textContent, detail.textContent] = narration[current];
            revealCode(activeStage);
        }
    }

    function schedule() {
        clearTimeout(timer);
        if (!playing) return;
        timer = setTimeout(() => {
            current = current === stages.length ? 0 : current + 1;
            if (current === stages.length && !loop.checked) playing = false;
            render();
            schedule();
        }, current === stages.length ? 5000 : 3600);
    }

    function pause() {
        playing = false;
        clearTimeout(timer);
        render();
    }

    function start(restart = false) {
        if (restart || current < 0 || current === stages.length) current = 0;
        playing = true;
        render();
        schedule();
    }

    function setOpen(open, { moveFocus = true } = {}) {
        drawer.hidden = !open;
        document.body.classList.toggle('debug-open', open);
        toggle.setAttribute('aria-expanded', String(open));
        toggle.textContent = open ? 'Close debug' : 'Debug';
        sessionStorage.setItem(storageKey, open ? 'true' : 'false');
        if (open) {
            if (moveFocus) heading.focus();
            if (!reducedMotion.matches && !document.hidden) start(true);
            else render();
        } else {
            pause();
            if (moveFocus) toggle.focus();
        }
    }

    toggle.hidden = false;
    toggle.addEventListener('click', () => setOpen(drawer.hidden));
    closeButton.addEventListener('click', () => setOpen(false));
    drawer.addEventListener('keydown', (event) => {
        if (event.key === 'Escape') setOpen(false);
    });
    play.addEventListener('click', () => playing ? pause() : start());
    replay.addEventListener('click', () => start(true));
    loop.addEventListener('change', () => {
        if (!loop.checked && current === stages.length) pause();
    });
    document.addEventListener('visibilitychange', () => {
        if (document.hidden && playing) pause();
    });
    reducedMotion.addEventListener('change', () => {
        if (reducedMotion.matches) pause();
    });

    const requested = new URLSearchParams(location.search).get('debug');
    if (requested === '1' || (requested !== '0' && sessionStorage.getItem(storageKey) === 'true')) {
        setOpen(true, { moveFocus: false });
    }
})();
