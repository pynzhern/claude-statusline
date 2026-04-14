#!/usr/bin/env python3
"""
claude usage data fetcher for the statusline.
caches results for 5 minutes so the API is not hammered on every refresh.
outputs JSON with usage percentages and prepaid balance.
"""
# only cheap stdlib imports at module load — heavier deps (Crypto, curl_cffi,
# sqlite3, subprocess) are imported lazily inside the cache-miss branch so the
# hot path stays fast. datetime is always needed (emit → time_until) so it
# lives at module level.
import json, os, time
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
    import subprocess, hashlib
    result = subprocess.run(
        ['security', 'find-generic-password', '-s', 'Claude Safe Storage', '-a', 'Claude Key', '-w'],
        capture_output=True, text=True, timeout=5
    )
    safe_key = result.stdout.strip().encode()
    return hashlib.pbkdf2_hmac('sha1', safe_key, b'saltysalt', 1003, dklen=16)

def decrypt_cookie(enc_val, key):
    from Crypto.Cipher import AES
    enc = bytes(enc_val)[3:]          # strip 'v10' prefix
    cipher = AES.new(key, AES.MODE_CBC, enc[:16])
    dec = cipher.decrypt(enc[16:])
    return dec[:-dec[-1]].decode('latin1')

def get_auth(key):
    import sqlite3, re
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
    """Human-readable countdown to an ISO 8601 timestamp (rounded up to the nearest minute)."""
    try:
        if not iso_str:
            return '—'
        dt   = datetime.fromisoformat(iso_str.replace('Z', '+00:00'))
        now  = datetime.now(timezone.utc)
        secs = max(0, (dt - now).total_seconds())
    except Exception:
        return '?'

    # round up to whole minutes via integer arithmetic, then divmod the carry
    total_mins = -(-int(secs) // 60)
    days,  rem_mins = divmod(total_mins, 24 * 60)
    hours, mins     = divmod(rem_mins, 60)

    if days:
        return f'{days}d{hours}h' if hours else f'{days}d'
    if hours:
        return f'{hours}h{mins:02d}m' if mins else f'{hours}h'
    return f'{mins}m'

def emit(data):
    """Output data with resets_in computed fresh from stored resets_at timestamps.
    resets_at is the raw ISO string from the API; we compute time_until() on every
    call so the countdown is always accurate regardless of how old the cache is."""
    out = {k: v for k, v in data.items() if not k.startswith('_')}
    if 'five_hour_resets_at' in out:
        out['five_hour_resets_in'] = time_until(out.pop('five_hour_resets_at'))
    if 'seven_day_resets_at' in out:
        out['seven_day_resets_in'] = time_until(out.pop('seven_day_resets_at'))
    print(json.dumps(out))

def main():
    # fast path: parse the cache, check _cached_at (zeroed by the Stop hook after
    # each Claude response), and emit with freshly computed countdowns so the
    # reset timers stay accurate across the 5-minute cache window.
    # also bypass the cache if any usage window has already reset — the stored
    # percentages are guaranteed stale once resets_at has passed.
    try:
        with open(CACHE_FILE) as f:
            data = json.load(f)
        now = datetime.now(timezone.utc)
        window_reset = any(
            datetime.fromisoformat(data[k].replace('Z', '+00:00')) <= now
            for k in ('five_hour_resets_at', 'seven_day_resets_at')
            if data.get(k)
        )
        if time.time() - data.get('_cached_at', 0) < CACHE_TTL and not window_reset:
            emit(data)
            return
    except Exception:
        pass

    try:
        key  = get_aes_key()
        session_key, cf_clearance, org_id = get_auth(key)
        if not session_key or not org_id:
            emit(load_cache(stale_ok=True) or {})
            return

        base = f'https://claude.ai/api/organizations/{org_id}'
        usage   = fetch(f'{base}/usage', session_key, cf_clearance)
        prepaid = fetch(f'{base}/prepaid/credits', session_key, cf_clearance)

        result = {}

        fh = usage.get('five_hour')
        if fh:
            result['five_hour_pct']       = int(fh.get('utilization', 0))
            result['five_hour_resets_at'] = fh.get('resets_at', '')

        sd = usage.get('seven_day')
        if sd:
            result['seven_day_pct']       = int(sd.get('utilization', 0))
            result['seven_day_resets_at'] = sd.get('resets_at', '')

        if prepaid and 'amount' in prepaid:
            amount   = prepaid['amount']          # in minor units (cents)
            currency = prepaid.get('currency', 'SGD')
            result['prepaid_balance']  = f'{amount / 100:.2f}'
            result['prepaid_currency'] = currency

        save_cache(result)
        emit(result)

    except Exception:
        # fall back to stale cache rather than showing nothing
        emit(load_cache(stale_ok=True) or {})

if __name__ == '__main__':
    main()
