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
username:,password:,paranoia::,sec_rule_engine::,skip_domain_mapping" -o "p:,b:,d:,l:,o:,g:,u:,w:,s" -- "${@}")
then
    echo "Terminating..." >&2
    exit 1
fi

eval set -- "${opts}"

if [ -z "${PARANOIA}" ]
then
    PARANOIA=2
fi
if [ -z "${SEC_RULE_ENGINE}" ]
then
    SEC_RULE_ENGINE=DetectionOnly
fi

DO_DOMAIN_MAPPING=1

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
        -s | --skip_domain_mapping ) DO_DOMAIN_MAPPING=0; shift ;;
        --paranoia ) PARANOIA="${2}"; shift 2 ;;
        --sec_rule_engine ) SEC_RULE_ENGINE="${2}"; shift 2 ;;
        -- ) break ;;
        *) echo "Unrecognized argument ${1}"
           usage
           exit 1
           ;;
    esac
done

if [ -z "${SECURELY_WAF_IMAGE_SOURCE}" ]
then
    echo "Please define SECURELY_WAF_IMAGE_SOURCE to the securely waf source container image"
    exit 1
fi

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
docker pull "${SECURELY_WAF_IMAGE_SOURCE}"
docker tag "${SECURELY_WAF_IMAGE_SOURCE}" "eu.gcr.io/${PROJECT_ID}/securely-waf"
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

if [ ${DO_DOMAIN_MAPPING} -eq 1 ]
then
    for _DOMAIN in ${FQDN//,/ }
    do
        if ! echo "${_DOMAIN}" | grep -e "\.appspot\.com$" -e "\.run\.app$"
        then
            gcloud beta run domain-mappings list --filter="${_DOMAIN}" \
              --platform="managed" \
              --region="europe-west1" \
              --project="${PROJECT_ID}" | grep "${_DOMAIN}\s*securely-waf " ||
            gcloud beta run domain-mappings create --service="securely-waf" \
              --platform="managed" \
              --region="europe-west1" \
              --domain="${_DOMAIN}" \
              --project="${PROJECT_ID}"
        fi
    done
fi
