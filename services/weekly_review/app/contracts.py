"""Versioned, privacy-minimized request and response contracts."""

from __future__ import annotations

from datetime import date, datetime, timedelta
from enum import Enum
from typing import Annotated, Literal
from uuid import UUID
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator


class ContractModel(BaseModel):
    """Reject fields outside the reviewed data contract by default."""

    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True, allow_inf_nan=False)


class RunType(str, Enum):
    RECOVERY = "recovery"
    TEMPO = "tempo"
    LONG = "long"
    OTHER = "other"


class WorkoutSource(str, Enum):
    HEALTHKIT = "healthkit"
    STRAVA = "strava"
    MANUAL = "manual"


class HealthKitSyncState(str, Enum):
    COMPLETE = "complete"
    NOT_AUTHORIZED = "not_authorized"
    UNKNOWN = "unknown"
    FAILED = "failed"


class WeekState(str, Enum):
    IN_PROGRESS = "in_progress"
    COMPLETE = "complete"


class ReviewStatus(str, Enum):
    COMPLETE = "complete"
    LIMITED_DATA = "limited_data"
    INSUFFICIENT_DATA = "insufficient_data"
    UNAVAILABLE = "unavailable"


class MetricQuality(str, Enum):
    MEASURED = "measured"
    DERIVED = "derived"
    MISSING = "missing"


class BreakReason(str, Enum):
    NONE = "none"
    ILLNESS = "illness"
    INJURY = "injury"
    TRAVEL = "travel"
    LIFE = "life"
    OTHER = "other"


class ReviewClaimCode(str, Enum):
    MILEAGE_BELOW_PLAN = "mileage_below_plan"
    MILEAGE_MET_PLAN = "mileage_met_plan"
    RUNS_BELOW_PLAN = "runs_below_plan"
    RUNS_MET_PLAN = "runs_met_plan"
    CURRENT_WEEK_IN_PROGRESS = "current_week_in_progress"
    LATEST_VO2_RECORDED = "latest_vo2_recorded"
    DATA_LIMITED = "data_limited"
    NO_RECORDED_WORKOUTS = "no_recorded_workouts"


Miles = Annotated[float, Field(ge=0, le=200)]
Seconds = Annotated[float, Field(ge=0, le=86_400)]


class PlannedMilesByType(ContractModel):
    recovery: Miles
    tempo: Miles
    long: Miles


class PlanWeek(ContractModel):
    week_start: date
    required_miles: Miles
    required_runs: Annotated[int, Field(ge=0, le=14)]
    planned_miles_by_type: PlannedMilesByType


class ZoneSeconds(ContractModel):
    z1: Seconds
    z2: Seconds
    z3: Seconds
    z4: Seconds
    z5: Seconds

    @property
    def total(self) -> float:
        return self.z1 + self.z2 + self.z3 + self.z4 + self.z5


class WorkoutInput(ContractModel):
    """A minimized per-request workout record with no stable user identifiers."""

    evidence_id: Annotated[str, Field(pattern=r"^w-[A-Za-z0-9_-]{1,32}$")]
    week_start: date
    started_on: date
    run_type: RunType
    distance_miles: Annotated[float, Field(gt=0, le=200)]
    duration_seconds: Annotated[float, Field(gt=0, le=86_400)]
    avg_hr_bpm: Annotated[float | None, Field(ge=30, le=260)] = None
    zone_seconds: ZoneSeconds | None = None
    source: WorkoutSource

    @model_validator(mode="after")
    def zone_seconds_do_not_exceed_workout_duration(self) -> "WorkoutInput":
        if self.zone_seconds is not None and self.zone_seconds.total > self.duration_seconds + 1e-6:
            raise ValueError("zone_seconds cannot exceed duration_seconds")
        return self


class DataFreshness(ContractModel):
    healthkit_sync_state: HealthKitSyncState
    last_successful_import_at: datetime | None = None


class Physiology(ContractModel):
    latest_vo2_max_ml_kg_min: Annotated[float | None, Field(ge=10, le=100)] = None
    latest_vo2_max_observed_on: date | None = None
    resting_hr_bpm: Annotated[int | None, Field(ge=25, le=120)] = None

    @model_validator(mode="after")
    def require_vo2_date_with_value(self) -> "Physiology":
        if (self.latest_vo2_max_ml_kg_min is None) != (self.latest_vo2_max_observed_on is None):
            raise ValueError("VO2 max value and observed date must be supplied together")
        return self


class BreakContext(ContractModel):
    reason: BreakReason = BreakReason.NONE
    has_note: bool = False


