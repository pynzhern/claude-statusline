#!/usr/bin/env python3
"""
claude-statusline: usage data fetcher
fetches live plan usage from claude.ai and caches it for 5 minutes.

supported platforms: macOS, Linux
requires: pycryptodome  (pip install pycryptodome)
"""
import hashlib
import json
import os
import re
import sqlite3
import subprocess
import sys
import time
from datetime import datetime, timezone

CACHE_FILE = '/tmp/claude_usage_cache.json'
CACHE_TTL  = 300  # seconds


# ── cache ──────────────────────────────────────────────────────────────────────

def load_cache():
    try:
        with open(CACHE_FILE) as f:
            data = json.load(f)
        if time.time() - data.get('_cached_at', 0) < CACHE_TTL:
            return data
    except Exception:
        pass
    return None

def save_cache(data):
    data['_cached_at'] = time.time()
    with open(CACHE_FILE, 'w') as f:
        json.dump(data, f)


# ── platform: cookie db path ───────────────────────────────────────────────────

def cookie_db_path():
    if sys.platform == 'darwin':
        return os.path.expanduser('~/Library/Application Support/Claude/Cookies')
    if sys.platform == 'linux':
        # try XDG_CONFIG_HOME first, then fall back to ~/.config
        cfg = os.environ.get('XDG_CONFIG_HOME', os.path.expanduser('~/.config'))
        return os.path.join(cfg, 'Claude', 'Cookies')
    raise RuntimeError(f'unsupported platform: {sys.platform}')


# ── platform: AES key derivation ──────────────────────────────────────────────

def derive_key_macos():
    """read safe storage password from macOS keychain and derive AES-128 key."""
    result = subprocess.run(
        ['security', 'find-generic-password',
         '-s', 'Claude Safe Storage', '-a', 'Claude Key', '-w'],
        capture_output=True, text=True, timeout=5
    )
    if result.returncode != 0:
        raise RuntimeError('could not read Claude Safe Storage from keychain')
    password = result.stdout.strip().encode()
    # macOS Chrome/Electron: PBKDF2-SHA1, 1003 iterations
    return hashlib.pbkdf2_hmac('sha1', password, b'saltysalt', 1003, dklen=16)

def derive_key_linux():
    """derive AES-128 key for Linux Electron cookie encryption."""
    # try libsecret / secretstorage first
    try:
        import secretstorage
        bus = secretstorage.dbus_init()
        col = secretstorage.get_default_collection(bus)
        for item in col.get_all_items():
            if 'Claude' in item.get_label():
                password = item.get_secret()
                # Linux Chrome/Electron: PBKDF2-SHA1, 1 iteration
                return hashlib.pbkdf2_hmac('sha1', password, b'saltysalt', 1, dklen=16)
    except Exception:
        pass
    # fallback: Electron uses 'peanuts' when no system keyring is available
    return hashlib.pbkdf2_hmac('sha1', b'peanuts', b'saltysalt', 1, dklen=16)

def get_aes_key():
    if sys.platform == 'darwin':
        return derive_key_macos()
    if sys.platform == 'linux':
        return derive_key_linux()
    raise RuntimeError(f'unsupported platform: {sys.platform}')


# ── cookie decryption ──────────────────────────────────────────────────────────

def decrypt_cookie(enc_val, key):
    """decrypt a v10 AES-128-CBC Electron cookie value."""
    from Crypto.Cipher import AES
    enc = bytes(enc_val)[3:]              # strip 'v10' prefix
    iv, ct = enc[:16], enc[16:]
    cipher = AES.new(key, AES.MODE_CBC, iv)
    dec = cipher.decrypt(ct)
    return dec[:-dec[-1]].decode('latin1')

def get_auth(key):
    """return (session_key, cf_clearance, org_id) from the Electron cookie db."""
    db = sqlite3.connect(cookie_db_path())
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

    m = re.search(
        r'([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]+)',
        raw.get('lastActiveOrg', '')
    )
    org_id = m.group(1) if m else ''

    return session_key, cf_clearance, org_id


# ── API calls ──────────────────────────────────────────────────────────────────

def fetch(url, session_key, cf_clearance):
    import urllib.request
    headers = {
        'Cookie': f'sessionKey={session_key}; cf_clearance={cf_clearance}',
        'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36',
        'Accept': 'application/json',
    }
    req = urllib.request.Request(url, headers=headers)
    return json.loads(urllib.request.urlopen(req, timeout=5).read())


# ── formatting ─────────────────────────────────────────────────────────────────

def time_until(iso_str):
    """human-readable countdown: Xd Yh or Xh YYm."""
    try:
        dt   = datetime.fromisoformat(iso_str.replace('Z', '+00:00'))
        now  = datetime.now(timezone.utc)
        secs = max(0, int((dt - now).total_seconds()))
        d, rem = divmod(secs, 86400)
        h = rem // 3600
        m = (rem % 3600) // 60
        if d > 0:
            return f'{d}d{h}h' if h else f'{d}d'
        if h > 0:
            return f'{h}h{m:02d}m' if m else f'{h}h'
        return f'{m}m'
    except Exception:
        return '?'


# ── main ───────────────────────────────────────────────────────────────────────

def main():
    cached = load_cache()
    if cached:
        print(json.dumps(cached))
        return

    try:
        key = get_aes_key()
        session_key, cf_clearance, org_id = get_auth(key)
        if not session_key or not org_id:
            print(json.dumps({}))
            return

        base    = f'https://claude.ai/api/organizations/{org_id}'
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
            result['prepaid_balance']  = f"{prepaid['amount'] / 100:.2f}"
            result['prepaid_currency'] = prepaid.get('currency', 'USD')

        save_cache(result)
        print(json.dumps(result))

    except Exception:
        print(json.dumps({}))


if __name__ == '__main__':
    main()
