# Opensearch Connect Script

This script provides a convenient way to connect to the Opensearch service within a specified Kubernetes namespace by setting up port forwarding. The script targets HMPPS Delius Alfresco environments.

## Usage

```sh
./opensearch-connect.sh <env> [local_port]
```

- `env`: Required. The environment you want to connect to (e.g., `dev`, `poc`, `prod`).
- `local_port`: Optional. The local port for port forwarding (defaults to `8080` if not specified).

## Features

- Automatically determines the appropriate namespace based on the environment provided.
- Identifies the pod running the Opensearch proxy within the namespace.
- Sets up port forwarding to allow local access to the Opensearch service.

## Environment Mapping

The environment (`<env>`) parameter maps to Kubernetes namespaces as follows:

- `poc` -> `hmpps-delius-alfrsco-poc`
- Other environments (e.g., `dev`, `prod`) -> `hmpps-delius-alfresco-<env>`

## Prerequisites

- Ensure you have `kubectl` installed and configured to interact with the appropriate Kubernetes cluster.

## Steps Performed by the Script

1. Validate the input and determine the Kubernetes namespace based on the provided environment (`env`).
2. Identify the Opensearch proxy pod running in the target namespace.
3. Set up port forwarding from the specified or default local port (`8080`) to the Opensearch service.

## Signals and Error Handling

- The script traps signals for interruption (Ctrl+C) and errors, ensuring graceful exit.
- If the script fails at any step or is interrupted, it will terminate the port-forwarding session and exit gracefully.

## Example

```sh
./opensearch-connect.sh dev 9090
```

This example connects to the `dev` environment and sets up port forwarding from the remote Opensearch service to local port `9090`.

## Important Notes

- The script assumes that the target namespace contains a pod with the name containing `opensearch-proxy-cloud-platform`.
- Pressing Ctrl+C will terminate the port-forwarding session.

## Cleanup

The script does not create any resources that require manual cleanup. The local port forwarding session will terminate upon script exit.

## Troubleshooting

- Ensure your Kubernetes context is set correctly to the cluster containing the target namespace.
- Ensure you have the necessary permissions to retrieve pods within the namespace.

---

This script is useful for developers and engineers who need to access the Opensearch service in HMPPS Delius Alfresco environments securely and conveniently.