from dataclasses import dataclass
from typing import Optional


@dataclass
class _Response:
    success: bool = False
    content: Optional[str] = None
    strategy_used: str = "disabled"
    error: str = "gateway disabled in standalone tier2 worker"


class _Gateway:
    async def scrape(self, _url: str, caller_id: str = "", try_direct_first: bool = True) -> _Response:
        return _Response()


_gw = _Gateway()


def get_unified_gateway() -> _Gateway:
    return _gw
