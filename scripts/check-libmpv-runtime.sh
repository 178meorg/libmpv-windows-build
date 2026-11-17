#!/usr/bin/env bash
set -Eeuo pipefail

dll="${1:?Usage: check-libmpv-runtime.sh /path/to/libmpv-2.dll}"
objdump_tool="${LIBMPV_OBJDUMP:-objdump}"

imports="$("$objdump_tool" -p "$dll")"
if ! grep -q 'DLL Name:' <<< "$imports"; then
    echo "error: could not read Windows DLL imports from $dll" >&2
    exit 1
fi

vulkan_imports="$(awk '/DLL Name:/ && tolower($3) ~ /vulkan/ {print $3}' <<< "$imports")"
if [[ -n "$vulkan_imports" ]]; then
    echo "error: libmpv must load without Vulkan Runtime, but imports: $vulkan_imports" >&2
    exit 1
fi

echo "PASS: $dll has no Vulkan DLL imports"
