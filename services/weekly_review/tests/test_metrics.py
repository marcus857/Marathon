from __future__ import annotations

from app.contracts import HealthKitSyncState, ReviewStatus, WeeklyReviewRequest
from app.metrics import derive_metrics, deterministic_fallback

import pytest


def test_complete_week_derives_metrics_and_model_payload_is_minimized(complete_request) -> None:
    context = derive_metrics(complete_request)

    assert context.status is ReviewStatus.COMPLETE
    assert context.can_call_model
    assert context.metric("m.current.actual_miles").value == 7.0
    assert context.metric("m.current.actual_runs").value == 2
    assert context.metric("m.current.planned_miles").value == 20.0
    assert context.metric("m.hr.coverage").value == 1.0

    provider_payload = context.provider_payload()
    serialized = str(provider_payload).lower()
    for forbidden in ("healthkituuid", "sharedroutepoints", "userid", "displayname", "notes"):
        assert forbidden not in serialized


def test_incomplete_healthkit_data_skips_provider(complete_request) -> None:
    request = complete_request.model_copy(
        update={
            "data_freshness": complete_request.data_freshness.model_copy(
                update={"healthkit_sync_state": HealthKitSyncState.NOT_AUTHORIZED}
            )
        }
    )

    context = derive_metrics(request)
    response = deterministic_fallback(context)

    assert context.status is ReviewStatus.INSUFFICIENT_DATA
    assert not context.can_call_model
    assert response.fallback_used
    assert response.status is ReviewStatus.INSUFFICIENT_DATA
    assert "healthkit_not_authorized" in response.data_quality_codes


def test_contract_rejects_identity_and_route_fields(complete_request) -> None:
    payload = complete_request.model_dump(mode="json")
    payload["user_id"] = "must-not-be-accepted"
    payload["workouts"][0]["shared_route_points"] = [40.0, -105.0]

    try:
        WeeklyReviewRequest.model_validate(payload)
    except Exception as error:
        message = str(error)
        assert "user_id" in message
        assert "shared_route_points" in message
    else:
        raise AssertionError("privacy-sensitive fields must be rejected")


def test_contract_rejects_free_text_plan_data(complete_request) -> None:
    payload = complete_request.model_dump(mode="json")
    payload["plans"][0]["plan_note"] = "Do not send user-authored plan text"

    try:
        WeeklyReviewRequest.model_validate(payload)
    except Exception as error:
        assert "plan_note" in str(error)
    else:
        raise AssertionError("free-text plan data must be rejected")


def test_contract_rejects_out_of_week_workouts(complete_request) -> None:
    payload = complete_request.model_dump(mode="json")
    payload["workouts"][0]["started_on"] = "2026-10-25"

    try:
        WeeklyReviewRequest.model_validate(payload)
    except Exception as error:
        assert "started_on" in str(error)
    else:
        raise AssertionError("out-of-week workouts must be rejected")


def test_contract_rejects_zone_duration_larger_than_workout(complete_request) -> None:
    payload = complete_request.model_dump(mode="json")
    payload["workouts"][0]["zone_seconds"] = {
        "z1": 1_800,
        "z2": 1,
        "z3": 0,
        "z4": 0,
        "z5": 0,
    }

    try:
        WeeklyReviewRequest.model_validate(payload)
    except Exception as error:
        assert "zone_seconds cannot exceed duration_seconds" in str(error)
    else:
        raise AssertionError("impossible aggregate zone duration must be rejected")


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("week_state", "in_progress"),
        ("generated_at", "2026-10-18T17:00:00-06:00"),
        ("reviewed_week_start", "2026-10-26"),
    ],
)
def test_contract_rejects_incoherent_week_state(complete_request, field, value):
    payload = complete_request.model_dump(mode="json")
    payload[field] = value
    with pytest.raises(ValueError):
        WeeklyReviewRequest.model_validate(payload)


@pytest.mark.parametrize(
    ("imported_at", "expected_code"),
    [
        (None, "healthkit_import_timestamp_missing"),
        ("2026-10-18T23:59:59-06:00", "healthkit_import_does_not_cover_week"),
    ],
)
def test_incomplete_import_coverage_skips_model(complete_request, imported_at, expected_code):
    payload = complete_request.model_dump(mode="json")
    payload["data_freshness"]["last_successful_import_at"] = imported_at
    context = derive_metrics(WeeklyReviewRequest.model_validate(payload))
    assert not context.can_call_model
    assert context.status is ReviewStatus.INSUFFICIENT_DATA
    assert expected_code in context.data_quality_codes


def test_current_week_with_stale_import_skips_model(complete_request):
    payload = complete_request.model_dump(mode="json")
    payload["generated_at"] = "2026-10-18T17:00:00-06:00"
    payload["week_state"] = "in_progress"
    payload["data_freshness"]["last_successful_import_at"] = "2026-10-16T17:00:00-06:00"
    context = derive_metrics(WeeklyReviewRequest.model_validate(payload))
    assert not context.can_call_model
    assert "healthkit_import_stale" in context.data_quality_codes


def test_note_presence_without_reason_still_limits_review(complete_request):
    payload = complete_request.model_dump(mode="json")
    payload["break_context"]["has_note"] = True
    context = derive_metrics(WeeklyReviewRequest.model_validate(payload))
    assert not context.can_call_model
    assert "break_context_present" in context.data_quality_codes


def test_current_week_cannot_contain_future_workouts(complete_request):
    payload = complete_request.model_dump(mode="json")
    payload["generated_at"] = "2026-10-14T17:00:00-06:00"
    payload["week_state"] = "in_progress"
    payload["data_freshness"]["last_successful_import_at"] = "2026-10-14T16:55:00-06:00"
    with pytest.raises(ValueError, match="started_on cannot be after"):
        WeeklyReviewRequest.model_validate(payload)
