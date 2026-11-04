#!/usr/bin/env bash
# Install the groundcover sensor with the documented CLI flow.
# Fails cleanly when .env is missing. Does not change the shop either way.
set -euo pipefail

cd "$(dirname "$0")/.."

ENV_FILE=".env"
CONTEXT="${PEBBLE_CONTEXT:-kind-pebble}"
VALUES="deploy/groundcover/values.local.yaml"

if [[ ! -f "$ENV_FILE" ]]; then
  cat <<'EOF'
groundcover is not installed: there is no .env file in the repo root.

The shop is unchanged and keeps running without it.

  cp .env.example .env

Set GROUNDCOVER_SITE to the ingestion endpoint from
Settings -> Access -> Ingestion Keys. That tab stays empty until a BYOC
backend exists in your own cloud account. Signup alone does not create one.
See the README, then run this script again.

Docs: https://docs.groundcover.com/getting-started/installation-and-updating/connect-kubernetes-cluster
EOF
  exit 1
fi

# .env is a list of KEY=value lines. It is not committed.
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

if [[ -z "${GROUNDCOVER_SITE:-}" ]]; then
  echo "GROUNDCOVER_SITE is empty in .env." >&2
  echo "Set it to the ingestion endpoint from Settings -> Access -> Ingestion Keys." >&2
  echo "Docs: https://docs.groundcover.com/collect-data/ingestion-keys" >&2
  exit 1
fi

if [[ ! "$GROUNDCOVER_SITE" =~ ^[A-Za-z0-9._:-]+$ ]]; then
  echo "GROUNDCOVER_SITE contains characters this script will not write into YAML." >&2
  exit 1
fi

CLUSTER_ID="${GROUNDCOVER_CLUSTER_ID:-pebble}"
ENV_NAME="${GROUNDCOVER_ENV:-dev}"

if [[ ! "$CLUSTER_ID" =~ ^[A-Za-z0-9._-]+$ ]] || [[ ! "$ENV_NAME" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "GROUNDCOVER_CLUSTER_ID and GROUNDCOVER_ENV must be plain identifiers." >&2
  exit 1
fi

if ! kubectl config use-context "$CONTEXT" >/dev/null 2>&1; then
  echo "Cannot use kubectl context ${CONTEXT}. Run ./setup.sh first." >&2
  exit 1
fi

if [[ ! -r /sys/kernel/btf/vmlinux ]]; then
  cat <<'EOF'
warning: /sys/kernel/btf/vmlinux is not readable on this machine.
The eBPF sensor needs Linux kernel 5.3+ built with BTF (CO:RE).
https://docs.groundcover.com/reference/requirements/kernel-requirements-for-ebpf-sensor
Continuing. The CLI also checks cluster compatibility.
EOF
fi

if ! command -v groundcover >/dev/null 2>&1; then
  echo "groundcover CLI is not on PATH. Installing it with the documented command:"
  echo "  sh -c \"\$(curl -fsSL https://groundcover.com/install.sh)\""
  sh -c "$(curl -fsSL https://groundcover.com/install.sh)"
fi

if ! command -v groundcover >/dev/null 2>&1; then
  echo "The installer finished but 'groundcover' is still not on PATH." >&2
  echo "Open a new shell, or add the install directory to PATH, then run this script again." >&2
  exit 1
fi

mkdir -p "$(dirname "$VALUES")"
umask 077
{
  echo "global:"
  echo "  backend:"
  echo "    enabled: false"
  echo "  ingress:"
  echo "    site: ${GROUNDCOVER_SITE}"
  if [[ -n "${GROUNDCOVER_TOKEN:-}" ]]; then
    if [[ "$GROUNDCOVER_TOKEN" == *$'\n'* || "$GROUNDCOVER_TOKEN" == *'"'* || "$GROUNDCOVER_TOKEN" == *' '* ]]; then
      echo "GROUNDCOVER_TOKEN cannot contain spaces, quotes, or newlines." >&2
      exit 1
    fi
    echo "  groundcover_token: \"${GROUNDCOVER_TOKEN}\""
  fi
  echo "clusterId: \"${CLUSTER_ID}\""
  echo "env: \"${ENV_NAME}\""
} >"$VALUES"

echo "Wrote ${VALUES} (gitignored)."
echo "If the CLI is not logged in yet, it will ask you to. You can also run: groundcover auth login"
echo "If it asks about control-plane taints, skip them. Pebble runs on the worker node."
echo "The documented coverage policy excludes control-plane nodes."
echo "Running: groundcover deploy -f ${VALUES}"
groundcover deploy -f "$VALUES"
