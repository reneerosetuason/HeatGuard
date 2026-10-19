"""Tests for the Rothfusz heat-index calculation."""

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from services.heat_index import (  # noqa: E402
    HeatIndexError,
    calculate_heat_index_c,
    celsius_to_fahrenheit,
    fahrenheit_to_celsius,
)


class ConversionTests(unittest.TestCase):
    def test_fahrenheit_celsius_round_trip(self):
        for value in (-40.0, 0.0, 32.0, 98.6, 212.0):
            self.assertAlmostEqual(
                fahrenheit_to_celsius(celsius_to_fahrenheit(value)), value, places=6
            )

    def test_known_conversions(self):
        self.assertAlmostEqual(celsius_to_fahrenheit(0.0), 32.0, places=6)
        self.assertAlmostEqual(celsius_to_fahrenheit(100.0), 212.0, places=6)
        self.assertAlmostEqual(fahrenheit_to_celsius(32.0), 0.0, places=6)


class HeatIndexValueTests(unittest.TestCase):
    def test_nws_reference_example(self):
        # NWS example: 90 F (32.22 C) and 70% RH is about 106 F (41 C).
        result = calculate_heat_index_c(32.2, 70.0)
        self.assertAlmostEqual(result, 41.1, delta=1.0)

    def test_low_temperature_uses_simple_formula(self):
        # 20 C (68 F) and 50% RH -> about 66.9 F (19.4 C).
        result = calculate_heat_index_c(20.0, 50.0)
        self.assertAlmostEqual(result, 19.4, delta=0.3)

    def test_high_humidity_adjustment(self):
        # 85 F (29.44 C) and 90% RH includes the high-humidity correction.
        result = calculate_heat_index_c(29.4, 90.0)
        self.assertAlmostEqual(result, 38.8, delta=1.0)

    def test_humidity_increases_heat_index(self):
        low = calculate_heat_index_c(33.0, 40.0)
        high = calculate_heat_index_c(33.0, 80.0)
        self.assertGreater(high, low)

    def test_temperature_increases_heat_index(self):
        cooler = calculate_heat_index_c(30.0, 70.0)
        hotter = calculate_heat_index_c(36.0, 70.0)
        self.assertGreater(hotter, cooler)

    def test_result_is_rounded_to_one_decimal(self):
        result = calculate_heat_index_c(31.7, 63.4)
        self.assertEqual(round(result, 1), result)


class HeatIndexValidationTests(unittest.TestCase):
    def test_temperature_out_of_range(self):
        with self.assertRaises(HeatIndexError):
            calculate_heat_index_c(100.0, 50.0)
        with self.assertRaises(HeatIndexError):
            calculate_heat_index_c(-80.0, 50.0)

    def test_humidity_out_of_range(self):
        with self.assertRaises(HeatIndexError):
            calculate_heat_index_c(30.0, 120.0)
        with self.assertRaises(HeatIndexError):
            calculate_heat_index_c(30.0, -5.0)

    def test_non_numeric_input(self):
        with self.assertRaises(HeatIndexError):
            calculate_heat_index_c("hot", 50.0)
        with self.assertRaises(HeatIndexError):
            calculate_heat_index_c(30.0, None)


if __name__ == "__main__":
    unittest.main()
