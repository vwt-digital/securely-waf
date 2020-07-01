#!/bin/bash

set -e

PROJECT_ID="${1}"

if [ -z "${PROJECT_ID}" ]
then
    echo "Please specify PROJECT_ID as a parameter"
    exit 1
fi

# Pull from source repo and push to current project's repo
# (required for Cloud Run service agent to be able to read the image)
docker pull "eu.gcr.io/vwt-d-gew1-dat-securely/securely-waf"
docker tag "eu.gcr.io/vwt-d-gew1-dat-securely/securely-waf eu.gcr.io/${PROJECT_ID}/securely-waf"
docker push "eu.gcr.io/${PROJECT_ID}/securely-waf"

# Remove old (more than 10) images in container registry
for digest in $(gcloud container images list-tags "eu.gcr.io/${PROJECT_ID}/securely-waf" --limit=99999 \
    --sort-by=TIMESTAMP --format='get(digest)' | head -n-10); do
  gcloud container images delete -q --force-delete-tags "eu.gcr.io/${PROJECT_ID}/securely-waf@${digest}"
done

# Deploy new revision of Cloud Run serverless WAF
# gcloud run deploy

