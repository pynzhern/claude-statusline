#!/usr/bin/env python3
"""
claude usage data fetcher for the statusline.
caches results for 5 minutes so the API is not hammered on every refresh.
outputs JSON with usage percentages and prepaid balance.
"""
import json, math, os, sqlite3, subprocess, hashlib, re, time
from datetime import datetime, timezone

CACHE_FILE = '/tmp/claude_usage_cache.json'
CACHE_TTL  = 300  # 5 minutes

def load_cache(stale_ok=False):
    try:
        with open(CACHE_FILE) as f:
            data = json.load(f)
        age = time.time() - data.get('_cached_at', 0)
        if stale_ok or age < CACHE_TTL:
            return data
    except Exception:
        pass
    return None

def save_cache(data):
    data['_cached_at'] = time.time()
    with open(CACHE_FILE, 'w') as f:
        json.dump(data, f)

def get_aes_key():
    result = subprocess.run(
        ['security', 'find-generic-password', '-s', 'Claude Safe Storage', '-a', 'Claude Key', '-w'],
        capture_output=True, text=True, timeout=5
    )
    safe_key = result.stdout.strip().encode()
    from Crypto.Cipher import AES as _AES  # noqa: F401 — ensure import works
    return hashlib.pbkdf2_hmac('sha1', safe_key, b'saltysalt', 1003, dklen=16)

def decrypt_cookie(enc_val, key):
    from Crypto.Cipher import AES
    enc = bytes(enc_val)[3:]          # strip 'v10' prefix
    cipher = AES.new(key, AES.MODE_CBC, enc[:16])
    dec = cipher.decrypt(enc[16:])
    return dec[:-dec[-1]].decode('latin1')

def get_auth(key):
    db_path = os.path.expanduser('~/Library/Application Support/Claude/Cookies')
    db = sqlite3.connect(db_path)
    rows = db.execute("""
        SELECT name, encrypted_value FROM cookies
        WHERE host_key LIKE '%claude.ai%'
        AND name IN ('sessionKey', 'cf_clearance', 'lastActiveOrg')
    """).fetchall()
    db.close()

    raw = {name: decrypt_cookie(v, key) for name, v in rows}

    m = re.search(r'sk-ant-sid\d+-[\w-]+', raw.get('sessionKey', ''))
    session_key = m.group() if m else ''

    m = re.search(r'`(.+)', raw.get('cf_clearance', ''))
    cf_clearance = m.group(1) if m else ''

    m = re.search(r'([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]+)',
                  raw.get('lastActiveOrg', ''))
    org_id = m.group(1) if m else ''

    return session_key, cf_clearance, org_id

def fetch(url, session_key, cf_clearance):
    # curl_cffi impersonates Chrome's TLS fingerprint, bypassing Cloudflare's JA3 check
    from curl_cffi import requests as cffi_requests
    resp = cffi_requests.get(
        url,
        cookies={'sessionKey': session_key, 'cf_clearance': cf_clearance},
        headers={'Accept': 'application/json'},
        impersonate='chrome',
        timeout=5,
    )
    resp.raise_for_status()
    return resp.json()

def time_until(iso_str):
    """Human-readable countdown to an ISO 8601 timestamp (hours/mins rounded up)."""
    try:
        dt   = datetime.fromisoformat(iso_str.replace('Z', '+00:00'))
        now  = datetime.now(timezone.utc)
        secs = max(0, (dt - now).total_seconds())
        if secs >= 86400:
            d = int(secs // 86400)
            h = math.ceil((secs % 86400) / 3600)
            if h == 24:
                d += 1; h = 0
            return f'{d}d{h}h' if h else f'{d}d'
        if secs >= 3600:
            h = int(secs // 3600)
            m = math.ceil((secs % 3600) / 60)
            if m == 60:
                h += 1; m = 0
            return f'{h}h{m:02d}m' if m else f'{h}h'
        m = math.ceil(secs / 60)
        return f'{m}m'
    except Exception:
        return '?'

def main():
    cached = load_cache()
    if cached:
        print(json.dumps(cached))
        return

    try:
        key  = get_aes_key()
        session_key, cf_clearance, org_id = get_auth(key)
        if not session_key or not org_id:
            print(json.dumps(load_cache(stale_ok=True) or {}))
            return

        base = f'https://claude.ai/api/organizations/{org_id}'
        usage   = fetch(f'{base}/usage', session_key, cf_clearance)
        prepaid = fetch(f'{base}/prepaid/credits', session_key, cf_clearance)

        result = {}

        fh = usage.get('five_hour')
        if fh:
            result['five_hour_pct']       = int(fh.get('utilization', 0))
            result['five_hour_resets_in'] = time_until(fh.get('resets_at', ''))

        sd = usage.get('seven_day')
        if sd:
            result['seven_day_pct']       = int(sd.get('utilization', 0))
            result['seven_day_resets_in'] = time_until(sd.get('resets_at', ''))

        if prepaid and 'amount' in prepaid:
            amount   = prepaid['amount']          # in minor units (cents)
            currency = prepaid.get('currency', 'SGD')
            result['prepaid_balance']  = f'{amount / 100:.2f}'
            result['prepaid_currency'] = currency

        save_cache(result)
        print(json.dumps(result))

    except Exception:
        # fall back to stale cache rather than showing nothing
        print(json.dumps(load_cache(stale_ok=True) or {}))

if __name__ == '__main__':
    main()
