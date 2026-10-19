"""Heat-index calculation.

HeatGuard calculates the heat index with the Rothfusz regression used by the
US National Weather Service (NWS) / National Oceanic and Atmospheric
Administration (NOAA), including the low-humidity and high-humidity
adjustments. Open-Meteo supplies temperature and relative humidity; it does
not supply a heat index for these coordinates, so the value is calculated
rather than measured.

Reference:
https://www.weather.gov/ama/heatindex
https://www.wpc.ncep.noaa.gov/html/heatindex_equation.shtml
"""

from __future__ import annotations

import math


class HeatIndexError(ValueError):
    """Raised when temperature or humidity inputs are outside valid ranges."""


def fahrenheit_to_celsius(value_f: float) -> float:
    return (value_f - 32.0) * 5.0 / 9.0


def celsius_to_fahrenheit(value_c: float) -> float:
    return (value_c * 9.0 / 5.0) + 32.0


def calculate_heat_index_c(temperature_c: float, humidity_pct: float) -> float:
    """Return the heat index in degrees Celsius.

    Temperature must be between -50 and 60 C and relative humidity between
    0 and 100 percent. The result is rounded to one decimal place.
    """

    try:
        temperature_c = float(temperature_c)
        humidity_pct = float(humidity_pct)
    except (TypeError, ValueError) as exc:
        raise HeatIndexError("Temperature and humidity must be numeric") from exc

    if not math.isfinite(temperature_c) or not math.isfinite(humidity_pct):
        raise HeatIndexError("Temperature and humidity must be finite numbers")
    if not -50.0 <= temperature_c <= 60.0:
        raise HeatIndexError("Temperature is outside the supported range")
    if not 0.0 <= humidity_pct <= 100.0:
        raise HeatIndexError("Relative humidity must be between 0 and 100%")

    t = celsius_to_fahrenheit(temperature_c)
    rh = humidity_pct

    # NWS guidance: use the simpler Steadman formula when the average
    # heat-index estimate is below 80 F, otherwise use the Rothfusz
    # regression with its adjustments.
    simple_hi = 0.5 * (
        t + 61.0 + ((t - 68.0) * 1.2) + (rh * 0.094)
    )

    if simple_hi < 80.0:
        heat_index_f = simple_hi
    else:
        heat_index_f = (
            -42.379
            + (2.04901523 * t)
            + (10.14333127 * rh)
            - (0.22475541 * t * rh)
            - (0.00683783 * t * t)
            - (0.05481717 * rh * rh)
            + (0.00122874 * t * t * rh)
            + (0.00085282 * t * rh * rh)
            - (0.00000199 * t * t * rh * rh)
        )

        if rh < 13.0 and 80.0 <= t <= 112.0:
            adjustment = (
                (13.0 - rh) / 4.0
                * math.sqrt((17.0 - abs(t - 95.0)) / 17.0)
            )
            heat_index_f -= adjustment
        elif rh > 85.0 and 80.0 <= t <= 87.0:
            adjustment = ((rh - 85.0) / 10.0) * ((87.0 - t) / 5.0)
            heat_index_f += adjustment

    return round(fahrenheit_to_celsius(heat_index_f), 1)
