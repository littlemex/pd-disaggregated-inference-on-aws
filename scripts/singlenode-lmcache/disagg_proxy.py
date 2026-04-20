"""
Disaggregated Inference Proxy Server (LMCache + ElastiCache Valkey)

Prefill-Decode 分離推論のリクエストルーティングを実装する。

処理フロー:
  1. Client -> Proxy: リクエスト受信
  2. Proxy -> Prefill server: max_tokens=1 で送信 (KV cache を ElastiCache に保存)
  3. Proxy -> Decode server: 元のリクエストを転送 (KV cache を ElastiCache から取得)
  4. Decode server -> Client: 生成結果を返す

KV cache handoff の仕組み:
  - Prefill server (kv_role=kv_both): プロンプトの prefill を実行し、KV cache を
    ElastiCache Serverless Valkey に保存する
  - Decode server (kv_role=kv_consumer): 同じプロンプトハッシュで ElastiCache から
    KV cache を取得し、decode のみを実行する
  - LMCache は同一 hash_algorithm + chunk_size でプロンプトのハッシュが一致すれば
    自動的に KV cache を再利用する

使用方法:
  python3 scripts/disagg_proxy.py \\
    --prefill-url http://localhost:8100 \\
    --decode-url http://localhost:8200 \\
    --port 9000

  # ローカルテスト (Prefill/Decode が同一ホスト)
  python3 scripts/disagg_proxy.py

  # リモート Decode server
  python3 scripts/disagg_proxy.py \\
    --prefill-url http://localhost:8100 \\
    --decode-url http://10.0.1.50:8200
"""

import argparse
import asyncio
import json
import logging
import time
import uuid
from dataclasses import dataclass, field
from typing import Optional

import aiohttp
from aiohttp import web

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
logger = logging.getLogger("disagg_proxy")


@dataclass
class ProxyConfig:
    """Proxy 設定"""

    prefill_url: str = "http://localhost:8100"
    decode_url: str = "http://localhost:8200"
    port: int = 9000
    host: str = "0.0.0.0"
    timeout: int = 300
    prefill_max_tokens: int = 1
    health_check_interval: int = 30


@dataclass
class RequestMetrics:
    """リクエストメトリクス"""

    request_id: str = ""
    prefill_start: float = 0.0
    prefill_end: float = 0.0
    decode_start: float = 0.0
    decode_end: float = 0.0
    total_start: float = 0.0
    total_end: float = 0.0
    prefill_status: int = 0
    decode_status: int = 0
    error: Optional[str] = None

    @property
    def prefill_latency_ms(self) -> float:
        if self.prefill_start and self.prefill_end:
            return (self.prefill_end - self.prefill_start) * 1000
        return 0.0

    @property
    def decode_latency_ms(self) -> float:
        if self.decode_start and self.decode_end:
            return (self.decode_end - self.decode_start) * 1000
        return 0.0

    @property
    def total_latency_ms(self) -> float:
        if self.total_start and self.total_end:
            return (self.total_end - self.total_start) * 1000
        return 0.0


