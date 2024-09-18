#!/usr/bin/env bash
# Description:
#
# Prerequisites:
# Read https://github.com/javiercanadillas/oracle-operator-on-gke/blob/main/Readme.md#pre-requisites
# (C) Javier Cañadillas(javiercm@google.com) - September 2024.

## Prevent this script from being sourced
#shellcheck disable=SC2317
return 0  2>/dev/null || :

# Script-wide variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
source env.bash
source "$SCRIPT_DIR/lib/support.bash"

ARCH=$(uname -m)
if [ "$ARCH" = "x86_64" ]; then
  ARCH="amd64"
fi
OS=$(uname -s | tr '[:upper:]' '[:lower:]')

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

create_gar_repo() {
  echo "Creating GCR repository..."
  gcloud artifacts repositories create "$REPO_NAME" --repository-format=docker --location="$REGION" --description="Oracle Database images"
}

install_cert_manager() {
  # https://cert-manager.io/docs/installation/kubectl/
  echo "Installing cert-manager..."
  # https://cert-manager.io/docs/reference/cmctl/#installation
  local remote_files
  IFS="," read -r -a remote_files <<< "${yaml_files["cm"]}"
  local dest_file="${remote_files[0]}"
  _get_remote_file "${remote_files[@]}"
  _apply_yaml_file "$dest_file"
}

install_cmctl() {
  local tool="cmctl"
  echo "Installing $tool..."
  case $OSTYPE in
    darwin*)
      _check_install_brew "$tool"
      ;;
    linux*)
      pushd "$(mktemp -d)" > /dev/null 2>&1 || exit
      local remote_files
      remote_files=(
        "$tool"
        "${non_yaml_files["$tool"]}"
      )
      local dest_file="${remote_files[0]}"
      _get_remote_file "${remote_files[@]}"
      sudo install "$dest_file" /usr/local/bin
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
  echo "Deploying Oracle Database Operator..."
  local op_files=(
    "op_rb"
    "op_yaml"
    "op_nr"
  )
  for op_file in "${op_files[@]}"; do
    local remote_files
    IFS="," read -r -a remote_files <<< "${yaml_files["$op_file"]}"
    local dest_file="${remote_files[0]}"
    _get_remote_file "${remote_files[@]}"
    _apply_yaml_file "$dest_file"
  done
}

check_operator() {
  echo "Checking Oracle Database Operator..."
  kubectl get pods --namespace "$OPERATOR_NAMESPACE"
}

get_oracle_docker_images() {
  echo "Downloading Oracle Database images..."
  [[ ! -d "docker-images" ]] && git clone "https://github.com/oracle/docker-images.git"
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
  _encode_secrets
  local dist_file="${dist_files["sidb"]}"
  _apply_dist_file "$dist_file"
}

check_sidbs() {
  echo "Checking Oracle Database..."
  kubectl get singleinstancedatabases -o name
}

check_sidb() {
  echo "Checking Oracle Database..."
  echo "This process may take a while..."
  local status
  while [[ "$status" != "Healthy" ]]; do
    status="$(kubectl get singleinstancedatabase "$SIDB_NAME" -o "jsonpath={.status.status}")"
    echo "Status: $status"
    sleep 2
  done
}

install_sqlplus() {
  echo "Installing sqlplus-compatible client..."
  case $OSTYPE in
    darwin*)
      _check_install_tap "InstantClientTap/instantclient"
      _check_install_brew instantclient-basic
      _check_install_brew instantclient-sqlplus
      ;;
    linux*)
      local tool="usql"
      push "$(mktemp -d)" > /dev/null 2>&1 || exit
      local downloaded_file="${tool}.tar.bz2"
      local remote_files
      remote_files=(
        "$downloaded_file"
        "${non_yaml_files["$tool"]}"
      )
      local dest_file="${remote_files[0]}"
      _get_remote_file "${remote_files[@]}"
      tar -xvf "$downloaded_file"
      sudo install "$dest_file" /usr/local/bin
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
  local sed_expression_reg="s|container-registry.oracle.com/java/jdk:latest|$ar_java_url|g"
  local sed_expression_ords="s|ORDSVERSION=.*|ORDSVERSION=$ORDS_VERSION|g"
  echo "Patching the Dockerfile to use locally buit JDK image and ORDS version $ORDS_VERSION..."
  if [[ "$OS" == "darwin" ]]; then
    sed -i '' "$sed_expression_reg" Dockerfile
    sed -i '' "$sed_expression_ords" Dockerfile
  else
    sed -i "$sed_expression_reg" Dockerfile
    sed -i "$sed_expression_ords" Dockerfile
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

