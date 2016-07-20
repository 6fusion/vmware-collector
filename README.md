# 6fusion VMware Collector

## Installation steps

### Server requirements

* A VMware Vsphere environment properly running with infrastructures and valid credentials

### Local computer requirements

* Latest Kubernetes client `kubectl`
* Have the kubeconfig and all credentials required to access the Vsphere instance and the OnPrem
* Download this repository to your local computer
* OnPrem API running

### VMware Collector configuration values
Go to the folder where you downloaded this repository, edit the file `vmwarecollector.yaml` and set the following values according to your needs:
(note: all values **must** be base64 encoded; a handy command (if available in your operating system) to encode a value is: `echo YOUR_VALUE | base64`)


**Vsphere Secret section (vsphere-secret)**
```
...
data:
  host: "BASE64_VALUE"              # IP address or domain of the VMware server
  user: "BASE64_VALUE"              # username to access the Vspere Vclient
  password: "BASE64_VALUE"          # password to access the previous username
  ignore-ssl-errors: "BASE64_VALUE" # True or false
  log-level: "BASE64_VALUE"         # Defined level for showing elements in log (defaults to debug) 
  session-limit: "BASE64_VALUE"     # Maximum number of connections allowed
...
```
**6fusion On Premise Secret section (on-prem-secret)**
```
...
data:
  api-host: "BASE64_VALUE"                   # IP address or domain of the 6fusion On Premise API server
  log-level: "BASE64_VALUE"                  # Defined level for showing elements in log (defaults to debug) 
  api-endpoint: "BASE64_VALUE"               # Endpoint to access the OnPrem API
  organization-id: "BASE64_VALUE"            # Organization ID of the one already created in the 6fusion On Premise API server
  collector-version: "BASE64_VALUE"          # Version of the collector being used
  registration-date: "BASE64_VALUE"          # Date in the format `YYYY-MM-DD`
  machines-by-inv-timestamp: "BASE64_VALUE"  # Total of machines that are included on each request to obtain metrics from vsphere 
  inventoried-limit: "BASE64_VALUE"          # Define the limit of inventoried timestamps that each replica controller will take each round
  batch_size: "BASE64_VALUE"                 # Number of simultaneous requests for Vsphere
  oauth-endpoint: "BASE64_VALUE"             # Oauth path that will be included after api-host (defaults to oauth)
  oauth-token: "BASE64_VALUE"                # Oauth 2 token to authenticate the requests
  refresh-token: "BASE64_VALUE"              # Oauth 2 token that will be used if oauth-token expires (most of the times not required)
  login-email: "BASE64_VALUE"                # Email for login the user in order to generate a new oauth token (not required if "oauth-token" provided)
  login-password: "BASE64_VALUE"             # Password for login the user in order to generate a new oauth token (not required if "oauth-token" provided)
  application-id: "BASE64_VALUE"             # Oauth Application id used to request a new oauth token (not required if "oauth-token" provided)
  application-secret: "BASE64_VALUE"         # Oauth Application secret used to request a new oauth token (not required if "oauth-token" provided)
  api-scope: "BASE64_VALUE"                  # Scope required for oauth authentication
  proxy-host: "BASE64_VALUE"                 # Host required for proxy connection
  proxy-port: "BASE64_VALUE"                 # Port required for proxy connection
  proxy-user: "BASE64_VALUE"                 # User required for proxy connection
  proxy-password: "BASE64_VALUE"             # Password required for proxy connection
...
```
**Metrics collector replication controller section (6fusion-vmwarecollector-metrics)**
```
...
spec:
  replicas: 2  # Set the amount of metrics collectors replicas (default 2)
...
```
Once you have set the above values, save the `vmwarecollector.yaml` file.

### 6fusion-system namespace installation (optional)
**NOTE:** do this step only if the `6fusion-system` namespace is not present on the Kubernetes cluster that runs on the server

`$ kubectl --kubeconfig=/path/to/kubeconfig_file create -f /path/to/repository/vmwarecollector-namespace.yaml`

### 6fusion VMware collector installation

`$ kubectl --kubeconfig=/path/to/kubeconfig_file create -f /path/to/repository/vmwarecollector.yaml`

### 6fusion VMware collector pods information
The 6fusion VMware collector will create the following pods:

##### VMware collector master pod (and service)
This pod named `6fusion-vmwarecollector-master` will contain the following containers:
* `vmware-collector-inventory`: the container that collects the cluster inventory
* `vmware-collector-mongodb`: the container that provides the cache db for the cluster data

The MongoDB cache in this pod will be exposed through a Kubernetes service called `6fusion-vmware-collector-master` on port `27017` so the separate Metrics container of this collector can connect to it and make the corresponding database operations required for the metrics collection.

##### VMwarecollector metrics pod
This pod named `6fusion-vmwarecollector-metrics` will run as a **Replication Controller** so depending on the amount of containers running in the whole cluster, it can be scaled horizontally at any time with the amount of replicas needed to satisfy the metrics collection in a short convenient amount of time. It contains the following container:
* `vmware-collector-metrics`: the container that collects the metrics of the machines in the cluster