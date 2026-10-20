"""Small single-process resource limits; deployment must add gateway limits."""

from __future__ import annotations

import hashlib
import math
import time
from collections import deque
from collections.abc import Callable

from starlette.responses import JSONResponse
from starlette.types import ASGIApp, Message, Receive, Scope, Send


class SubjectRateLimiter:
    """Memory-only hashed subjects; bounded storage, no token or health-data keys."""

    def __init__(
        self,
        per_minute: int,
        per_day: int,
        *,
        clock: Callable[[], float] = time.monotonic,
        max_subjects: int = 10_000,
    ) -> None:
        self._per_minute = per_minute
        self._per_day = per_day
        self._clock = clock
        self._max_subjects = max_subjects
        self._requests: dict[bytes, deque[float]] = {}

    def retry_after(self, subject: str) -> int | None:
        now = self._clock()
        for key in list(self._requests):
            times = self._requests[key]
            while times and times[0] <= now - 86_400:
                times.popleft()
            if not times:
                del self._requests[key]
        key = hashlib.sha256(subject.encode()).digest()
        if key not in self._requests:
            if len(self._requests) >= self._max_subjects:
                return 60  # Fail closed; do not evict live limits to admit identities.
            self._requests[key] = deque()
        times = self._requests[key]
        if len(times) >= self._per_day:
            return max(1, math.ceil(times[0] + 86_400 - now))
        recent = [timestamp for timestamp in times if timestamp > now - 60]
        if len(recent) >= self._per_minute:
            return max(1, math.ceil(recent[0] + 60 - now))
        times.append(now)
        return None


class PrivateRequestMiddleware:
    """Bound JSON before parsing, including chunked requests; forbid HTTP caching."""

    def __init__(self, app: ASGIApp, max_bytes: Callable[[], int]) -> None:
        self.app = app
        self._max_bytes = max_bytes

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        async def no_store(message: Message) -> None:
            if message["type"] == "http.response.start":
                message["headers"] = [
                    (name, value)
                    for name, value in message.get("headers", [])
                    if name.lower() != b"cache-control"
                ] + [(b"cache-control", b"no-store")]
            await send(message)

        if scope["method"] != "POST" or scope["path"] != "/v1/weekly-reviews":
            await self.app(scope, receive, no_store)
            return

        headers = dict(scope.get("headers", []))
        content_type = headers.get(b"content-type", b"").split(b";", 1)[0].strip().lower()
        if content_type != b"application/json" or headers.get(b"content-encoding", b"identity") != b"identity":
            response = JSONResponse({"detail": "An uncompressed JSON request is required."}, status_code=415)
            await response(scope, receive, no_store)
            return

        limit = self._max_bytes()
        try:
            if int(headers.get(b"content-length", b"0")) > limit:
                raise OverflowError
            body = bytearray()
            while True:
                message = await receive()
                if message["type"] == "http.disconnect":
                    return
                body.extend(message.get("body", b""))
                if len(body) > limit:
                    raise OverflowError
                if not message.get("more_body", False):
                    break
        except (ValueError, OverflowError):
            response = JSONResponse({"detail": "Weekly review request is too large."}, status_code=413)
            await response(scope, receive, no_store)
            return

        delivered = False

        async def bounded_receive() -> Message:
            nonlocal delivered
            if not delivered:
                delivered = True
                return {"type": "http.request", "body": bytes(body), "more_body": False}
            return await receive()

        await self.app(scope, bounded_receive, no_store)
