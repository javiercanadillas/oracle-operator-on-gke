# Deploying the Oracle Operator on GKE

## Why?

Because you can, it's _kind of_ fun, and it's a way to learn about other database options for GCP and Kubernetes.

**Disclaimer**: As of the time of writing, the Oracle Database Operator for Kubernetes [has not yet been tested by Oracle on GKE](https://github.com/oracle/oracle-database-operator?tab=readme-ov-file#release-status). However, as you'll see here, it works :-)

## Some concepts

This tutorial will be deploying the Oracle Database Operator for Kubernetes on GKE. This operator is designed to simplify the deployment and management of Oracle Database instances on Kubernetes. It will work with the concept of _Multitenant_ databases, which is a feature of Oracle Database that allows you to have multiple databases within a single Oracle Database instance. This is a feature that is available in Oracle Database 12c and later versions.

For multitenant databases, there are two key concepts that the Operator will be creating and managing for you when you later deploy a `Singleinstancedatabase` object in your GKE cluster:

- The _Container Database_ (CDB): it contains one or many _Pluggable Databases_ (PDBs). The CDB is a main multitenancy enabled database instance, and it functions as the foundation, housing system metadata and shared resources essential for managing all the PDBs it contains.
- The _Pluggable Database_ (PDB): the PDBs are the individual databases that you can create within the CDB. It is essentially a portable collection of schemas, schema objects (like tables, views, etc.), and other database components, and acts like a self-contained database from an application's perspective, providing isolation and a dedicated environment.

So, the CDB acts as the foundation or container for the PDBs, where a single CDB can hold multiple PDBs, with each PDB functioning as a separate, pluggable unit within it.  The CDB provides centralized services and infrastructure that are shared by all the PDBs within it.

This is important in this context as the long term goal would be to have PDBs acting as separate databases for different applications, and the CDB providing the shared services and infrastructure for all the PDBs, all part of a Kubernetes Platform deployed on GKE.

In this tutorial you will be deploying a Single Instance Database through the Oracle Operator. What does this have to do with the CDB and PDBs? Well, **the Single Instance Database is a special case of a CDB with a single PDB**. This means that as soon as you've deployed it, you'll have a CDB with a single PDB, and you'll be able to connect to both the CDB and the PDB using standart Oracle Database tools like `sqlplus`.

Now that this is more or less clear, let's move on to the steps to deploy the Oracle Operator on GKE.

## Pre-requisites

Here are the things you'll need to have in place before you can run the steps to install the Oracle Operator on GKE:

- You'll need a GCP Project. Create it in your GCP environment.
- You'll need a Mac or a Linux computer. If a Mac, you'll need to install Homebrew. If you're using Windows, I'd recommend you to use [Cloud Shell](https://cloud.google.com/shell/docs/launching-cloud-shell).
- You'll need to install the Google Cloud SDK.  You can find the instructions [here](https://cloud.google.com/sdk/docs/install).
- You'll need to install kubectl.  You can find the instructions [here](https://kubernetes.io/docs/tasks/tools/install-kubectl/).

Once this is done, edit the `env.sh` file and set the environment variables to match your setup. You will need at least to change the `PROJECT_ID` variable. You may also want to check the `DB_VERSION` value by visiting [the Oracle docker-images GitHub repo](https://github.com/oracle/docker-images/tree/main/OracleDatabase/SingleInstance/dockerfiles) and making sure there version used matches an existing directory there. You may leave the other variables as they are.

Finally, you need to set and export the DB_PASSWORD environment variable. This is the password for the Oracle Database. You can do this by running the following command:

```bash
export DB_PASSWORD=<your_password>
```

## Installing the operator

Use the [`steps.bash`](./steps.bash) script. The script accepts a single argument, the name of a script's function.  Every step in the Oracle Operator for Kubernetes has a corresponding function in the script.  The script will execute the function and print the output to the console.

You can either launch a wrapper function called `all` to execute all the steps or call each function individually:

```bash
./steps.bash all
```

or you can call each function individually, for example the `check_prereqs` function:

```bash
./steps.bash check_prereqs
```

I would recommend you the second option, as it will allow you to understand what each step is doing and correct any mistakes that may happen.

### Running the steps

1. Make sure you have performed the pre-requisites steps above.

2. Set the GCP environment:

```bash
./steps.bash set_gcp_environment
```

3. Enable the necessary APIs:

  ```bash
  ./steps.bash enable_apis
  ```

4. Create the GKE cluster with one starting node in the configured region where you'll be deploying the Oracle Operator:

  ```bash
  ./steps.bash create_gke_cluster
  ```

5. Get the GKE credentials into your local kubeconfig file so you can interact with the cluster using `kubectl`:

  ```bash
  ./steps.bash get_gke_credentials
  ```

6. Install the required [Cert Manager](https://cert-manager.io/):
  ```bash
  ./steps.bash install_cert_manager
  ```

7. Install the `cmctl` tool in your local computer that will be used to check the proper installation of the Cert Manager:
  
  ```bash
  ./steps.bash install_cmctl
  ```

8. Check the Cert Manager installation using the previously installed `cmctl` tool:

  ```bash
  ./steps.bash check_cert_manager
  ```

9. Now, deploy the Oracle Operator. This will use [the corresponding yaml](https://github.com/oracle/oracle-database-operator/blob/main/oracle-database-operator.yaml) file taken from the Oracle Database Operator GitHub repository. This step will also take care of configuring the necessary roles bindings:

  ```bash
  ./steps.bash deploy_oracle_operator
  ```

10. Check the Oracle Operator installation, by listing the pods in the `oracle-database-operator-syste` namespace:

  ```bash
  ./steps.bash check_oracle_operator
  ```

11. Next would be builiding a container image for the database version and flavor you want to base your PDBs and CDBs on. For this, you first need to clone the `docker-images` GitHub repository containing the source to build Oracle Database Container Images, from where you can select the Oracle Database 23.4.0 free version that's going to be used for this tutorial. This step automates all this for you:

  ```bash
  ./steps.bash get_oracle_docker_images
  ```
  
12. You now need to create a Google Artifact Registry to host the Oracle Database image you're about to build:

  ```bash
  ./steps.bash create_gar_repo
  ```

13. You have now all the building blocks in place to actually build an Oracle Database 23.4.0 free version image. This step will take some time to complete, and will use Cloud Build to build the image and publish it to the Google Artifact Registry repository that you've created before:

  ```bash
  ./steps.bash build_image
  ```

14. Using the Oracle Operator, you will create a Single Instance Oracle Database from the image created above. For this, you will create a `SingleInstanceDatabase` object in the Kubernetes cluster using as template the [`singleinstancedatabase.yaml.dist`](./k8s/singleinstancedatabase.yaml.dist) file in this repo. This step will also create a `Secret` object that will store the password for the Oracle Database:

  ```bash
  ./steps.bash create_sidb
  ```
  
15. Check that the installation went well by querying the status of the `SingleInstanceDatabase` object you created before:

  ```bash
  ./steps.bash check_sidb
  ```
  
16. Install the `sqlplus` tool that you'll be using to test connectivity agains the PDB and CDB databases:

  ```bash
  ./steps.bash install_sqlplus
  ```

17. Use the `sqlplus` tool to connect to the Oracle Database:

  ```bash
  ./steps.bash check_connection
  ```

You should be able to connect to both. If you can't, check the logs of the `oracle-database-operator-controller-manager` pod in the `oracle-database-operator-system` namespace to trouebleshoot any possible issues.

# Relevant links

- [Oracle Database Operator Usecase 01](https://github.com/oracle/oracle-database-operator/blob/main/docs/multitenant/usecase01/README.md)
- [Oracle Database - Fit for Kubernetes](https://blogs.oracle.com/coretec/post/oracle-database-fit-for-kubernetes)