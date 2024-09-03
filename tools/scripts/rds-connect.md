# RDS Connect Script

This script provides a convenient way to connect to an RDS (Relational Database Service) instance within a specified Kubernetes namespace by setting up port forwarding. The script targets HMPPS Delius Alfresco environments.

## Usage

```sh
./rds-connect.sh <env> [local_port]
```

- `env`: Required. The environment you want to connect to (e.g., `dev`, `poc`, `prod`).
- `local_port`: Optional. The local port for port forwarding (defaults to the remote port if not specified).

## Features

- Automatically determines the appropriate namespace based on the environment provided.
- Retrieves the RDS JDBC URL from Kubernetes secrets.
- Sets up port forwarding to allow local access to the RDS instance.

## Environment Mapping

The environment (`<env>`) parameter maps to Kubernetes namespaces as follows:

- `poc` -> `hmpps-delius-alfrsco-poc`
- Other environments (e.g., `dev`, `prod`) -> `hmpps-delius-alfresco-<env>`

## Prerequisites

- Ensure you have `kubectl` installed and configured to interact with the appropriate Kubernetes cluster.
- Ensure the `jq` utility is installed for JSON parsing.
- Ensure OpenSSL is installed for generating random hex strings.
- Ensure the Docker image `ghcr.io/ministryofjustice/hmpps-delius-alfresco-port-forward-pod:latest` is available and accessible.

## Steps Performed by the Script

1. Validate the input and determine the Kubernetes namespace based on the provided environment (`env`).
2. Retrieve the RDS JDBC URL from the Kubernetes secret `rds-instance-output`.
3. Extract the necessary details (protocol, host, ports, and database name) from the URL.
4. Generate a random hex string for unique identification.
5. Create a pod for port forwarding using the Docker image `ghcr.io/ministryofjustice/hmpps-delius-alfresco-port-forward-pod:latest`.
6. Wait for the pod to become ready.
7. Start port forwarding from the remote RDS instance to the local machine.

## Signals and Error Handling

- The script traps signals for interruption (Ctrl+C) and errors, ensuring proper cleanup of the port-forwarding pod.
- If the script fails at any step or is interrupted, it will delete the port-forward pod and exit gracefully.

## Example

```sh
./rds-connect.sh dev 5432
```

This example connects to the `dev` environment and sets up port forwarding from the remote RDS instance to local port `5432`.

## Important Notes

- The script assumes that the Kubernetes secret `rds-instance-output` exists in the target namespace and contains the key `RDS_JDBC_URL`.
- Pressing Ctrl+C will terminate the port-forwarding session and clean up the pod created for this purpose.

## Cleanup

The script automatically deletes the created port-forward pod upon script termination or failure. Manual cleanup should not be necessary.

## Troubleshooting

- Ensure your Kubernetes context is set correctly to the cluster containing the target namespace.
- Ensure you have the necessary permissions to create and delete pods and retrieve secrets within the namespace.
- Verify the `ghcr.io/ministryofjustice/hmpps-delius-alfresco-port-forward-pod:latest` image is accessible and that your Kubernetes cluster can pull it.

---

This script is useful for developers and engineers who need to access the RDS instance in HMPPS Delius Alfresco environments securely and conveniently.
