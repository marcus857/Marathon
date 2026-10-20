"""Fail-closed grounding checks for structured model output."""

from __future__ import annotations

import re

from .contracts import (
    GeneratedReview,
    ReviewClaimCode,
    ReviewItem,
    ReviewStatus,
    WeeklyReviewResponse,
)
from .metrics import MetricContext


class UnsupportedReviewError(ValueError):
    """Raised when model output is syntactically valid but not evidence-grounded."""


_DIGIT = re.compile(r"\d")
_PROHIBITED_LANGUAGE = re.compile(
    r"\b(?:diagnos(?:e|is|tic)|treat(?:ment)?|medical|injur(?:y|ies)|illness|"
    r"overtrain(?:ing)?|fatigue|readiness|prescri(?:be|ption)|therap(?:y|ies))\b",
    re.IGNORECASE,
)

_REQUIRED_EVIDENCE: dict[ReviewClaimCode, frozenset[str]] = {
    ReviewClaimCode.MILEAGE_BELOW_PLAN: frozenset(
        {"m.current.actual_miles", "m.current.planned_miles"}
    ),
    ReviewClaimCode.MILEAGE_MET_PLAN: frozenset(
        {"m.current.actual_miles", "m.current.planned_miles"}
    ),
    ReviewClaimCode.RUNS_BELOW_PLAN: frozenset({"m.current.actual_runs", "m.current.required_runs"}),
    ReviewClaimCode.RUNS_MET_PLAN: frozenset({"m.current.actual_runs", "m.current.required_runs"}),
    ReviewClaimCode.CURRENT_WEEK_IN_PROGRESS: frozenset({"m.data.week_state"}),
    ReviewClaimCode.LATEST_VO2_RECORDED: frozenset({"m.vo2.latest"}),
    ReviewClaimCode.DATA_LIMITED: frozenset({"m.data.healthkit_sync_state"}),
    ReviewClaimCode.NO_RECORDED_WORKOUTS: frozenset({"m.data.workout_count"}),
}


def _items(review: GeneratedReview) -> list[ReviewItem]:
    return [review.headline, *review.items, review.next_focus]


def _numeric_metric(context: MetricContext, metric_id: str) -> float:
    value = context.metric(metric_id).value
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise UnsupportedReviewError(f"{metric_id} is not a numeric metric")
    return float(value)


def _assert_claim_relation(item: ReviewItem, context: MetricContext) -> None:
    code = item.claim_code
    if code is ReviewClaimCode.MILEAGE_BELOW_PLAN:
        if _numeric_metric(context, "m.current.actual_miles") >= _numeric_metric(
            context, "m.current.planned_miles"
        ):
            raise UnsupportedReviewError("mileage_below_plan does not match deterministic metrics")
    elif code is ReviewClaimCode.MILEAGE_MET_PLAN:
        if _numeric_metric(context, "m.current.actual_miles") < _numeric_metric(
            context, "m.current.planned_miles"
        ):
            raise UnsupportedReviewError("mileage_met_plan does not match deterministic metrics")
    elif code is ReviewClaimCode.RUNS_BELOW_PLAN:
        if _numeric_metric(context, "m.current.actual_runs") >= _numeric_metric(
            context, "m.current.required_runs"
        ):
            raise UnsupportedReviewError("runs_below_plan does not match deterministic metrics")
    elif code is ReviewClaimCode.RUNS_MET_PLAN:
        if _numeric_metric(context, "m.current.actual_runs") < _numeric_metric(
            context, "m.current.required_runs"
        ):
            raise UnsupportedReviewError("runs_met_plan does not match deterministic metrics")
    elif code is ReviewClaimCode.CURRENT_WEEK_IN_PROGRESS:
        if context.metric("m.data.week_state").value != "in_progress":
            raise UnsupportedReviewError("current_week_in_progress requires an in-progress week")
    elif code is ReviewClaimCode.LATEST_VO2_RECORDED:
        if context.metric("m.vo2.latest").value is None:
            raise UnsupportedReviewError("latest_vo2_recorded requires an observed VO2 value")
    elif code is ReviewClaimCode.NO_RECORDED_WORKOUTS:
        if _numeric_metric(context, "m.data.workout_count") != 0:
            raise UnsupportedReviewError("no_recorded_workouts requires an empty current week")


def validate_generated_review(review: GeneratedReview, context: MetricContext) -> None:
    """Verify every model statement is allowable and traceable to deterministic facts."""

    if not context.can_call_model:
        raise UnsupportedReviewError("model output is forbidden for this data-completeness state")

    valid_metric_ids = context.metric_ids
    for item in _items(review):
        if item.claim_code not in context.allowed_claim_codes:
            raise UnsupportedReviewError(f"claim code is not allowed: {item.claim_code.value}")
        if _DIGIT.search(item.text):
            raise UnsupportedReviewError("review prose may not contain numeric literals")
        if _PROHIBITED_LANGUAGE.search(item.text):
            raise UnsupportedReviewError("review prose contains prohibited health/coaching language")

        evidence_ids = set(item.evidence_ids)
        unknown_ids = evidence_ids - valid_metric_ids
        if unknown_ids:
            raise UnsupportedReviewError(f"review cites unknown evidence: {sorted(unknown_ids)}")

        required = _REQUIRED_EVIDENCE[item.claim_code]
        if not required.issubset(evidence_ids):
            raise UnsupportedReviewError(
                f"{item.claim_code.value} is missing required evidence: {sorted(required - evidence_ids)}"
            )
        _assert_claim_relation(item, context)


def accepted_response(context: MetricContext, review: GeneratedReview) -> WeeklyReviewResponse:
    """Wrap a validated model response in the stable client-facing contract."""

    validate_generated_review(review, context)
    return WeeklyReviewResponse(
        request_id=context.request.request_id,
        status=ReviewStatus.COMPLETE,
        data_quality_codes=list(context.data_quality_codes),
        metrics=list(context.metrics),
        review=review,
        fallback_used=False,
    )