create_cdbs_pdbs_namespaces() {
  echo "Creating namespace for CDB..."
  local dist_file="${dist_files["namespaces"]}" 
  _apply_dist_file "$dist_file"
}

create_cdb_secrets() {
  echo "Encoding secrets for CDB..."
  encode_secrets
  local dist_file="${dist_files["cdb-secrets"]}"
  _apply_dist_file "$dist_file"
}

create_certificates() {
  echo "Creating certificates..."

  command -v openssl &> /dev/null || {
    echo "openssl could not be found. Exiting."
    exit 1
  }
  
  mkdir -p "$SCRIPT_DIR/certs"
  pushd "$SCRIPT_DIR/certs" > /dev/null 2>&1 || exit
  openssl genrsa -out "$ca_key" 2048
  openssl req -new -x509 -days 365 -key "$ca_key" \
    -subj "/C=US/ST=California/L=SanFrancisco/O=${company}/CN=${company} Root CA" \
    -out "$ca_crt"
  openssl req -newkey rsa:2048 -nodes -keyout "$tls_key" \
    -subj "/C=US/ST=California/L=SanFrancisco/O=${company}/CN=cdb-dev-${rest_server}" \
    -out "$server_csr"
  echo "subjectAltName=DNS:cdb-dev-${rest_server},DNS:cdb-dev-${rest_server}.${CDB_NAMESPACE},DNS:cdb-dev-${rest_server}.${CDB_NAMESPACE}.svc,DNS:cdb-dev-${rest_server}.${CDB_NAMESPACE}.svc.cluster,DNS:cdb-dev-${rest_server}.${CDB_NAMESPACE}.svc.cluster.local,DNS:localhost" > "extfile.txt"
  openssl x509 -req -extfile "extfile.txt" \
    -days 365 \
    -in "$server_csr" \
    -CA "$ca_crt" \
    -CAkey "$ca_key" \
    -CAcreateserial \
    -out "$tls_crt"
  popd > /dev/null 2>&1 || exit
}

create_cert_secrets() {
  echo "Creating secrets for certificates..."
  _setup_certs_vars
  [[ ! -d "$SCRIPT_DIR/certs" ]] && {
    echo "Certificates directory not found. Exiting."
    exit 1
  }
  pushd "$SCRIPT_DIR/certs" > /dev/null 2>&1 || exit
  [[ ! -f "$tls_key" || ! -f "$tls_crt" || ! -f "$ca_crt" ]] && {
    echo "Required certificates not found. Exiting."
    exit 1
  }
  secrets_namespaces=(
    "$CDB_NAMESPACE"
    "$PDB_NAMESPACE"
    "$OPERATOR_NAMESPACE")
  for namespace in "${secrets_namespaces[@]}"; do
    kubectl delete secret db-tls -n "$namespace" 2>/dev/null
    kubectl create secret tls db-tls \
      --key="$tls_key" \
      --cert="$tls_crt"  \
      -n "$namespace"
    kubectl delete secret db-ca -n "$namespace" 2>/dev/null
    kubectl create secret generic db-ca \
      --from-file="$ca_crt" \
      -n "$namespace"
  done
  popd > /dev/null 2>&1 || exit
}

create_cdb() {
  echo "Preparing CDB YAML..."
  _get_cdb_details
  local dist_file="${dist_files["cdb"]}" 
  _apply_dist_file "$dist_file"
}

check_cdb() {
  echo "Getting logs from the ORDS pod..."
  echo "Press Ctrl-C to exit"
  kubectl logs -f "$(kubectl get pods -n "$CDB_NAMESPACE" | grep ords | cut -d ' ' -f 1)" -n "$CDB_NAMESPACE"
}

