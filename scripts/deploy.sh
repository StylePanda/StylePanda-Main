#!/usr/bin/env bash

set -Eeuo pipefail
umask 022

readonly APP_ROOT="/var/www/stylepanda-app"
readonly REPO_DIR="${APP_ROOT}/repo"
readonly RELEASES_DIR="${APP_ROOT}/releases"
readonly CURRENT_LINK="${APP_ROOT}/current"
readonly LOCK_FILE="${APP_ROOT}/deploy.lock"
readonly REMOTE="origin"
readonly BRANCH="main"
readonly EXPECTED_REPOSITORY="StylePanda/StylePanda-Main"
readonly RETAIN_RELEASES=5
readonly RELEASE_NAME_PATTERN='^[0-9]{14}-[0-9a-f]{7,40}$'

NEW_RELEASE_DIR=""
PREVIOUS_TARGET=""
SWITCHED=0
DEPLOYMENT_COMPLETE=0
TEMP_LINK=""
RELEASES_REAL=""

log() {
    local level="$1"
    local timestamp
    shift
    timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)" || timestamp="time-unavailable"
    printf '[%s] [%s] %s\n' "$timestamp" "$level" "$*"
}

die() {
    log "ERROR" "$*"
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

path_is_direct_release() {
    local candidate="$1"
    local candidate_real

    [[ -n "$candidate" ]] || return 1
    candidate_real="$(realpath -m -- "$candidate")" || return 1
    [[ "$(dirname -- "$candidate_real")" == "$RELEASES_REAL" ]]
}

is_managed_release_name() {
    local candidate="$1"
    [[ "$(basename -- "$candidate")" =~ $RELEASE_NAME_PATTERN ]]
}

remove_managed_release() {
    local candidate="$1"
    local candidate_real
    local active_target=""

    candidate_real="$(realpath -m -- "$candidate")" || die "Cannot resolve release path for removal: $candidate"
    path_is_direct_release "$candidate_real" || die "Refusing to remove path outside releases: $candidate_real"
    is_managed_release_name "$candidate_real" || die "Refusing to remove unrecognized release directory: $candidate_real"

    if [[ -L "$CURRENT_LINK" ]]; then
        active_target="$(readlink -f -- "$CURRENT_LINK" 2>/dev/null || true)"
    fi
    [[ "$candidate_real" != "$active_target" ]] || die "Refusing to remove active release: $candidate_real"

    if [[ -e "$candidate_real" ]]; then
        log "INFO" "Removing inactive managed release: $(basename -- "$candidate_real")"
        rm -rf --one-file-system -- "$candidate_real"
    fi
}

atomic_switch() {
    local target="$1"
    local temp_candidate

    [[ -d "$target" ]] || die "Symlink target is not a directory: $target"
    path_is_direct_release "$target" || die "Symlink target is outside releases: $target"

    temp_candidate="${APP_ROOT}/.current.$$.new"
    [[ ! -e "$temp_candidate" && ! -L "$temp_candidate" ]] || die "Temporary symlink path already exists: $temp_candidate"

    ln -s -- "$target" "$temp_candidate"
    TEMP_LINK="$temp_candidate"
    mv -Tf -- "$TEMP_LINK" "$CURRENT_LINK"
    TEMP_LINK=""
    SWITCHED=1

    [[ "$(readlink -f -- "$CURRENT_LINK")" == "$(realpath -e -- "$target")" ]] \
        || die "Current symlink verification failed"
}

rollback_after_failure() {
    local current_target=""

    [[ "$SWITCHED" -eq 1 ]] || return 0
    if [[ -L "$CURRENT_LINK" ]]; then
        current_target="$(readlink -f -- "$CURRENT_LINK" 2>/dev/null || true)"
    fi

    if [[ -n "$PREVIOUS_TARGET" && -d "$PREVIOUS_TARGET" ]] && path_is_direct_release "$PREVIOUS_TARGET"; then
        log "WARN" "Post-switch check failed; restoring previous release: $(basename -- "$PREVIOUS_TARGET")"
        atomic_switch "$PREVIOUS_TARGET"
        SWITCHED=0
        return 0
    fi

    if [[ -z "$PREVIOUS_TARGET" && -L "$CURRENT_LINK" && "$current_target" == "$NEW_RELEASE_DIR" ]]; then
        log "WARN" "Post-switch check failed on first release; removing current symlink"
        rm -f -- "$CURRENT_LINK"
        SWITCHED=0
        return 0
    fi

    log "ERROR" "Automatic rollback was not possible; inspect current immediately"
    return 1
}

handle_exit() {
    local exit_code="$1"
    local current_target=""

    trap - EXIT
    [[ -n "$TEMP_LINK" && -L "$TEMP_LINK" ]] && rm -f -- "$TEMP_LINK"

    if [[ "$exit_code" -ne 0 && "$DEPLOYMENT_COMPLETE" -eq 0 ]]; then
        set +e
        rollback_after_failure

        if [[ -n "$NEW_RELEASE_DIR" && -d "$NEW_RELEASE_DIR" ]]; then
            if [[ -L "$CURRENT_LINK" ]]; then
                current_target="$(readlink -f -- "$CURRENT_LINK" 2>/dev/null || true)"
            fi
            if [[ "$current_target" != "$NEW_RELEASE_DIR" ]]; then
                remove_managed_release "$NEW_RELEASE_DIR"
            fi
        fi
        log "ERROR" "Deployment failed with exit code ${exit_code}"
    fi

    exit "$exit_code"
}

trap 'handle_exit $?' EXIT
trap 'log "ERROR" "Deployment interrupted"; exit 130' INT TERM

git_repo() {
    git -c safe.directory="$REPO_DIR" -C "$REPO_DIR" "$@"
}

validate_release() {
    local release_dir="$1"
    local required_file
    local unreadable=""
    local unsearchable=""
    local symlink=""

    path_is_direct_release "$release_dir" || die "Release path is outside releases: $release_dir"
    is_managed_release_name "$release_dir" || die "Release name is not managed: $release_dir"

    for required_file in index.html 404.html robots.txt sitemap.xml assets/css/main.css; do
        [[ -f "${release_dir}/${required_file}" ]] || die "Release validation failed; missing ${required_file}"
        [[ -r "${release_dir}/${required_file}" ]] || die "Release validation failed; unreadable ${required_file}"
    done

    [[ -s "${release_dir}/index.html" ]] || die "Release validation failed; index.html is empty"
    [[ -d "${release_dir}/assets/css" ]] || die "Release validation failed; assets/css is missing"
    [[ ! -e "${release_dir}/.git" ]] || die "Release validation failed; .git must not be exported"
    [[ ! -e "${release_dir}/scripts" ]] || die "Release validation failed; deployment scripts must not be public"

    unreadable="$(find "$release_dir" -type f ! -perm -004 -print -quit)"
    [[ -z "$unreadable" ]] || die "Release validation failed; file is not publicly readable: $unreadable"

    unsearchable="$(find "$release_dir" -type d ! -perm -005 -print -quit)"
    [[ -z "$unsearchable" ]] || die "Release validation failed; directory lacks public read/execute permissions: $unsearchable"

    symlink="$(find "$release_dir" -type l -print -quit)"
    [[ -z "$symlink" ]] || die "Release validation failed; symlinks are not allowed in release content: $symlink"

    grep -Fq 'StylePanda' "${release_dir}/index.html" || die "Release validation failed; StylePanda marker missing"
    grep -Fq 'BrickMissing' "${release_dir}/index.html" || die "Release validation failed; BrickMissing marker missing"
    grep -Fq 'Impressum' "${release_dir}/index.html" || die "Release validation failed; Impressum marker missing"
    grep -Fq 'https://brickmissing.stylepanda.me/impressum/' "${release_dir}/index.html" \
        || die "Release validation failed; exact Impressum URL missing"

    log "INFO" "Release validation passed"
}

http_body_check() {
    local url="$1"
    local marker="$2"
    local body

    body="$(curl --fail --silent --show-error --location --max-redirs 3 \
        --proto '=https' --proto-redir '=https' \
        --connect-timeout 10 --max-time 30 "$url")" \
        || die "HTTP smoke check failed: $url"
    grep -Fq -- "$marker" <<<"$body" || die "Expected marker missing from $url"
}

run_production_smoke_checks() {
    local cache_key="$1"
    local not_found_response
    local not_found_status
    local not_found_body

    log "INFO" "Running production smoke checks"
    http_body_check "https://stylepanda.me/?release=${cache_key}" "StylePanda"
    http_body_check "https://stylepanda.me/robots.txt?release=${cache_key}" "Sitemap: https://stylepanda.me/sitemap.xml"
    http_body_check "https://stylepanda.me/sitemap.xml?release=${cache_key}" "https://stylepanda.me/"
    http_body_check "https://stylepanda.me/assets/css/main.css?release=${cache_key}" "--accent:"

    not_found_response="$(curl --silent --show-error --max-redirs 0 --proto '=https' \
        --connect-timeout 10 --max-time 30 --write-out $'\n%{http_code}' \
        "https://stylepanda.me/deployment-smoke-${cache_key}-not-found")" || true
    not_found_status="${not_found_response##*$'\n'}"
    not_found_body="${not_found_response%$'\n'*}"
    if [[ "$not_found_status" == "404" ]] && grep -Fq 'Seite nicht gefunden' <<<"$not_found_body"; then
        log "INFO" "Custom 404 smoke check passed"
    else
        log "WARN" "Custom 404 smoke check did not match (HTTP ${not_found_status:-unknown}); nginx error_page may still need configuration"
    fi
}

check_www_redirect() {
    local response
    local status
    local redirect_url

    response="$(curl --silent --show-error --output /dev/null --max-redirs 0 --proto '=https' \
        --connect-timeout 10 --max-time 30 --write-out '%{http_code}|%{redirect_url}' \
        'https://www.stylepanda.me/')" || {
        log "WARN" "Could not check www redirect"
        return 0
    }

    status="${response%%|*}"
    redirect_url="${response#*|}"
    if [[ ( "$status" == "301" || "$status" == "308" ) && "$redirect_url" == "https://stylepanda.me/" ]]; then
        log "INFO" "www redirect check passed"
    else
        log "WARN" "www redirect differs from requirement (HTTP ${status}, target ${redirect_url:-none})"
    fi
}

cleanup_old_releases() {
    local -a releases=()
    local release_name
    local release_path
    local release_real
    local keep_count=0
    declare -A keep=()

    mapfile -t releases < <(
        find "$RELEASES_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' \
            | grep -E "$RELEASE_NAME_PATTERN" \
            | sort -r
    )

    release_real="$(readlink -f -- "$CURRENT_LINK")"
    keep["$release_real"]=1
    keep_count=1

    if [[ -n "$PREVIOUS_TARGET" && -d "$PREVIOUS_TARGET" && "$PREVIOUS_TARGET" != "$release_real" ]]; then
        keep["$(realpath -e -- "$PREVIOUS_TARGET")"]=1
        keep_count=$((keep_count + 1))
    fi

    for release_name in "${releases[@]}"; do
        release_path="${RELEASES_DIR}/${release_name}"
        release_real="$(realpath -e -- "$release_path")"
        if [[ -z "${keep[$release_real]+present}" && "$keep_count" -lt "$RETAIN_RELEASES" ]]; then
            keep["$release_real"]=1
            keep_count=$((keep_count + 1))
        fi
    done

    for release_name in "${releases[@]}"; do
        release_path="${RELEASES_DIR}/${release_name}"
        release_real="$(realpath -e -- "$release_path")"
        if [[ -z "${keep[$release_real]+present}" ]]; then
            remove_managed_release "$release_real"
        fi
    done

    log "INFO" "Release retention completed; kept up to ${RETAIN_RELEASES} managed/protected releases and left foreign directories untouched"
}

main() {
    local app_real
    local repo_real
    local origin_url
    local dirty_status
    local current_branch
    local current_head
    local target_commit
    local deployed_commit
    local short_commit
    local release_name
    local command_name

    [[ "$EUID" -eq 0 ]] || die "Run this deployment with sudo/root privileges"

    for command_name in basename curl date dirname find flock git grep ln mkdir mv readlink realpath rm sort tar; do
        require_command "$command_name"
    done

    [[ -d "$APP_ROOT" ]] || die "Application root does not exist: $APP_ROOT"
    [[ -d "$REPO_DIR" ]] || die "Repository directory does not exist: $REPO_DIR"
    [[ -d "$RELEASES_DIR" ]] || die "Releases directory does not exist: $RELEASES_DIR"

    app_real="$(realpath -e -- "$APP_ROOT")"
    repo_real="$(realpath -e -- "$REPO_DIR")"
    RELEASES_REAL="$(realpath -e -- "$RELEASES_DIR")"
    [[ "$app_real" == "$APP_ROOT" ]] || die "Application root resolves unexpectedly: $app_real"
    [[ "$repo_real" == "$REPO_DIR" ]] || die "Repository path resolves unexpectedly: $repo_real"
    [[ "$RELEASES_REAL" == "$RELEASES_DIR" ]] || die "Releases path resolves unexpectedly: $RELEASES_REAL"

    exec 9>"$LOCK_FILE"
    flock -n 9 || die "Another StylePanda deployment is already running"
    log "INFO" "Deployment lock acquired"

    [[ "$(git_repo rev-parse --is-inside-work-tree 2>/dev/null)" == "true" ]] \
        || die "Repository check failed: $REPO_DIR"
    [[ "$(realpath -e -- "$(git_repo rev-parse --show-toplevel)")" == "$REPO_DIR" ]] \
        || die "Git top-level directory does not match the dedicated production checkout"

    origin_url="$(git_repo remote get-url "$REMOTE")" || die "Git remote not found: $REMOTE"
    case "$origin_url" in
        *:StylePanda/StylePanda-Main|*:StylePanda/StylePanda-Main.git|*/StylePanda/StylePanda-Main|*/StylePanda/StylePanda-Main.git)
            log "INFO" "Git remote repository validated: $EXPECTED_REPOSITORY"
            ;;
        *)
            die "Git remote does not point to expected repository: $origin_url"
            ;;
    esac

    dirty_status="$(git_repo status --porcelain --untracked-files=all)"
    [[ -z "$dirty_status" ]] || die "Production repository contains tracked or untracked changes; deployment aborted"

    current_branch="$(git_repo symbolic-ref --short -q HEAD || printf 'detached')"
    current_head="$(git_repo rev-parse --verify HEAD)"
    log "INFO" "Repository before fetch: branch=${current_branch}, commit=${current_head}"

    log "INFO" "Fetching ${REMOTE}/${BRANCH}"
    git_repo fetch --prune "$REMOTE" "$BRANCH"
    target_commit="$(git_repo rev-parse --verify "refs/remotes/${REMOTE}/${BRANCH}^{commit}")"

    if git_repo show-ref --verify --quiet "refs/heads/${BRANCH}"; then
        git_repo checkout --force "$BRANCH"
    else
        git_repo checkout --force -b "$BRANCH" --track "${REMOTE}/${BRANCH}"
    fi
    git_repo reset --hard "${REMOTE}/${BRANCH}"

    deployed_commit="$(git_repo rev-parse --verify HEAD)"
    [[ "$deployed_commit" == "$target_commit" ]] || die "Repository HEAD does not match ${REMOTE}/${BRANCH}"
    [[ "$(git_repo symbolic-ref --short HEAD)" == "$BRANCH" ]] || die "Repository is not on branch ${BRANCH}"
    [[ -z "$(git_repo status --porcelain --untracked-files=all)" ]] || die "Repository is not clean after reset"
    log "INFO" "Deploying exact ${REMOTE}/${BRANCH} commit: $deployed_commit"

    short_commit="$(git_repo rev-parse --short=7 "$deployed_commit")"
    release_name="$(date -u '+%Y%m%d%H%M%S')-${short_commit}"
    [[ "$release_name" =~ $RELEASE_NAME_PATTERN ]] || die "Generated release name is invalid: $release_name"
    NEW_RELEASE_DIR="${RELEASES_DIR}/${release_name}"
    path_is_direct_release "$NEW_RELEASE_DIR" || die "Generated release path is unsafe: $NEW_RELEASE_DIR"
    [[ ! -e "$NEW_RELEASE_DIR" ]] || die "Release already exists: $NEW_RELEASE_DIR"

    if [[ -e "$CURRENT_LINK" && ! -L "$CURRENT_LINK" ]]; then
        die "Current path exists but is not a symlink: $CURRENT_LINK"
    fi
    if [[ -L "$CURRENT_LINK" ]]; then
        PREVIOUS_TARGET="$(readlink -f -- "$CURRENT_LINK")"
        [[ -d "$PREVIOUS_TARGET" ]] || die "Current symlink target is not a directory"
        path_is_direct_release "$PREVIOUS_TARGET" || die "Current symlink points outside releases"
        log "INFO" "Previous release: $(basename -- "$PREVIOUS_TARGET")"
    else
        log "INFO" "No previous current release found"
    fi

    log "INFO" "Creating release: $release_name"
    mkdir -- "$NEW_RELEASE_DIR"
    git_repo archive --format=tar "$deployed_commit" -- \
        index.html 404.html robots.txt sitemap.xml assets \
        | tar -xf - -C "$NEW_RELEASE_DIR"

    validate_release "$NEW_RELEASE_DIR"

    log "INFO" "Switching current symlink"
    atomic_switch "$NEW_RELEASE_DIR"
    log "INFO" "Current now points to: $(readlink -f -- "$CURRENT_LINK")"

    run_production_smoke_checks "$release_name"
    check_www_redirect

    DEPLOYMENT_COMPLETE=1
    if ! (cleanup_old_releases); then
        log "WARN" "Release retention encountered an error; active release was preserved"
    fi

    log "INFO" "Deployment successful"
    log "INFO" "Release: $release_name"
    log "INFO" "Commit: $deployed_commit"
    log "INFO" "Current: $(readlink -f -- "$CURRENT_LINK")"
}

main "$@"
