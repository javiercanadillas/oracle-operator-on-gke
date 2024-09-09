#!/usr/bin/env bash
# Description:    
#                 
# Prerequisites:  
# (C) Javier Cañadillas - August 2024.

## Prevent this script from being sourced
#shellcheck disable=SC2317
return 0  2>/dev/null || :

# Script-wide variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

_check_oracle_reg_creds() {
  [[ $DOCKER_PASSWORD ]] || {
    echo "DOCKER_PASSWORD is not set. You need to set it with export DOCKER_PASSWORD=<password> before running this script"
    echo "You need to create an Oracle account before downloading any image from them."
    echo "Once the account is created, you need to set the username with export DOCKER_USER."
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
  echo "This process may take a while..."
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
}

set_building_permissions() {
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
}

build_sidb_image() {
  echo "Preparing the selected image..."
  mkdir -p "$SCRIPT_DIR/images"
  cp -r "$SCRIPT_DIR/docker-images/OracleDatabase/SingleInstance/dockerfiles/$DB_VERSION" "$SCRIPT_DIR/images"
  pushd "images/$DB_VERSION" > /dev/null 2>&1 || exit
  mv "Containerfile.free" "Dockerfile"
  echo "Building Single Instance Database image..."
  echo "This process may take a while..."
  local remote_tag="$REGION-docker.pkg.dev/$PROJECT_ID/$REPO_NAME/$DB_IMAGE_NAME:$DB_VERSION"
  gcloud builds submit --tag "$remote_tag" --region "$REGION" .
  popd > /dev/null 2>&1 || exit
}

create_sidb() {
  echo "Creating Oracle Database..."
  db_pass_encoded=$(echo -n "$DB_PASSWORD" | base64)
  export db_pass_encoded
  envsubst < k8s/singleinstancedatabase.yaml.dist > "k8s/singleinstancedatabase.yaml"
  kubectl apply -f "k8s/singleinstancedatabase.yaml"
}

check_sidb() {
  echo "Checking Oracle Database..."
  echo "This process may take a while..."
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
      echo "Unsupported OS. Exiting."
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
      sqlplus "sys/$DB_PASSWORD@$CDB_CONN_STRING" as sysdba<<EOF
quit
EOF
      ;;
    linux*)
      usql "oracle://sys:$DB_PASSWORD@$CDB_CONN_STRING" <<EOF
quit
EOF
      ;;
    *?)
      echo "Unsupported OS. Exiting."
      exit 1
      ;;
  esac
  echo "Conecting to the PDB... (press Ctrl-C to exit)"
  case $OSTYPE in
    darwin*)
      sqlplus "sys/$DB_PASSWORD@$PDB_CONN_STRING" AS SYSDBA <<EOF
quit
EOF
      ;;
    linux*)
      usql "oracle://sys:$DB_PASSWORD@$PDB_CONN_STRING" <<EOF
quit
EOF
      ;;
    *?)
      echo "Unsupported OS. Exiting."
      exit 1
      ;;
  esac
}

download_ords_images() {
  echo "Downloading ORDS images..."
  pushd "$SCRIPT_DIR" > /dev/null 2>&1 || exit
  [[ -d "oracle-database-operator" ]] && rm -rf "oracle-database-operator"
  git clone "https://github.com/oracle/oracle-database-operator"
  cp -rf "oracle-database-operator/ords" "images"
  popd > /dev/null 2>&1 || exit
}

build_jdk_image() {
  echo "Preparing the $JDK_IMAGE_NAME image for building..."
  mkdir -p "$SCRIPT_DIR/images"
  cp -r "$SCRIPT_DIR/docker-images/OracleJava/$JDK_VERSION" "$SCRIPT_DIR/images"
  pushd "images/$JDK_VERSION" > /dev/null 2>&1 || exit
  echo "Building Oracle JDK $JDK_VERSION image..."
  echo "This process may take a while..."
  local remote_tag="$REGION-docker.pkg.dev/$PROJECT_ID/$REPO_NAME/$JDK_IMAGE_NAME:$JDK_VERSION"
  gcloud builds submit --tag "$remote_tag" --region "$REGION" .
  popd > /dev/null 2>&1 || exit
}

build_ords_image() {
  echo "Preparing ORDS image for building..."
  pushd "images/ords" > /dev/null 2>&1 || exit
  local ar_java_url="$REGION-docker.pkg.dev/$PROJECT_ID/$REPO_NAME/$JDK_IMAGE_NAME:$JDK_VERSION"
  local sed_expression="s|container-registry.oracle.com/java/jdk:latest|$ar_java_url|g"
  if [[ "$OS" == "darwin" ]]; then
    sed -i '' "$sed_expression" Dockerfile
  else
    sed -i "$sed_expression" Dockerfile
  fi
  echo "Building ORDS image..."
  echo "This process may take a while..."
  local ar_ords_url="$REGION-docker.pkg.dev/$PROJECT_ID/$REPO_NAME/$ORDS_IMAGE_NAME:latest"
  gcloud builds submit -t "$ar_ords_url" --region "$REGION" .
  popd > /dev/null 2>&1 || exit
}

prepare_cdb_database() {
  echo "Preparing CDB database..."
  _get_db_creds hide
  if [[ $DB_PASSWORD ]]; then
    envsubst < "$SCRIPT_DIR/sql/configure_cdb.sql.dist" > "$SCRIPT_DIR/sql/configure_cdb.sql"
    echo "Modyfing the CDB configuration..."
    echo "All passwords will be set to $DB_PASSWORD"
    case $OSTYPE in
      darwin*)
        sqlplus "sys/$DB_PASSWORD@$CDB_CONN_STRING" as sysdba < "$SCRIPT_DIR/sql/configure_cdb.sql"
        ;;
      linux*)
        usql "oracle://sys:$DB_PASSWORD@$CDB_CONN_STRING" < "$SCRIPT_DIR/sql/configure_cdb.sql"
        ;;
      *?)
        echo "Unsupported OS"
        exit 1
        ;;
    esac
  else
    echo "DB_PASSWORD is not set. You need to set it with export DB_PASSWORD=<password> before running this script"
    exit 1
  fi
}

