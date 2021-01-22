#!/bin/bash

set -e

function usage()
{
    echo "$0 --project=<project_id>
    --backend=<backend>
    --fqdn=<fully qualified domain name>
    --grpc_url=<grpc_url>
    --username=<username>
    --password=<password>
    [--logstash_host=<logstash_host> --organization=<organization>]
    [--paranoia=<paranoia>]
    [--sec_rule_engine=DetectionOnly|On]
    [--skip_domain_mapping]
    [--gcp_iam_audiences=<comma-separated-list-of-audiences>]
    [--additional_ca_cert=<ca-cert.crt>]"
}

if ! opts=$(getopt -l "project:,backend:,fqdn:,logstash_host:,organization:,grpc_url:,\
username:,password:,paranoia::,sec_rule_engine::,gcp_iam_audiences::,skip_domain_mapping,additional_ca_cert::" \
    -o "p:,b:,d:,l:,o:,g:,u:,w:,s,i" -- "${@}")
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
        --gcp_iam_audiences ) GCP_IAM_AUDIENCES="${2}"; shift 2 ;;
        --paranoia ) PARANOIA="${2}"; shift 2 ;;
        --sec_rule_engine ) SEC_RULE_ENGINE="${2}"; shift 2 ;;
        --additional_ca_cert ) ADDITIONAL_CA_CERT="${ADDITIONAL_CA_CERT} ${2}"; shift 2 ;;
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

if [ -z "${PROJECT_ID}" ] || [ -z "${BACKEND}" ] || [ -z "${FQDN}" ] ||
    [ -z "${GRPC_URL}" ] || [ -z "${USERNAME}" ] || [ -z "${PASSWORD}" ]
then
    echo "Missing required arguments" >&2
    usage
    exit 1
fi

if [ -n "${LOGSTASH_HOST}" ]
then
    if [ -z "${ORGANIZATION}" ]
    then
        echo "When using filebeat by specifying LOGSTASH_HOST then ORGANIZATION is a required argument" >&2
        usage
        exit 1
    fi

    output_env_vars="FILEBEAT=1,LOGSTASH_HOST=${LOGSTASH_HOST},ORGANIZATION=${ORGANIZATION},GRPC_URL=${GRPC_URL}"
else
    output_env_vars="GRPC_URL=${GRPC_URL}"  # Implies output on /var/log, to be picked-up by Stackdriver from Cloud Run
fi

echo "Deploying securely-waf to ${PROJECT_ID}..."

# Pull from source repo and push to current project's repo
# (required for Cloud Run service agent to be able to read the image)
docker pull "${SECURELY_WAF_IMAGE_SOURCE}"
if [ -n "${ADDITIONAL_CA_CERT}" ]
then
    mkdir -p waf_with_ca_cert
    cp ${ADDITIONAL_CA_CERT} waf_with_ca_cert/
    pushd waf_with_ca_cert
    echo "FROM ${SECURELY_WAF_IMAGE_SOURCE}
COPY ${ADDITIONAL_CA_CERT} /usr/local/share/ca-certificates/
RUN update-ca-certificates" > Dockerfile
    docker build -t "eu.gcr.io/${PROJECT_ID}/securely-waf" .
    popd
else
    docker tag "${SECURELY_WAF_IMAGE_SOURCE}" "eu.gcr.io/${PROJECT_ID}/securely-waf"
fi

docker push "eu.gcr.io/${PROJECT_ID}/securely-waf"

# Remove old (more than 10) images in container registry
for digest in $(gcloud container images list-tags "eu.gcr.io/${PROJECT_ID}/securely-waf" --limit=99999 \
    --sort-by=TIMESTAMP --format='get(digest)' | head -n-10); do
  gcloud container images delete -q --force-delete-tags "eu.gcr.io/${PROJECT_ID}/securely-waf@${digest}"
done

# Determine service account to use for Cloud Run WAF container
cloud_run_service_account=$(gcloud iam service-accounts list --project="${PROJECT_ID}" --format="get(email)" |
    grep -e "^back-end-gsa@" -e "^[0-9]*-compute@" | sort | tail -n1)

if echo "${PASSWORD}" | grep -q "^secret:"
then
    # Secret should be retrieved from Secret Manager. Get the secret for which cloudbuilder serviceaccount
    # is authorized and create a new secret for which this project's Cloud Run serviceaccount is authorized.
    secret_version=$(echo "${PASSWORD}" | cut -d: -f2-)
    secret_value=$(gcloud secrets versions access "${secret_version}")
    waf_secret_id="${PROJECT_ID}-securely-waf-password"

    if gcloud secrets describe "${waf_secret_id}" --project="${PROJECT_ID}"
    then
        # Secret exists, check if value has changed and add new version if it did change
        if [ -n "$(gcloud secrets versions list "${waf_secret_id}" --format='get(name)' --project="${PROJECT_ID}")" ]
        then
            waf_secret_value=$(gcloud secrets versions access latest --secret="${waf_secret_id}" \
                --project="${PROJECT_ID}")
        else
            waf_secret_value=""
        fi
        if [ "${waf_secret_value}" != "${secret_value}" ]
        then
            echo "${secret_value}" | gcloud secrets versions add "${waf_secret_id}" \
                --project="${PROJECT_ID}" --data-file=-
        fi
    else
        # Secret does not yet exist, create it
        echo "${secret_value}" | gcloud secrets create "${waf_secret_id}" --project="${PROJECT_ID}" --data-file=-
        gcloud secrets add-iam-policy-binding "${waf_secret_id}" --project="${PROJECT_ID}" \
            --member="serviceAccount:${cloud_run_service_account}" --role="roles/secretmanager.secretAccessor"
    fi
    waf_password="secret:projects/${PROJECT_ID}/secrets/${waf_secret_id}/versions/latest"
else
    waf_password="${PASSWORD}"
fi

authentication_vars="USERNAME=${USERNAME},PASSWORD=${waf_password}"

# Deploy new revision of Cloud Run serverless WAF
gcloud run deploy securely-waf \
    --quiet \
    --project="${PROJECT_ID}" \
    --image="eu.gcr.io/$PROJECT_ID/securely-waf" \
    --timeout=600 \
    --region=europe-west1 \
    --allow-unauthenticated \
    --platform=managed \
    --memory=1024Mi \
    --service-account="${cloud_run_service_account}" \
    --set-env-vars="^--^BACKEND=${BACKEND}" \
    --set-env-vars="^--^FQDN=${FQDN}" \
    --set-env-vars="${output_env_vars}" \
    --set-env-vars="SECURELY=true" \
    --set-env-vars="TLS=true" \
    --set-env-vars="${authentication_vars}" \
    --set-env-vars="GCP_IAM_AUDIENCES=${GCP_IAM_AUDIENCES}" \
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