create_pdb_secret() {
  echo "Preparing PDB secret YAML file..."
  _encode_secrets
  local dist_file="${dist_files["pdb-secrets"]}" 
  _apply_dist_file "$dist_file"
}

create_pdb() {
  echo "Preparing PDB YAML file..."
  _get_cdb_details
  local dist_file="${dist_files["pdb"]}" 
  _apply_dist_file "$dist_file"
}

check_pdb() {
  echo "Checking PDB..."
  kubectl get pdbs -n "$PDB_NAMESPACE" -o=jsonpath='{range .items[*]}
{"\n==================================================================\n"}
{"CDB="}{.metadata.labels.cdb}
{"K8SNAME="}{.metadata.name}
{"PDBNAME="}{.spec.pdbName}
{"OPENMODE="}{.status.openMode}
{"ACTION="}{.status.action}
{"MSG="}{.status.msg}
{"\n"}{end}'
}

check_pdb_databases() {
  echo "Checking PDB databases..."
  _get_db_creds hide
  echo "Connecting to the CDB... (press Ctrl-C to exit)"
  case $OSTYPE in
    darwin*)
      sqlplus "sys/$DB_PASSWORD@$CDB_CONN_STRING" as sysdba<<EOF
show pdbs
EOF
      ;;
    linux*)
      usql "oracle://sys:$DB_PASSWORD@$CDB_CONN_STRING" <<EOF
show pdbs
EOF
      ;;
    *?)
      echo "Unsupported OS. Exiting."
      exit 1
      ;;
  esac
}

render_dist_yamls() {
  echo "Rendering dist YAMLs..."
  _encode_secrets
  kubectl kustomize "$SCRIPT_DIR/$KUSTOMIZE_DIR" | envsubst | tee "$SCRIPT_DIR/$K8S_DIR"/all.yaml
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
  rm -rf "$SCRIPT_DIR/$K8S_DIR"/*.yaml
  rm -rf "$SCRIPT_DIR"/*.sql
  rm -rf "$SCRIPT_DIR"/certs
}

_call_functions() {
  local function_list=("$@")
  for function in "${function_list[@]}"; do
    echo "Calling function $function..."
    "$function"
  done
}

full_cleanup() {
  local function_list=(
    cleanup_gke
    cleanup_ar
    cleanup_local_data)
  _call_functions "${function_list[@]}"
}

step1_create_infra() {
  local function_list=(
    set_gcp_environment
    enable_apis
    set_building_permissions
    create_cluster
    get_gke_credentials
    create_gar_repo)
  _call_functions "${function_list[@]}"    
}

step2_install_oracle_operator() {
  local function_list=(
    install_cert_manager
    install_cmctl
    check_cert_manager
    deploy_operator)
  _call_functions "${function_list[@]}"
  echo "Now run $SCRIPT_NAME check_operator to check the operator status. Do not proceed with the next step
  until the all the pods show up in a \"Running\" state."
}

step3_install_sidb() {
  local function_list=(
    get_oracle_docker_images
    build_sidb_image
    create_sidb
    check_sidb
    install_sqlplus
    check_connection)
  _call_functions "${function_list[@]}"
}

step4_install_ords() {
  local function_list=(
    download_ords_images
    build_jdk_image
    build_ords_image
    prepare_cdb_database
    create_cdbs_pdbs_namespaces
    create_cdb_secrets
    create_certificates
    create_cert_secrets
    create_cdb)
  _call_functions "${function_list[@]}"
  echo "Now run $SCRIPT_NAME check_cdb to check connect to the ORDS container inside the ORDS pod for logs."
}

step5_install_pdb() {
  local function_list=(
    create_pdb_secret
    create_pdb)
  _call_functions "${function_list[@]}"
}

all_steps() {
  local function_list=(
    step1_create_infra
    step2_create_operator
    step3_install_sidb
    step4_install_ords)
  _call_functions "${function_list[@]}"
}

main() {
  if declare -f "$1" > /dev/null; then
    _set_environment
    _check_prereqs
    _define_files
    "$1"
  else
    echo "Function \"$1\" not found. You need to provide a valid function name present in the script."
    exit 1
  fi
}

main "$@"