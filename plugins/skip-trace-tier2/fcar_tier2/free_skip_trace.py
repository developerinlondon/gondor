"""
Free Skip Trace Sources Provider (Tier 2) - UNIFIED VERSION
Implements web scraping for TruePeopleSearch, FastPeopleSearch, Google, Whitepages, 411.com

🔄 CONSOLIDATION: Merged from services/free_skip_trace.py + scrapers/free_skip_trace_service.py
- Added TruePeopleSearch + FastPeopleSearch from scrapers/ (specialized people search sites)
- Kept Google, Whitepages, 411.com from services/ (general directories)
- Added random user agent rotation from scrapers/
- Now supports 5 data sources total for maximum coverage

NOTE: This is a working implementation that uses public search engines
and data aggregators. For production use, consider:
1. Rate limiting to avoid IP bans (✅ implemented)
2. Proxy rotation for high-volume usage
3. User-agent rotation (✅ implemented)
4. CAPTCHA solving services if needed
"""

import asyncio
import logging
import random
import re
import time
from typing import Any, Dict, List, Optional
from urllib.parse import quote_plus, urlencode

import httpx
from bs4 import BeautifulSoup

from .feature_flags import is_enabled
from .phone_validation_service import get_phone_validation_service
from .unified_scraping_gateway import get_unified_gateway

logger = logging.getLogger(__name__)


