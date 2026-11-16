//! Browser-assisted OAuth authorization endpoints.
//!
//! The authorize endpoint requires an hCaptcha client attestation that only
//! a real browser can mint, so a sessionKey alone cannot produce OAuth
//! tokens headlessly any more. These endpoints split the flow in two for the
//! admin UI: one call builds the authorize URL (keeping the PKCE verifier
//! server-side), the operator approves in their own logged-in browser and
//! copies the displayed code back, and the second call redeems it. The
//! stored token then renews through the ordinary refresh flow, which does
//! not need attestation.

use std::{
    collections::HashMap,
    sync::{LazyLock, Mutex, PoisonError},
    time::{Duration, Instant},
};

use axum::{Json, extract::State};
use axum_auth::AuthBearer;
use serde::Deserialize;
use serde_json::json;
use tracing::{error, info, warn};

use crate::{
    api::error::ApiError,
    claude_code_state::ClaudeCodeState,
    config::{CC_REDIRECT_URI, CLEWDR_CONFIG},
    services::cookie_pool::CookiePool,
};

/// A browser authorization waiting for its code to come back.
struct PendingAuthorization {
    verifier: String,
    org_uuid: String,
    created: Instant,
}

/// Verifiers for authorize URLs handed out but not redeemed yet, keyed by
/// the OAuth state that the redirect echoes back.
static PENDING: LazyLock<Mutex<HashMap<String, PendingAuthorization>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

/// How long an authorize URL stays redeemable before it is pruned.
const PENDING_TTL: Duration = Duration::from_mins(15);

fn remember_pending(state: String, verifier: String, org_uuid: String) {
    let mut pending = PENDING.lock().unwrap_or_else(PoisonError::into_inner);
    let now = Instant::now();
    pending.retain(|_, p| now.duration_since(p.created) < PENDING_TTL);
    pending.insert(
        state,
        PendingAuthorization {
            verifier,
            org_uuid,
            created: now,
        },
    );
}

fn take_pending(state: &str) -> Option<PendingAuthorization> {
    let pending = PENDING.lock().unwrap_or_else(PoisonError::into_inner);
    let p = pending.get(state)?;
    (p.created.elapsed() < PENDING_TTL).then(|| PendingAuthorization {
        verifier: p.verifier.clone(),
        org_uuid: p.org_uuid.clone(),
        created: p.created,
    })
}

/// Drop a redeemed authorization so its verifier cannot be reused.
fn forget_pending(state: &str) {
    PENDING
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .remove(state);
}

/// Build an authorize URL for the operator to open in their own browser.
///
/// Uses one cookie from the pool to resolve the organization, then returns
/// the cookie immediately; only the URL and its state travel to the client,
/// never the PKCE verifier.
///
/// # Errors
/// 401 for a wrong admin token, 500 when no cookie is available or the
/// upstream bootstrap fails.
pub async fn api_oauth_authorize_url(
    State(pool): State<CookiePool>,
    AuthBearer(t): AuthBearer,
) -> Result<Json<serde_json::Value>, ApiError> {
    if !CLEWDR_CONFIG.load().admin_auth(&t) {
        return Err(ApiError::unauthorized());
    }
    let cookie = pool.request(None).map_err(|e| {
        error!("No cookie available for authorization: {e}");
        ApiError::internal("No cookie available")
    })?;
    let state = ClaudeCodeState::from_cookie(pool.clone(), cookie).map_err(|e| {
        error!("Failed to build state: {e}");
        ApiError::internal("Failed to build state")
    })?;
    let org_uuid = match state.get_organization().await {
        Ok(org) => org,
        Err(e) => {
            state.return_cookie(None);
            error!("Bootstrap failed while building authorize URL: {e}");
            return Err(ApiError::internal(format!("Bootstrap failed: {e}")));
        }
    };
    state.return_cookie(None);
    let (url, verifier, oauth_state) = ClaudeCodeState::browser_authorize_url(&org_uuid);
    remember_pending(oauth_state.clone(), verifier, org_uuid.clone());
    info!("Issued browser authorize URL for org {org_uuid}");
    Ok(Json(json!({
        "url": url.as_str(),
        "redirect_uri": CC_REDIRECT_URI,
        "state": oauth_state,
    })))
}

#[derive(Deserialize)]
pub struct OauthCompleteParams {
    /// The code copied from the redirect page, or the whole callback URL.
    pub code: String,
    /// The state issued with the authorize URL; optional when the pasted
    /// text carries it, which a URL paste always does.
    pub state: Option<String>,
}

