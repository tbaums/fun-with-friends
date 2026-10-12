//! GitHub App identity: mint installation tokens from `~/.fwf/apps.toml`.
//!
//! M0 scope (T-03, first slice): JWT (RS256) → installation access token, plus
//! one read helper used by the week-0 assignee test. No ETag cache, no
//! single-flight, no writes yet — those arrive with the client proper.

use serde::Deserialize;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

/// The agent every GitHub call in this process goes through — one place for
/// the timeout and one place for the status policy.
///
/// ureq 3 turns 4xx/5xx into `Error::StatusCode(code)` and drops the response
/// with it, but this system reads the *body* of a refusal (secondary
/// rate-limit text, 422 reasons, the 409 that means "already merged"), so the
/// status is left on the response instead and callers keep reading the
/// `(status, body)` pair they always have. `timeout` is the whole-call
/// ceiling; `None` is no ceiling, which is what these calls had under ureq 2.
pub fn http_agent(timeout: Option<Duration>) -> ureq::Agent {
    ureq::Agent::new_with_config(
        ureq::Agent::config_builder()
            .http_status_as_error(false)
            .timeout_global(timeout)
            .build(),
    )
}

/// The body of a reply, or `""` when it cannot be read — `into_string()`'s
/// `unwrap_or_default()` under ureq 2.
pub fn body_text(resp: &mut ureq::http::Response<ureq::Body>) -> String {
    resp.body_mut().read_to_string().unwrap_or_default()
}

/// One response header, as ureq 2's `resp.header(name)` gave it.
pub fn header(resp: &ureq::http::Response<ureq::Body>, name: &str) -> Option<String> {
    resp.headers()
        .get(name)
        .and_then(|v| v.to_str().ok())
        .map(str::to_string)
}

/// A refusal: exactly the 4xx/5xx that [`http_agent`] declines to raise as an
/// error, so the handful of callers that branch on it say so themselves.
fn refused(resp: &ureq::http::Response<ureq::Body>) -> bool {
    let s = resp.status();
    s.is_client_error() || s.is_server_error()
}

#[derive(Debug, Deserialize, Clone)]
pub struct AppEntry {
    pub app_id: u64,
    pub installation_id: u64,
    pub key: String,
}

#[derive(Debug, Deserialize)]
pub struct Apps(pub BTreeMap<String, AppEntry>);

#[derive(Debug)]
pub enum AuthError {
    NoConfig(PathBuf),
    BadConfig(String),
    KeyUnreadable(PathBuf, String),
    Jwt(String),
    Http(String),
    Denied(u16, String),
}

impl std::fmt::Display for AuthError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            AuthError::NoConfig(p) => write!(f, "no apps config at {}", p.display()),
            AuthError::BadConfig(e) => write!(f, "apps config unparseable: {e}"),
            AuthError::KeyUnreadable(p, e) => write!(f, "cannot read key {}: {e}", p.display()),
            AuthError::Jwt(e) => write!(f, "jwt: {e}"),
            AuthError::Http(e) => write!(f, "http: {e}"),
            AuthError::Denied(code, body) => write!(f, "github refused ({code}): {body}"),
        }
    }
}

pub fn apps_path() -> PathBuf {
    std::env::var_os("FWF_APPS_TOML")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".fwf/apps.toml")))
        .unwrap_or_else(|| PathBuf::from("apps.toml"))
}

pub fn load_apps(path: &Path) -> Result<Apps, AuthError> {
    let text =
        std::fs::read_to_string(path).map_err(|_| AuthError::NoConfig(path.to_path_buf()))?;
    let map: BTreeMap<String, AppEntry> =
        toml::from_str(&text).map_err(|e| AuthError::BadConfig(e.to_string()))?;
    Ok(Apps(map))
}

fn expand_home(p: &str) -> PathBuf {
    if let Some(rest) = p.strip_prefix("~/") {
        if let Some(h) = std::env::var_os("HOME") {
            return PathBuf::from(h).join(rest);
        }
    }
    PathBuf::from(p)
}

#[derive(serde::Serialize)]
struct Claims {
    iat: u64,
    exp: u64,
    iss: String,
}

/// A signed App JWT, valid for ~9 minutes (GitHub caps at 10).
pub fn app_jwt(entry: &AppEntry) -> Result<String, AuthError> {
    let key_path = expand_home(&entry.key);
    let pem = std::fs::read(&key_path)
        .map_err(|e| AuthError::KeyUnreadable(key_path.clone(), e.to_string()))?;
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|e| AuthError::Jwt(e.to_string()))?
        .as_secs();
    let claims = Claims {
        iat: now.saturating_sub(30),
        exp: now + 9 * 60,
        iss: entry.app_id.to_string(),
    };
    let key =
        jsonwebtoken::EncodingKey::from_rsa_pem(&pem).map_err(|e| AuthError::Jwt(e.to_string()))?;
    jsonwebtoken::encode(
        &jsonwebtoken::Header::new(jsonwebtoken::Algorithm::RS256),
        &claims,
        &key,
    )
    .map_err(|e| AuthError::Jwt(e.to_string()))
}

#[derive(Debug, Deserialize)]
pub struct InstallationToken {
    pub token: String,
    pub expires_at: String,
    #[serde(default)]
    pub permissions: BTreeMap<String, String>,
}

