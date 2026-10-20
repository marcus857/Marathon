"""Offline reviewer demo: synthetic inputs, deterministic metrics, no AI or API."""

from __future__ import annotations

import json

from .contracts import WeeklyReviewRequest
from .metrics import derive_metrics, deterministic_fallback


def synthetic_request() -> WeeklyReviewRequest:
    """Build a fixed past week without files, environment settings, or user data."""

    week = "2025-01-06"
    workouts = [
        ("w-demo-recovery", "2025-01-07", "recovery", 3.0, 1_800),
        ("w-demo-tempo", "2025-01-09", "tempo", 4.0, 2_400),
    ]
    return WeeklyReviewRequest.model_validate({
        "schema_version": "weekly-review-input/v1",
        "request_id": "00000000-0000-4000-8000-000000000001",
        "reviewed_week_start": week,
        "generated_at": "2025-01-13T12:00:00Z",
        "timezone": "UTC",
        "week_state": "complete",
        # Deliberately incomplete: demonstrates the no-model safety path.
        "data_freshness": {"healthkit_sync_state": "unknown"},
        "plans": [{
            "week_start": week,
            "required_miles": 10.0,
            "required_runs": 3,
            "planned_miles_by_type": {"recovery": 3.0, "tempo": 3.0, "long": 4.0},
        }],
        "workouts": [{
            "evidence_id": evidence,
            "week_start": week,
            "started_on": started_on,
            "run_type": run_type,
            "distance_miles": miles,
            "duration_seconds": seconds,
            "source": "manual",
        } for evidence, started_on, run_type, miles, seconds in workouts],
    })


def demo_result() -> dict[str, object]:
    request = synthetic_request()
    response = deterministic_fallback(derive_metrics(request))
    return {
        "demo": {
            "synthetic_data": True,
            "ai_generated": False,
            "network_used": False,
            "reviewed_week_start": request.reviewed_week_start.isoformat(),
            "notice": "Synthetic offline demo. Metrics and fallback text are deterministic, not AI-generated.",
        },
        "response": response.model_dump(mode="json"),
    }


def main() -> None:
    print(json.dumps(demo_result(), indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
