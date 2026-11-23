#!/usr/bin/env bash
# One-time setup of the GitHub "release" environment used by .github/workflows/release.yml.
# Run this on your own Mac, signed in to `gh`, with your Developer ID certificate in the
# login keychain. See docs/RELEASING.md.
#
# Secret values are never printed and never typed into the terminal: they're read from
# the keychain or files and piped straight into `gh secret set` on stdin.
set -euo pipefail

ENV_NAME="release"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OPENSSL=/usr/bin/openssl   # LibreSSL: reads/writes the legacy PKCS#12 that macOS `security` uses

REPO=""
BUNDLE_ID=""
P8_PATH=""
ISSUER_ID=""
IDENTITY_HINT=""
DRY_RUN=0
DO_CERT=1
DO_NOTARY=1
DO_SPARKLE=1

usage() {
    cat <<'EOF'
Usage: scripts/setup-release-secrets.sh --bundle-id ID [options]

Configures the GitHub "release" environment (secrets and variables) for signed,
notarized MacSize releases with Sparkle auto-updates.

Required:
  --bundle-id ID       Bundle identifier for official builds,
                       e.g. io.github.<owner>.macsize  (sets variable BUNDLE_ID)

Options:
  --repo OWNER/REPO    Target repository (default: current repo from `gh repo view`)
  --p8 PATH            App Store Connect API key file, AuthKey_<KEYID>.p8 (prompted if omitted)
  --issuer-id ID       App Store Connect Issuer ID (prompted if omitted; not secret)
  --identity TEXT      Pick the Developer ID identity whose SHA-1 or name contains TEXT
  --skip-cert          Don't touch MACOS_CERT_* / APPLE_TEAM_ID
  --skip-notary        Don't touch NOTARY_API_*
  --skip-sparkle       Don't touch SPARKLE_* keys
  --dry-run            Show what would be done; change nothing (no keychain export,
                       no key generation, no GitHub writes)
  -h, --help           Show this help

Sets in environment "release":
  secrets   MACOS_CERT_P12_BASE64  MACOS_CERT_PASSWORD
            NOTARY_API_KEY_P8_BASE64  NOTARY_API_KEY_ID  NOTARY_API_ISSUER_ID
            SPARKLE_ED_PRIVATE_KEY
  variables APPLE_TEAM_ID  BUNDLE_ID  SPARKLE_PUBLIC_ED_KEY
EOF
}

# ---------- output helpers ----------
if [[ -t 1 ]]; then BOLD=$'\033[1m'; DIM=$'\033[2m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; RESET=$'\033[0m'
else BOLD=""; DIM=""; GREEN=""; YELLOW=""; RED=""; RESET=""; fi
step() { printf '\n%s==> %s%s\n' "$BOLD" "$*" "$RESET"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '    %s✓%s %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '    %s!%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }
dry()  { printf '    %s[dry-run]%s %s\n' "$DIM" "$RESET" "$*"; }

# ---------- arguments ----------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo) REPO="${2:?--repo needs a value}"; shift 2 ;;
        --bundle-id) BUNDLE_ID="${2:?--bundle-id needs a value}"; shift 2 ;;
        --p8) P8_PATH="${2:?--p8 needs a value}"; shift 2 ;;
        --issuer-id) ISSUER_ID="${2:?--issuer-id needs a value}"; shift 2 ;;
        --identity) IDENTITY_HINT="${2:?--identity needs a value}"; shift 2 ;;
        --skip-cert) DO_CERT=0; shift ;;
        --skip-notary) DO_NOTARY=0; shift ;;
        --skip-sparkle) DO_SPARKLE=0; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "unknown argument: $1" ;;
    esac
done

[[ -n "$BUNDLE_ID" ]] || { usage >&2; die "--bundle-id is required (e.g. io.github.<owner>.macsize)"; }
[[ "$BUNDLE_ID" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]] || die "invalid bundle identifier: $BUNDLE_ID"
[[ "$(uname -s)" == "Darwin" ]] || die "run this on macOS"
command -v gh >/dev/null || die "GitHub CLI not found (brew install gh)"

