### Purpose

These example instsructions explain how you would customise one particular dependant Helm chart and publish a newer version to GitHub pages. Instructions assume GitHub pages are already configured for your repo; see the reference section below

### Start services
In order to start the alfresco-repository service, we need to make a valid  license available in the namespace. A secret containing the license needs to be created:
```bash
ACS_NAMESPACE=hmpps-delius-alfrsco-poc
kubectl create secret generic alfresco-license \
  --namespace $ACS_NAMESPACE \
  --from-file /example/path/to/license/file.lic
```

Next We will need to ensure all services are up and running.
Start k8s services by executing helm command _(Helm will complain if a random secret is not created)_

```bash
cd hmpps-delius-alfresco-poc/alfresco-content-services
export SECRET=$(openssl rand -base64 20)
export BUCKET_NAME=$(awk '{print substr($0, 0)}' <<< $(kubectl get secrets s3-bucket-output -o jsonpath='{.data.BUCKET_NAME}' | base64 -d))
helm install alfresco-content-services . --values=./values.yaml \
--set s3connector.config.bucketName=$BUCKET_NAME \
--set global.tracking.sharedsecret=$SECRET
```

### Check the chart file for dependent charts and pull the required version
For the purpose of this demo, we will select the following service from the `Chart.yaml` file
```yaml
- condition: alfresco-sync-service.enabled
  name: alfresco-sync-service
  repository: https://alfresco.github.io/alfresco-helm-charts/
  version: 4.1.0
```
```
1. Delete existing tar file for the sync service. There will be an error pulling the chart otherwise
rm -rf charts/alfresco-sync-service-4.1.0.tgz

2. Pull a particular version of `alfresco-sync-service` chart
helm pull alfresco-sync-service --repo  https://alfresco.github.io/alfresco-helm-charts --version 4.1.0 -d charts --untar

3. The above command will pull a tar file called `charts/alfresco-sync-service-4.1.0.tgz` and then untar it into a directory called `alfresco-sync-service`. Delete the tar file
rm -rf charts/alfresco-sync-service-4.1.0.tgz
```

### Modify charts

1. Change the chart version in the newly pulled chart. For example change is from `4.1.0` to `4.1.1`
2. Make your changes and then test them by upgrading Helm release
   ```
   - export SECRET=$(awk '{print substr($0, 19)}' <<< $(kubectl get secrets alfresco-content-services-alfresco-repository-properties-secret -o jsonpath='{.data.alfresco-global\.properties}' | base64 -d))
   - export BUCKET_NAME=$(awk '{print substr($0, 0)}' <<< $(kubectl get secrets s3-bucket-output -o jsonpath='{.data.BUCKET_NAME}' | base64 -d))
   - helm upgrade alfresco-content-services . --values=./values.yaml --set s3connector.config.bucketName=$BUCKET_NAME --set global.tracking.sharedsecret=$SECRET
   - NOTE: For the release upgrade, use the existing secret. You will otherwise have to restart pods consuming those secrets
   ```
4. Once satisfied with your changes, create a package and add it to the docs directory
   - "helm package charts/alfresco-sync-service -d ../docs"
5. Create / update an index file in docs directory
   - "helm repo index ../docs --url https://ministryofjustice.github.io/hmpps-delius-alfresco-poc"


### Update the lock file and commit changes
Locate the `Chart.yaml` file and modify the repository URL and version. It should now look like the code snippet below after the change:
```yaml
- condition: alfresco-sync-service.enabled
  name: alfresco-sync-service
  repository: https://ministryofjustice.github.io/hmpps-delius-alfresco-poc/
  version: 4.1.1
```

1. Delete `charts/alfresco-sync-service` directory as it is no longer needed
2. Push your changes / docs directory to the feature branch
3. Update your GitHub pages settings so that the `source branch` is pointing to your feature branch
4. Update helm dependencies which will pull the updated charts and will update the lock file
   - `helm dependency update .`
5. Push the lock file and charts dirctory to the feature branch and get merge approval
6. Merge into main branch
7. Update your GitHub pages settings so that the `source branch` is pointing to your main branch
8. Upgrade the helm release for the changes to be updated in kubernetes cluster
   ```
   - export SECRET=$(awk '{print substr($0, 19)}' <<< $(kubectl get secrets alfresco-content-services-alfresco-repository-properties-secret -o jsonpath='{.data.alfresco-global\.properties}' | base64 -d))
   - helm upgrade alfresco-content-services . --values=./values.yaml --set global.tracking.sharedsecret=$SECRET
   - NOTE: For the release upgrade, use the existing secret. You will otherwise have to restart pods consuming those secrets
   ```

### Alternatively, pull a particular chart either directly from repository URL or by adding it in the local repo

1. Pull a chart with a particular version direcly from the GitHub pages
- `helm pull alfresco-sync-service --repo  https://ministryofjustice.github.io/hmpps-delius-alfresco-poc/ --version 4.1.1 -d charts --untar`

2. Or add the updated chart in a local helm repo
```
helm repo add alfresco-sync-service https://ministryofjustice.github.io/hmpps-delius-alfresco-poc/

helm search repo alfresco-sync-service
NAME                                            CHART VERSION   APP VERSION     DESCRIPTION
alfresco-sync-service/alfresco-sync-service     4.1.1           3.9.0           Alfresco Sync Service
```

### References to various docs that explain how to set up GitHub pages and how to publish Helm charts
- [The Chart Repository Guide](https://helm.sh/docs/topics/chart_repository/#github-pages-example)
- [Chart Releaser Action to Automate GitHub Page Charts ](https://helm.sh/docs/howto/chart_releaser_action/#github-actions-workflow)
- [Example on how to publish a chart on GitHub pages](https://github.com/technosophos/tscharts)
