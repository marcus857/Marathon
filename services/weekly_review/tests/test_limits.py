from app.limits import SubjectRateLimiter


def test_rate_limit_is_per_subject_and_windows_expire():
    clock = [100.0]
    limiter = SubjectRateLimiter(2, 3, clock=lambda: clock[0])
    assert limiter.retry_after("alice") is None
    assert limiter.retry_after("alice") is None
    assert limiter.retry_after("alice") == 60
    assert limiter.retry_after("bob") is None
    clock[0] += 61
    assert limiter.retry_after("alice") is None
    assert limiter.retry_after("alice") == 86_339
    clock[0] += 86_400
    assert limiter.retry_after("alice") is None


def test_limiter_bounds_memory_without_evicting_active_limits():
    clock = [100.0]
    limiter = SubjectRateLimiter(1, 1, max_subjects=1, clock=lambda: clock[0])
    assert limiter.retry_after("alice") is None
    assert limiter.retry_after("bob") == 60
    assert limiter.retry_after("alice") == 86_400
    clock[0] += 86_400
    assert limiter.retry_after("bob") is None
