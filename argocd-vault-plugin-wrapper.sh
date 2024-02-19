#!/bin/bash 
set -Eeuo pipefail
shopt -s inherit_errexit

exit_error() {
  >&2 echo $@ && exit 1
}

BASE_DIR="."
HELM_REPO_CREDS_DIR="${ENV_HELM_REPO_CREDS_DIR:-$BASE_DIR}"

APP_TYPE="${ARGOCD_ENV_APP_TYPE:-PLAIN_YAML}"
APP_NAME="${ARGOCD_APP_NAME:-}"
APP_NAMESPACE="${ARGOCD_APP_NAMESPACE:-}"
APP_PRODUCT_NAME="${ARGOCD_ENV_PRODUCT_NAME:-`basename $(dirname $ARGOCD_APP_SOURCE_REPO_URL)`}"
APP_HELM_VALUES_FILES="${ARGOCD_ENV_HELM_VALUES_FILES:-}"
APP_HELM_VALUES="${ARGOCD_ENV_HELM_VALUES:-}"
APP_HELM_CHART_URL="${ARGOCD_ENV_HELM_CHART_URL:-}"
APP_HELM_RELEASE_NAME="${ARGOCD_ENV_HELM_RELEASE_NAME:-$APP_NAME}"

GENERATE_FUNCTION_NAME=generate_plain_yaml

if find $BASE_DIR -maxdepth 1 -name 'Chart.yaml' | grep -q .
then 
  GENERATE_FUNCTION_NAME=generate_helm
elif [ ! -z "$APP_HELM_CHART_URL" ]
then
  GENERATE_FUNCTION_NAME=generate_helm
elif find $BASE_DIR -maxdepth 1 -name kustomization.yaml -o -name kustomization.yml -o -name Kustomization | grep -q .
then
  GENERATE_FUNCTION_NAME=generate_kustomize
fi

join_by_char() {
  local IFS="$1"
  shift
  echo "$*"
}

base64_encodings() {
  # Inspired by https://www.leeholmes.com/searching-for-content-in-base-64-strings/
  buffer=$1
  var1=`echo -n $buffer | base64 | sed 's/.==\?$//'`
  var2=`echo -n " $buffer" | base64 | sed 's/.==\?$//'`
  var3=`echo -n "  $buffer" | base64 | sed 's/.==\?$//'`
  echo $var1 ${var2:2} ${var3:4}
}

filter_base64_by_pattern(){
  pattern=$1
  encodings=`base64_encodings $pattern`
  regex=`join_by_char '|' $encodings`
  cat | awk -v search=$regex -F: -e '$2 ~ search {print $2}'
}

base64_decode(){
  ENCODED=$1
  >&2 echo Trying to decode as base64 $ENCODED
  IS_BASE64=false
  DECODED=`echo $ENCODED | base64 -d -w 0 2>/dev/null` && IS_BASE64=true || true
  [ "$IS_BASE64" = true ] && echo $DECODED || true
}

decode_all_base64(){
  while read line
  do
    base64_decode "$line"
  done
}

check_vault_paths(){
  cat | grep "<path:..*/data/argocd/..*>\\|avp\\.kubernetes\\.io/path:" \
    | grep -v "<path:${APP_PRODUCT_NAME}/data/\\|avp\\.kubernetes\\.io/path: \"${APP_PRODUCT_NAME}/data/" \
    && exit_error "Wrong VAULT secret path!!! Did you mean ${APP_PRODUCT_NAME}?" || true
}

is_helm_repo_creds_allowed(){
  echo $APP_HELM_CHART_URL | awk -F/ '{print $5}' | grep -q ^${APP_PRODUCT_NAME}__helm$
}

set_helm_repo_creds(){
  REPO_CREDS_SUBDIR=$HELM_REPO_CREDS_DIR/$(basename `echo $APP_HELM_CHART_URL | awk -F/ '{print $3}'`)
  if [ -d $REPO_CREDS_SUBDIR ]
  then
    REPO_PASS=`cat $REPO_CREDS_SUBDIR/password`
    REPO_USER=`cat $REPO_CREDS_SUBDIR/username`
    [ ! -z $REPO_PASS ] && [ ! -z $REPO_USER ] && echo "--password $REPO_PASS --username $REPO_USER" || true
  fi
}

generate_helm() {
  CHART_NAME=""
  APP_HELM_FILES=()
  HELM_REPO_CREDS=""

  if [ ! -z "$APP_HELM_CHART_URL" ]; then
    [ -f $BASE_DIR/Chart.yaml ] && exit_error "ERROR: 'Chart.yaml' file found in local repo and HELM_CHART_URL variable is defined"
    [ -d $BASE_DIR/templates ] && exit_error "ERROR: 'templates' directory found in local repo and HELM_CHART_URL variable is defined"

    is_helm_repo_creds_allowed && HELM_REPO_CREDS=$(set_helm_repo_creds)
    TMP_DIR=`mktemp -d -p $BASE_DIR`
    helm pull $HELM_REPO_CREDS $APP_HELM_CHART_URL --untar -d $TMP_DIR && rmdir ${TMP_DIR}/`basename $APP_HELM_CHART_URL`

    CHART_NAME=$(basename `ls -d ${TMP_DIR}/*`)
    mv $TMP_DIR/$CHART_NAME $BASE_DIR && rmdir $TMP_DIR
  fi

  if [ ! -z "$APP_HELM_VALUES_FILES" ]; then
    IFS=';' read -ra FILES <<< "$APP_HELM_VALUES_FILES"
    for i in "${FILES[@]}"; do
      APP_HELM_FILES+=(" -f $i")
    done
  fi
  helm dependency build $BASE_DIR/$CHART_NAME 1>&2
  helm template $APP_HELM_RELEASE_NAME -n $APP_NAMESPACE ${APP_HELM_FILES[@]} -f <(echo "$APP_HELM_VALUES") $BASE_DIR/$CHART_NAME
}

generate_kustomize() {
  kustomize build $BASE_DIR
}

generate_plain_yaml() {
  cat $BASE_DIR/*.yaml
}

MANIFESTS=$($GENERATE_FUNCTION_NAME)
echo "$MANIFESTS" | check_vault_paths
echo "$MANIFESTS" | filter_base64_by_pattern "/data/argocd/" | decode_all_base64 | check_vault_paths 
echo "$MANIFESTS" | argocd-vault-plugin generate -s avp-secret -
