# 0002 — The access policy is data in Terraform; each tool declares one scope

**Status:** accepted

`CALLERS_JSON` maps an email to a set of scopes (`ops:read`, `notes:read`, `notes:write`) and is rendered by Terraform from named service accounts, so *who may do what* is reviewed in a pull request, never edited at runtime, and visible in the plan. Unknown scopes fail at start-up. Each tool is wrapped with `@guarded(server, scope)`, so a tool cannot be added without deciding its scope, and a refusal is audited with `reason=missing_scope:<scope>`.

Registration is separate from authorization: a valid, invoker-permitted identity that is **not in the policy** is refused with 403 `unregistered_caller` (the `mcp-guest` test identity exists to prove exactly this layer).
