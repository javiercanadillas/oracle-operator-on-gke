#!/usr/bin/false
# This script is meant to be sourced.

# Script-wide variables
export PROJECT_ID=javiercm-oracle
export REGION=europe-west1
export ZONE_1=${REGION}-b
export ZONE_2=${REGION}-c
export CLUSTER_NAME=oracle
export REPO_NAME=oracle-databases
export K8S_DIR=k8s
export KUSTOMIZE_DIR=kustomize
export SIDB_NAME=sidb-sample
export DB_IMAGE_NAME=oracle-database
export JDK_IMAGE_NAME=jdk
export ORDS_IMAGE_NAME=ords
export ORDS_VERSION="23.3.0-10"
export DB_VERSION="23.5.0"
export JDK_VERSION="23"
export CDB_NAMESPACE="oracle-cdbs"
export PDB_NAMESPACE="oracle-pdbs"
export OPERATOR_NAMESPACE="oracle-database-operator-system"
export CDB_SECRET="cdb-secret"
export PDB_SECRET="pdb-secret"
export CDB_ADMIN_USER="C##DBAPI_CDB_ADMIN"
export PDB_SYSADMIN_USER="pdbadmin"
export WEBSERVER_USER="sql_admin"