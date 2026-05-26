import os
import sys
from pathlib import Path

# Add the gateway folder to the Python path so we can import app.py
sys.path.append(str(Path(__file__).resolve().parent.parent / "gateway"))

# Ensure dynamic thresholds are set in the environment for consistent testing
os.environ["FAST_THRESHOLD_MS"] = "80"
os.environ["MEDIUM_THRESHOLD_MS"] = "180"
os.environ["SMALL_WORD_THRESHOLD"] = "8"
os.environ["MEDIUM_WORD_THRESHOLD"] = "25"

from app import select_model


def test_short_text_routes_to_small():
    """
    Test that short text (word count < SMALL_WORD_THRESHOLD) always routes
    to the 'small' model, even if the latency budget is high.
    """
    # 5 words (less than threshold of 8)
    text = "This is a short text."
    
    # Even with a high latency budget, short text should go to small model
    model = select_model(text, latency_budget_ms=300.0)
    assert model == "small"


def test_low_latency_budget_routes_to_small():
    """
    Test that requests with a low latency budget (budget < FAST_THRESHOLD_MS)
    always route to the 'small' model, even if the text is long/complex.
    """
    # 31 words (well above medium threshold of 25)
    text = (
        "This is an exceptionally long and complex piece of text containing "
        "many words to ensure that under normal circumstances it would trigger "
        "the selection of the larger and more accurate model service."
    )
    
    # Strict latency budget (less than threshold of 80ms) triggers the small model
    model = select_model(text, latency_budget_ms=50.0)
    assert model == "small"


def test_medium_text_routes_to_medium():
    """
    Test that medium text (SMALL_WORD_THRESHOLD <= word count < MEDIUM_WORD_THRESHOLD)
    routes to the 'medium' model when the latency budget is generous.
    """
    # 12 words (between 8 and 25)
    text = "This is a moderately long text message meant to test routing."
    
    # Generous latency budget (>= 180ms)
    model = select_model(text, latency_budget_ms=300.0)
    assert model == "medium"


def test_moderate_latency_budget_routes_to_medium():
    """
    Test that moderate latency budget (FAST_THRESHOLD_MS <= budget < MEDIUM_THRESHOLD_MS)
    routes to the 'medium' model, even if the text is long/complex.
    """
    # 31 words (exceeds 25 words)
    text = (
        "This is an exceptionally long and complex piece of text containing "
        "many words to ensure that under normal circumstances it would trigger "
        "the selection of the larger and more accurate model service."
    )
    
    # Moderate latency budget (120ms is between 80ms and 180ms)
    model = select_model(text, latency_budget_ms=120.0)
    assert model == "medium"


def test_high_budget_and_long_text_routes_to_large():
    """
    Test that a high latency budget (budget >= MEDIUM_THRESHOLD_MS) combined
    with long, complex text (word count >= MEDIUM_WORD_THRESHOLD) successfully
    routes to the 'large' model for maximum accuracy.
    """
    # 31 words (exceeds 25 words)
    text = (
        "This is an exceptionally long and complex piece of text containing "
        "many words to ensure that under normal circumstances it would trigger "
        "the selection of the larger and more accurate model service."
    )
    
    # Generous latency budget (300ms is >= 180ms)
    model = select_model(text, latency_budget_ms=300.0)
    assert model == "large"
