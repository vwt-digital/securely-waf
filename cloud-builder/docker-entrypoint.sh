#!/bin/bash

set -e

function usage()
{
    echo "$0 --project=<project_id>
    --backend=<backend>
    --logstash_host=<logstash_host>
    --organization=<organization>
    --grpc_url=<grpc_url>
    --username=<username>
    --password=<password>
    [--paranoia=<paranoia>]
    [--sec_rule_engine=DetectionOnly|On]"
}

if ! opts=$(getopt -l "project:,backend:,fqdn:,logstash_host:,organization:,grpc_url:,\
username:,password:,paranoia::,sec_rule_engine::" -o "p:,b:,d:,l:,o:,g:,u:,w:" -- "${@}")
then
    echo "Terminating..." >&2
    exit 1
fi

eval set -- "${opts}"

PROJECT_ID=
BACKEND=
FQDN=
LOGSTASH_HOST=
ORGANIZATION=
GRPC_URL=
USERNAME=
PASSWORD=
PARANOIA=2
SEC_RULE_ENGINE=DetectionOnly

while [ -n "${1}" ]
do
    case "${1}" in
        -p | --project ) PROJECT_ID="${2}"; shift 2 ;;
        -b | --backend ) BACKEND="${2}"; shift 2 ;;
        -d | --fqdn ) FQDN="${2}"; shift 2 ;;
        -l | --logstash_host ) LOGSTASH_HOST="${2}"; shift 2 ;;
        -o | --organization ) ORGANIZATION="${2}"; shift 2 ;;
        -g | --grpc_url ) GRPC_URL="${2}"; shift 2 ;;
        -u | --username ) USERNAME="${2}"; shift 2 ;;
        -w | --password ) PASSWORD="${2}"; shift 2 ;;
        --paranoia ) PARANOIA="${2}"; shift 2 ;;
        --sec_rule_engine ) SEC_RULE_ENGINE="${2}"; shift 2 ;;
        -- ) break ;;
        *) echo "Unrecognized argument ${1}"
           usage
           exit 1
           ;;
    esac
done

if [ -z "${PROJECT_ID}" ] || [ -z "${BACKEND}" ] || [ -z "${FQDN}" ] || [ -z "${LOGSTASH_HOST}" ] || \
    [ -z "${ORGANIZATION}" ] || [ -z "${GRPC_URL}" ] || [ -z "${USERNAME}" ] || [ -z "${PASSWORD}" ]
then
    echo "Missing required arguments" >&2
    usage
    exit 1
fi

echo "Deploying securely-waf to ${PROJECT_ID}..."

# Pull from source repo and push to current project's repo
# (required for Cloud Run service agent to be able to read the image)
docker pull "eu.gcr.io/vwt-d-gew1-dat-securely/securely-waf"
docker tag "eu.gcr.io/vwt-d-gew1-dat-securely/securely-waf" "eu.gcr.io/${PROJECT_ID}/securely-waf"
docker push "eu.gcr.io/${PROJECT_ID}/securely-waf"

# Remove old (more than 10) images in container registry
for digest in $(gcloud container images list-tags "eu.gcr.io/${PROJECT_ID}/securely-waf" --limit=99999 \
    --sort-by=TIMESTAMP --format='get(digest)' | head -n-10); do
  gcloud container images delete -q --force-delete-tags "eu.gcr.io/${PROJECT_ID}/securely-waf@${digest}"
done

# Deploy new revision of Cloud Run serverless WAF
gcloud run deploy securely-waf \
    --quiet \
    --project="${PROJECT_ID}" \
    --image="eu.gcr.io/$PROJECT_ID/securely-waf" \
    --timeout=600 \
    --region=europe-west1 \
    --allow-unauthenticated \
    --platform=managed \
    --memory=256Mi \
    --set-env-vars="^--^BACKEND=${BACKEND}" \
    --set-env-vars="^--^FQDN=${FQDN}" \
    --set-env-vars="FILEBEAT=1" \
    --set-env-vars="LOGSTASH_HOST=${LOGSTASH_HOST}" \
    --set-env-vars="ORGANIZATION=${ORGANIZATION}" \
    --set-env-vars="GRPC_URL=${GRPC_URL}" \
    --set-env-vars="USERNAME=${USERNAME}" \
    --set-env-vars="PASSWORD=${PASSWORD}" \
    --set-env-vars="PARANOIA=${PARANOIA}" \
    --set-env-vars="SEC_RULE_ENGINE=${SEC_RULE_ENGINE}"

