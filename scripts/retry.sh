# A network step that may blip, tried again: `retry <command...>`.
#
# Up to RELEASE_TRIES attempts (4), the first pause RELEASE_RETRY_DELAY
# seconds (5) and doubling. Sourced by ship.sh and github-release.sh. It
# only repeats; making a step safe to repeat is the caller's job (look
# before creating, replace before uploading), because a request that timed
# out on the client may have succeeded on the server.
retry() {
    local tries="${RELEASE_TRIES:-4}" pause="${RELEASE_RETRY_DELAY:-5}" n=1
    until "$@"; do
        [ "$n" -ge "$tries" ] && return 1
        echo "  … ${1##*/} ${2:-} did not go through (attempt $n of $tries); again in ${pause}s" >&2
        sleep "$pause"
        n=$((n + 1))
        pause=$((pause * 2))
    done
}
