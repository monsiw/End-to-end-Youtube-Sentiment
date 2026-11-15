#!/usr/bin/env bash
set -Eeuo pipefail

IMAGE="${1:?Podaj obraz Docker}"

sed "s|IMAGE_PLACEHOLDER|${IMAGE}|g" \
  k8s/deployment.yaml | sudo k3s kubectl apply -f -

sudo k3s kubectl apply -f k8s/service.yaml

sudo k3s kubectl rollout status \
  deployment/sentiment --timeout=300s