class DisaggProxy:
    """Prefill-Decode Disaggregated Inference Proxy"""

    def __init__(self, config: ProxyConfig):
        self.config = config
        self.session: Optional[aiohttp.ClientSession] = None
        self.request_count = 0
        self.error_count = 0
        self.metrics_history: list[RequestMetrics] = []

    async def setup(self):
        """HTTP session を作成"""
        timeout = aiohttp.ClientTimeout(total=self.config.timeout)
        self.session = aiohttp.ClientSession(timeout=timeout)

    async def cleanup(self):
        """HTTP session を閉じる"""
        if self.session:
            await self.session.close()

    async def _prefill_request(
        self, path: str, payload: dict, metrics: RequestMetrics
    ) -> bool:
        """
        Prefill server にリクエストを送信して KV cache を生成させる。

        - max_tokens=1 で送信し、プロンプトの prefill のみを実行
        - KV cache は LMCache 経由で ElastiCache に自動保存される
        - stream=False で同期的に完了を待つ
        """
        prefill_payload = payload.copy()
        prefill_payload["max_tokens"] = self.config.prefill_max_tokens
        prefill_payload["stream"] = False

        url = f"{self.config.prefill_url}{path}"
        logger.info(
            "[Prefill] request_id=%s sending to %s", metrics.request_id, url
        )

        metrics.prefill_start = time.time()

        try:
            async with self.session.post(url, json=prefill_payload) as resp:
                metrics.prefill_status = resp.status
                metrics.prefill_end = time.time()

                if resp.status != 200:
                    body = await resp.text()
                    logger.error(
                        "[Prefill] request_id=%s failed status=%d body=%s",
                        metrics.request_id,
                        resp.status,
                        body[:500],
                    )
                    metrics.error = f"Prefill failed: status={resp.status}"
                    return False

                result = await resp.json()
                usage = result.get("usage", {})
                logger.info(
                    "[Prefill] request_id=%s completed latency=%.0fms usage=%s",
                    metrics.request_id,
                    metrics.prefill_latency_ms,
                    usage,
                )
                return True

        except asyncio.TimeoutError:
            metrics.prefill_end = time.time()
            logger.error(
                "[Prefill] request_id=%s timeout after %ds",
                metrics.request_id,
                self.config.timeout,
            )
            metrics.error = "Prefill timeout"
            return False
        except Exception as e:
            metrics.prefill_end = time.time()
            logger.error(
                "[Prefill] request_id=%s exception: %s", metrics.request_id, e
            )
            metrics.error = f"Prefill exception: {e}"
            return False

    async def _decode_request(
        self, path: str, payload: dict, metrics: RequestMetrics, stream: bool
    ):
        """
        Decode server にリクエストを転送して生成を実行する。

        - 同じプロンプトハッシュにより LMCache が ElastiCache から KV cache を取得
        - Decode server のログに "LMCache hit tokens: N" (N > 0) が出れば成功
        """
        url = f"{self.config.decode_url}{path}"
        logger.info(
            "[Decode] request_id=%s sending to %s stream=%s",
            metrics.request_id,
            url,
            stream,
        )

        metrics.decode_start = time.time()

        try:
            async with self.session.post(url, json=payload) as resp:
                metrics.decode_status = resp.status

                if resp.status != 200:
                    metrics.decode_end = time.time()
                    body = await resp.text()
                    logger.error(
                        "[Decode] request_id=%s failed status=%d body=%s",
                        metrics.request_id,
                        resp.status,
                        body[:500],
                    )
                    metrics.error = f"Decode failed: status={resp.status}"
                    return web.Response(
                        text=json.dumps({"error": body}),
                        status=resp.status,
                        content_type="application/json",
                    )

                if stream:
                    # Streaming response
                    response = web.StreamResponse(
                        status=200,
                        headers={"Content-Type": "text/event-stream"},
                    )
                    await response.prepare(None)  # placeholder, set in handler

                    async for chunk in resp.content.iter_any():
                        await response.write(chunk)

                    metrics.decode_end = time.time()
                    await response.write_eof()
                    return response
                else:
                    body = await resp.read()
                    metrics.decode_end = time.time()
                    logger.info(
                        "[Decode] request_id=%s completed latency=%.0fms",
                        metrics.request_id,
                        metrics.decode_latency_ms,
                    )
                    return web.Response(
                        body=body,
                        status=200,
                        content_type="application/json",
                    )

        except asyncio.TimeoutError:
            metrics.decode_end = time.time()
            logger.error(
                "[Decode] request_id=%s timeout", metrics.request_id
            )
            metrics.error = "Decode timeout"
            return web.Response(
                text=json.dumps({"error": "Decode timeout"}),
                status=504,
                content_type="application/json",
            )
        except Exception as e:
            metrics.decode_end = time.time()
            logger.error(
                "[Decode] request_id=%s exception: %s", metrics.request_id, e
            )
            metrics.error = f"Decode exception: {e}"
            return web.Response(
                text=json.dumps({"error": str(e)}),
                status=502,
                content_type="application/json",
            )

    async def handle_request(self, request: web.Request) -> web.Response:
        """
        Prefill -> Decode ルーティングのメインハンドラ。

        フロー:
          1. Client からリクエストを受信
          2. Prefill server に max_tokens=1 で送信 (KV cache 生成)
          3. Decode server に元のリクエストを転送 (KV cache 再利用)
          4. Decode の結果を Client に返す
        """
        self.request_count += 1
        metrics = RequestMetrics(
            request_id=str(uuid.uuid4())[:8],
            total_start=time.time(),
        )

        try:
            payload = await request.json()
        except Exception as e:
            return web.Response(
                text=json.dumps({"error": f"Invalid JSON: {e}"}),
                status=400,
                content_type="application/json",
            )

        path = request.path
        stream = payload.get("stream", False)

        logger.info(
            "[Proxy] request_id=%s path=%s model=%s stream=%s",
            metrics.request_id,
            path,
            payload.get("model", "unknown"),
            stream,
        )

        # Step 1: Prefill (KV cache 生成)
        prefill_ok = await self._prefill_request(path, payload, metrics)
        if not prefill_ok:
            self.error_count += 1
            metrics.total_end = time.time()
            self.metrics_history.append(metrics)
            return web.Response(
                text=json.dumps({
                    "error": "Prefill stage failed",
                    "detail": metrics.error,
                    "request_id": metrics.request_id,
                }),
                status=502,
                content_type="application/json",
            )

        # Step 2: Decode (KV cache 再利用 + 生成)
        if stream:
            # Streaming の場合は StreamResponse を使用
            response = web.StreamResponse(
                status=200,
                headers={
                    "Content-Type": "text/event-stream",
                    "Cache-Control": "no-cache",
                    "Connection": "keep-alive",
                },
            )
            await response.prepare(request)

            url = f"{self.config.decode_url}{path}"
            metrics.decode_start = time.time()

            try:
                async with self.session.post(url, json=payload) as resp:
                    metrics.decode_status = resp.status
                    if resp.status != 200:
                        body = await resp.text()
                        await response.write(
                            f"data: {json.dumps({'error': body})}\n\n".encode()
                        )
                    else:
                        async for chunk in resp.content.iter_any():
                            await response.write(chunk)
            except Exception as e:
                logger.error(
                    "[Decode/Stream] request_id=%s exception: %s",
                    metrics.request_id,
                    e,
                )

            metrics.decode_end = time.time()
            metrics.total_end = time.time()
            self.metrics_history.append(metrics)

            logger.info(
                "[Proxy] request_id=%s completed total=%.0fms prefill=%.0fms decode=%.0fms",
                metrics.request_id,
                metrics.total_latency_ms,
                metrics.prefill_latency_ms,
                metrics.decode_latency_ms,
            )

            await response.write_eof()
            return response
        else:
            decode_response = await self._decode_request(
                path, payload, metrics, stream=False
            )
            metrics.total_end = time.time()
            self.metrics_history.append(metrics)

            logger.info(
                "[Proxy] request_id=%s completed total=%.0fms prefill=%.0fms decode=%.0fms",
                metrics.request_id,
                metrics.total_latency_ms,
                metrics.prefill_latency_ms,
                metrics.decode_latency_ms,
            )

            return decode_response

    async def handle_health(self, request: web.Request) -> web.Response:
        """ヘルスチェック: Prefill と Decode 双方の状態を返す"""
        status = {"proxy": "ok", "prefill": "unknown", "decode": "unknown"}

        try:
            async with self.session.get(
                f"{self.config.prefill_url}/health",
                timeout=aiohttp.ClientTimeout(total=5),
            ) as resp:
                status["prefill"] = "ok" if resp.status == 200 else "error"
        except Exception:
            status["prefill"] = "unreachable"

        try:
            async with self.session.get(
                f"{self.config.decode_url}/health",
                timeout=aiohttp.ClientTimeout(total=5),
            ) as resp:
                status["decode"] = "ok" if resp.status == 200 else "error"
        except Exception:
            status["decode"] = "unreachable"

        status["request_count"] = self.request_count
        status["error_count"] = self.error_count

        overall = 200 if all(
            status[k] == "ok" for k in ["proxy", "prefill", "decode"]
        ) else 503

        return web.Response(
            text=json.dumps(status, indent=2),
            status=overall,
            content_type="application/json",
        )

    async def handle_models(self, request: web.Request) -> web.Response:
        """モデル一覧を Decode server から取得"""
        try:
            async with self.session.get(
                f"{self.config.decode_url}/v1/models"
            ) as resp:
                body = await resp.read()
                return web.Response(
                    body=body,
                    status=resp.status,
                    content_type="application/json",
                )
        except Exception as e:
            return web.Response(
                text=json.dumps({"error": str(e)}),
                status=502,
                content_type="application/json",
            )

    async def handle_metrics(self, request: web.Request) -> web.Response:
        """最近のリクエストメトリクスを返す"""
        recent = self.metrics_history[-100:]
        data = {
            "total_requests": self.request_count,
            "total_errors": self.error_count,
            "recent_requests": [
                {
                    "request_id": m.request_id,
                    "prefill_latency_ms": round(m.prefill_latency_ms, 1),
                    "decode_latency_ms": round(m.decode_latency_ms, 1),
                    "total_latency_ms": round(m.total_latency_ms, 1),
                    "prefill_status": m.prefill_status,
                    "decode_status": m.decode_status,
                    "error": m.error,
                }
                for m in recent
            ],
        }
        return web.Response(
            text=json.dumps(data, indent=2),
            content_type="application/json",
        )


