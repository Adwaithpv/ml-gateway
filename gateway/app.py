"""
ML Gateway Service
Routes classification requests to the appropriate model service
based on latency budget and text complexity.
"""

import logging
import os
import time
from contextlib import asynccontextmanager
from typing import Optional

import httpx
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s | %(levelname)-8s | %(name)s | %(message)s",
)
logger = logging.getLogger("gateway")

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
SMALL_URL: str = os.getenv("SMALL_URL", "http://localhost:8001")
MEDIUM_URL: str = os.getenv("MEDIUM_URL", "http://localhost:8002")
LARGE_URL: str = os.getenv("LARGE_URL", "http://localhost:8003")

MODEL_ENDPOINTS: dict[str, str] = {
    "small": SMALL_URL,
    "medium": MEDIUM_URL,
    "large": LARGE_URL,
}

SERVICE_TIMEOUT_SECONDS: float = float(os.getenv("SERVICE_TIMEOUT_SECONDS", "30"))

# ---------------------------------------------------------------------------
# Pydantic schemas
# ---------------------------------------------------------------------------

class ClassifyRequest(BaseModel):
    """Incoming classification request."""
    text: str = Field(..., min_length=1, description="Text to classify")
    latency_budget_ms: float = Field(
        ..., gt=0, description="Maximum acceptable latency in milliseconds"
    )


class ClassifyResponse(BaseModel):
    """Response returned by the gateway after routing."""
    label: str
    confidence: float
    selected_model: str
    latency_ms: float = Field(description="Latency reported by the downstream service")
    gateway_latency_ms: float = Field(description="Total round-trip latency measured by the gateway")


class HealthResponse(BaseModel):
    """Simple health-check response."""
    status: str
    service: str


class ModelHealthStatus(BaseModel):
    """Health status for a single downstream model service."""
    model: str
    url: str
    status: str
    detail: Optional[str] = None


class ModelsResponse(BaseModel):
    """Aggregated health status of all downstream model services."""
    models: list[ModelHealthStatus]


# ---------------------------------------------------------------------------
# Application lifespan – manage the shared httpx.AsyncClient
# ---------------------------------------------------------------------------
_http_client: Optional[httpx.AsyncClient] = None


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Create and tear down the shared async HTTP client."""
    global _http_client
    _http_client = httpx.AsyncClient(
        timeout=httpx.Timeout(SERVICE_TIMEOUT_SECONDS),
        limits=httpx.Limits(
            max_connections=100,
            max_keepalive_connections=20,
            keepalive_expiry=30,
        ),
    )
    logger.info(
        "Gateway started – routing to small=%s, medium=%s, large=%s",
        SMALL_URL, MEDIUM_URL, LARGE_URL,
    )
    yield
    await _http_client.aclose()
    logger.info("Gateway shut down – HTTP client closed")


app = FastAPI(
    title="ML Gateway",
    description="Intelligent router for ML classification services",
    version="1.0.0",
    lifespan=lifespan,
)


def _get_client() -> httpx.AsyncClient:
    """Return the shared httpx client, raising if not initialised."""
    if _http_client is None:
        raise RuntimeError("HTTP client has not been initialised")
    return _http_client


# ---------------------------------------------------------------------------
# Routing logic
# ---------------------------------------------------------------------------

def select_model(text: str, latency_budget_ms: float) -> str:
    """
    Decide which model service should handle the request.

    Rules:
        1. small  – if latency_budget_ms < 80  OR word_count < 8
        2. medium – if latency_budget_ms < 180 OR word_count < 25
        3. large  – otherwise
    """
    word_count = len(text.split())
    if latency_budget_ms < 80 or word_count < 8:
        return "small"
    if latency_budget_ms < 180 or word_count < 25:
        return "medium"
    return "large"


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------

@app.post("/classify", response_model=ClassifyResponse)
async def classify(request: ClassifyRequest) -> ClassifyResponse:
    """
    Classify the supplied text by routing to the most appropriate
    downstream model service based on latency budget and text length.
    """
    selected = select_model(request.text, request.latency_budget_ms)
    base_url = MODEL_ENDPOINTS[selected]
    predict_url = f"{base_url}/predict"

    logger.info(
        "Routing request to %s (%s) – budget=%.1f ms, words=%d",
        selected, predict_url, request.latency_budget_ms, len(request.text.split()),
    )

    client = _get_client()
    gateway_start = time.perf_counter()

    try:
        response = await client.post(
            predict_url,
            json={"text": request.text},
        )
        response.raise_for_status()
    except httpx.TimeoutException:
        logger.error("Timeout calling %s at %s", selected, predict_url)
        raise HTTPException(
            status_code=504,
            detail=f"Timeout while waiting for the {selected} model service",
        )
    except httpx.ConnectError:
        logger.error("Connection refused for %s at %s", selected, predict_url)
        raise HTTPException(
            status_code=503,
            detail=f"The {selected} model service is unavailable at {base_url}",
        )
    except httpx.HTTPStatusError as exc:
        logger.error(
            "HTTP %d from %s: %s", exc.response.status_code, selected, exc.response.text,
        )
        raise HTTPException(
            status_code=502,
            detail=f"The {selected} model service returned HTTP {exc.response.status_code}",
        )
    except httpx.HTTPError as exc:
        logger.error("Unexpected HTTP error from %s: %s", selected, exc)
        raise HTTPException(
            status_code=502,
            detail=f"Unexpected error communicating with the {selected} model service",
        )

    gateway_latency_ms = (time.perf_counter() - gateway_start) * 1000
    data = response.json()

    return ClassifyResponse(
        label=data.get("label", "unknown"),
        confidence=data.get("confidence", 0.0),
        selected_model=selected,
        latency_ms=data.get("latency_ms", 0.0),
        gateway_latency_ms=round(gateway_latency_ms, 2),
    )


@app.get("/health", response_model=HealthResponse)
async def health() -> HealthResponse:
    """Return the gateway's own health status."""
    return HealthResponse(status="ok", service="gateway")


@app.get("/models", response_model=ModelsResponse)
async def models() -> ModelsResponse:
    """
    Concurrently check the health of every downstream model service
    and return an aggregated report.
    """
    client = _get_client()

    async def _check(name: str, base_url: str) -> ModelHealthStatus:
        try:
            resp = await client.get(f"{base_url}/health", timeout=5.0)
            resp.raise_for_status()
            return ModelHealthStatus(model=name, url=base_url, status="healthy")
        except httpx.TimeoutException:
            return ModelHealthStatus(
                model=name, url=base_url, status="unhealthy", detail="timeout",
            )
        except httpx.ConnectError:
            return ModelHealthStatus(
                model=name, url=base_url, status="unhealthy", detail="connection refused",
            )
        except httpx.HTTPStatusError as exc:
            return ModelHealthStatus(
                model=name, url=base_url, status="unhealthy",
                detail=f"HTTP {exc.response.status_code}",
            )
        except httpx.HTTPError as exc:
            return ModelHealthStatus(
                model=name, url=base_url, status="unhealthy", detail=str(exc),
            )

    import asyncio
    statuses = await asyncio.gather(
        *[_check(name, url) for name, url in MODEL_ENDPOINTS.items()]
    )

    return ModelsResponse(models=list(statuses))
