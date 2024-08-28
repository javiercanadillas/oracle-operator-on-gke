#!/usr/bin/env bash
# Description:    
#                 
# Prerequisites:  
# (C) Javier Cañadillas - August 2024.

## Prevent this script from being sourced
#shellcheck disable=SC2317
return 0  2>/dev/null || :

# Script-wide variables
source env.bash
ARCH=$(uname -m)
if [ "$ARCH" = "x86_64" ]; then
  ARCH="amd64"
fi
OS=$(uname -s | tr '[:upper:]' '[:lower:]')

_check_install_tap() {
  local tap_name="$1" && shift
  if brew tap | grep -i "$tap_name" 1>/dev/null; then
    echo "Tap $tap_name is already installed."
  else
    brew tap "$tap_name"
  fi  
}

_check_install_brew() {
  brew_formula="$1" && shift
  if brew list | grep -i "$brew_formula" 1>/dev/null; then
    echo "Formula $brew_formula is already installed."
  else
    brew install "$brew_formula"
  fi
}

_check_prereqs() {
  [[ $DB_PASSWORD ]] || {
    echo "DB_PASSWORD is not set. You need to set it with export DB_PASSWORD=<password> before running this script"
    exit 1
  }
  [[ "$OS" != "darwin" && "$OS" != "linux" ]] && {
    echo "This system has been identified as $OS"
    echo "This script is intended to be run on Mac OS X or Linux. Exiting."
    exit 1
  }
  [[ ${BASH_VERSION%%.*} -lt 4 ]] && {
    echo "This script requires bash version 4 or higher. Exiting."
    exit 1
  }
  [[ "$OS" == "darwin" ]] && {
    ! command -v brew &> /dev/null && {
      echo "brew could not be found. Exiting."
      exit 1
    }
  }
  ! command -v gcloud &> /dev/null && {
    echo "gcloud could not be found. Exiting."
    exit 1
  }
  ! command -v kubectl &> /dev/null && {
    echo "kubectl could not be found. Exiting."
    exit 1
  }
}

_get_db_creds() {
  local display=$1 && shift
  CDB_CONN_STRING="$(kubectl get singleinstancedatabase sidb-sample -o "jsonpath={.status.connectString}")"
  PDB_CONN_STRING="$(kubectl get singleinstancedatabase sidb-sample -o "jsonpath={.status.pdbConnectString}")"
  if [[ "$display" == "display" ]]; then
    echo "CDB connection string: $CDB_CONN_STRING"
    echo "PDB connection string: $PDB_CONN_STRING"
  fi
}

_set_environment() {
  PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')
  export PROJECT_NUMBER
  export SA_NAME="$PROJECT_NUMBER-compute"  
}

set_gcp_environment() {
  echo "Setting GCP environment..."
  gcloud config set compute/region "$REGION" --quiet 2>/dev/null
  gcloud config set compute/zone "$ZONE_1" --quiet 2>/dev/null
}

enable_apis() {
  echo "Enabling APIS..."
  gcloud services enable \
    compute.googleapis.com \
    container.googleapis.com \
    containerregistry.googleapis.com \
    cloudbuild.googleapis.com
}

create_cluster() {
  echo "Creating GKE cluster $CLUSTER_NAME..."
  gcloud container clusters create "$CLUSTER_NAME"   \
    --location "$REGION" \
    --workload-pool="${PROJECT_ID}.svc.id.goog" \
    --enable-image-streaming \
    --enable-ip-alias \
    --node-locations "$ZONE_1" \
    --addons GcsFuseCsiDriver \
    --machine-type n2d-standard-8 \
    --num-nodes 1 --min-nodes=1 --max-nodes=3 \
    --ephemeral-storage-local-ssd count=2 \
    --subnetwork default \
    --quiet
} 

get_gke_credentials() {
  echo "Getting credentials for cluster $CLUSTER_NAME..."
  gcloud container clusters get-credentials "$CLUSTER_NAME" --region "$REGION"
}

install_cert_manager() {
  # @TODO Explore using Google-managed certificates: https://cloud.google.com/kubernetes-engine/docs/how-to/managed-certs
  local cmversion="v1.5.3"
  # https://cert-manager.io/docs/installation/kubectl/
  echo "Installing cert-manager..."
  # https://cert-manager.io/docs/reference/cmctl/#installation
  kubectl apply -f "https://github.com/cert-manager/cert-manager/releases/download/${cmversion}/cert-manager.yaml" || {
    echo "Could not install cmctl. Exiting."
    exit 1
  }
}

install_cmctl() {
  echo "Installing cmctl..."
  case $OSTYPE in
    darwin*)
      _check_install_brew cmctl
      ;;
    linux*)
      curl -fsSL -o cmctl "https://github.com/cert-manager/cmctl/releases/latest/download/cmctl_${OS}_${ARCH}"
      chmod +x cmctl
      sudo mv cmctl /usr/local/bin
      ;;
    *?)
      echo "Unsupported OS"
      exit 1
      ;;
  esac
}

check_cert_manager() {
  echo "Checking cert-manager..."
  kubectl get pods --namespace cert-manager
  echo "Checking webhook..."
  cmctl check api --wait=2m
}