class FreeSkipTraceProvider:
    """
    Unified free skip trace provider - searches 5 free data sources.

    Data Sources:
    1. TruePeopleSearch - Specialized people search (high accuracy)
    2. FastPeopleSearch - Specialized people search (high accuracy)
    3. Google Search - General web search
    4. Whitepages - Public directory
    5. 411.com - Public directory

    Features:
    - Parallel search execution across all sources
    - Random user agent rotation to avoid bans
    - Rate limiting (2 second delay between requests)
    - Phone, email, and address extraction
    - Confidence scoring based on data completeness
    """

    def __init__(self):
        self.timeout = httpx.Timeout(30.0, connect=10.0)

        # User agent rotation (merged from scrapers/)
        self.user_agents = [
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:109.0) Gecko/20100101 Firefox/121.0",
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.1 Safari/605.1.15",
        ]

        # Rate limiting to avoid bans
        self.last_request_time = 0
        self.min_delay = 2.0  # 2 seconds between requests

        logger.info(
            "✅ Free Skip Trace Provider initialized (5 sources: TruePeopleSearch, FastPeopleSearch, Google, Whitepages, 411.com)"
        )

    async def _rate_limit_delay(self):
        """Enforce rate limiting between requests"""
        elapsed = time.time() - self.last_request_time
        if elapsed < self.min_delay:
            await asyncio.sleep(self.min_delay - elapsed)
        self.last_request_time = time.time()

    async def _fetch_html(self, url: str, headers: Optional[Dict[str, str]] = None) -> Optional[str]:
        """Fetch HTML content from URL with error handling and random user agent"""
        if self._gateway_enabled():
            try:
                gateway_response = await get_unified_gateway().scrape(
                    url,
                    caller_id="free_skip_trace",
                    try_direct_first=True,
                )
                if gateway_response.success:
                    return gateway_response.content

                logger.warning(
                    "Gateway fetch failed for %s (strategy=%s, error=%s)",
                    url,
                    gateway_response.strategy_used,
                    gateway_response.error,
                )
                return None
            except Exception as e:
                logger.error(f"Gateway error fetching {url}: {str(e)}")
                return None

        if headers is None:
            # Use random user agent for each request (anti-ban feature from scrapers/)
            headers = {"User-Agent": random.choice(self.user_agents)}

        try:
            await self._rate_limit_delay()

            async with httpx.AsyncClient(timeout=self.timeout, follow_redirects=True) as client:
                response = await client.get(url, headers=headers)

                if response.status_code == 200:
                    return response.text
                else:
                    logger.warning(f"HTTP {response.status_code} for {url}")
                    return None

        except asyncio.TimeoutError:
            logger.warning(f"Timeout fetching {url}")
            return None
        except Exception as e:
            logger.error(f"Error fetching {url}: {str(e)}")
            return None

    def _gateway_enabled(self) -> bool:
        return is_enabled("gateway.free_skip_trace.enabled")

    def _extract_phone_numbers(self, text: str) -> List[str]:
        """Extract phone numbers from text"""
        return get_phone_validation_service().extract_phones_from_text(text)

    def _extract_emails(self, text: str) -> List[str]:
        """Extract email addresses from text"""
        email_pattern = r"[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}"
        emails = re.findall(email_pattern, text)

        # Filter out common false positives
        filtered = []
        for email in emails:
            email_lower = email.lower()
            if not any(x in email_lower for x in ["example.com", "test.com", "sample.com"]):
                if email not in filtered:
                    filtered.append(email)

        return filtered

    # ========================================================================
    # SPECIALIZED PEOPLE SEARCH SITES (merged from scrapers/)
    # ========================================================================

    async def search_truepeoplesearch(self, first_name: str, last_name: str, city: str, state: str) -> Dict[str, Any]:
        """
        Search TruePeopleSearch.com for person information.
        Specialized people search site with high accuracy.
        Merged from scrapers/free_skip_trace_service.py
        """
        try:
            name = f"{first_name} {last_name}"
            params = {"name": name, "citystatezip": f"{city}, {state}"}

            logger.info(f"TruePeopleSearch: {name}, {city}, {state}")

            if self._gateway_enabled():
                query = urlencode(params)
                html = await self._fetch_html(f"https://www.truepeoplesearch.com/results?{query}")

                if not html:
                    return {"found": False}

                soup = BeautifulSoup(html, "html.parser")
                person_cards = soup.select(".card.person, .search-result")

                if not person_cards:
                    return {"found": False}

                # Check top 3 results for matching person
                for card in person_cards[:3]:
                    phone_elems = card.select('a[href^="tel:"]')
                    phones = []
                    for phone in phone_elems:
                        phone_clean = "".join(filter(str.isdigit, phone.get_text(strip=True)))
                        if len(phone_clean) == 10:
                            phones.append(f"{phone_clean[:3]}-{phone_clean[3:6]}-{phone_clean[6:]}")

                    if phones:
                        return {
                            "found": True,
                            "source": "TruePeopleSearch",
                            "phones": phones,
                            "confidence": 0.7,
                        }

                return {"found": False}

            headers = {"User-Agent": random.choice(self.user_agents)}

            async with httpx.AsyncClient(timeout=self.timeout, follow_redirects=True) as client:
                await self._rate_limit_delay()
                response = await client.get(
                    "https://www.truepeoplesearch.com/results",
                    params=params,
                    headers=headers,
                )

                if response.status_code != 200:
                    logger.warning(f"TruePeopleSearch returned {response.status_code}")
                    return {"found": False}

                soup = BeautifulSoup(response.text, "html.parser")
                person_cards = soup.select(".card.person, .search-result")

                if not person_cards:
                    return {"found": False}

                # Check top 3 results for matching person
                for card in person_cards[:3]:
                    phone_elems = card.select('a[href^="tel:"]')
                    phones = []
                    for phone in phone_elems:
                        phone_clean = "".join(filter(str.isdigit, phone.get_text(strip=True)))
                        if len(phone_clean) == 10:
                            phones.append(f"{phone_clean[:3]}-{phone_clean[3:6]}-{phone_clean[6:]}")

                    if phones:
                        return {
                            "found": True,
                            "source": "TruePeopleSearch",
                            "phones": phones,
                            "confidence": 0.7,  # Higher confidence for specialized site
                        }

                return {"found": False}

        except Exception as e:
            logger.error(f"TruePeopleSearch error: {e}")
            return {"found": False, "error": str(e)}

    async def search_fastpeoplesearch(self, first_name: str, last_name: str, city: str, state: str) -> Dict[str, Any]:
        """
        Search FastPeopleSearch.com for person information.
        Specialized people search site with high accuracy.
        Merged from scrapers/free_skip_trace_service.py
        """
        try:
            name_slug = f"{first_name.lower()}-{last_name.lower()}"
            location_slug = f"{city.lower().replace(' ', '-')}-{state.lower()}"
            url = f"https://www.fastpeoplesearch.com/name/{name_slug}_{location_slug}"

            logger.info(f"FastPeopleSearch: {first_name} {last_name}, {city}, {state}")

            if self._gateway_enabled():
                html = await self._fetch_html(url)

                if not html:
                    return {"found": False}

                soup = BeautifulSoup(html, "html.parser")
                phone_elem = soup.select_one('a[href^="tel:"]')

                if not phone_elem:
                    return {"found": False}

                phone_clean = "".join(filter(str.isdigit, phone_elem.get_text(strip=True)))
                if len(phone_clean) == 10:
                    formatted_phone = f"{phone_clean[:3]}-{phone_clean[3:6]}-{phone_clean[6:]}"
                    return {
                        "found": True,
                        "source": "FastPeopleSearch",
                        "phones": [formatted_phone],
                        "confidence": 0.65,
                    }

                return {"found": False}

            headers = {"User-Agent": random.choice(self.user_agents)}

            async with httpx.AsyncClient(timeout=self.timeout, follow_redirects=True) as client:
                await self._rate_limit_delay()
                response = await client.get(url, headers=headers)

                if response.status_code != 200:
                    logger.warning(f"FastPeopleSearch returned {response.status_code}")
                    return {"found": False}

                soup = BeautifulSoup(response.text, "html.parser")
                phone_elem = soup.select_one('a[href^="tel:"]')

                if not phone_elem:
                    return {"found": False}

                phone_clean = "".join(filter(str.isdigit, phone_elem.get_text(strip=True)))
                if len(phone_clean) == 10:
                    formatted_phone = f"{phone_clean[:3]}-{phone_clean[3:6]}-{phone_clean[6:]}"
                    return {
                        "found": True,
                        "source": "FastPeopleSearch",
                        "phones": [formatted_phone],
                        "confidence": 0.65,
                    }

                return {"found": False}

        except Exception as e:
            logger.error(f"FastPeopleSearch error: {e}")
            return {"found": False, "error": str(e)}

    # ========================================================================
    # GENERAL SEARCH ENGINES & DIRECTORIES
    # ========================================================================

    async def search_google(self, name: str, state: Optional[str] = None, city: Optional[str] = None) -> Dict[str, Any]:
        """
        Search Google for person information.
        Uses Google search to find publicly available contact info.
        """
        try:
            # Build search query
            query_parts = [name]
            if city and state:
                query_parts.append(f"{city} {state}")
            elif state:
                query_parts.append(state)

            query_parts.extend(["phone", "email", "address"])
            query = " ".join(query_parts)

            # Google search URL
            google_url = f"https://www.google.com/search?q={quote_plus(query)}"

            logger.info(f"Google search: {query}")

            html = await self._fetch_html(google_url)

            if not html:
                return {"found": False}

            # Extract phone numbers and emails from search results
            phones = self._extract_phone_numbers(html)
            emails = self._extract_emails(html)

            if phones or emails:
                return {
                    "found": True,
                    "source": "Google Search",
                    "phones": phones[:3],  # Top 3 results
                    "emails": emails[:3],
                }

            return {"found": False}

        except Exception as e:
            logger.error(f"Google search error: {str(e)}")
            return {"found": False, "error": str(e)}

    async def search_whitepages(self, name: str, state: Optional[str] = None) -> Dict[str, Any]:
        """
        Search Whitepages.com (free results only).
        Note: Full results require paid subscription, we only get free preview data.
        """
        try:
            # Build Whitepages search URL
            name_encoded = quote_plus(name)
            state_param = f"&where={state}" if state else ""

            url = f"https://www.whitepages.com/name/{name_encoded}{state_param}"

            logger.info(f"Whitepages search: {name} {state or ''}")

            html = await self._fetch_html(url)

            if not html:
                return {"found": False}

            soup = BeautifulSoup(html, "html.parser")

            # Look for phone numbers in the preview
            phones = self._extract_phone_numbers(html)

            # Look for location info
            location_divs = soup.find_all("div", class_="location")
            locations = []
            for div in location_divs[:3]:
                locations.append(div.get_text(strip=True))

            if phones or locations:
                return {
                    "found": True,
                    "source": "Whitepages",
                    "phones": phones[:2],
                    "locations": locations,
                }

            return {"found": False}

        except Exception as e:
            logger.error(f"Whitepages search error: {str(e)}")
            return {"found": False, "error": str(e)}

    async def search_411_com(
        self, name: str, state: Optional[str] = None, city: Optional[str] = None
    ) -> Dict[str, Any]:
        """
        Search 411.com for person information.
        This is a free public directory.
        """
        try:
            # Build 411.com search URL
            name_encoded = quote_plus(name)
            location = ""
            if city and state:
                location = quote_plus(f"{city} {state}")
            elif state:
                location = quote_plus(state)

            url = (
                f"https://www.411.com/name/{name_encoded}/{location}"
                if location
                else f"https://www.411.com/name/{name_encoded}"
            )

            logger.info(f"411.com search: {name} {location or ''}")

            html = await self._fetch_html(url)

            if not html:
                return {"found": False}

            # Extract phone numbers and addresses
            phones = self._extract_phone_numbers(html)

            # Look for address information
            soup = BeautifulSoup(html, "html.parser")
            address_divs = soup.find_all("div", class_="address")
            addresses = []
            for div in address_divs[:2]:
                addresses.append(div.get_text(strip=True))

            if phones or addresses:
                return {
                    "found": True,
                    "source": "411.com",
                    "phones": phones[:2],
                    "addresses": addresses,
                }

            return {"found": False}

        except Exception as e:
            logger.error(f"411.com search error: {str(e)}")
            return {"found": False, "error": str(e)}

    async def comprehensive_search(
        self, name: str, state: Optional[str] = None, city: Optional[str] = None
    ) -> Dict[str, Any]:
        """
        Execute comprehensive free skip trace search across ALL 5 sources.
        Aggregates results from all available free sources.

        Sources searched (in parallel):
        1. TruePeopleSearch (specialized, high accuracy)
        2. FastPeopleSearch (specialized, high accuracy)
        3. Google Search (general)
        4. Whitepages (directory)
        5. 411.com (directory)
        """
        logger.info(f"🔍 Starting comprehensive free search (5 sources) for: {name}, {city or ''} {state or ''}")

        start_time = time.time()

        # Parse name for specialized sites
        name_parts = name.split()
        first_name = name_parts[0] if len(name_parts) > 0 else ""
        last_name = name_parts[-1] if len(name_parts) > 1 else ""

        # Execute all 5 searches in parallel for maximum speed
        search_tasks = [
            self.search_google(name, state, city),
            self.search_whitepages(name, state),
            self.search_411_com(name, state, city),
        ]

        # Add specialized searches if we have name components and location
        if first_name and last_name and city and state:
            search_tasks.extend(
                [
                    self.search_truepeoplesearch(first_name, last_name, city, state),
                    self.search_fastpeoplesearch(first_name, last_name, city, state),
                ]
            )

        results = await asyncio.gather(*search_tasks, return_exceptions=True)

        # Aggregate results
        all_phones = []
        all_emails = []
        all_addresses = []
        sources_found = []

        for result in results:
            if isinstance(result, dict) and result.get("found"):
                sources_found.append(result.get("source", "Unknown"))

                # Collect phones
                for phone in result.get("phones", []):
                    if phone not in all_phones:
                        all_phones.append(phone)

                # Collect emails
                for email in result.get("emails", []):
                    if email not in all_emails:
                        all_emails.append(email)

                # Collect addresses/locations
                for addr in result.get("addresses", []) + result.get("locations", []):
                    if addr and addr not in all_addresses:
                        all_addresses.append(addr)

        execution_time = time.time() - start_time

        # Calculate confidence based on data completeness
        confidence = 0.0
        if all_phones:
            confidence += 0.5  # Phone is most important for outreach
        if all_emails:
            confidence += 0.3
        if all_addresses:
            confidence += 0.1
        if len(sources_found) >= 2:
            confidence += 0.1  # Multiple sources corroborate

        found = len(all_phones) > 0 or len(all_emails) > 0

        logger.info(
            f"Free search completed: found={found}, phones={len(all_phones)}, "
            f"emails={len(all_emails)}, time={execution_time:.2f}s"
        )

        return {
            "found": found,
            "phones": all_phones,
            "emails": all_emails,
            "addresses": all_addresses,
            "sources": sources_found,
            "confidence": confidence,
            "execution_time": execution_time,
        }

    # ========================================================================
    # BACKWARD COMPATIBILITY METHOD (for ai_cascading_skip_trace.py)
    # ========================================================================

    async def free_skip_trace(
        self, first_name: str, last_name: str, city: str, state: str
    ) -> Optional[Dict[str, Any]]:
        """
        Backward compatibility method for ai_cascading_skip_trace.py

        This method provides the same interface as the old scrapers/free_skip_trace_service.py
        but now uses the comprehensive search across all 5 sources internally.

        Returns format compatible with cascading skip trace:
        {
            'phones': [...] or 'phone': '...',
            'source': '...',
            'confidence': 0.0-1.0
        }
        """
        logger.info(f"[FREE] Skip tracing (backward compat): {first_name} {last_name}, {city}, {state}")

        # First try specialized sites sequentially (TruePeopleSearch -> FastPeopleSearch)
        # for fastest results, then fall back to comprehensive search if needed
        result = await self.search_truepeoplesearch(first_name, last_name, city, state)
        if result and result.get("found") and result.get("phones"):
            return result

        # Add small delay before next attempt
        await asyncio.sleep(random.uniform(2, 4))

        result = await self.search_fastpeoplesearch(first_name, last_name, city, state)
        if result and result.get("found") and result.get("phones"):
            # Normalize to 'phone' singular for backward compatibility
            phones = result.get("phones", [])
            if phones:
                result["phone"] = phones[0]
            return result

        # If specialized sites failed, try comprehensive search as fallback
        full_name = f"{first_name} {last_name}"
        comprehensive_result = await self.comprehensive_search(full_name, state, city)

        if comprehensive_result.get("found") and comprehensive_result.get("phones"):
            # Convert to backward compatible format
            return {
                "phones": comprehensive_result.get("phones", []),
                "phone": comprehensive_result.get("phones", [None])[0],
                "source": ", ".join(comprehensive_result.get("sources", ["Free Sources"])),
                "confidence": comprehensive_result.get("confidence", 0.5),
            }

        return None


# Global instance
free_skip_trace_provider = FreeSkipTraceProvider()
