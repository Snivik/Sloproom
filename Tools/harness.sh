#!/bin/bash
#
# Compile a headless CLI harness from engine (non-UI) sources, with the same Swift settings
# as the app target (Swift 5 mode, default MainActor isolation, approachable concurrency,
# MemberImportVisibility). The CLI is NOT sandboxed, so it can read test files directly.
#
# Usage:
#   Tools/harness.sh <output-binary> <main.swift> [extra .swift files...]
#
# <main.swift> must use `@main struct X { static func main() async throws { ... } }`
# (files are compiled with -parse-as-library).
#
# The default engine file set (ENGINE_FILES below) is always included; extra files are added
# (duplicates are ignored). Set HARNESS_NO_DEFAULT=1 to pass the full file list yourself.
# Set HARNESS_OPT=-Onone for faster compiles / better debugging (default -O).
#
set -euo pipefail

if [ $# -lt 2 ]; then
  echo "usage: $0 <output-binary> <main.swift> [extra .swift files...]" >&2
  exit 2
fi

REPO="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$1"; MAIN="$2"; shift 2
APP="$REPO/sloproom"

ENGINE_FILES=(
  "$APP"/Catalog/*.swift
  "$APP"/Develop/EditSettings.swift
  "$APP"/Develop/GeometryMath.swift
  "$APP"/Develop/CanvasGeometry.swift
  "$APP"/Develop/RenderPipeline.swift
  "$APP"/Develop/Stages/*.swift
  "$APP"/Develop/Masking/*.swift
  "$APP"/Develop/Adjustments/*.swift
  "$APP"/Develop/Kernels/*.swift
  "$APP"/Import/PhotoMetadataReader.swift
  "$APP"/Previews/*.swift          # engine only; SwiftUI views live in Previews/UI/
)
# Feature engineers: add further UI-free engine files here (or pass them as extra args).

FILES=("$MAIN")
if [ "${HARNESS_NO_DEFAULT:-0}" != "1" ]; then FILES+=("${ENGINE_FILES[@]}"); fi
FILES+=("$@")

# De-duplicate by absolute path, keep order.
UNIQUE=()
SEEN=" "
for f in "${FILES[@]}"; do
  abs="$(cd "$(dirname "$f")" && pwd)/$(basename "$f")"
  case "$SEEN" in *" $abs "*) continue ;; esac
  SEEN="$SEEN$abs "
  UNIQUE+=("$abs")
done

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
mkdir -p "$(dirname "$OUT")"

exec xcrun swiftc "${HARNESS_OPT:--O}" \
  -swift-version 5 \
  -parse-as-library \
  -default-isolation=MainActor \
  -enable-upcoming-feature MemberImportVisibility \
  -enable-upcoming-feature DisableOutwardActorInference \
  -enable-upcoming-feature GlobalActorIsolatedTypesUsability \
  -enable-upcoming-feature InferIsolatedConformances \
  -enable-upcoming-feature InferSendableFromCaptures \
  -enable-upcoming-feature NonisolatedNonsendingByDefault \
  -target arm64-apple-macosx26.0 \
  -module-name SloproomHarness \
  -o "$OUT" \
  "${UNIQUE[@]}"
