import re
from typing import List

_PHONE_RE = re.compile(r"\b(?:\+?1[-.\s]?)?\(?([2-9][0-9]{2})\)?[-.\s]?([0-9]{3})[-.\s]?([0-9]{4})\b")


class _PhoneValidationService:
    def extract_phones_from_text(self, text: str) -> List[str]:
        seen = set()
        out = []
        for m in _PHONE_RE.finditer(text or ""):
            n = f"({m.group(1)}) {m.group(2)}-{m.group(3)}"
            if n not in seen:
                seen.add(n)
                out.append(n)
        return out


_svc = _PhoneValidationService()


def get_phone_validation_service() -> _PhoneValidationService:
    return _svc
