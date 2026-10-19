"""Heat-risk classification using the central PAGASA thresholds."""

from __future__ import annotations

import math

import config


class RiskClassificationError(ValueError):
    """Raised when a heat index cannot be classified."""


def _validate_configuration() -> None:
    categories = config.RISK_CATEGORIES
    if not categories:
        raise RiskClassificationError("No heat-risk categories configured")
    if categories[0]["min_c"] is not None:
        raise RiskClassificationError("The first risk category needs min_c=None")
    if categories[-1]["max_c"] is not None:
        raise RiskClassificationError("The last risk category needs max_c=None")
    for index, category in enumerate(categories):
        if category["level"] != index:
            raise RiskClassificationError(
                "Risk category levels must be consecutive integers starting at 0"
            )
        if index > 0 and category["min_c"] != categories[index - 1]["max_c"]:
            raise RiskClassificationError(
                "Risk category thresholds must be contiguous"
            )


_validate_configuration()


def classify_heat_index(heat_index_c: float) -> dict:
    """Return the configured risk category for a heat-index value."""

    try:
        value = float(heat_index_c)
    except (TypeError, ValueError) as exc:
        raise RiskClassificationError("Heat index must be numeric") from exc
    if not math.isfinite(value):
        raise RiskClassificationError("Heat index must be a finite number")

    for category in config.RISK_CATEGORIES:
        maximum = category["max_c"]
        if maximum is None or value < maximum:
            return {
                **category,
                "recommendations": list(category["recommendations"]),
            }

    # The final category has max_c=None, so this is unreachable unless the
    # configuration is malformed.
    raise RiskClassificationError("No matching heat-risk category")


def get_category(risk_key: str) -> dict | None:
    for category in config.RISK_CATEGORIES:
        if category["key"] == risk_key:
            return {
                **category,
                "recommendations": list(category["recommendations"]),
            }
    return None


def is_warning(risk_key: str | None) -> bool:
    category = get_category(risk_key or "")
    return bool(category and int(category["level"]) >= 1)


def public_categories() -> list[dict]:
    """Threshold data safe to send to the browser."""

    return [
        {
            "key": category["key"],
            "label": category["label"],
            "short_label": category["short_label"],
            "level": category["level"],
            "min_c": category["min_c"],
            "max_c": category["max_c"],
            "color": category["color"],
            "summary": category["summary"],
        }
        for category in config.RISK_CATEGORIES
    ]
