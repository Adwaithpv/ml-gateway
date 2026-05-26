"""Training script for the Small model (Naive Bayes + TF-IDF).

Reads the UCI SMS Spam Collection dataset, trains a MultinomialNB pipeline,
and persists the trained model as model.pkl.
"""

import logging
import os
import sys
from pathlib import Path

import joblib
import numpy as np
import pandas as pd
from sklearn.feature_extraction.text import TfidfVectorizer
from sklearn.metrics import accuracy_score, classification_report
from sklearn.model_selection import train_test_split
from sklearn.naive_bayes import MultinomialNB
from sklearn.pipeline import Pipeline

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s | %(levelname)-8s | %(message)s",
)
logger = logging.getLogger(__name__)

DEFAULT_DATA_PATH = Path(__file__).resolve().parent / "../../data/spam.csv"
MODEL_DIR = Path(__file__).resolve().parent
MODEL_PATH = MODEL_DIR / "model.pkl"


def load_data(data_path: Path) -> pd.DataFrame:
    """Load and validate the SMS Spam Collection CSV."""
    logger.info("Loading data from %s", data_path)
    if not data_path.exists():
        logger.error("Data file not found: %s", data_path)
        sys.exit(1)

    df = pd.read_csv(
        data_path,
        encoding="latin-1",
        usecols=[0, 1],
        names=["label", "text"],
        header=0,
    )
    df = df.dropna(subset=["label", "text"])
    logger.info("Loaded %d samples (spam=%.1f%%)", len(df), (df["label"] == "spam").mean() * 100)
    return df


def train(data_path: Path | None = None) -> None:
    """Train the Naive Bayes pipeline and persist the model."""
    data_path = data_path or Path(os.environ.get("DATA_PATH", str(DEFAULT_DATA_PATH)))
    data_path = Path(data_path).resolve()

    df = load_data(data_path)

    X_train, X_test, y_train, y_test = train_test_split(
        df["text"], df["label"], test_size=0.2, random_state=42, stratify=df["label"]
    )

    pipeline = Pipeline(
        [
            ("tfidf", TfidfVectorizer(max_features=10_000, ngram_range=(1, 2), stop_words="english")),
            ("clf", MultinomialNB(alpha=0.1)),
        ]
    )

    logger.info("Training MultinomialNB pipeline …")
    pipeline.fit(X_train, y_train)

    y_pred = pipeline.predict(X_test)
    accuracy = accuracy_score(y_test, y_pred)
    logger.info("Test accuracy: %.4f", accuracy)
    logger.info("\n%s", classification_report(y_test, y_pred))

    joblib.dump(pipeline, MODEL_PATH)
    logger.info("Model saved to %s", MODEL_PATH)


if __name__ == "__main__":
    train()
