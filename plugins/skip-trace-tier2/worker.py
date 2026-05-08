import asyncio
import json
import logging
import os
import signal
import sys
from typing import Any, Dict

import httpx

from fcar_tier2.free_skip_trace import free_skip_trace_provider

logging.basicConfig(
    level=os.environ.get("LOG_LEVEL", "INFO"),
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)
log = logging.getLogger("skip-trace-tier2")

ENGINE_URL = os.environ.get("ENGINE_URL", "http://127.0.0.1:8082").rstrip("/")
TOKEN = os.environ.get("GONDOR_ADMIN_API_KEYS") or os.environ.get("ASSAY_ADMIN_KEY") or ""
QUEUE = os.environ.get("QUEUE", "skip-trace-tier2")
NAMESPACE = os.environ.get("WORKFLOW_NAMESPACE", "main")
IDENTITY = os.environ.get("WORKER_IDENTITY", f"py-tier2-{os.getpid()}")
MAX_CONCURRENT = int(os.environ.get("MAX_CONCURRENT", "4"))
HEARTBEAT_INTERVAL = float(os.environ.get("HEARTBEAT_INTERVAL_SECS", "10"))

API = "/api/v1/engine/workflow"
HEADERS = {"Content-Type": "application/json"}
if TOKEN:
    HEADERS["Authorization"] = f"Bearer {TOKEN}"


def _shape_result(raw: Dict[str, Any]) -> Dict[str, Any]:
    phones = raw.get("phones") or []
    emails = raw.get("emails") or []
    addresses = raw.get("addresses") or []
    sources = raw.get("sources") or []
    return {
        "phone": phones[0] if phones else "",
        "email": emails[0] if emails else "",
        "address": addresses[0] if addresses else "",
        "phones": phones,
        "emails": emails,
        "addresses": addresses,
        "sources": sources,
        "confidence": raw.get("confidence", 0.0),
    }


async def _run_lookup(client: httpx.AsyncClient, task: Dict[str, Any]) -> None:
    tid = task["id"]
    try:
        raw_input = task.get("input")
        args = json.loads(raw_input) if isinstance(raw_input, str) else (raw_input or {})
        name = args.get("name") or ""
        if not name:
            raise ValueError("missing 'name' in activity input")
        state = args.get("state") or args.get("state_code")
        city = args.get("city")
        log.info("lookup tid=%s name=%r state=%r city=%r", tid, name, state, city)
        raw = await free_skip_trace_provider.comprehensive_search(name=name, state=state, city=city)
        result = _shape_result(raw)
        await client.post(f"{API}/tasks/{tid}/complete", json={"result": result})
        log.info(
            "complete tid=%s found=%s phones=%d emails=%d sources=%d",
            tid,
            raw.get("found"),
            len(raw.get("phones") or []),
            len(raw.get("emails") or []),
            len(raw.get("sources") or []),
        )
    except Exception as e:
        log.exception("activity failed tid=%s: %s", tid, e)
        try:
            await client.post(f"{API}/tasks/{tid}/fail", json={"error": f"{type(e).__name__}: {e}"})
        except Exception:
            log.exception("could not report failure for tid=%s", tid)


async def _heartbeat_loop(client: httpx.AsyncClient, worker_id: str, stop: asyncio.Event) -> None:
    while not stop.is_set():
        try:
            await client.post(f"{API}/workers/heartbeat", json={"worker_id": worker_id})
        except Exception as e:
            log.warning("heartbeat failed: %s", e)
        try:
            await asyncio.wait_for(stop.wait(), timeout=HEARTBEAT_INTERVAL)
        except asyncio.TimeoutError:
            pass


async def main() -> int:
    stop = asyncio.Event()

    def _shutdown(sig_name: str) -> None:
        log.info("received %s, shutting down", sig_name)
        stop.set()

    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, _shutdown, sig.name)

    timeout = httpx.Timeout(60.0, connect=5.0)
    async with httpx.AsyncClient(base_url=ENGINE_URL, headers=HEADERS, timeout=timeout) as client:
        reg = await client.post(
            f"{API}/workers/register",
            json={
                "namespace": NAMESPACE,
                "identity": IDENTITY,
                "queue": QUEUE,
                "activities": ["lookup_t2"],
                "max_concurrent_workflows": 0,
                "max_concurrent_activities": MAX_CONCURRENT,
            },
        )
        reg.raise_for_status()
        worker_id = reg.json()["worker_id"]
        log.info(
            "registered worker_id=%s queue=%s namespace=%s engine=%s",
            worker_id,
            QUEUE,
            NAMESPACE,
            ENGINE_URL,
        )

        sem = asyncio.Semaphore(MAX_CONCURRENT)
        hb_task = asyncio.create_task(_heartbeat_loop(client, worker_id, stop))
        in_flight: set[asyncio.Task[None]] = set()

        async def _claim_one() -> None:
            async with sem:
                try:
                    resp = await client.post(f"{API}/tasks/poll", json={"queue": QUEUE, "worker_id": worker_id})
                    resp.raise_for_status()
                    body = resp.json()
                except Exception as e:
                    log.warning("poll error: %s", e)
                    await asyncio.sleep(1.0)
                    return
                # Engine returns either an activity object or {"task": null}.
                if not body or body.get("task") is None and "id" not in body:
                    await asyncio.sleep(0.5)
                    return
                task = body
                t = asyncio.create_task(_run_lookup(client, task))
                in_flight.add(t)
                t.add_done_callback(in_flight.discard)

        while not stop.is_set():
            await _claim_one()

        log.info("draining %d in-flight tasks", len(in_flight))
        if in_flight:
            await asyncio.gather(*in_flight, return_exceptions=True)
        hb_task.cancel()
        try:
            await hb_task
        except asyncio.CancelledError:
            pass

    log.info("shutdown complete")
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
