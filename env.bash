#!/usr/bin/false
# This script is meant to be sourced.

# Script-wide variables
export PROJECT_ID=javiercm-oracle
export REGION=europe-west1
export ZONE_1=${REGION}-b
export ZONE_2=${REGION}-c
export CLUSTER_NAME=oracle
export REPO_NAME=oracle-databases
export DB_IMAGE_NAME=oracle-database
export JDK_IMAGE_NAME=jdk
export ORDS_IMAGE_NAME=ords
export DB_VERSION="23.5.0"
export JDK_VERSION="22"
export CDB_SECRET="cdb-secret"
export DOCKER_USER=javiercm@google.com