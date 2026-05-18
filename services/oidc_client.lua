--! oidc_client.lua — OAuth2 / OIDC Relying Party for the gondor dashboard.
--!
--! Makes gondor a confidential-less (PKCE) RP against an assay-auth
--! issuer (typically gondor's own engine sidecar). Pattern matches what
--! argocd / openbao / immich do against Rauthy.
--!
--!   local oc = require("services.oidc_client").new({
--!     issuer       = env.get("AUTH_ISSUER"),       -- e.g. https://gondor-engine.fcar.ai/auth
--!     client_id    = env.get("AUTH_CLIENT_ID"),    -- "gondor-dashboard"
--!     redirect_uri = env.get("AUTH_REDIRECT_URI"), -- https://gondor.fcar.ai/auth/callback
--!     scopes       = { "openid", "email", "profile" },
--!     session_ttl  = 86400,                        -- seconds; default 24h
--!   })
--!
--!   oc.start(return_to)   → { redirect_url, ephemeral } for /login
--!   oc.complete(query, ephemeral) → { session_id, email, expires_at, return_to }
--!   oc.logout(session_id, return_to) → { redirect_url } for /logout
--!   oc.session(session_id) → live session row, or nil

local M = {}

local DEFAULT_SCOPES      = { "openid", "email", "profile" }
local DEFAULT_SESSION_TTL = 86400
local STATE_TTL           = 600 -- 10 min — enough for a slow Google round-trip

local function now() return os.time() end

local function urlenc(s)
  return (tostring(s or "")):gsub("([^A-Za-z0-9%-_%.~])", function(c)
    return string.format("%%%02X", string.byte(c))
  end)
end

local function form_encode(params)
  local parts = {}
  for k, v in pairs(params) do parts[#parts + 1] = urlenc(k) .. "=" .. urlenc(v) end
  return table.concat(parts, "&")
end

-- RFC 4648 §5 alphabet — base64url, no-pad. Inlined because the
-- runtime's `base64.encode` builtin rejects non-UTF-8 input (sha256
-- digest bytes aren't valid UTF-8), so we can't reuse it on raw
-- digest bytes.
local B64URL = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"

local function b64url_from_hex(hex)
  -- Group hex chars 6 at a time → 3 bytes → 4 base64url chars; pad
  -- pair / triplet handled at the tail.
  local out, n = {}, #hex
  local i = 1
  while i <= n do
    local b1 = tonumber(hex:sub(i, i + 1), 16)
    local b2 = (i + 2 <= n) and tonumber(hex:sub(i + 2, i + 3), 16) or nil
    local b3 = (i + 4 <= n) and tonumber(hex:sub(i + 4, i + 5), 16) or nil
    local v = b1 * 65536 + (b2 or 0) * 256 + (b3 or 0)
    out[#out + 1] = B64URL:sub(math.floor(v / 262144) + 1, math.floor(v / 262144) + 1)
    out[#out + 1] = B64URL:sub(math.floor(v / 4096) % 64 + 1, math.floor(v / 4096) % 64 + 1)
    if b2 then out[#out + 1] = B64URL:sub(math.floor(v / 64) % 64 + 1, math.floor(v / 64) % 64 + 1) end
    if b3 then out[#out + 1] = B64URL:sub(v % 64 + 1, v % 64 + 1) end
    i = i + 6
  end
  return table.concat(out)
end

-- RFC 7636 §4: code_challenge = BASE64URL(SHA-256(code_verifier)).
local function pkce_pair()
  local verifier  = crypto.random(64)
  local challenge = b64url_from_hex(crypto.hash(verifier, "sha256"))
  return verifier, challenge
end

local function ok2xx(status) return type(status) == "number" and status >= 200 and status < 300 end

-- Validate the user-supplied return_to so we don't forward the
-- browser to an attacker-controlled URL after a legitimate login.
-- Strictest reasonable rule for a same-origin dashboard: allow only
-- relative paths starting with `/` (and not `//`, which is
-- protocol-relative). Everything else → "/".
local function safe_return_to(s)
  if not s or s == "" then return "/" end
  if s:sub(1, 2) == "//" then return "/" end
  if s:sub(1, 1) ~= "/" then return "/" end
  return s
end

function M.new(opts)
  if not (opts and opts.issuer and opts.client_id and opts.redirect_uri) then
    error("oidc_client.new: issuer, client_id, redirect_uri are required")
  end
  local self = {
    issuer       = opts.issuer:gsub("/$", ""),
    client_id    = opts.client_id,
    redirect_uri = opts.redirect_uri,
    scopes       = opts.scopes or DEFAULT_SCOPES,
    session_ttl  = opts.session_ttl or DEFAULT_SESSION_TTL,
  }

  local pending  = {} -- state_token → { verifier, return_to, expires_at }
  local sessions = {} -- session_id  → { user_id, email, display_name, expires_at }

  local function authorize_url()  return self.issuer .. "/authorize" end
  local function token_url()      return self.issuer .. "/token" end
  local function end_session_url() return self.issuer .. "/logout" end

  -- Build the /authorize redirect. Caller persists the returned state
  -- token in a short-lived cookie; we hold the verifier + return_to
  -- server-side keyed by that state.
  function self.start(return_to)
    local state             = crypto.random(40)
    local verifier, challenge = pkce_pair()
    pending[state] = {
      verifier   = verifier,
      return_to  = safe_return_to(return_to),
      expires_at = now() + STATE_TTL,
    }
    local url = authorize_url() .. "?" .. form_encode({
      response_type         = "code",
      client_id             = self.client_id,
      redirect_uri          = self.redirect_uri,
      scope                 = table.concat(self.scopes, " "),
      state                 = state,
      code_challenge        = challenge,
      code_challenge_method = "S256",
    })
    return { redirect_url = url, state = state }
  end

  -- Exchange the `code` from the callback for tokens. `query` is the
  -- parsed query string from /auth/callback; `state_cookie` is the raw
  -- state value we set on /login. Returns a session row on success.
  function self.complete(query, state_cookie)
    if not query or not query.code or not query.state then
      return nil, "missing code or state"
    end
    if query.state ~= state_cookie then
      return nil, "state mismatch"
    end
    local p = pending[query.state]
    if not p then return nil, "unknown state" end
    pending[query.state] = nil
    if p.expires_at < now() then return nil, "state expired" end

    local body = form_encode({
      grant_type    = "authorization_code",
      code          = query.code,
      redirect_uri  = self.redirect_uri,
      client_id     = self.client_id,
      code_verifier = p.verifier,
    })
    local ok, resp = pcall(http.post, token_url(), body, {
      headers = {
        ["Content-Type"] = "application/x-www-form-urlencoded",
        ["Accept"]       = "application/json",
      },
    })
    if not ok or not resp or not ok2xx(resp.status) then
      return nil, "token exchange: " .. tostring(resp and resp.status or "no response")
    end
    local tok = json.parse(resp.body)
    if not tok or not tok.id_token then return nil, "no id_token" end

    local decoded = crypto.jwt_decode(tok.id_token)
    local claims  = decoded and decoded.claims or {}
    if not claims.sub then return nil, "id_token missing sub" end

    local session_id = crypto.random(48)
    local row = {
      user_id      = claims.sub,
      email        = claims.email,
      display_name = claims.name or claims.preferred_username or claims.email,
      expires_at   = now() + self.session_ttl,
      return_to    = p.return_to,
      id_token     = tok.id_token,
    }
    sessions[session_id] = row
    return { session_id = session_id, return_to = p.return_to, email = row.email }
  end

  function self.session(session_id)
    if not session_id then return nil end
    local row = sessions[session_id]
    if not row then return nil end
    if row.expires_at < now() then
      sessions[session_id] = nil
      return nil
    end
    return row
  end

  function self.logout(session_id, return_to)
    local row = session_id and sessions[session_id]
    if session_id then sessions[session_id] = nil end
    local params = { post_logout_redirect_uri = return_to or "/" }
    if row and row.id_token then params.id_token_hint = row.id_token end
    return { redirect_url = end_session_url() .. "?" .. form_encode(params) }
  end

  function self.sweep()
    local cutoff = now()
    for k, v in pairs(pending)  do if v.expires_at < cutoff then pending[k]  = nil end end
    for k, v in pairs(sessions) do if v.expires_at < cutoff then sessions[k] = nil end end
  end

  return self
end

return M
