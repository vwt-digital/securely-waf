# Serverless ModSecurity deployed with Cloud Builder image

This Docker image inherits from the Google Cloud SDK docker image and can be used to deploy the Serverless ModSecurity container (serverless Modsec). By adding this image as a step in your build, the serverless Modsec will be deployed and configured.
The Serverless Modsec can also connect to Securely App, thus implementing platform spanning visitor profiling and blocking.

## Building the Serverless Modsec and its Cloud Builder image

First, the images should be build before they can be used, which requires some configuration upfront.
To be able to connect to Securely App, a Certificate Authority and it's key must be available as Secret Manager secrets in the GCP project.
The CA certificate secret's name should be `${PROJECT_ID}-ca-cert`, the CA key secret's name should be `${PROJECT_ID}-ca-key`. Both secrets should be accessible by the GCP Cloud Builder service account. Also Cloud Run API and (obvious) Secret Manager API must be enabled on the GCP project.
Building the images can be done using the [cloudbuild.yaml](../cloudbuild.yaml) in the root of the repository.
The following substitution variables can be used to specify the connection parameters to Elastic and Securely blocker:

| Substitution variable | Description |
| ---- | --- |
| _LOGSTASH_HOST | Logstash host name and port number |
| _GRPC_URL | The Securely App server address in the format of host:port |
| _ELASTIC_USERNAME |  Username for configurator service |
| _ELASTIC_PASSWORD| Password for configurator service |

```
git clone https://github.com/vwt-digital/securely-waf.git
cd securely-waf
gcloud builds submit --substitutions=_LOGSTASH_HOST="<ip>:<port>",_GRPC_URL="<ip>:<port>"_ELASTIC_USERNAME="elastic",_ELASTIC_PASSWORD="password" . 
```
This will build two images that will be pushed to the GCP project's container registry:
* cloud-builder-waf: the Cloud Build image that can be used to deploy the Modsec WAF.
* securely-waf-source: the image of the serverless Modsec WAF.

## Deploying the serverless Modsec

The serverless Modsec will be deployed in each GCP project that contains a web application that needs to be protected. To be able to retrieve the images from the container registry, all Cloud Build service accounts deploying a serverless Modsec will need `roles/storage.objectViewer` permission in the project containing the registry with the images.
The Cloud Build step to deploy the serverless Modsec can be added at the end of the Cloud Build of the web application deployment:
```
  - name: 'eu.gcr.io/<container-registry-project-id>/cloud-builder-waf'
    id: 'Deploy WAF'
    args: ['--project="${PROJECT_ID}"',
           '--backend="myapi-internal.example.com/"',
           '--fqdn="myapi-external.example.com"',
           '--organization="MyCompany"',
           '--paranoia="1"',
           '--sec_rule_engine="On"']
```
This step will pull the securely-waf-source image from the container registry it was pushed to before and push it to the web applications project container registry. Thereafter, it will deploy the serverless Modsec to the project and route traffic to the specified fqdn to it.
The parameters that can be passed to the cloud-builder-waf image:
|Parameter|Required|Description|
|---|---|---|
|project|Yes|Project id of project deploying to|
|backend|Yes|Application backend URI that ModSecurity proxies to, comma separated. (Example: https://www.example.com/ )|
|fqdn|Yes|Domain name that ModSecurity listens to for the given Backend, comma separated. (Example: www.example.com) |
|organization|Yes|Your organization name|
|paranoia|No|An integer indicating the blocking paranoia level. Level 1 has very vew false positives and is intended to protect against basic attacks only. Levels two and three require incrementally more tuning, but also provide more protection. (Default: 1)|
|sec_rule_engine|No|This sets ModSecurity in DetectionOnly or blocking (On) mode. (Default: DetectionOnly)|
|skip_domain_mapping|No|Will skip routing traffic from specified custom domain to deployed serverless Modsec|
|additional_ca_cert|No|Filename of additional Certificate Authority certificate that should be trusted by Modsec to connect to. Can be added multiple times to add multiple CA certificates. Additional certificate files should exist in the directory from which the cloudbuild is submitted.|
