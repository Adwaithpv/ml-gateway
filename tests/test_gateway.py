import unittest
import os
import sys
from pathlib import Path

# Add the gateway folder to the Python path so we can import app.py
sys.path.append(str(Path(__file__).resolve().parent.parent / "gateway"))

# Mock threshold configurations before importing select_model
os.environ["FAST_THRESHOLD_MS"] = "80"
os.environ["MEDIUM_THRESHOLD_MS"] = "180"
os.environ["SMALL_WORD_THRESHOLD"] = "8"
os.environ["MEDIUM_WORD_THRESHOLD"] = "25"

from app import select_model

class TestGatewayRouting(unittest.TestCase):
    def test_routing_small_model_strict_latency(self):
        """Should route to small model when latency budget is highly restricted (< 80ms)."""
        text = "Hello there my friend"  # 4 words
        model = select_model(text, latency_budget_ms=50)
        self.assertEqual(model, "small")

    def test_routing_small_model_short_text(self):
        """Should route to small model when text is very short (< 8 words) even with high budget."""
        text = "Short text"  # 2 words
        model = select_model(text, latency_budget_ms=300)
        self.assertEqual(model, "small")

    def test_routing_medium_model_moderate_latency(self):
        """Should route to medium model when latency budget is moderately restricted (< 180ms)."""
        text = "This is a moderately long text message meant to test the medium model."  # 14 words
        model = select_model(text, latency_budget_ms=120)
        self.assertEqual(model, "medium")

    def test_routing_medium_model_moderate_length(self):
        """Should route to medium model when text is moderately complex (< 25 words)."""
        text = "This is a moderately long text message meant to test the medium model."  # 14 words
        model = select_model(text, latency_budget_ms=500)
        self.assertEqual(model, "medium")

    def test_routing_large_model_complex_request(self):
        """Should route to large model when text complexity is high and latency budget allows."""
        text = (
            "This is a very long and detailed text message that definitely exceeds "
            "twenty five words in length to ensure that the large model is chosen "
            "for maximum accuracy and processing power."
        )  # 31 words
        model = select_model(text, latency_budget_ms=300)
        self.assertEqual(model, "large")

if __name__ == "__main__":
    unittest.main()
