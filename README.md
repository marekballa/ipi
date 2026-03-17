# Azure OAuth Flow — ABS Search Integration

## Overview

When `plugin.identity.provider=azure` is set, the service uses a cookie-based OAuth 2.0 Authorization Code flow to authenticate users against Azure AD and obtain tokens for calling the Ansera (ABS) search API.

```mermaid
flowchart TD
    Browser([Browser])
    AzureAD([Azure AD])
    SRS[search-report-service]
    ABS[Ansera / ABS Search API]

    subgraph "① Initial Login — Authorization Code Flow"
        A1["Protected endpoint hit\n(no refresh_token cookie)"]
        A2["401 + Azure authorize URL\nAzureAuthenticationEntryPoint"]
        A3["User logs in on Azure AD"]
        A4["GET /api/oauth/callback?code=…&state=…\nAzureTokenController"]
        A5["Exchange code → tokens\nPOST /oauth2/v2.0/token"]
        A6["Set-Cookie: refresh_token\n(httpOnly, 30 days)"]
        A1 --> A2 --> A3 --> A4 --> A5 --> A6
    end

    subgraph "② Per-Request Filter"
        B1["AccessTokenFromCookieFilter\nreads refresh_token cookie"]
        B2["Sets SecurityContext\n(credentials = refresh_token)"]
        B1 --> B2
    end

    subgraph "③ Token Refresh"
        C1["POST /api/oauth/refresh\nAzureRefreshTokenController"]
        C2["grant_type=refresh_token → Azure"]
        C3["Update access_token + refresh_token cookies"]
        C1 --> C2 --> C3
    end

    subgraph "④ Search-Scoped Token Exchange"
        D1["WebClient call to Ansera\nAzureAuthenticatedSearchClientConfig"]
        D2{"Cached search\ntoken valid?"}
        D3["grant_type=refresh_token\nscope=api://…/search → Azure"]
        D4["Cache token per user\n(ConcurrentHashMap)"]
        D5["Bearer token → Ansera API"]
        D1 --> D2
        D2 -- yes --> D5
        D2 -- no --> D3 --> D4 --> D5
    end

    Browser -->|"accesses protected route"| A1
    A3 -->|"redirected to"| AzureAD
    A5 -->|"token exchange"| AzureAD
    A6 -->|"subsequent requests"| B1
    B2 -->|"authenticated request"| SRS
    SRS -->|"calls search"| D1
    D3 -->|"token exchange"| AzureAD
    D5 --> ABS
    Browser -->|"access token expired"| C1
    C2 --> AzureAD
```

### Key classes

| Class | Role |
|---|---|
| `AzureAuthenticationEntryPoint` | Returns 401 + Azure authorize URL when no cookie is present |
| `OAuthStateEncoder` | Encodes `{redirectUrl, timestamp}` as Base64 state param (10 min TTL, CSRF protection) |
| `AzureTokenController` | Handles `/api/oauth/callback` — exchanges auth code, stores `refresh_token` cookie |
| `AzureRefreshTokenController` | Handles `POST /api/oauth/refresh` — rotates `access_token` + `refresh_token` cookies |
| `AccessTokenFromCookieFilter` | Reads cookies per request, populates Spring `SecurityContext` (stateless, no session) |
| `AzureAuthenticatedSearchClientConfig` | WebClient filter that exchanges `refresh_token` for a search-scoped token before each Ansera call |
| `SearchTokenManager` | Optional: exchanges refresh token for search-scoped token and caches it in a `search_token` cookie |

### Configuration Properties

| Property | Description |
|---|---|
| `plugin.identity.provider=azure` | Activates all Azure beans |
| `openid.issuer-uri` | Azure AD tenant URL (`https://login.microsoftonline.com/{tenant}/v2.0`) |
| `openid.client-id` / `openid.client-secret` | App registration credentials |
| `openid.scopes` | Default: `openid offline_access email` |
| `openid.redirect-uri` | Default: `/api/oauth/callback` |
| `openid.search-scope` | Scope for Ansera token exchange, default: `api://b16225bd-…/search` |
| `integration-endpoints.authenticated-search-service` | Ansera/ABS base URL |
| `azure.search.scope-exchange.*` | Optional cookie-based search token caching (`SearchTokenManager`) |

---

## Programmatic / External Partner Access (TO BE)