class WeeklyReviewRequest(ContractModel):
    schema_version: Literal["weekly-review-input/v1"]
    request_id: UUID
    reviewed_week_start: date
    generated_at: datetime
    timezone: Annotated[str, Field(min_length=1, max_length=64)]
    week_state: WeekState
    data_freshness: DataFreshness
    # V1 evaluates exactly one selected week. Accepting extra historical plans
    # would expand the data boundary without contributing to a deterministic
    # metric or an allowed review claim.
    plans: Annotated[list[PlanWeek], Field(min_length=1, max_length=1)]
    workouts: Annotated[list[WorkoutInput], Field(max_length=80)]
    physiology: Physiology | None = None
    break_context: BreakContext = Field(default_factory=BreakContext)

    @field_validator("plans")
    @classmethod
    def plan_weeks_are_unique(cls, plans: list[PlanWeek]) -> list[PlanWeek]:
        if len({plan.week_start for plan in plans}) != len(plans):
            raise ValueError("plans cannot contain duplicate week_start values")
        return plans

    @field_validator("workouts")
    @classmethod
    def workout_evidence_ids_are_unique(cls, workouts: list[WorkoutInput]) -> list[WorkoutInput]:
        if len({workout.evidence_id for workout in workouts}) != len(workouts):
            raise ValueError("workouts cannot contain duplicate evidence_id values")
        return workouts

    @field_validator("timezone")
    @classmethod
    def timezone_is_recognized(cls, value: str) -> str:
        try:
            ZoneInfo(value)
        except ZoneInfoNotFoundError as error:
            raise ValueError("timezone must be an IANA timezone identifier") from error
        return value

    @model_validator(mode="after")
    def selected_week_is_coherent_and_not_future(self) -> "WeeklyReviewRequest":
        if self.generated_at.tzinfo is None:
            raise ValueError("generated_at must include a timezone offset")
        if self.reviewed_week_start.weekday() != 0:
            raise ValueError("reviewed_week_start must be a Monday")

        timezone = ZoneInfo(self.timezone)
        generated_local_day = self.generated_at.astimezone(timezone).date()
        current_week_start = generated_local_day - timedelta(days=generated_local_day.weekday())
        if self.reviewed_week_start > current_week_start:
            raise ValueError("reviewed_week_start cannot be a future week")
        expected_state = (
            WeekState.IN_PROGRESS
            if self.reviewed_week_start == current_week_start
            else WeekState.COMPLETE
        )
        if self.week_state is not expected_state:
            raise ValueError("week_state must match the selected week and generated_at")

        plan = self.plans[0]
        if plan.week_start != self.reviewed_week_start:
            raise ValueError("plan week_start must match reviewed_week_start")

        reviewed_week_end = self.reviewed_week_start + timedelta(days=7)
        for workout in self.workouts:
            if workout.week_start != self.reviewed_week_start:
                raise ValueError("workout week_start must match reviewed_week_start")
            if not self.reviewed_week_start <= workout.started_on < reviewed_week_end:
                raise ValueError("workout started_on must fall within reviewed week")
            if workout.started_on > generated_local_day:
                raise ValueError("workout started_on cannot be after generated_at")

        if (
            self.physiology is not None
            and self.physiology.latest_vo2_max_observed_on is not None
            and self.physiology.latest_vo2_max_observed_on > generated_local_day
        ):
            raise ValueError("VO2 max observation cannot be after generated_at")

        imported_at = self.data_freshness.last_successful_import_at
        if imported_at is not None:
            if imported_at.tzinfo is None:
                raise ValueError("last_successful_import_at must include a timezone offset")
            if imported_at > self.generated_at:
                raise ValueError("last_successful_import_at cannot be after generated_at")
        return self


class Metric(ContractModel):
    id: Annotated[str, Field(pattern=r"^m\.[a-z0-9_.-]{1,80}$")]
    value: float | int | str | bool | None
    unit: Annotated[str, Field(max_length=40)]
    quality: MetricQuality
    source_evidence_ids: Annotated[list[str], Field(max_length=80)] = Field(default_factory=list)


class ReviewItem(ContractModel):
    claim_code: ReviewClaimCode
    text: Annotated[str, Field(min_length=1, max_length=280)]
    evidence_ids: Annotated[list[str], Field(min_length=1, max_length=6)]


class GeneratedReview(ContractModel):
    """The strict schema Azure must return before the service accepts it."""

    headline: ReviewItem
    items: Annotated[list[ReviewItem], Field(max_length=3)] = Field(default_factory=list)
    next_focus: ReviewItem


class WeeklyReviewResponse(ContractModel):
    schema_version: Literal["weekly-review-response/v1"] = "weekly-review-response/v1"
    request_id: UUID
    status: ReviewStatus
    data_quality_codes: Annotated[list[str], Field(max_length=12)]
    metrics: Annotated[list[Metric], Field(max_length=32)]
    review: GeneratedReview
    fallback_used: bool
