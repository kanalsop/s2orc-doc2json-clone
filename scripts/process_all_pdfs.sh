#!/usr/bin/env bash

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

INPUT_DIR="${1:-${REPO_ROOT}/input_dir}"
TEMP_DIR="${2:-${REPO_ROOT}/temp_dir}"
OUTPUT_DIR="${3:-${REPO_ROOT}/output_dir}"
PYTHON_BIN="${PYTHON_BIN:-python}"

if [[ ! -d "${INPUT_DIR}" ]]; then
    echo "input directory does not exist: ${INPUT_DIR}" >&2
    exit 1
fi

mkdir -p "${TEMP_DIR}" "${OUTPUT_DIR}"

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

    echo "process: ${pdf_file}"
    if "${PYTHON_BIN}" -m doc2json.grobid2json.process_pdf \
        -i "${pdf_file}" \
        -t "${TEMP_DIR}" \
        -o "${OUTPUT_DIR}"; then
        processed_count=$((processed_count + 1))
    else
        echo "failed: ${pdf_file}" >&2
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