def create_app(config: ProxyConfig) -> web.Application:
    """aiohttp アプリケーションを作成"""
    proxy = DisaggProxy(config)
    app = web.Application()

    # ルーティング
    app.router.add_post("/v1/completions", proxy.handle_request)
    app.router.add_post("/v1/chat/completions", proxy.handle_request)
    app.router.add_get("/health", proxy.handle_health)
    app.router.add_get("/v1/models", proxy.handle_models)
    app.router.add_get("/metrics", proxy.handle_metrics)

    # ライフサイクル
    app.on_startup.append(lambda app: proxy.setup())
    app.on_cleanup.append(lambda app: proxy.cleanup())

    return app


def parse_args():
    parser = argparse.ArgumentParser(
        description="Disaggregated Inference Proxy (LMCache + ElastiCache)"
    )
    parser.add_argument(
        "--prefill-url",
        default="http://localhost:8100",
        help="Prefill server URL (default: http://localhost:8100)",
    )
    parser.add_argument(
        "--decode-url",
        default="http://localhost:8200",
        help="Decode server URL (default: http://localhost:8200)",
    )
    parser.add_argument(
        "--port",
        type=int,
        default=9000,
        help="Proxy listen port (default: 9000)",
    )
    parser.add_argument(
        "--host",
        default="0.0.0.0",
        help="Proxy listen host (default: 0.0.0.0)",
    )
    parser.add_argument(
        "--timeout",
        type=int,
        default=300,
        help="Request timeout in seconds (default: 300)",
    )
    parser.add_argument(
        "--prefill-max-tokens",
        type=int,
        default=1,
        help="max_tokens for prefill request (default: 1)",
    )
    return parser.parse_args()


def main():
    args = parse_args()
    config = ProxyConfig(
        prefill_url=args.prefill_url,
        decode_url=args.decode_url,
        port=args.port,
        host=args.host,
        timeout=args.timeout,
        prefill_max_tokens=args.prefill_max_tokens,
    )

    logger.info("Starting Disaggregated Inference Proxy")
    logger.info("  Prefill: %s", config.prefill_url)
    logger.info("  Decode:  %s", config.decode_url)
    logger.info("  Listen:  %s:%d", config.host, config.port)
    logger.info("  Timeout: %ds", config.timeout)

    app = create_app(config)
    web.run_app(app, host=config.host, port=config.port)


if __name__ == "__main__":
    main()
