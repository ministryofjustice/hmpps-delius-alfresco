# hmpps-delius-alfresco

## Helm + Kustomize

This repository contains the Helm and Kustomize configuration for the Delius Alfresco deployment.

Rather than using/modifying the Helm chart directly, we use Kustomize to overlay the Helm chart with our custom configuration.
This allows us to keep the Helm chart as a dependency and only modify the configuration that we need to.

### Usage

Note: we use taskfile to simplify the commands. You can install taskfile by running `brew install go-task/tap/go-task`.


To deploy the Delius Alfresco stack, you can use the following command:

```
task helm_upgrade ENV=<dev|test|stage|preprod|prod> DEBUG=<true|false>
```

This will deploy the Delius Alfresco stack to the specified environment.
The `DEBUG` flag can be used to enable debug mode, which will enable helm verbose logging + output the templated,
rendered and kustomized manifests to the environment directory.


### Configuration

1. Helm values
The base helm values are stored in the `kustomize/base/values.yaml` file.
Each environment has its own values file, which is stored in the `kustomize/environments/<env>/values.yaml` file.
These values are combined when deploying the stack, with the environment values taking precedence.

2. Kustomize
The kustomize overlays are stored in the `kustomize/environments/<env>` directory.
These overlays are applied to the Helm chart's resources to modify the configuration as needed for the environment.


### Secrets

A number of secrets are required to deploy the Delius Alfresco stack. Some of these are set by the cloud-platform-environments repository, while others are set manually.

Table:
| Secret Name | Description | Set By | example/required keys |
| --- | --- | --- | --- |
| amazon-mq-broker-secret | The secret for the Amazon MQ broker | cloud-platform-environments |  see [cloud-platform-environments](https://github.com/ministryofjustice/cloud-platform-environments/blob/7968f9c66f6914d33db35b68209c55b2dcb25d7d/namespaces/live.cloud-platform.service.justice.gov.uk/hmpps-delius-alfresco-stage/resources/amq.tf#L218) |
| alfresco-license | The Alfresco license file | manual | `<alfresco-license-file-name> : <base64-encoded-alfresco-license-file>`
| legacy-rds-instance | The RDS instance for the legacy Delius Alfresco stack | manual | `DATABASE_NAME: <database-name>, DATABASE_USERNAME: <database-username>, DATABASE_PASSWORD: <database-password>, RDS_INSTANCE_ADDRESS: <rds-instance-address>` |
| rds-instance-outpur | The RDS instance for the CP Delius Alfresco stack | cloud-platform-environments | see [cloud-platform-environments](https://github.com/ministryofjustice/cloud-platform-environments/blob/7968f9c66f6914d33db35b68209c55b2dcb25d7d/namespaces/live.cloud-platform.service.justice.gov.uk/hmpps-delius-alfresco-stage/resources/rds.tf#L35) |
| quay-registry-secret | The secret for the Quay registry | manual | `.dockerconfigjson: {"auths":{"quay.io":{"username":"<quay-username>","password":"<quay-password>","email":"<quay-email>","auth":"<base64-encoded-auth>"}}}` |
