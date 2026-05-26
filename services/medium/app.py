"""FastAPI service for the Medium model (Logistic Regression + TF-IDF).

Exposes prediction and health-check endpoints on port 8002.
"""

import logging
import time
from pathlib import Path
from typing import Any

import joblib
import numpy as np
import uvicorn
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s | %(levelname)-8s | %(message)s",
)
logger = logging.getLogger(__name__)

MODEL_PATH = Path(__file__).resolve().parent / "model.pkl"
MODEL_NAME = "medium"
PORT = 8002

app = FastAPI(
    title="ML Gateway – Medium Model",
    description="Logistic Regression + TF-IDF spam classifier",
    version="1.0.0",
)

model: Any = None


class PredictRequest(BaseModel):
    """Prediction request payload."""
    text: str = Field(..., min_length=1, description="Text to classify")


class PredictResponse(BaseModel):
    """Prediction response payload."""
    label: str
    confidence: float
    latency_ms: float
    model: str


class HealthResponse(BaseModel):
    """Health-check response payload."""
    status: str
    model: str


@app.on_event("startup")
async def load_model() -> None:
    """Load the serialised model on application startup."""
    global model
    if not MODEL_PATH.exists():
        logger.error("Model file not found at %s – run train.py first.", MODEL_PATH)
        raise FileNotFoundError(f"Model not found: {MODEL_PATH}")
    model = joblib.load(MODEL_PATH)
    logger.info("Model '%s' loaded from %s", MODEL_NAME, MODEL_PATH)


@app.post("/predict", response_model=PredictResponse)
async def predict(request: PredictRequest) -> PredictResponse:
    """Return spam/ham prediction with confidence and latency."""
    if model is None:
        raise HTTPException(status_code=503, detail="Model not loaded")

    start = time.perf_counter()
    label: str = model.predict([request.text])[0]
    probas = model.predict_proba([request.text])[0]
    confidence = float(np.max(probas))
    latency_ms = (time.perf_counter() - start) * 1_000

    logger.info(
        "Prediction: label=%s  confidence=%.4f  latency=%.2fms",
        label, confidence, latency_ms,
    )
    return PredictResponse(
        label=label,
        confidence=round(confidence, 4),
        latency_ms=round(latency_ms, 2),
        model=MODEL_NAME,
    )


@app.get("/health", response_model=HealthResponse)
async def health() -> HealthResponse:
    """Liveness / readiness probe."""
    return HealthResponse(status="ok", model=MODEL_NAME)


if __name__ == "__main__":
    uvicorn.run("app:app", host="0.0.0.0", port=PORT, reload=False, log_level="info")