# ---------- temp dir (removed on exit, files overwritten first) ----------
WORK="$(mktemp -d "${TMPDIR:-/tmp}/macsize-release.XXXXXX")"
chmod 700 "$WORK"
cleanup() {
    if [[ -d "$WORK" ]]; then
        find "$WORK" -type f -exec rm -P {} + 2>/dev/null || true
        rm -rf "$WORK"
    fi
}
trap cleanup EXIT

# ---------- GitHub helpers ----------
set_secret() { # name < value-on-stdin
    local name="$1"
    if [[ $DRY_RUN -eq 1 ]]; then cat >/dev/null; dry "gh secret set $name --env $ENV_NAME"; return; fi
    gh secret set "$name" --env "$ENV_NAME" --repo "$REPO" >/dev/null
    ok "secret $name"
}
set_variable() { # name value (not secret)
    local name="$1" value="$2"
    if [[ $DRY_RUN -eq 1 ]]; then dry "gh variable set $name --env $ENV_NAME = $value"; return; fi
    gh variable set "$name" --env "$ENV_NAME" --repo "$REPO" --body "$value" >/dev/null
    ok "variable $name = $value"
}
confirm() { # prompt [default N]
    local reply
    read -r -p "    $1 [y/N] " reply </dev/tty || reply=""
    [[ "$reply" =~ ^[Yy] ]]
}

# ---------- repository and environment ----------
step "Repository"
if [[ $DRY_RUN -eq 0 ]]; then
    gh auth status >/dev/null 2>&1 || die "not signed in to GitHub CLI (run: gh auth login)"
fi
if [[ -z "$REPO" ]]; then
    REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)" \
        || die "couldn't determine the repository; pass --repo OWNER/REPO"
fi
info "Target: $REPO, environment \"$ENV_NAME\""

step "Environment \"$ENV_NAME\""
if [[ $DRY_RUN -eq 1 ]]; then
    dry "create environment $ENV_NAME if missing, limited to tags matching v*"