deploy_operator () {
  # https://github.com/oracle/oracle-database-operator/blob/main/README.md#create-role-bindings-for-access-management
  echo "Granting serviceaccount:oracle-database-operator-system:default cluster wide permissions..."
  kubectl apply -f https://raw.githubusercontent.com/oracle/oracle-database-operator/main/rbac/cluster-role-binding.yaml
  echo "Deploying Oracle Database Operator..."
  kubectl apply -f https://raw.githubusercontent.com/oracle/oracle-database-operator/main/oracle-database-operator.yaml
  echo "Applying Node RBAC..."
  kubectl apply -f https://raw.githubusercontent.com/oracle/oracle-database-operator/main/rbac/node-rbac.yaml
}

check_operator() {
  echo "Checking Oracle Database Operator..."
  kubectl get pods --namespace oracle-database-operator-system
}

check_sidbs() {
  echo "Checking Oracle Database..."
  kubectl get singleinstancedatabases -o name
}

create_gar_repo() {
  echo "Creating GCR repository..."
  gcloud artifacts repositories create "$REPO_NAME" --repository-format=docker --location="$REGION" --description="Oracle Database images"
}

get_oracle_docker_images() {
  echo "Downloading Oracle Database images..."
  [[ ! -d "docker-images" ]] && git clone "https://github.com/oracle/docker-images.git"
  echo "Preparing the selected image..."
  mkdir -p "images"
  cp -r "docker-images/OracleDatabase/SingleInstance/dockerfiles/$DB_VERSION" "images"
  mv "images/$DB_VERSION/Containerfile.free" "images/$DB_VERSION/Dockerfile"
}

build_image() {
  PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')
  SA_NAME="$PROJECT_NUMBER-compute"

  echo "Setting up permissions..."
  declare -a roles=(
    "logging.logWriter"
    "viewer"
    "storage.objectViewer"
    "artifactregistry.writer"
  )

  for role in "${roles[@]}"; do
   gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member serviceAccount:"${SA_NAME}@developer.gserviceaccount.com" \
    --role "roles/$role"
  done

  echo "Building image..."
  pushd "images/$DB_VERSION" > /dev/null 2>&1 || exit
  gcloud builds submit \
    --tag "$REGION-docker.pkg.dev/$PROJECT_ID/$REPO_NAME/$IMAGE_NAME:$DB_VERSION" \
    --region "$REGION"
    .
  popd > /dev/null 2>&1 || exit
}

create_sidb() {
  echo "Creating Oracle Database..."
  envsubst < k8s/singleinstancedatabase.yaml.dist > "k8s/singleinstancedatabase.yaml"
  kubectl apply -f "k8s/singleinstancedatabase.yaml"
}

check_sidb() {
  echo "Checking Oracle Database..."
  local status
  while [[ "$status" != "Healthy" ]]; do
    status="$(kubectl get singleinstancedatabase sidb-sample -o "jsonpath={.status.status}")"
    echo "Status: $status"
    sleep 2
  done
}

_wait_for_sidb() {
  echo "Waiting for Oracle Database..."
  kubectl wait --for=jsonpath='{.status.status}'=Healthy singleinstancedatabase/sidb-sample
}

install_sqlplus() {
  echo "Installing sqlplus-compatible client..."
  case $OSTYPE in
    darwin*)
      _check_install_tap "InstantClientTap/instantclient"
      _check_install_brew instantclient-basic
      _check_install_brew instantclient-sqlplus
      _check_install_brew gqlplus
      ;;
    linux*)
      push "$(mktemp -d)" > /dev/null 2>&1 || exit
      curl -fsSL "https://github.com/xo/usql/releases/download/v0.19.3/usql-0.19.3-linux-amd64.tar.bz2"
      tar -xvf "usql-0.19.3-linux-amd64.tar.bz2"
      sudo install usql /usr/local/bin
      popd > /dev/null 2>&1 || exit
      ;;
    *?)
      echo "Unsupported OS"
      exit 1
      ;;
  esac
}

show_db_creds() {
  _get_db_creds display
}

check_connection() {
  _wait_for_sidb
  echo "Getting connection string to the CDB..."
  _get_db_creds hide
  echo "Connecting to the CDB... (press Ctrl-C to exit)"
  case $OSTYPE in
    darwin*)
      gqlplus "sys/$DB_PASSWORD@$CDB_CONN_STRING" as sysdba
      ;;
    linux*)
      usql "oracle://sys:$DB_PASSWORD@$CDB_CONN_STRING"
      ;;
    *?)
      echo "Unsupported OS"
      exit 1
      ;;
  esac
  echo "Conecting to the PDB... (press Ctrl-C to exit)"
  case $OSTYPE in
    darwin*)
      gqlplus "sys/$DB_PASSWORD@$PDB_CONN_STRING" as sysdba
      ;;
    linux*)
      usql "oracle://sys:$DB_PASSWORD@$PDB_CONN_STRING"
      ;;
    *?)
      echo "Unsupported OS"
      exit 1
      ;;
  esac
}

all() {
  set_gcp_environment
  enable_apis
  create_cluster
  get_gke_credentials
  install_cert_manager
  install_cmctl
  check_cert_manager
  deploy_operator
  check_operator
  get_oracle_docker_images
  create_gar_repo
  build_image
  create_sidb
  check_sidb
  install_sqlplus
  check_connection
}

main() {
  if declare -f "$1" > /dev/null; then
    _set_environment
    _check_prereqs
    "$1"
  else
    echo "Function $1 not found"
    exit 1
  fi
}

main "$@"