/// Mint an installation access token. Optionally narrow `permissions`
/// (e.g. `{"contents":"read"}`) — how a seat gets a read-only token.
pub fn mint(
    entry: &AppEntry,
    permissions: Option<&BTreeMap<&str, &str>>,
) -> Result<InstallationToken, AuthError> {
    let jwt = app_jwt(entry)?;
    let url = format!(
        "https://api.github.com/app/installations/{}/access_tokens",
        entry.installation_id
    );
    let body = match permissions {
        Some(p) => serde_json::json!({ "permissions": p }),
        None => serde_json::json!({}),
    };
    let resp = http_agent(None)
        .post(&url)
        .header("Authorization", format!("Bearer {jwt}"))
        .header("Accept", "application/vnd.github+json")
        .header("User-Agent", "fwfd/0.1")
        .header("X-GitHub-Api-Version", "2022-11-28")
        .send(body.to_string());
    match resp {
        Ok(mut r) if refused(&r) => {
            let code = r.status().as_u16();
            let text = body_text(&mut r);
            Err(AuthError::Denied(code, text.chars().take(200).collect()))
        }
        Ok(mut r) => r
            .body_mut()
            .read_json::<InstallationToken>()
            .map_err(|e| AuthError::Http(e.to_string())),
        Err(e) => Err(AuthError::Http(e.to_string())),
    }
}

/// GET with an installation token; returns the HTTP status and body.
pub fn get_status(token: &str, path: &str) -> Result<(u16, String), AuthError> {
    let url = format!("https://api.github.com{path}");
    let resp = http_agent(None)
        .get(&url)
        .header("Authorization", format!("Bearer {token}"))
        .header("Accept", "application/vnd.github+json")
        .header("User-Agent", "fwfd/0.1")
        .header("X-GitHub-Api-Version", "2022-11-28")
        .call();
    match resp {
        Ok(mut r) => {
            let code = r.status().as_u16();
            Ok((code, body_text(&mut r)))
        }
        Err(e) => Err(AuthError::Http(e.to_string())),
    }
}

/// POST/PATCH JSON with an installation token; returns status and body.
/// Every authority-bearing write in the system goes through here, under
/// the App the supervisor chose — never a seat.
pub fn send_json(
    method: &str,
    token: &str,
    path: &str,
    body: &serde_json::Value,
) -> Result<(u16, String), AuthError> {
    let url = format!("https://api.github.com{path}");
    if !matches!(method, "POST" | "PATCH" | "PUT" | "DELETE") {
        return Err(AuthError::Http(format!("unsupported method {method}")));
    }
    // The http-crate request shape, not a typed `post()`/`delete()` builder:
    // the method is a runtime string, and DELETE carries a body here.
    let req = ureq::http::Request::builder()
        .method(method)
        .uri(&url)
        .header("Authorization", format!("Bearer {token}"))
        .header("Accept", "application/vnd.github+json")
        .header("User-Agent", "fwfd/0.1")
        .header("X-GitHub-Api-Version", "2022-11-28")
        .body(body.to_string())
        .map_err(|e| AuthError::Http(e.to_string()))?;
    match http_agent(None).run(req) {
        Ok(mut r) => {
            let code = r.status().as_u16();
            Ok((code, body_text(&mut r)))
        }
        Err(e) => Err(AuthError::Http(e.to_string())),
    }
}

/// Convert a draft PR to ready-for-review. REST has no field for this; it is
/// a GraphQL mutation, and only an identity that may edit the PR (the author
/// App) can do it.
pub fn mark_ready(token: &str, node_id: &str) -> Result<bool, AuthError> {
    let q = serde_json::json!({ "query": format!("mutation {{ markPullRequestReadyForReview(input:{{pullRequestId:\"{node_id}\"}}) {{ pullRequest {{ isDraft }} }} }}") });
    let resp = http_agent(None)
        .post("https://api.github.com/graphql")
        .header("Authorization", format!("Bearer {token}"))
        .header("User-Agent", "fwfd/0.1")
        .send(q.to_string());
    match resp {
        Ok(mut r) if refused(&r) => Err(AuthError::Denied(
            r.status().as_u16(),
            body_text(&mut r).chars().take(200).collect(),
        )),
        Ok(mut r) => {
            let v: serde_json::Value = r
                .body_mut()
                .read_json()
                .map_err(|e| AuthError::Http(e.to_string()))?;
            // GraphQL reports failures as 200 + `errors`; surface them, never
            // fold them into a bare `false`.
            if let Some(errs) = v["errors"].as_array() {
                let msg: Vec<String> = errs
                    .iter()
                    .filter_map(|e| e["message"].as_str().map(String::from))
                    .collect();
                return Err(AuthError::Denied(
                    200,
                    msg.join("; ").chars().take(200).collect(),
                ));
            }
            Ok(
                v["data"]["markPullRequestReadyForReview"]["pullRequest"]["isDraft"]
                    == serde_json::Value::Bool(false),
            )
        }
        Err(e) => Err(AuthError::Http(e.to_string())),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn apps_toml_parses_and_missing_file_is_a_typed_error() {
        let dir = std::env::temp_dir().join(format!("fwfd-apps-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let p = dir.join("apps.toml");
        std::fs::write(
            &p,
            "[impl]\napp_id = 1\ninstallation_id = 2\nkey = \"~/.fwf/keys/fwf-impl.pem\"\n",
        )
        .unwrap();
        let apps = load_apps(&p).unwrap();
        assert_eq!(apps.0["impl"].installation_id, 2);
        assert!(matches!(
            load_apps(&dir.join("nope.toml")),
            Err(AuthError::NoConfig(_))
        ));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn unreadable_key_is_a_typed_error_not_a_panic() {
        let e = AppEntry {
            app_id: 1,
            installation_id: 2,
            key: "/nonexistent/key.pem".into(),
        };
        assert!(matches!(app_jwt(&e), Err(AuthError::KeyUnreadable(_, _))));
    }
}
