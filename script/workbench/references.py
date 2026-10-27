"""Bounded public documentation only; no caller URLs, redirects or credentials."""
import hashlib
import time
from html.parser import HTMLParser
import urllib.request

from repository import NoRedirect

CATALOG = {
    'python-json': 'https://docs.python.org/3/library/json.html',
    'python-unittest': 'https://docs.python.org/3/library/unittest.html',
    'python-csv': 'https://docs.python.org/3/library/csv.html',
    'perl-json-pp': 'https://metacpan.org/pod/JSON::PP',
    'perl-test-more': 'https://metacpan.org/pod/Test::More',
}


class Text(HTMLParser):
    def __init__(self):
        super().__init__()
        self.parts, self.hidden = [], 0

    def handle_starttag(self, tag, attrs):
        if tag in ('script', 'style'): self.hidden += 1

    def handle_endtag(self, tag):
        if tag in ('script', 'style'): self.hidden = max(0, self.hidden - 1)

    def handle_data(self, data):
        if not self.hidden and data.strip(): self.parts.append(data.strip())


class References:
    def __init__(self):
        self.cache = {}

    def read(self, key):
        if not isinstance(key, str) or key not in CATALOG:
            raise ValueError('unknown reference; available: ' + ', '.join(CATALOG))
        if key not in self.cache:
            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
            req = urllib.request.Request(CATALOG[key], headers={'User-Agent': 'burt-reference/1'})
            started = time.monotonic()
            with opener.open(req, timeout=5) as response:
                if response.geturl() != CATALOG[key]:
                    raise ValueError('reference URL changed')
                raw = bytearray()
                while len(raw) <= 262144:
                    if time.monotonic() - started > 10:
                        raise ValueError('reference deadline exceeded')
                    chunk = response.read1(min(4096, 262145 - len(raw)))
                    if not chunk: break
                    raw.extend(chunk)
            parser = Text()
            parser.feed(raw.decode('utf-8', errors='replace'))
            self.cache[key] = dict(reference=key, url=CATALOG[key], sha256=hashlib.sha256(raw).hexdigest(),
                                   text='\n'.join(parser.parts)[:24000], untrusted=True,
                                   truncated=len(raw) > 262144 or len('\n'.join(parser.parts)) > 24000)
        return self.cache[key].copy()
