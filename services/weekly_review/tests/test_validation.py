from __future__ import annotations

import pytest

from app.contracts import GeneratedReview, ReviewClaimCode, ReviewItem
from app.metrics import derive_metrics
from app.validation import UnsupportedReviewError, accepted_response, validate_generated_review


def valid_review() -> GeneratedReview:
    return GeneratedReview(
        headline=ReviewItem(
            claim_code=ReviewClaimCode.MILEAGE_BELOW_PLAN,
            text="Recorded mileage is below the planned amount.",
            evidence_ids=["m.current.actual_miles", "m.current.planned_miles"],
        ),
        items=[
            ReviewItem(
                claim_code=ReviewClaimCode.RUNS_BELOW_PLAN,
                text="The recorded run count is below the planned count.",
                evidence_ids=["m.current.actual_runs", "m.current.required_runs"],
            )
        ],
        next_focus=ReviewItem(
            claim_code=ReviewClaimCode.LATEST_VO2_RECORDED,
            text="A latest VO two value is available in the recorded metrics.",
            evidence_ids=["m.vo2.latest"],
        ),
    )


def test_accepts_grounded_structured_review(complete_request) -> None:
    context = derive_metrics(complete_request)

    response = accepted_response(context, valid_review())

    assert not response.fallback_used
    assert response.review.headline.claim_code is ReviewClaimCode.MILEAGE_BELOW_PLAN


@pytest.mark.parametrize(
    ("item", "expected"),
    [
        (
            ReviewItem(
                claim_code=ReviewClaimCode.MILEAGE_BELOW_PLAN,
                text="Recorded mileage is 7 miles.",
                evidence_ids=["m.current.actual_miles", "m.current.planned_miles"],
            ),
            "numeric literals",
        ),
        (
            ReviewItem(
                claim_code=ReviewClaimCode.MILEAGE_BELOW_PLAN,
                text="Recorded mileage is below the planned amount.",
                evidence_ids=["m.current.actual_miles", "m.unknown"],
            ),
            "unknown evidence",
        ),
        (
            ReviewItem(
                claim_code=ReviewClaimCode.MILEAGE_BELOW_PLAN,
                text="This indicates injury risk.",
                evidence_ids=["m.current.actual_miles", "m.current.planned_miles"],
            ),
            "prohibited health",
        ),
    ],
)
def test_rejects_unsupported_claims(complete_request, item, expected: str) -> None:
    context = derive_metrics(complete_request)
    review = valid_review().model_copy(update={"headline": item})

    with pytest.raises(UnsupportedReviewError, match=expected):
        validate_generated_review(review, context)
