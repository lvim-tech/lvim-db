// lvim-db-native/secret: credential templates that never leak.
//
// A `Secret` wraps a TEMPLATE STRING, not a resolved value. The store persists
// only the template; the daemon resolves it at connect time via `resolve()`.
// Its Debug/Display are redacted, so a Secret can never be printed into a log or
// a daemon.log notification by accident — the root-cause guard against leaking
// DSNs/passwords, rather than remembering to scrub at every call site.
//
// Template forms (whole-string):
//   literal text            → used verbatim
//   {{ env "VAR" }}         → the value of environment variable VAR
//   {{ cmd "prog args" }}   → stdout of a shell command, trimmed
//   {{ vault "name" }}      → the secret named `name` from the lvim-keyring agent (see vault.rs)
// An empty template resolves to an empty string.

use std::fmt;

use serde::Deserialize;

/// A credential template. Deserialized from a plain JSON string; redacted on
/// Debug so it is safe to include a whole ConnSpec in an error/log.
#[derive(Clone, Default, Deserialize)]
pub struct Secret(String);

impl Secret {
    #[allow(dead_code)] // used by tests / driver specs as they land
    pub fn new(s: impl Into<String>) -> Self {
        Secret(s.into())
    }

    #[allow(dead_code)] // template-presence check used by driver specs as they land
    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }

    /// Resolve the template to its actual secret value. Async because `{{ cmd }}`
    /// spawns a process.
    pub async fn resolve(&self) -> anyhow::Result<String> {
        let raw = self.0.trim();
        if raw.is_empty() {
            return Ok(String::new());
        }
        if let Some(inner) = strip_template(raw) {
            let (verb, arg) = split_verb(&inner)?;
            return match verb.as_str() {
                "env" => {
                    std::env::var(&arg).map_err(|_| anyhow::anyhow!("secret: environment variable '{arg}' is not set"))
                }
                "cmd" => run_cmd(&arg).await,
                "vault" => crate::vault::fetch(&arg).await,
                other => Err(anyhow::anyhow!("secret: unknown template verb '{other}'")),
            };
        }
        Ok(raw.to_string())
    }
}

impl fmt::Debug for Secret {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.0.is_empty() {
            f.write_str("Secret(empty)")
        } else {
            f.write_str("Secret(redacted)")
        }
    }
}

/// If `s` is exactly `{{ … }}`, return the trimmed inner text.
fn strip_template(s: &str) -> Option<String> {
    let s = s.trim();
    let inner = s.strip_prefix("{{")?.strip_suffix("}}")?;
    Some(inner.trim().to_string())
}

/// Split `env "VAR"` / `cmd "prog args"` into (verb, quoted-argument).
fn split_verb(inner: &str) -> anyhow::Result<(String, String)> {
    let inner = inner.trim();
    let (verb, rest) = inner
        .split_once(char::is_whitespace)
        .ok_or_else(|| anyhow::anyhow!("secret: malformed template '{inner}'"))?;
    let rest = rest.trim();
    let arg = rest
        .strip_prefix('"')
        .and_then(|r| r.strip_suffix('"'))
        .ok_or_else(|| anyhow::anyhow!("secret: template argument must be double-quoted"))?;
    Ok((verb.to_string(), arg.to_string()))
}

/// Run a shell command and return its trimmed stdout.
async fn run_cmd(cmd: &str) -> anyhow::Result<String> {
    let out = tokio::process::Command::new("sh")
        .arg("-c")
        .arg(cmd)
        .output()
        .await
        .map_err(|e| anyhow::anyhow!("secret: command failed to spawn: {e}"))?;
    if !out.status.success() {
        return Err(anyhow::anyhow!("secret: command exited with a non-zero status"));
    }
    Ok(String::from_utf8_lossy(&out.stdout).trim().to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn literal_resolves_to_itself() {
        assert_eq!(Secret::new("hunter2").resolve().await.unwrap(), "hunter2");
    }

    #[tokio::test]
    async fn empty_resolves_empty() {
        assert_eq!(Secret::new("").resolve().await.unwrap(), "");
    }

    #[tokio::test]
    async fn env_template_resolves() {
        std::env::set_var("LVIM_DB_TEST_SECRET", "from-env");
        assert_eq!(
            Secret::new("{{ env \"LVIM_DB_TEST_SECRET\" }}")
                .resolve()
                .await
                .unwrap(),
            "from-env"
        );
    }

    #[tokio::test]
    async fn cmd_template_resolves_trimmed() {
        assert_eq!(
            Secret::new("{{ cmd \"printf secret\" }}").resolve().await.unwrap(),
            "secret"
        );
    }

    #[test]
    fn debug_is_redacted() {
        let s = Secret::new("topsecret");
        assert_eq!(format!("{s:?}"), "Secret(redacted)");
        assert!(!format!("{s:?}").contains("topsecret"));
    }
}
