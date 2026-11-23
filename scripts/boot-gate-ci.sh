#!/usr/bin/env bash
# Run scripts/boot-gate.sh on a GitHub runner and turn its report into what a
# run summary can show: a notice per phase while it runs, an error annotation
# per failed check at the end. The job log needs permissions the repository's
# own automation may not have; annotations do not.
#
# Usage: scripts/boot-gate-ci.sh WORKDIR [boot-gate.sh arguments...]
#
# Used by the build (on the image it just built, before anything is published)
# and by .github/workflows/boot-gate.yml (on the published image).
set -uo pipefail

workdir="${1:?usage: boot-gate-ci.sh WORKDIR [boot-gate.sh arguments...]}"
shift
mkdir -p "${workdir}"
report="${workdir}/boot-gate.log"
: > "${report}"

# Even a bug in the wait loops must end the step while the report can still be
# annotated, rather than at the job timeout.
timeout 3000 "$(dirname "$0")/boot-gate.sh" --workdir "${workdir}" "$@" 2>&1 \
    | while IFS= read -r line; do
        printf '%s\n' "${line}" >> "${report}"
        case "${line}" in
            PHASE\ *) echo "::notice title=DISTR0 boot gate::${line#PHASE }" ;;
        esac
    done
status=${PIPESTATUS[0]}

cat "${report}"
if [[ ${status} -eq 0 ]]; then
    exit 0
fi

annotated=0
while IFS= read -r line; do
    case "${line}" in
        FAIL*)
            echo "::error title=DISTR0 boot gate::${line}"
            annotated=$((annotated + 1))
            ;;
    esac
done < "${report}"
if [[ ${annotated} -eq 0 ]]; then
    echo "::error title=DISTR0 boot gate::$(tail -n 1 "${report}")"
fi
exit 1