The Authorization Code + cookie flow above is **browser-only** — it requires the search-report-mfe to be in the loop. An external third-party caller (no browser, no MFE) cannot follow a redirect-based login.

For service-to-service access the correct flow is **OAuth 2.0 Client Credentials** on both legs.

```mermaid
flowchart LR
    Partner([External Partner])
    AzureAD([Azure AD])
    SRS[search-report-service]
    ABS[Ansera / ABS Search API]

    subgraph "Leg 1 — Partner → SRS"
        P1["client_credentials grant\nclient_id + client_secret\nscope=api://srs-app-id/.default"]
        P2["Bearer service token\n+ userName in request body"]
        P1 --> P2
    end

    subgraph "Leg 2 — SRS → ABS"
        S1["client_credentials grant\nSRS service principal\nscope=api://abs-search/.default"]
        S2["Bearer service token\nuserName passed as payload field"]
        S1 --> S2
    end

    Partner -->|"① token request"| P1
    P1 -->|"token exchange"| AzureAD
    P2 -->|"② API call"| SRS
    SRS -->|"③ token request"| S1
    S1 -->|"token exchange"| AzureAD
    S2 -->|"④ POST /project/"| ABS
```

### Why Auth Code flow cannot serve this use case

| Property | Auth Code + Cookie *(current, MFE)* | Client Credentials *(needed, external)* |
|---|---|---|
| Requires browser | ✅ Yes | ❌ No |
| User interacts | ✅ Yes | ❌ No |
| Token stored in cookie | ✅ Yes | ❌ No |
| `name` from JWT claim | ✅ Available | ❌ Not available — must be explicit request field |
| Works for external API clients | ❌ No | ✅ Yes |
| Works for async background jobs | ❌ No | ✅ Yes |

> **Open blocker**: ABS/Ansera must be verified to accept service-level (Client Credentials) tokens. If ABS mandates user-delegated tokens, ABS-side configuration changes are required before this architecture is viable.

---

## Can Entra ID inject a user identity into a Client Credentials token?

**No — this is a hard OAuth 2.0 constraint, not an Azure limitation.**

Client Credentials tokens are application-only by definition. There is no user in the flow, so there is nothing to map from. Azure AD claims mapping policies, optional claims, and extension attributes only transform claims that already exist for the authenticated principal — which in Client Credentials is the service app, not a person.

The only Entra mechanism that preserves user identity through a service call is **On-Behalf-Of (OBO)**:

```mermaid
sequenceDiagram
    participant Caller as External Caller
    participant AzureAD as Azure AD
    participant SRS as search-report-service
    participant ABS as Ansera / ABS

    Caller->>AzureAD: Auth Code / Device Flow (user authenticates)
    AzureAD-->>Caller: user token (contains name, oid, etc.)

    Caller->>SRS: API call + Authorization: Bearer <user-token>

    SRS->>AzureAD: OBO exchange<br/>grant_type=jwt-bearer<br/>assertion=user-token<br/>scope=api://b16225bd.../.default
    AzureAD-->>SRS: search-scoped token (user claims preserved)

    SRS->>ABS: Authorization: Bearer <search-scoped-token><br/>(token still contains user identity)
    ABS-->>SRS: result
```

OBO requires the external caller to already hold a **real user token** — they must have authenticated as an actual person first (Auth Code or Device Flow). It does not help for pure machine-to-machine calls where no user is involved.

### Decision: which flow based on ABS project ownership model

| ABS project ownership | Correct flow | User identity source |
|---|---|---|
| No per-user control (shared) | **Client Credentials** | Not needed |
| Per-user, user exists in Entra | **OBO** — caller authenticates as a user first (Device Flow if no browser) | JWT claims preserved through OBO exchange |
| Per-user, user identified by name/email in payload | **Client Credentials** + `userName` in request body | ABS maps by data, not token claims |

---

# How to run
```
chmod +x run.sh
./run.sh GH_ACCOUNT GH_ACCESS_TOKEN


#Monitor
docker logs -f search-report-service


```

# Logging
For more logging options use following variables 
```
    root: ${ROOT_LOGGING_LEVEL:WARN}
    org.epo.itc: ${APP_LOGGING_LEVEL:INFO}
    org.springframework: ${SPRING_LOGGING_LEVEL:WARN}
    org.hibernate.SQL: ${SQL_LOGGING_LEVEL:WARN}
```