/// Redeem a code from a browser-assisted authorization.
///
/// Parses the code out of a raw code or a pasted callback URL, looks up the
/// verifier by state, exchanges the code for a token, and leaves the token
/// stored on the cookie in the pool.
///
/// # Errors
/// 400 when no code or no matching pending authorization, 500 without a
/// cookie or when the upstream token exchange fails.
pub async fn api_oauth_complete(
    State(pool): State<CookiePool>,
    AuthBearer(t): AuthBearer,
    Json(params): Json<OauthCompleteParams>,
) -> Result<Json<serde_json::Value>, ApiError> {
    if !CLEWDR_CONFIG.load().admin_auth(&t) {
        return Err(ApiError::unauthorized());
    }
    let (code, state_from_input) = parse_code(&params.code)
        .ok_or_else(|| ApiError::bad_request("No code found in the pasted text"))?;
    let state_key = state_from_input
        .clone()
        .or_else(|| params.state.clone())
        .unwrap_or_default();
    let pending = take_pending(&state_key).ok_or_else(|| {
        warn!("Redeem attempted without a matching pending authorization");
        ApiError::bad_request(
            "No pending authorization for this state; generate a new authorize URL",
        )
    })?;
    let org_uuid = pending.org_uuid.clone();

    let cookie = pool.request(None).map_err(|e| {
        error!("No cookie available for token exchange: {e}");
        ApiError::internal("No cookie available")
    })?;
    let mut state = ClaudeCodeState::from_cookie(pool.clone(), cookie).map_err(|e| {
        error!("Failed to build state: {e}");
        ApiError::internal("Failed to build state")
    })?;
    match state
        .redeem_authorization_code(code, state_from_input, pending.verifier, org_uuid.clone())
        .await
    {
        Ok(()) => {
            forget_pending(&state_key);
            info!("Browser-assisted authorization redeemed for org {org_uuid}");
            let expires_at = state
                .cookie
                .as_ref()
                .and_then(|c| c.token.as_ref())
                .map(|t| t.expires_at.timestamp());
            Ok(Json(json!({ "ok": true, "expires_at": expires_at })))
        }
        Err(e) => {
            state.return_cookie(None);
            error!("Token exchange failed: {e}");
            Err(ApiError::internal(format!("Token exchange failed: {e}")))
        }
    }
}

/// Extracts `(code, state)` from whatever the operator pasted: the bare
/// code, or the full callback URL carrying both as query parameters.
#[must_use]
pub fn parse_code(input: &str) -> Option<(String, Option<String>)> {
    let trimmed = input.trim();
    if trimmed.is_empty() {
        return None;
    }
    if let Some((_, query)) = trimmed.split_once('?') {
        let mut code = None;
        let mut state = None;
        for (k, v) in url::form_urlencoded::parse(query.as_bytes()) {
            match k.as_ref() {
                "code" => code = Some(v.into_owned()),
                "state" => state = Some(v.into_owned()),
                _ => {}
            }
        }
        if let Some(code) = code {
            return Some((code, state));
        }
    }
    // The redirect page shows the code and state joined by '#', as one
    // copyable string.
    if let Some((code, state)) = trimmed.split_once('#')
        && !code.trim().is_empty()
        && !code.trim().contains('/')
    {
        let code = code.trim();
        let state = state.trim();
        return Some((
            code.to_owned(),
            (!state.is_empty()).then(|| state.to_owned()),
        ));
    }
    // A bare code, possibly with the state following it on the same paste.
    let mut parts = trimmed.split_whitespace();
    let code = parts.next()?.to_owned();
    if code.contains('/') || code.contains(':') {
        return None; // looked like a URL but carried no ?code=
    }
    let state = parts.next().map(str::to_owned);
    Some((code, state))
}

/// The standalone helper page: self-contained HTML so it works without the
/// admin frontend. The APIs it calls still require the admin password.
pub async fn api_oauth_helper_page() -> axum::response::Html<&'static str> {
    axum::response::Html(include_str!("../../assets/oauth-helper.html"))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A pasted callback URL carries both halves; the state ties the code to
    /// the verifier kept for it.
    #[test]
    fn parses_code_and_state_from_a_callback_url() {
        let (code, state) = parse_code(
            "https://platform.claude.com/oauth/code/callback?code=abc%2F123&state=st-ate",
        )
        .unwrap();

        assert_eq!(code, "abc/123");
        assert_eq!(state.as_deref(), Some("st-ate"));
    }

    #[test]
    fn parses_a_bare_code_with_and_without_state() {
        assert_eq!(parse_code(" xyz789 "), Some(("xyz789".to_owned(), None)));
        assert_eq!(
            parse_code("xyz789 st-ate"),
            Some(("xyz789".to_owned(), Some("st-ate".to_owned())))
        );
    }

    /// The redirect page shows `code#state` as one string to copy; that is
    /// what an operator pastes back.
    #[test]
    fn parses_the_code_hash_state_form_the_page_displays() {
        assert_eq!(
            parse_code("QXK9LKB7bGm#-GTvIElVWCJg"),
            Some(("QXK9LKB7bGm".to_owned(), Some("-GTvIElVWCJg".to_owned())))
        );
        assert_eq!(
            parse_code("QXK9LKB7bGm#"),
            Some(("QXK9LKB7bGm".to_owned(), None))
        );
    }

    /// A URL without a code must not fall through to the bare-code path:
    /// its slashes would be stored as a code and sent upstream.
    #[test]
    fn rejects_a_url_with_no_code() {
        assert!(parse_code("https://example.com/oauth/denied?error=access_denied").is_none());
        assert!(parse_code("").is_none());
    }
}