create_cdb_secrets() {
  echo "Encoding secrets for CDB..."
  db_pass_encoded=$(echo -n "$DB_PASSWORD" | base64)
  export db_pass_encoded
  cdbadmin_user_encoded=$(echo -n C##DBAPI_CDB_ADMIN | base64)
  export cdbadmin_user_encoded
  webserver_user_encoded=$(echo -n sql_admin | base64)
  export webserver_user_encoded
  envsubst < "$SCRIPT_DIR/k8s/secrets.yaml.dist" > "$SCRIPT_DIR/k8s/secrets.yaml"
  echo "Creating secrets for CDB..."
  kubectl apply -f "$SCRIPT_DIR/k8s/secrets.yaml"
}

create_certificates() {
  echo "Creating certificates..."
  command -v openssl &> /dev/null || {
    echo "openssl could not be found. Exiting."
    exit 1
  }
  mkdir -p "$SCRIPT_DIR/certs"
  pushd "$SCRIPT_DIR/certs" > /dev/null 2>&1 || exit
  openssl genrsa -out "ca.key" 2048
  openssl req -new -x509 -days 365 -key "ca.key" \
    -subj "/C=US/ST=California/L=SanFrancisco/O=oracle /CN=cdb-dev-ords /CN=localhost  Root CA " \
    -out "ca.crt"
  openssl req -newkey rsa:2048 -nodes -keyout "tls.key" \
    -subj "/C=US/ST=California/L=SanFrancisco/O=oracle /CN=cdb-dev-ords /CN=localhost" \
    -out "server.csr"
  echo "subjectAltName=DNS:cdb-dev-ords,DNS:www.example.com" > "extfile.txt"
  openssl x509 -req -extfile "extfile.txt" \
    -days 365 \
    -in server.csr \
    -CA ca.crt \
    -CAkey ca.key \
    -CAcreateserial \
    -out tls.crt
  popd > /dev/null 2>&1 || exit
}

create_cert_secrets() {
  echo "Creating secrets for certificates..."
  pushd "$SCRIPT_DIR/certs" > /dev/null 2>&1 || exit
  kubectl create secret tls db-tls \
    --key=tls.key \
    --cert=tls.crt  \
    -n oracle-database-operator-system
  kubectl create secret generic db-ca \
    --from-file=ca.crt \
    -n oracle-database-operator-system
  popd > /dev/null 2>&1 || exit
}

prepare_cdb_yaml() {
  echo "Preparing CDB YAML..."
  CDB_CONN_STRING="$(kubectl get singleinstancedatabase sidb-sample -o "jsonpath={.status.connectString}")"
  CDB_IP_ADDRESS=$(echo "$CDB_CONN_STRING" | cut -d':' -f1) && export CDB_IP_ADDRESS
  CDB_PORT=$(echo "$CDB_CONN_STRING" | cut -d':' -f2 | cut -d'/' -f1) && export CDB_PORT
  CDB_NAME=$(echo "$CDB_CONN_STRING" | cut -d':' -f2 | cut -d'/' -f2) && export CDB_NAME
  envsubst < "$SCRIPT_DIR/k8s/cdb.yaml.dist" > "$SCRIPT_DIR/k8s/cdb.yaml"
}

apply_cdb_yaml() {
  echo "Applying CDB YAML..."
  kubectl apply -f "$SCRIPT_DIR/k8s/cdb.yaml"
}

cleanup_gke() {
  echo "Cleaning up GKE resources..."
  gcloud container clusters delete "$CLUSTER_NAME" --region "$REGION" --quiet
}

cleanup_ar() {
  echo "Cleaning up Artifact Registry resources..."
  gcloud artifacts repositories delete "$REPO_NAME" --location "$REGION" --quiet
}

cleanup_local_data() {
  echo "Cleaning up local data..."
  rm -rf "$SCRIPT_DIR/images"
  rm -rf "$SCRIPT_DIR/docker-images"
  rm -rf "$SCRIPT_DIR/oracle-database-operator"
  rm -rf "$SCRIPT_DIR"/k8s/*.yaml
  rm -rf "$SCRIPT_DIR"/*.sql
  rm -rf "$SCRIPT_DIR"/certs
}

full_cleanup() {
  cleanup_gke
  cleanup_ar
  cleanup_local_data
}

step_create_infra() {
  set_gcp_environment
  enable_apis
  create_cluster
  get_gke_credentials
  install_cert_manager
  install_cmctl
  check_cert_manager
  deploy_operator
  check_operator
  create_gar_repo
  get_oracle_docker_images
  set_building_permissions
}

step_install_sidb() {
  build_sidb_image
  create_sidb
  check_sidb
  install_sqlplus
  check_connection
}

step_install_ords() {
  download_ords_images
  build_jdk_image
  build_ords_image
  prepare_cdb_database
  create_cdb_secrets
}

all() {
  step_create_infra
  step_install_sidb
  step_install_ords
}

main() {
  if declare -f "$1" > /dev/null; then
    _set_environment
    _check_prereqs
    "$1"
  else
    echo "Function \"$1\" not found. You need to provide a valid function name present in the script."
    exit 1
  fi
}

main "$@"