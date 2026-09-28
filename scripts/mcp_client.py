#!/usr/bin/env python3
"""A minimal MCP client for humans and tests (official SDK, streamable HTTP).

    mcp_client.py <url> <token> list
    mcp_client.py <url> <token> call <tool> '<json-arguments>'

Prints one JSON object: {"tools":[...]} or {"is_error":bool,"text":"..."}; exit 0 on protocol success.
"""

import asyncio
import json
import sys

from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client


async def main(url: str, token: str, action: str, tool: str | None, args: dict) -> dict:
    async with streamablehttp_client(url, headers={"Authorization": f"Bearer {token}"}) as (r, w, _):
        async with ClientSession(r, w) as session:
            await session.initialize()
            if action == "list":
                return {"tools": sorted(t.name for t in (await session.list_tools()).tools)}
            res = await session.call_tool(tool, args)
            return {
                "is_error": bool(res.isError),
                "text": "".join(c.text for c in res.content if hasattr(c, "text")),
            }


if __name__ == "__main__":
    url, token, action = sys.argv[1:4]
    tool = sys.argv[4] if action == "call" else None
    args = json.loads(sys.argv[5]) if action == "call" and len(sys.argv) > 5 else {}
    try:
        print(json.dumps(asyncio.run(main(url.rstrip("/") + "/mcp", token, action, tool, args))))
    except BaseException as exc:  # protocol-level refusal (401/403/429) surfaces as an exception group
        print(json.dumps({"transport_error": type(exc).__name__, "detail": str(exc)[:300]}))
        sys.exit(1)
