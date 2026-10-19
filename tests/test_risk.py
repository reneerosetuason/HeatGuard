"""Tests for PAGASA-based heat-risk classification."""

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import config  # noqa: E402
from services import risk  # noqa: E402


class ClassificationTests(unittest.TestCase):
    def test_category_boundaries(self):
        cases = [
            (-10.0, "safe", 0),
            (0.0, "safe", 0),
            (26.9, "safe", 0),
            (27.0, "caution", 1),
            (32.9, "caution", 1),
            (33.0, "extreme_caution", 2),
            (41.9, "extreme_caution", 2),
            (42.0, "danger", 3),
            (51.9, "danger", 3),
            (52.0, "extreme_danger", 4),
            (70.0, "extreme_danger", 4),
        ]
        for heat_index, key, level in cases:
            category = risk.classify_heat_index(heat_index)
            self.assertEqual(category["key"], key, msg=f"HI={heat_index}")
            self.assertEqual(category["level"], level, msg=f"HI={heat_index}")

    def test_classification_returns_recommendations(self):
        category = risk.classify_heat_index(45.0)
        self.assertTrue(category["recommendations"])
        self.assertIsInstance(category["recommendations"], list)

    def test_invalid_value_rejected(self):
        with self.assertRaises(risk.RiskClassificationError):
            risk.classify_heat_index(None)
        with self.assertRaises(risk.RiskClassificationError):
            risk.classify_heat_index(float("nan"))


class HelperTests(unittest.TestCase):
    def test_get_category(self):
        self.assertEqual(risk.get_category("danger")["level"], 3)
        self.assertIsNone(risk.get_category("does-not-exist"))

    def test_is_warning(self):
        self.assertTrue(risk.is_warning("caution"))
        self.assertTrue(risk.is_warning("extreme_danger"))
        self.assertFalse(risk.is_warning("safe"))
        self.assertFalse(risk.is_warning(None))
        self.assertFalse(risk.is_warning("unknown"))

    def test_public_categories_shape(self):
        categories = risk.public_categories()
        self.assertEqual(len(categories), len(config.RISK_CATEGORIES))
        for category in categories:
            for field in ("key", "label", "short_label", "level", "color", "summary"):
                self.assertIn(field, category)
            self.assertNotIn("recommendations", category)


class ConfigurationTests(unittest.TestCase):
    def test_thresholds_are_contiguous_and_ordered(self):
        categories = config.RISK_CATEGORIES
        self.assertIsNone(categories[0]["min_c"])
        self.assertIsNone(categories[-1]["max_c"])
        for index, category in enumerate(categories):
            self.assertEqual(category["level"], index)
            if index > 0:
                self.assertEqual(
                    category["min_c"], categories[index - 1]["max_c"]
                )

    def test_pagasa_ranges_match_configuration(self):
        by_key = {c["key"]: c for c in config.RISK_CATEGORIES}
        self.assertEqual(by_key["caution"]["min_c"], 27.0)
        self.assertEqual(by_key["caution"]["max_c"], 33.0)
        self.assertEqual(by_key["extreme_caution"]["min_c"], 33.0)
        self.assertEqual(by_key["extreme_caution"]["max_c"], 42.0)
        self.assertEqual(by_key["danger"]["min_c"], 42.0)
        self.assertEqual(by_key["danger"]["max_c"], 52.0)
        self.assertEqual(by_key["extreme_danger"]["min_c"], 52.0)


if __name__ == "__main__":
    unittest.main()
