from datetime import UTC, datetime
from typing import Any

import pytest
from fastapi.testclient import TestClient

from knowledge_hub.app import create_app
from knowledge_hub.models import Article, SearchResult
from test_pipeline_view import INDEX, PIPELINE


class FakeRepository:
    def __init__(self) -> None:
        self.saved: list[tuple] = []
        self.deleted: list[int] = []
        self.reset_count = 0
        self.searches: list[tuple[str, str]] = []
        self.fail = False
        self.articles = [
            Article(1, "Reefer unit failure response", "Handling procedure", "If a refrigerated trailer stops cooling...",
                    "Caldova Operations", datetime(2026, 10, 16, tzinfo=UTC), 2, 2, True),
            Article(2, "Lithium battery acceptance", "Handling procedure", "Shipments containing lithium cells...",
                    "Caldova Operations", datetime(2026, 10, 16, tzinfo=UTC), 1, 0, False),
        ]

    def list_articles(self) -> list[Article]:
        if self.fail:
            raise RuntimeError("database down")
        return self.articles

    def get_article(self, article_id: int) -> Article | None:
        return next((article for article in self.articles if article.article_id == article_id), None)

    def save_article(self, article_id, title, category, content, author) -> int:
        self.saved.append((article_id, title, category, content, author))
        return article_id or 99

    def delete_article(self, article_id: int) -> bool:
        self.deleted.append(article_id)
        return True

    def reset_demo(self) -> None:
        self.reset_count += 1

    def search(self, query: str, mode: str) -> list[SearchResult]:
        self.searches.append((query, mode))
        return [SearchResult(1, "Reefer unit failure response", "Handling procedure", "<b>stops cooling</b>", 0.459,
                             "cosine similarity", vector_rank=1, keyword_rank=None)]

    def pipeline_status(self) -> dict[str, Any]:
        return {
            "checked_at": "2026-10-16T21:00:20+00:00",
            "pipeline": PIPELINE,
            "runs": [{"id": 24, "status": "completed", "rows_processed": 1, "error": None,
                      "started_at": "2026-10-16T21:00:00+00:00", "completed_at": "2026-10-16T21:00:02+00:00",
                      "instance_id": "abc12345"}],
            "nodes": [],
            "freshness": {"articles": 2, "searchable_articles": 1, "expected_chunks": 3, "embedded_chunks": 2},
            "reconciler": {"id": "57c29dcf", "status": "running", "iteration": 3, "last_tick": "2026-10-16T21:00:15+00:00"},
            "sink_rows": 3,
        }

    def freshness(self) -> list[dict[str, Any]]:
        return [{"article_id": 2, "expected_chunks": 1, "embedded_chunks": 1, "searchable": True}]

    def vector_index_definition(self) -> str | None:
        return INDEX


@pytest.fixture
def repository() -> FakeRepository:
    return FakeRepository()


@pytest.fixture
def client(repository: FakeRepository) -> TestClient:
    with TestClient(create_app(repository)) as test_client:
        yield test_client


def test_home_shows_app_and_live_pipeline_side_by_side(client: TestClient) -> None:
    response = client.get("/")

    assert response.status_code == 200
    body = response.text
    assert "Find the right procedure" in body
    assert 'id="pipeline-pane"' in body
    assert 'aria-expanded="true"' in body
    assert "Searchable · 2 chunks" in body
    assert "Embedding 0/1" in body
    assert "-- Live definition, rendered from ai.pipelines" in body
    for stage in ("source", "chunk", "embed", "sink", "trigger", "index"):
        assert f'data-code-stage="{stage}"' in body
    assert "df.loop(" in body
    assert body.count('class="stage"') == 7
    assert '"run_status": "completed"' in body


@pytest.mark.parametrize("mode", ["vector", "keyword", "hybrid"])
def test_search_modes(client: TestClient, repository: FakeRepository, mode: str) -> None:
    response = client.get("/", params={"q": "truck fridge died", "mode": mode})

    assert response.status_code == 200
    assert repository.searches == [("truck fridge died", mode)]
    assert "Reefer unit failure response" in response.text
    assert "&lt;b&gt;stops cooling&lt;/b&gt;" in response.text
    assert 'mode-tab is-active' in response.text


def test_unknown_mode_falls_back_to_vector(client: TestClient, repository: FakeRepository) -> None:
    client.get("/", params={"q": "battery", "mode": "drop table"})

    assert repository.searches == [("battery", "vector")]


def test_save_article_redirects_to_watch(client: TestClient, repository: FakeRepository) -> None:
    response = client.post(
        "/articles",
        data={"title": "Hazmat placards", "category": "Handling procedure",
              "content": "Confirm placards on all four sides match the papers.", "author": "Ops", "q": "hazmat", "mode": "hybrid"},
        follow_redirects=False,
    )

    assert response.status_code == 303
    assert response.headers["location"] == "/?q=hazmat&mode=hybrid&watch=99"
    assert repository.saved == [(None, "Hazmat placards", "Handling procedure", "Confirm placards on all four sides match the papers.", "Ops")]


def test_save_rejects_unknown_category(client: TestClient, repository: FakeRepository) -> None:
    response = client.post(
        "/articles",
        data={"title": "Bad", "category": "Gossip", "content": "This category is not allowed at all."},
        follow_redirects=False,
    )

    assert response.status_code == 303
    assert "error=" in response.headers["location"]
    assert repository.saved == []


def test_edit_opens_editor_with_article(client: TestClient) -> None:
    response = client.get("/", params={"edit": 1})

    assert "Edit article" in response.text
    assert 'name="article_id" value="1"' in response.text
    assert "data-open" in response.text


def test_delete_and_reset(client: TestClient, repository: FakeRepository) -> None:
    assert client.post("/articles/2/delete", follow_redirects=False).status_code == 303
    assert client.post("/reset", follow_redirects=False).status_code == 303

    assert repository.deleted == [2]
    assert repository.reset_count == 1


def test_status_api(client: TestClient) -> None:
    response = client.get("/api/status")

    assert response.status_code == 200
    assert response.headers["cache-control"] == "no-store"
    payload = response.json()
    assert payload["run"]["id"] == 24
    assert payload["reconciler"]["iteration"] == 3
    assert payload["articles"] == [{"article_id": 2, "expected_chunks": 1, "embedded_chunks": 1, "searchable": True}]


def test_database_outage_degrades_gracefully(client: TestClient, repository: FakeRepository) -> None:
    repository.fail = True

    response = client.get("/")

    assert response.status_code == 200
    assert "HorizonDB is unavailable" in response.text


def test_static_assets(client: TestClient) -> None:
    script = client.get("/static/app.js")
    stylesheet = client.get("/static/app.css")

    assert script.status_code == 200 and "pg_durable" in script.text and "/api/status" in script.text
    assert stylesheet.status_code == 200 and ".pipeline-pane" in stylesheet.text
