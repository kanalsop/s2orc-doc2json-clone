#!/usr/bin/env bash

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

INPUT_DIR="${1:-${REPO_ROOT}/input_dir}"
TEMP_DIR="${2:-${REPO_ROOT}/temp_dir}"
OUTPUT_DIR="${3:-${REPO_ROOT}/output_dir}"
PYTHON_BIN="${PYTHON_BIN:-python}"
LOG_DIR="${REPO_ROOT}/log"
ERROR_LOG="${LOG_DIR}/errors.log"

log_error() {
    local pdf_file="$1"
    local message="$2"

    {
        printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')" "${pdf_file}"
        printf '%s\n\n' "${message}"
    } >> "${ERROR_LOG}"
}

has_unreadable_body_fonts() {
    local pdf_file="$1"
    local font_output
    local suspicious_fonts
    local suspicious_count
    local text_preview
    local garble_metrics

    if ! command -v pdffonts >/dev/null 2>&1; then
        return 1
    fi

    if ! font_output="$(pdffonts "${pdf_file}" 2>&1)"; then
        log_error "${pdf_file}" "failed to inspect fonts with pdffonts
${font_output}"
        return 1
    fi

    suspicious_fonts="$(
        printf '%s\n' "${font_output}" | awk '
            NR <= 2 || NF == 0 { next }
            {
                uni = $(NF - 2)
                type = ""
                for (i = 2; i <= NF - 6; i++) {
                    type = type (type ? " " : "") $i
                }
                if (type == "Type 3" || uni == "no") {
                    print $0
                }
            }
        '
    )"

    suspicious_count="$(printf '%s\n' "${suspicious_fonts}" | sed '/^$/d' | wc -l | tr -d ' ')"

    if [[ "${suspicious_count}" -ge 3 ]]; then
        if ! command -v pdftotext >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
            return 1
        fi

        if ! text_preview="$(pdftotext -f 1 -l 1 -layout "${pdf_file}" - 2>/dev/null)"; then
            return 1
        fi

        if garble_metrics="$(
            TEXT_PREVIEW="${text_preview}" python3 - <<'PY'
import sys
import os

text = os.environ.get("TEXT_PREVIEW", "")
chars = [c for c in text if not c.isspace()]

if not chars:
    raise SystemExit(1)

alpha_ratio = sum(c.isalpha() for c in chars) / len(chars)
punct_ratio = sum(not c.isalnum() for c in chars) / len(chars)
control_chars = sum(ord(c) < 32 and c not in "\n\t\r" for c in text)

if alpha_ratio < 0.5 and (punct_ratio > 0.4 or control_chars >= 100):
    print(
        f"alpha_ratio={alpha_ratio:.3f} "
        f"punct_ratio={punct_ratio:.3f} "
        f"control_chars={control_chars}"
    )
    raise SystemExit(0)

raise SystemExit(1)
PY
        )"; then
            log_error "${pdf_file}" "skip: unreadable body fonts detected
${garble_metrics}
${suspicious_fonts}"
            return 0
        fi
    fi

    return 1
}

if [[ ! -d "${INPUT_DIR}" ]]; then
    echo "input directory does not exist: ${INPUT_DIR}" >&2
    exit 1
fi

mkdir -p "${TEMP_DIR}" "${OUTPUT_DIR}" "${LOG_DIR}"

processed_count=0
skipped_count=0
failed_count=0
found_count=0

cd "${REPO_ROOT}" || exit 1

while IFS= read -r -d '' pdf_file; do
    found_count=$((found_count + 1))

    pdf_name="$(basename "${pdf_file}")"
    paper_id="${pdf_name%.*}"
    output_file="${OUTPUT_DIR}/${paper_id}.json"

    if [[ -f "${output_file}" ]]; then
        echo "skip: ${pdf_file}"
        skipped_count=$((skipped_count + 1))
        continue
    fi

    if has_unreadable_body_fonts "${pdf_file}"; then
        echo "skip unreadable fonts: ${pdf_file}"
        skipped_count=$((skipped_count + 1))
        continue
    fi

    echo "process: ${pdf_file}"
    error_tmp="$(mktemp)"
    if "${PYTHON_BIN}" -m doc2json.grobid2json.process_pdf \
        -i "${pdf_file}" \
        -t "${TEMP_DIR}" \
        -o "${OUTPUT_DIR}" \
        2>"${error_tmp}"; then
        processed_count=$((processed_count + 1))
        rm -f "${error_tmp}"
    else
        echo "failed: ${pdf_file}" >&2
        log_error "${pdf_file}" "$(cat "${error_tmp}")"
        cat "${error_tmp}" >&2
        rm -f "${error_tmp}"
        failed_count=$((failed_count + 1))
    fi
done < <(find "${INPUT_DIR}" -type f \( -iname '*.pdf' \) -print0)

if [[ "${found_count}" -eq 0 ]]; then
    echo "no PDF files found under ${INPUT_DIR}" >&2
    exit 1
fi

echo "summary: processed=${processed_count} skipped=${skipped_count} failed=${failed_count}"

if [[ "${failed_count}" -gt 0 ]]; then
    exit 1
fi
