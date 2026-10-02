#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
cargo build --release --locked --manifest-path helper/Cargo.toml
npm test --prefix frontend
npm run build --prefix frontend
go test -race ./...
go vet ./...
