//! GitHub App identity: mint installation tokens from `~/.fwf/apps.toml`.
//!
//! M0 scope (T-03, first slice): JWT (RS256) → installation access token, plus
//! one read helper used by the week-0 assignee test. No ETag cache, no
//! single-flight, no writes yet — those arrive with the client proper.

use serde::Deserialize;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

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
    let resp = ureq::post(&url)
        .set("Authorization", &format!("Bearer {jwt}"))
        .set("Accept", "application/vnd.github+json")
        .set("User-Agent", "fwfd/0.1")
        .set("X-GitHub-Api-Version", "2022-11-28")
        .send_string(&body.to_string());
    match resp {
        Ok(r) => r
            .into_json::<InstallationToken>()
            .map_err(|e| AuthError::Http(e.to_string())),
        Err(ureq::Error::Status(code, r)) => {
            let text = r.into_string().unwrap_or_default();
            Err(AuthError::Denied(code, text.chars().take(200).collect()))
        }
        Err(e) => Err(AuthError::Http(e.to_string())),
    }
}

/// GET with an installation token; returns the HTTP status and body.
pub fn get_status(token: &str, path: &str) -> Result<(u16, String), AuthError> {
    let url = format!("https://api.github.com{path}");
    let resp = ureq::get(&url)
        .set("Authorization", &format!("Bearer {token}"))
        .set("Accept", "application/vnd.github+json")
        .set("User-Agent", "fwfd/0.1")
        .set("X-GitHub-Api-Version", "2022-11-28")
        .call();
    match resp {
        Ok(r) => {
            let code = r.status();
            Ok((code, r.into_string().unwrap_or_default()))
        }
        Err(ureq::Error::Status(code, r)) => Ok((code, r.into_string().unwrap_or_default())),
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
