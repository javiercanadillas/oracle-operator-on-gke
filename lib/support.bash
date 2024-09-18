#!/usr/bin/false

# Certificates variables
# shellcheck disable=SC2034
tls_key=tls.key
tls_crt=tls.crt
ca_key=ca.key
ca_crt=ca.crt
server_csr=server.csr
company=google
rest_server=ords

# shellcheck disable=SC2034
_define_files() {
  local cmversion="v1.5.3"
  # Format must be ["identifier"]="local_file,remote_file", no spaces between commas
  declare -g -A yaml_files=(
    ["cm"]="$SCRIPT_DIR/$K8S_DIR/cert-manager.yaml,https://github.com/cert-manager/cert-manager/releases/download/${cmversion}/cert-manager.yaml"
    ["op_rb"]="$SCRIPT_DIR/$K8S_DIR/cluster-role-binding.yaml,https://raw.githubusercontent.com/oracle/oracle-database-operator/main/rbac/cluster-role-binding.yaml"
    ["op_yaml"]="$SCRIPT_DIR/$K8S_DIR/oracle-database-operator.yaml,https://raw.githubusercontent.com/oracle/oracle-database-operator/main/oracle-database-operator.yaml"
    ["op_nr"]="$SCRIPT_DIR/$K8S_DIR/node-rbac.yaml,https://raw.githubusercontent.com/oracle/oracle-database-operator/main/rbac/node-rbac.yaml"
  )
  declare -g -A dist_files=(
    ["sidb"]="$SCRIPT_DIR/$KUSTOMIZE_DIR/sidb.yaml.dist"
    ["namespaces"]="$SCRIPT_DIR/$KUSTOMIZE_DIR/namespaces.yaml.dist"
    ["cdb-secrets"]="$SCRIPT_DIR/$KUSTOMIZE_DIR/cdb-secrets.yaml.dist"
    ["cdb"]="$SCRIPT_DIR/$KUSTOMIZE_DIR/cdb.yaml.dist"
    ["pdb"]="$SCRIPT_DIR/$KUSTOMIZE_DIR/pdb.yaml.dist"
    ["pdb-secrets"]="$SCRIPT_DIR/$KUSTOMIZE_DIR/pdb-secrets.yaml.dist"
  )
  declare -g -A non_yaml_files=(
    ["cmctl"]="https://github.com/cert-manager/cmctl/releases/latest/download/cmctl_${OS}_${ARCH}"
    ["usql"]="https://github.com/xo/usql/releases/download/v0.19.3/usql-0.19.3-linux-amd64.tar.bz2"
  )
}

_get_remote_file() {
  local remote_files=("$@")
  local dest_file="${remote_files[0]}"
  local source_url="${remote_files[1]}"
  curl -fsSL -o "$dest_file" "$source_url"
}

_apply_yaml_file() {
  local dest_file=$1 && shift
  echo "Applying $1 file..."
  kubectl apply -f "$dest_file" || {
    echo "Error applying $dest_file. Exiting."
    exit 1
  }
}

_apply_dist_file() {
  local dist_file="${1}" && shift
  local yaml_file_source_path="${dist_file%.dist}"
  local yaml_file="${yaml_file_source_path##*/}"
  local yaml_file_final_path="${SCRIPT_DIR}/${K8S_DIR}/${yaml_file}"
  echo "Applying $yaml_file_final_path file..."
  envsubst < "${dist_file}" | tee "${yaml_file_final_path}" | kubectl apply -f - || {
    echo "Error applying $dest_file. Exiting."
    exit 1
  }
}

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

# shellcheck disable=SC2153
_get_db_creds() {
  local display=$1 && shift
  CDB_CONN_STRING="$(kubectl get singleinstancedatabase "$SIDB_NAME" -o "jsonpath={.status.connectString}")"
  PDB_CONN_STRING="$(kubectl get singleinstancedatabase "$SIDB_NAME" -o "jsonpath={.status.pdbConnectString}")"
  if [[ "$display" == "display" ]]; then
    echo "CDB connection string: $CDB_CONN_STRING"
    echo "PDB connection string: $PDB_CONN_STRING"
  fi
}

_wait_for_sidb() {
  echo "Waiting for Oracle Database..."
  kubectl wait --for=jsonpath='{.status.status}'=Healthy "singleinstancedatabase/${SIDB_NAME}"
}

_get_cdb_details() {
  CDB_CONN_STRING="$(kubectl get singleinstancedatabase sidb-sample -o "jsonpath={.status.connectString}")"
  CDB_IP_ADDRESS=$(echo "$CDB_CONN_STRING" | cut -d':' -f1) && export CDB_IP_ADDRESS
  CDB_PORT=$(echo "$CDB_CONN_STRING" | cut -d':' -f2 | cut -d'/' -f1) && export CDB_PORT
  CDB_NAME=$(echo "$CDB_CONN_STRING" | cut -d':' -f2 | cut -d'/' -f2) && export CDB_NAME
}

_encode_secrets() {
  db_pass_encoded=$(echo -n "$DB_PASSWORD" | base64) && export db_pass_encoded
  cdbadmin_user_encoded=$(echo -n "$CDB_ADMIN_USER" | base64) && export cdbadmin_user_encoded
  webserver_user_encoded=$(echo -n "$WEBSERVER_USER" | base64) && export webserver_user_encoded
  sysadmin_user_encoded=$(echo -n "$PDB_SYSADMIN_USER" | base64) && export sysadmin_user_encoded
  webserver_user_encoded=$(echo -n "$WEBSERVER_USER" | base64) && export webserver_user_encoded
}