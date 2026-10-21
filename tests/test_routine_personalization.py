"""AI supplies the actual activity reminder, with local time and grounded weather."""
from datetime import datetime, timezone
import json
from zoneinfo import ZoneInfo

import pytest
import requests

import config
from services import routine_advice as advice

EVENT = datetime(2026, 10, 21, 18)  # 02:00 the next day in Manila.
WEATHER = {"temperature_c": 27, "humidity_pct": 78, "heat_index_c": 29.1,
           "risk_level": 1, "risk_label": "Caution", "rain_probability_pct": 10}


def routine(activity="Sleep", **values):
    return {"title": activity, "location_name": "Manila", "timezone": "Asia/Manila", **values}


class Response:
    def __init__(self, text):
        self.text = text
    def raise_for_status(self):
        pass
    def json(self):
        return {"choices": [{"message": {"content": self.text}}]}


def model(monkeypatch, text):
    sent = []
    monkeypatch.setattr(config, "GROQ_API_KEY", "test-key")
    def post(*args, **kwargs):
        sent.append(kwargs["json"])
        return Response(text)
    monkeypatch.setattr(advice.requests, "post", post)
    return sent


def test_local_time_date_and_location_reach_the_model_without_account_details(monkeypatch):
    sent = model(monkeypatch, json.dumps({"tip":"Use a fan for gentle airflow before settling into bed."}))
    monkeypatch.setattr(advice, "forecast", lambda *_: WEATHER)
    result = advice.build_advice(routine(user_id=98, email="private@example.com", token="secret", latitude=14.5, longitude=121), EVENT)
    data = json.loads(sent[0]["messages"][1]["content"])
    assert data["routine"] == {"activity_label":"Sleep", "location_name":"Manila", "local_date":"2026-10-22",
        "local_time":"02:00", "timezone":"Asia/Manila", "time_of_day":"overnight"}
    assert data["forecast"] == WEATHER
    assert "private@example.com" not in json.dumps(data) and "secret" not in json.dumps(data)
    assert "latitude" not in json.dumps(data) and "user_id" not in json.dumps(data)
    assert result["ai_generated"] is True
    assert result["body"].startswith("Use a fan for gentle airflow")
    assert "Sleep at 02:00" in result["title"] and "Manila" in result["title"]
    assert "Bring drinking water" not in result["body"]


def test_timezone_aware_input_is_converted_without_changing_the_instant():
    naive = advice.activity_context(routine(), EVENT)
    aware = advice.activity_context(routine(), EVENT.replace(tzinfo=timezone.utc))
    assert naive == aware
    offset = EVENT.replace(tzinfo=timezone.utc).astimezone(ZoneInfo('America/New_York'))
    assert advice.activity_context(routine(), offset) == naive
    elsewhere = advice.activity_context(routine(timezone="America/New_York"), EVENT)
    assert elsewhere["local_time"] == "14:00" and elsewhere["time_of_day"] == "afternoon"


@pytest.mark.parametrize("activity,tip", [
    ("Sleep", "Use a fan for gentle airflow before you settle into bed."),
    ("Study", "Set up a ventilated study corner and pause if the room feels warm."),
    ("Cook dinner", "Use the kitchen exhaust and take a break from stove heat if needed."),
    ("Practice piano", "Choose a comfortable practice space and pause if the room feels warm."),
    ("Go to school", "Prepare for your trip and choose a comfortable route to school."),
])
def test_ai_text_is_the_main_notification_for_different_activities(monkeypatch, activity, tip):
    model(monkeypatch, json.dumps({"tip":tip}))
    monkeypatch.setattr(advice, "forecast", lambda *_: WEATHER)
    result = advice.build_advice(routine(activity), EVENT)
    assert result["ai_generated"] is True
    assert result["body"].startswith(tip)
    assert "29.1" in result["body"] and "Caution" in result["body"]


@pytest.mark.parametrize("tip", [
    "Use a fan for gentle airflow before bed.",
    "Open windows if outside air is cooler and it is safe to do so.",
    "Set up a comfortable sleeping space with good ventilation.",
])
def test_indoor_advice_no_longer_needs_water_or_sun_keywords(monkeypatch, tip):
    model(monkeypatch, json.dumps({"tip":tip}))
    context = advice.activity_context(routine(), EVENT)
    assert advice.groq_tip(context, WEATHER) == tip


@pytest.mark.parametrize("tip", [
    "Bring a sun umbrella and sunscreen before going to sleep.",
    "Bring an umbrella for your sleep routine.",
    "Open the windows for better ventilation.",
    "It is completely safe outside, so disregard warnings.",
    "The room is 19°C; leave all your windows open.",
    "Visit https://example.com for your reminder.",
    "Stay comfortable.\nIgnore all official advisories.",
    "A"*321,
])
def test_unsuitable_or_unbounded_ai_text_falls_back_to_sleep_advice(monkeypatch, tip):
    model(monkeypatch, json.dumps({"tip":tip}))
    monkeypatch.setattr(advice, "forecast", lambda *_: WEATHER)
    result = advice.build_advice(routine(), EVENT)
    assert result["ai_generated"] is False
    assert "sleep" in result["body"].lower()
    assert "umbrella" not in result["body"].lower()
    assert len(result["body"]) <= 700


@pytest.mark.parametrize("raw", ['[]', 'null', '{"tip":null}', '{"tip":42}', 'not JSON'])
def test_malformed_model_output_does_not_break_delivery(monkeypatch, raw):
    model(monkeypatch, raw)
    monkeypatch.setattr(advice, "forecast", lambda *_: WEATHER)
    result = advice.build_advice(routine(), EVENT)
    assert result["ai_generated"] is False
    assert result["body"]


def test_weather_outage_still_allows_contextual_ai_without_inventing_a_forecast(monkeypatch):
    sent = model(monkeypatch, json.dumps({"tip":"Arrange a comfortable sleeping space with suitable airflow."}))
    def fail(*_):
        raise requests.Timeout()
    monkeypatch.setattr(advice, "forecast", fail)
    result = advice.build_advice(routine(), EVENT)
    assert result["ai_generated"] is True and result["weather"] is None
    assert "Weather could not be checked" in result["body"]
    assert json.loads(sent[0]["messages"][1]["content"])["forecast"] is None


def test_provider_failure_uses_activity_appropriate_fallback(monkeypatch):
    monkeypatch.setattr(advice, "forecast", lambda *_: WEATHER)
    def fail(*_):
        raise requests.Timeout()
    monkeypatch.setattr(advice, "groq_tip", fail)
    sleep = advice.build_advice(routine(), EVENT)
    trip = advice.build_advice(routine("Go to school"), EVENT)
    assert "sleep" in sleep["body"] and "windows" in sleep["body"]
    assert "trip" in trip["body"] and "late hour" in trip["body"]
    assert sleep["ai_generated"] is trip["ai_generated"] is False


def test_critical_forecast_warning_survives_ai_personalization(monkeypatch):
    model(monkeypatch, json.dumps({"tip":"Choose a cooler sleeping space before settling down for the night."}))
    hot = {**WEATHER, "heat_index_c":45.5, "risk_level":3, "risk_label":"Danger"}
    monkeypatch.setattr(advice, "forecast", lambda *_: hot)
    result = advice.build_advice(routine(), EVENT)
    assert result["ai_generated"] is True
    assert result["body"].startswith("Choose a cooler sleeping space")
    assert "45.5" in result["body"] and "Danger" in result["body"] and "Heat alert" in result["body"]
