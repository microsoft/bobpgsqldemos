from __future__ import annotations

import logging
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any, Protocol
from urllib.parse import urlencode

from fastapi import FastAPI, Form, Request
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates

from knowledge_hub.models import CATEGORIES, SEARCH_MODES, Article, SearchResult
from knowledge_hub.pipeline_view import RECONCILER_SQL, STAGES, render_pipeline_sql, summarize

PACKAGE_ROOT = Path(__file__).parent
templates = Jinja2Templates(directory=PACKAGE_ROOT / "templates")
logger = logging.getLogger(__name__)


class Repository(Protocol):
    def list_articles(self) -> list[Article]: ...

    def get_article(self, article_id: int) -> Article | None: ...

    def save_article(self, article_id: int | None, title: str, category: str, content: str, author: str) -> int: ...

    def delete_article(self, article_id: int) -> bool: ...

    def reset_demo(self) -> None: ...

    def search(self, query: str, mode: str) -> list[SearchResult]: ...

    def pipeline_status(self) -> dict[str, Any]: ...

    def freshness(self) -> list[dict[str, Any]]: ...

    def vector_index_definition(self) -> str | None: ...


def _home_url(query: str = "", mode: str = "vector", **extra: object) -> str:
    parameters = {key: value for key, value in {"q": query, "mode": mode, **extra}.items() if value not in ("", None)}
    return "/?" + urlencode(parameters) if parameters else "/"


def create_app(repository: Repository | None = None) -> FastAPI:
    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        database = None
        if repository is None:
            from knowledge_hub.database import Database
            from knowledge_hub.repository import KnowledgeHubRepository

            database = Database()
            database.open()
            app.state.repository = KnowledgeHubRepository(database)
        else:
            app.state.repository = repository
        yield
        if database is not None:
            database.close()

    app = FastAPI(title="Caldova Knowledge Hub", lifespan=lifespan)
    app.mount("/static", StaticFiles(directory=PACKAGE_ROOT / "static"), name="static")

    @app.get("/", response_class=HTMLResponse)
    def home(
        request: Request,
        q: str = "",
        mode: str = "vector",
        edit: int | None = None,
        new: int = 0,
        watch: int | None = None,
        error: str = "",
    ) -> HTMLResponse:
        current: Repository = request.app.state.repository
        mode = mode if mode in SEARCH_MODES else "vector"
        query = q.strip()[:300]
        results: list[SearchResult] = []
        messages = [error] if error else []
        try:
            articles = current.list_articles()
            if query:
                results = current.search(query, mode)
            status = current.pipeline_status()
            code_lines = render_pipeline_sql(status.get("pipeline"), current.vector_index_definition())
        except Exception:
            logger.exception("Knowledge Hub page failed to load")
            articles, status, code_lines = [], {}, render_pipeline_sql(None, None)
            messages.append("HorizonDB is unavailable. Check the connection settings and firewall, then refresh.")
        editing = next((article for article in articles if article.article_id == edit), None)
        return templates.TemplateResponse(
            request=request,
            name="index.html",
            context={
                "query": query,
                "mode": mode,
                "modes": SEARCH_MODES,
                "results": results,
                "articles": articles,
                "categories": CATEGORIES,
                "editing": editing,
                "show_editor": bool(new) or editing is not None,
                "watch": watch,
                "messages": messages,
                "code_lines": code_lines,
                "reconciler_sql": RECONCILER_SQL,
                "stages": STAGES,
                "initial_status": summarize(status) if status else None,
            },
        )

    @app.post("/articles")
    def save_article(
        request: Request,
        title: str = Form(min_length=3, max_length=160),
        category: str = Form(),
        content: str = Form(min_length=20, max_length=20000),
        author: str = Form(default="", max_length=80),
        article_id: int | None = Form(default=None),
        q: str = Form(default=""),
        mode: str = Form(default="vector"),
    ) -> RedirectResponse:
        if category not in CATEGORIES:
            return RedirectResponse(_home_url(q, mode, error="Choose a valid category."), status_code=303)
        current: Repository = request.app.state.repository
        try:
            saved = current.save_article(article_id, title, category, content, author)
        except Exception:
            logger.exception("Saving article failed")
            return RedirectResponse(_home_url(q, mode, error="The article could not be saved."), status_code=303)
        return RedirectResponse(_home_url(q, mode, watch=saved), status_code=303)

    @app.post("/articles/{article_id}/delete")
    def delete_article(
        request: Request,
        article_id: int,
        q: str = Form(default=""),
        mode: str = Form(default="vector"),
    ) -> RedirectResponse:
        current: Repository = request.app.state.repository
        try:
            current.delete_article(article_id)
        except Exception:
            logger.exception("Deleting article failed")
            return RedirectResponse(_home_url(q, mode, error="The article could not be deleted."), status_code=303)
        return RedirectResponse(_home_url(q, mode), status_code=303)

    @app.post("/reset")
    def reset(request: Request) -> RedirectResponse:
        current: Repository = request.app.state.repository
        try:
            current.reset_demo()
        except Exception:
            logger.exception("Reset failed")
            return RedirectResponse(_home_url(error="The demo could not be reset."), status_code=303)
        return RedirectResponse("/", status_code=303)

    @app.get("/api/status")
    def api_status(request: Request) -> JSONResponse:
        current: Repository = request.app.state.repository
        try:
            payload = summarize(current.pipeline_status())
            payload["articles"] = current.freshness()
        except Exception:
            logger.exception("Pipeline status failed")
            return JSONResponse({"error": "HorizonDB is unavailable."}, status_code=503)
        return JSONResponse(payload, headers={"Cache-Control": "no-store"})

    @app.get("/health")
    def health() -> dict[str, str]:
        return {"status": "ok"}

    return app
