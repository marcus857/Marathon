"""Deterministic metric derivation and incomplete-data gating."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, time, timedelta
from zoneinfo import ZoneInfo

from .contracts import (
    BreakReason,
    GeneratedReview,
    HealthKitSyncState,
    Metric,
    MetricQuality,
    ReviewClaimCode,
    ReviewItem,
    ReviewStatus,
    WeekState,
    WeeklyReviewRequest,
    WeeklyReviewResponse,
)


@dataclass(frozen=True)
class MetricContext:
    request: WeeklyReviewRequest
    metrics: tuple[Metric, ...]
    status: ReviewStatus
    data_quality_codes: tuple[str, ...]
    allowed_claim_codes: frozenset[ReviewClaimCode]
    can_call_model: bool

    @property
    def metric_ids(self) -> frozenset[str]:
        return frozenset(metric.id for metric in self.metrics)

    def metric(self, metric_id: str) -> Metric:
        return next(metric for metric in self.metrics if metric.id == metric_id)

    def provider_payload(self) -> dict[str, object]:
        """The only payload sent to the LLM provider: derived facts + constraints."""

        return {
            "schema_version": "weekly-review-provider-input/v1",
            "reviewed_week_start": self.request.reviewed_week_start.isoformat(),
            "week_state": self.request.week_state.value,
            "data_quality_codes": list(self.data_quality_codes),
            "metrics": [metric.model_dump(mode="json") for metric in self.metrics],
            "allowed_claim_codes": sorted(code.value for code in self.allowed_claim_codes),
            "rules": [
                "Use only allowed claim codes.",
                "Cite only supplied metric IDs.",
                "Do not include digits or numeric values in prose.",
                "Do not make medical, injury, illness, readiness, fatigue, diagnosis, or treatment claims.",
                "Do not prescribe a workout or schedule.",
            ],
        }


def _metric(
    metric_id: str,
    value: float | int | str | bool | None,
    unit: str,
    quality: MetricQuality,
    evidence_ids: list[str] | None = None,
) -> Metric:
    return Metric(
        id=metric_id,
        value=value,
        unit=unit,
        quality=quality,
        source_evidence_ids=evidence_ids or [],
    )


def derive_metrics(request: WeeklyReviewRequest) -> MetricContext:
    """Compute every factual quantity before an LLM can see or describe it."""

    current_workouts = [
        workout for workout in request.workouts if workout.week_start == request.reviewed_week_start
    ]
    evidence_ids = [workout.evidence_id for workout in current_workouts]
    plan = next(
        (candidate for candidate in request.plans if candidate.week_start == request.reviewed_week_start),
        None,
    )

    actual_miles = sum(workout.distance_miles for workout in current_workouts)
    actual_duration = sum(workout.duration_seconds for workout in current_workouts)
    qualifying_runs = sum(workout.distance_miles >= 1.0 for workout in current_workouts)
    weighted_pace = actual_duration / actual_miles if actual_miles > 0 else None

    hr_workouts = [workout for workout in current_workouts if workout.avg_hr_bpm is not None]
    hr_duration = sum(workout.duration_seconds for workout in hr_workouts)
    hr_coverage = hr_duration / actual_duration if actual_duration > 0 else None

    metrics: list[Metric] = [
        _metric(
            "m.data.healthkit_sync_state",
            request.data_freshness.healthkit_sync_state.value,
            "state",
            MetricQuality.MEASURED,
        ),
        _metric("m.data.week_state", request.week_state.value, "state", MetricQuality.MEASURED),
        _metric("m.data.workout_count", len(current_workouts), "workouts", MetricQuality.DERIVED, evidence_ids),
        _metric("m.data.plan_available", plan is not None, "boolean", MetricQuality.DERIVED),
        _metric(
            "m.current.actual_miles",
            round(actual_miles, 3),
            "mi",
            MetricQuality.DERIVED,
            evidence_ids,
        ),
        _metric(
            "m.current.actual_runs",
            qualifying_runs,
            "runs",
            MetricQuality.DERIVED,
            evidence_ids,
        ),
        _metric(
            "m.current.duration_seconds",
            round(actual_duration, 1),
            "s",
            MetricQuality.DERIVED,
            evidence_ids,
        ),
        _metric(
            "m.current.weighted_pace_sec_per_mile",
            round(weighted_pace, 3) if weighted_pace is not None else None,
            "s/mi",
            MetricQuality.DERIVED if weighted_pace is not None else MetricQuality.MISSING,
            evidence_ids,
        ),
        _metric(
            "m.hr.coverage",
            round(hr_coverage, 4) if hr_coverage is not None else None,
            "fraction",
            MetricQuality.DERIVED if hr_coverage is not None else MetricQuality.MISSING,
            [workout.evidence_id for workout in hr_workouts],
        ),
    ]

    if plan is not None:
        metrics.extend(
            [
                _metric(
                    "m.current.planned_miles",
                    round(plan.required_miles, 3),
                    "mi",
                    MetricQuality.MEASURED,
                ),
                _metric(
                    "m.current.required_runs",
                    plan.required_runs,
                    "runs",
                    MetricQuality.MEASURED,
                ),
            ]
        )
    else:
        metrics.extend(
            [
                _metric("m.current.planned_miles", None, "mi", MetricQuality.MISSING),
                _metric("m.current.required_runs", None, "runs", MetricQuality.MISSING),
            ]
        )

    physiology = request.physiology
    if physiology is not None and physiology.latest_vo2_max_ml_kg_min is not None:
        metrics.append(
            _metric(
                "m.vo2.latest",
                physiology.latest_vo2_max_ml_kg_min,
                "ml/kg/min",
                MetricQuality.MEASURED,
            )
        )
    else:
        metrics.append(_metric("m.vo2.latest", None, "ml/kg/min", MetricQuality.MISSING))

    data_quality_codes: list[str] = []
    complete_import = request.data_freshness.healthkit_sync_state is HealthKitSyncState.COMPLETE
    if request.data_freshness.healthkit_sync_state is not HealthKitSyncState.COMPLETE:
        data_quality_codes.append(f"healthkit_{request.data_freshness.healthkit_sync_state.value}")
    else:
        imported_at = request.data_freshness.last_successful_import_at
        if imported_at is None:
            data_quality_codes.append("healthkit_import_timestamp_missing")
            complete_import = False
        elif request.week_state is WeekState.COMPLETE:
            end_of_week = datetime.combine(
                request.reviewed_week_start + timedelta(days=7),
                time.min,
                tzinfo=ZoneInfo(request.timezone),
            )
            if imported_at < end_of_week:
                data_quality_codes.append("healthkit_import_does_not_cover_week")
                complete_import = False
        elif request.generated_at - imported_at > timedelta(hours=24):
            data_quality_codes.append("healthkit_import_stale")
            complete_import = False
    if plan is None:
        data_quality_codes.append("plan_missing")
    if request.week_state is WeekState.IN_PROGRESS:
        data_quality_codes.append("current_week_in_progress")
    if hr_coverage is None or hr_coverage < 0.8 or len(hr_workouts) < 2:
        data_quality_codes.append("hr_coverage_low")
    has_break_context = request.break_context.reason is not BreakReason.NONE or request.break_context.has_note
    if has_break_context:
        data_quality_codes.append("break_context_present")

    status = ReviewStatus.COMPLETE
    if not complete_import:
        status = ReviewStatus.INSUFFICIENT_DATA
    elif plan is None or has_break_context:
        status = ReviewStatus.LIMITED_DATA

    allowed = {ReviewClaimCode.DATA_LIMITED}
    can_call_model = status is ReviewStatus.COMPLETE
    if can_call_model:
        if request.week_state is WeekState.IN_PROGRESS:
            allowed.add(ReviewClaimCode.CURRENT_WEEK_IN_PROGRESS)
        else:
            allowed.add(
                ReviewClaimCode.MILEAGE_MET_PLAN
                if actual_miles >= plan.required_miles
                else ReviewClaimCode.MILEAGE_BELOW_PLAN
            )
            allowed.add(
                ReviewClaimCode.RUNS_MET_PLAN
                if qualifying_runs >= plan.required_runs
                else ReviewClaimCode.RUNS_BELOW_PLAN
            )
            if not current_workouts:
                allowed.add(ReviewClaimCode.NO_RECORDED_WORKOUTS)
        if physiology is not None and physiology.latest_vo2_max_ml_kg_min is not None:
            allowed.add(ReviewClaimCode.LATEST_VO2_RECORDED)

    return MetricContext(
        request=request,
        metrics=tuple(metrics),
        status=status,
        data_quality_codes=tuple(data_quality_codes),
        allowed_claim_codes=frozenset(allowed),
        can_call_model=can_call_model,
    )


def deterministic_fallback(
    context: MetricContext,
    *,
    status: ReviewStatus | None = None,
    additional_code: str | None = None,
) -> WeeklyReviewResponse:
    """Return a transparent non-LLM response for incomplete data or outages."""

    resolved_status = status or context.status
    codes = list(context.data_quality_codes)
    if additional_code is not None and additional_code not in codes:
        codes.append(additional_code)

    if resolved_status is ReviewStatus.UNAVAILABLE:
        text = "Weekly review generation is unavailable. Use the deterministic training metrics below."
    elif resolved_status is ReviewStatus.INSUFFICIENT_DATA:
        text = "A weekly review is unavailable until the workout import is complete."
    else:
        text = "A limited review is available because plan or context data is incomplete."

    item = ReviewItem(
        claim_code=ReviewClaimCode.DATA_LIMITED,
        text=text,
        evidence_ids=["m.data.healthkit_sync_state"],
    )
    return WeeklyReviewResponse(
        request_id=context.request.request_id,
        status=resolved_status,
        data_quality_codes=codes,
        metrics=list(context.metrics),
        review=GeneratedReview(headline=item, items=[], next_focus=item),
        fallback_used=True,
    )