else
    if gh api "repos/$REPO/environments/$ENV_NAME" >/dev/null 2>&1; then
        ok "environment exists"
    else
        gh api -X PUT "repos/$REPO/environments/$ENV_NAME" --input - >/dev/null <<'JSON'
{"deployment_branch_policy": {"protected_branches": false, "custom_branch_policies": true}}
JSON
        ok "created environment"
    fi
    policies="$(gh api "repos/$REPO/environments/$ENV_NAME/deployment-branch-policies" \
        -q '.branch_policies[] | "\(.type // "branch"):\(.name)"' 2>/dev/null || true)"
    if grep -qx 'tag:v\*' <<<"$policies"; then
        ok "deployment policy: tags v*"
    else
        # Policies only apply when custom policies are enabled; make sure they are.
        gh api -X PUT "repos/$REPO/environments/$ENV_NAME" --input - >/dev/null <<'JSON'
{"deployment_branch_policy": {"protected_branches": false, "custom_branch_policies": true}}
JSON
        gh api -X POST "repos/$REPO/environments/$ENV_NAME/deployment-branch-policies" \
            -f name='v*' -f type=tag >/dev/null
        ok "added deployment policy: tags v*"
    fi
    if [[ -n "$policies" ]] && grep -qv 'tag:v\*' <<<"$policies"; then
        warn "other deployment policies exist on \"$ENV_NAME\"; review them in Settings > Environments"
    fi
fi

# ---------- bundle id ----------
step "Bundle identifier"
set_variable BUNDLE_ID "$BUNDLE_ID"

# ---------- Developer ID certificate ----------
if [[ $DO_CERT -eq 1 ]]; then
    step "Developer ID Application certificate"
    IDENTITIES=()
    while IFS= read -r line; do IDENTITIES+=("$line"); done < <(
        security find-identity -v -p codesigning \
            | sed -n 's/^ *[0-9][0-9]*) \([0-9A-F]\{40\}\) "\(Developer ID Application: .*\)"$/\1 \2/p' \
            | sort -u
    )
    [[ ${#IDENTITIES[@]} -gt 0 ]] || die "no valid \"Developer ID Application\" identity in your keychain. Create one at developer.apple.com (see docs/RELEASING.md) and install it first."

    CHOSEN=""
    if [[ -n "$IDENTITY_HINT" ]]; then
        for entry in "${IDENTITIES[@]}"; do
            if [[ "$entry" == *"$IDENTITY_HINT"* ]]; then CHOSEN="$entry"; break; fi
        done
        [[ -n "$CHOSEN" ]] || die "no Developer ID identity matches \"$IDENTITY_HINT\""
    elif [[ ${#IDENTITIES[@]} -eq 1 ]]; then
        CHOSEN="${IDENTITIES[0]}"
    else
        info "Found ${#IDENTITIES[@]} identities:"
        for i in "${!IDENTITIES[@]}"; do info "  $((i + 1))) ${IDENTITIES[$i]#* }"; done
        read -r -p "    Choose 1-${#IDENTITIES[@]}: " pick </dev/tty
        [[ "$pick" =~ ^[0-9]+$ && "$pick" -ge 1 && "$pick" -le ${#IDENTITIES[@]} ]] || die "invalid choice"
        CHOSEN="${IDENTITIES[$((pick - 1))]}"
    fi
    CERT_SHA1="${CHOSEN%% *}"
    CERT_NAME="${CHOSEN#* }"
    APPLE_TEAM_ID="$(sed -n 's/.*(\([A-Z0-9]\{10\}\))$/\1/p' <<<"$CERT_NAME")"
    [[ -n "$APPLE_TEAM_ID" ]] || die "couldn't read the Team ID from \"$CERT_NAME\""
    info "Identity: $CERT_NAME"
    info "SHA-1:    $CERT_SHA1"

    if [[ $DRY_RUN -eq 1 ]]; then
        dry "export the private key + certificate for $CERT_SHA1 only, into a password-protected .p12"
        printf 'x' | set_secret MACOS_CERT_P12_BASE64
        printf 'x' | set_secret MACOS_CERT_PASSWORD
    else
        # `security export` can only export *all* identities, so export them to a throwaway
        # .p12, then rebuild a .p12 holding just the chosen certificate and its private key.
        # Private keys stay in memory (process substitution); nothing unencrypted hits disk.
        info "macOS will ask for permission to export keys from your keychain."
        ALL_P12="$WORK/all.p12"
        ONE_P12="$WORK/identity.p12"
        EXPORT_PW="$($OPENSSL rand -hex 24)"
        P12_PASSWORD="$($OPENSSL rand -base64 32 | tr -d '\n')"
        export EXPORT_PW P12_PASSWORD

        security export -k login.keychain-db -t identities -f pkcs12 -P "$EXPORT_PW" -o "$ALL_P12" >/dev/null \
            || die "keychain export failed (denied?)"

        # Chosen certificate, by SHA-1.
        CERT_PEM="$(security find-certificate -a -Z -p | awk -v sha="$CERT_SHA1" '
            /^SHA-1 hash:/ { keep = ($3 == sha); next }
            keep { print } /-----END CERTIFICATE-----/ { if (keep) exit }')"
        [[ -n "$CERT_PEM" ]] || die "couldn't read certificate $CERT_SHA1 from the keychain"
        CERT_PUB="$($OPENSSL x509 -noout -pubkey <<<"$CERT_PEM")"

        # Find the private key whose public half matches the certificate.
        ALL_KEYS="$($OPENSSL pkcs12 -in "$ALL_P12" -nocerts -nodes -passin env:EXPORT_PW 2>/dev/null)" \
            || die "couldn't read the exported keychain identities"
        KEY_PEM=""
        current=""
        while IFS= read -r line; do
            if [[ "$line" == "-----BEGIN"*"PRIVATE KEY-----" ]]; then current="$line"$'\n'; continue; fi
            if [[ -n "$current" ]]; then
                current+="$line"$'\n'
                if [[ "$line" == "-----END"*"PRIVATE KEY-----" ]]; then
                    if [[ "$($OPENSSL pkey -pubout 2>/dev/null <<<"$current")" == "$CERT_PUB" ]]; then
                        KEY_PEM="$current"; break
                    fi
                    current=""
                fi
            fi
        done <<<"$ALL_KEYS"
        unset ALL_KEYS current
        rm -P "$ALL_P12"

        if [[ -z "$KEY_PEM" ]]; then
            die "couldn't isolate the private key for this certificate. Export it manually instead:
       Keychain Access > login > My Certificates > right-click \"$CERT_NAME\" > Export… (.p12),
       then: base64 -i cert.p12 | gh secret set MACOS_CERT_P12_BASE64 --env $ENV_NAME --repo $REPO
             gh secret set MACOS_CERT_PASSWORD --env $ENV_NAME --repo $REPO   (prompts, hidden)
       and re-run this script with --skip-cert after setting APPLE_TEAM_ID=$APPLE_TEAM_ID:
             gh variable set APPLE_TEAM_ID --env $ENV_NAME --repo $REPO --body $APPLE_TEAM_ID"
        fi

        # Include the Developer ID intermediate CA(s) so the runner can build the chain.
        CHAIN_PEM="$(security find-certificate -a -c "Developer ID Certification Authority" -p 2>/dev/null || true)"
        if [[ -n "$CHAIN_PEM" ]]; then
            $OPENSSL pkcs12 -export -out "$ONE_P12" -name "$CERT_NAME" \
                -inkey <(printf '%s' "$KEY_PEM") -in <(printf '%s\n' "$CERT_PEM") \
                -certfile <(printf '%s\n' "$CHAIN_PEM") -passout env:P12_PASSWORD
        else
            $OPENSSL pkcs12 -export -out "$ONE_P12" -name "$CERT_NAME" \
                -inkey <(printf '%s' "$KEY_PEM") -in <(printf '%s\n' "$CERT_PEM") \
                -passout env:P12_PASSWORD
        fi
        unset KEY_PEM

        # Sanity check: exactly one private key in the new .p12.
        nkeys="$($OPENSSL pkcs12 -in "$ONE_P12" -nocerts -nodes -passin env:P12_PASSWORD 2>/dev/null | grep -c 'BEGIN.*PRIVATE KEY' || true)"
        [[ "$nkeys" == "1" ]] || die "rebuilt .p12 has $nkeys private keys, expected 1"
        ok "exported only \"$CERT_NAME\""

        base64 -i "$ONE_P12" | tr -d '\n' | set_secret MACOS_CERT_P12_BASE64
        printf '%s' "$P12_PASSWORD" | set_secret MACOS_CERT_PASSWORD
        rm -P "$ONE_P12"
        unset P12_PASSWORD EXPORT_PW
    fi
    set_variable APPLE_TEAM_ID "$APPLE_TEAM_ID"
fi

# ---------- App Store Connect API key (notarytool) ----------
if [[ $DO_NOTARY -eq 1 ]]; then
    step "App Store Connect API key (notarization)"
    if [[ -z "$P8_PATH" ]]; then
        read -r -p "    Path to AuthKey_<KEYID>.p8 (drag the file here): " P8_PATH </dev/tty
    fi
    P8_PATH="${P8_PATH%"${P8_PATH##*[![:space:]]}"}"   # trim trailing space from drag-and-drop
    P8_PATH="${P8_PATH/#\~/$HOME}"
    P8_PATH="${P8_PATH//\\ / }"
    [[ -f "$P8_PATH" ]] || die "file not found: $P8_PATH"
    P8_FILE="$(basename "$P8_PATH")"
    NOTARY_API_KEY_ID="$(sed -n 's/^AuthKey_\([A-Z0-9]\{1,\}\)\.p8$/\1/p' <<<"$P8_FILE")"
    [[ -n "$NOTARY_API_KEY_ID" ]] || die "expected a file named AuthKey_<KEYID>.p8, got $P8_FILE"
    grep -q 'BEGIN PRIVATE KEY' "$P8_PATH" || die "$P8_FILE doesn't look like a .p8 private key"
    info "Key ID: $NOTARY_API_KEY_ID"

    if [[ -z "$ISSUER_ID" ]]; then
        info "Issuer ID: App Store Connect > Users and Access > Integrations > App Store Connect API"
        read -r -p "    Issuer ID: " ISSUER_ID </dev/tty
    fi
    [[ "$ISSUER_ID" =~ ^[0-9a-fA-F-]{36}$ ]] || die "Issuer ID should be a UUID"

    base64 -i "$P8_PATH" | tr -d '\n' | set_secret NOTARY_API_KEY_P8_BASE64
    printf '%s' "$NOTARY_API_KEY_ID" | set_secret NOTARY_API_KEY_ID
    printf '%s' "$ISSUER_ID" | set_secret NOTARY_API_ISSUER_ID

    if [[ $DRY_RUN -eq 1 ]]; then
        dry "offer to move $P8_FILE to the Trash"
    elif confirm "Move $P8_FILE to the Trash? (Apple lets you download it only once; keep a backup if you need one)"; then
        if osascript -e 'on run argv' -e 'tell application "Finder" to delete (POSIX file (item 1 of argv) as alias)' -e 'end run' \
            "$(cd "$(dirname "$P8_PATH")" && pwd)/$P8_FILE" >/dev/null; then
            ok "moved $P8_FILE to the Trash"
        else
            warn "couldn't move it; delete it yourself"
        fi
    fi
fi

# ---------- Sparkle EdDSA key ----------
if [[ $DO_SPARKLE -eq 1 ]]; then
    step "Sparkle EdDSA signing key"
    SPARKLE_BIN="$ROOT_DIR/.build/artifacts/sparkle/Sparkle/bin"
    if [[ ! -x "$SPARKLE_BIN/generate_keys" ]]; then
        info "Resolving Swift packages to get Sparkle's tools…"
        (cd "$ROOT_DIR" && swift package resolve >/dev/null)
    fi
    [[ -x "$SPARKLE_BIN/generate_keys" ]] || die "Sparkle's generate_keys not found in $SPARKLE_BIN"

    if [[ $DRY_RUN -eq 1 ]]; then
        if PUB="$("$SPARKLE_BIN/generate_keys" -p 2>/dev/null)" && [[ -n "$PUB" ]]; then
            info "Existing key in your login keychain will be reused."
        else
            dry "generate a new key pair in your login keychain"
        fi
        dry "export the private key with generate_keys -x into a temp file"
        printf 'x' | set_secret SPARKLE_ED_PRIVATE_KEY
        set_variable SPARKLE_PUBLIC_ED_KEY "<public key from generate_keys -p>"
    else
        # Creates a key in the login keychain only if none exists; otherwise reuses it.
        # Reusing matters: installed copies only accept updates signed with this key.
        "$SPARKLE_BIN/generate_keys" >/dev/null
        PUB="$("$SPARKLE_BIN/generate_keys" -p)"
        [[ -n "$PUB" ]] || die "generate_keys -p returned nothing"
        KEY_FILE="$WORK/sparkle_private_key"
        "$SPARKLE_BIN/generate_keys" -x "$KEY_FILE" >/dev/null
        [[ -s "$KEY_FILE" ]] || die "generate_keys -x didn't export a key"
        tr -d '\n' < "$KEY_FILE" | set_secret SPARKLE_ED_PRIVATE_KEY
        rm -P "$KEY_FILE"
        set_variable SPARKLE_PUBLIC_ED_KEY "$PUB"
        warn "The Sparkle private key lives in your login keychain (item \"https://sparkle-project.org\")."
        warn "Back it up (e.g. generate_keys -x to an encrypted volume or password manager)."
        warn "If it's lost, existing installs can never auto-update again."
    fi
fi

step "Done"
if [[ $DRY_RUN -eq 1 ]]; then
    info "Dry run: nothing was changed."
else
    info "Review: https://github.com/$REPO/settings/environments"
    info "Release: git tag vX.Y.Z && git push origin vX.Y.Z"
fi
