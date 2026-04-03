import json
import os
import ssl
from datetime import datetime, timedelta, timezone
from typing import Optional
import boto3
import requests
from requests.adapters import HTTPAdapter
from urllib3.poolmanager import PoolManager
from urllib3.util.retry import Retry

 
DEFAULT_TIMEOUT = (5, 15)
PER_PAGE = 50
s3 = boto3.client("s3")
secrets = boto3.client("secretsmanager")
_token_cache: Optional[str] = None

class TLS13OnlyAdapter(HTTPAdapter):
    """Force TLS 1.3 for all HTTPS connections."""
    def init_poolmanager(self, connections, maxsize, block=False, **pool_kwargs):
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        ctx.minimum_version = ssl.TLSVersion.TLSv1_3
        ctx.maximum_version = ssl.TLSVersion.TLSv1_3
        ctx.check_hostname = True
        ctx.verify_mode = ssl.CERT_REQUIRED
        ctx.load_default_certs()
        self.poolmanager = PoolManager(
            num_pools=connections,
            maxsize=maxsize,
            block=block,
            ssl_context=ctx,
            **pool_kwargs,
        )

def build_session() -> requests.Session:
    retry = Retry(
        total=3,
        connect=3,
        read=3,
        backoff_factor=1,
        status_forcelist=[429, 500, 502, 503, 504],
        allowed_methods=["GET"],
    )
    session = requests.Session()
    adapter = TLS13OnlyAdapter(max_retries=retry)
    session.mount("https://", adapter)
    return session

def load_plaintext_secret(secret_id: str) -> str:
    """Load the plain-text Monday audit token from Secrets Manager."""
    global _token_cache
    if _token_cache:
        return _token_cache
    response = secrets.get_secret_value(SecretId=secret_id)
    secret = response.get("SecretString")
    if not secret:
        raise RuntimeError("SecretString is empty or missing.")
    _token_cache = secret.strip()
    return _token_cache

def get_last_hour_timestamp() -> str:
    """Return ISO8601 UTC timestamp for one hour ago."""
    ts = datetime.now(timezone.utc) - timedelta(hours=1)
    return ts.replace(microsecond=0).isoformat().replace("+00:00", "Z")

def build_logs_url(domain: str, page: int, per_page: int, start_time: str) -> str:
    """Build the Monday audit logs URL and enforce HTTPS."""
    if not domain:
        raise ValueError("MONDAY_DOMAIN is required.")
    filters = json.dumps({"start_time": start_time}, separators=(",", ":"))
    url = (
        f"https://{domain}.monday.com/audit-api/get-logs"
        f"?page={page}&per_page={per_page}&filters={filters}"
    )
    if not url.startswith("https://"):
        raise RuntimeError("Refusing non-HTTPS URL.")
    return url

def fetch_last_hour_logs(
    session: requests.Session,
    domain: str,
    token: str,
    context=None,
) -> list[dict]:
    """Fetch all Monday audit logs from the last hour."""
    start_time = get_last_hour_timestamp()
    all_logs: list[dict] = []
    page = 1
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/json",
    }
    while True:
        if context and context.get_remaining_time_in_millis() < 5000:
            break
        url = build_logs_url(
            domain=domain,
            page=page,
            per_page=PER_PAGE,
            start_time=start_time,
        )
        response = session.get(url, headers=headers, timeout=DEFAULT_TIMEOUT)
        response.raise_for_status()
        payload = response.json()
        logs = payload.get("data", [])
        if not logs:
            break
        all_logs.extend(logs)
        if payload.get("next_page") is None:
            break
        page += 1
    return all_logs

def write_logs_to_s3(bucket: str, logs: list[dict]) -> Optional[str]:
    """Write logs as a JSON file into S3."""
    if not logs:
        return None
    now = datetime.now(timezone.utc)
    key = f"monday/audit/{now:%Y-%m-%d-%H:%M:%S}.json"
    s3.put_object(
        Bucket=bucket,
        Key=key,
        Body=json.dumps(logs, ensure_ascii=False).encode("utf-8"),
        ContentType="application/json",
    )
    return key

def lambda_handler(event, context):
    """AWS Lambda entrypoint."""
    domain = os.environ["MONDAY_DOMAIN"]
    bucket = os.environ["AUDIT_BUCKET"]
    secret_id = os.environ["TOKEN_SECRET"]
    token = load_plaintext_secret(secret_id)
    session = build_session()
    logs = fetch_last_hour_logs(
        session=session,
        domain=domain,
        token=token,
        context=context,
    )
    s3_key = write_logs_to_s3(bucket, logs)
    return {
        "statusCode": 200,
        "events_collected": len(logs),
        "s3_key": s3_key,
        "window": "last_hour",
    }