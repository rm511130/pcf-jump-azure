#!/usr/bin/env bash
source ~/.env.sh
cd ${HOME_DIR}
MYSELF=$(basename $0)
mkdir -p ${HOME_DIR}/logs
exec &> >(tee -a "${HOME_DIR}/logs/${MYSELF}.$(date '+%Y-%m-%d-%H').log")
exec 2>&1
POSITIONAL=()
while [[ $# -gt 0 ]]
do
key="$1"
case $key in
    -n|--NO_DOWNLOAD)
    NO_DOWNLOAD=TRUE
    echo "No download is ${NO_DOWNLOAD}"
    # shift # past value if  arg value
    ;;
    -d|--DO_NOT_APPLY_CHANGES)
    NO_APPLY=TRUE
    echo "No APPLY is ${NO_APPLY}"
    # shift # past value ia arg value
    ;;
    -r|--DO_NOT_CREATE_REDIS_INSTANCE)
    NO_REDIS=TRUE
    echo "No APPLY is ${NO_APPLY}"
    # shift # past value ia arg value
    ;;          
    *)    # unknown option
    POSITIONAL+=("$1") # save it in an array for later
    shift # past argument
    ;;
esac
shift
done
set -- "${POSITIONAL[@]}" # restore positional parameters


export OM_TARGET=${PCF_OPSMAN_FQDN}
export OM_USERNAME=${PCF_OPSMAN_USERNAME}
export OM_PASSWORD="${PCF_PIVNET_UAA_TOKEN}"
START_OSBA_DEPLOY_TIME=$(date)
$(cat <<-EOF >> ${HOME_DIR}/.env.sh
START_OSBA_DEPLOY_TIME="${START_OSBA_DEPLOY_TIME}"
EOF
)

source  ~/osba.env

PIVNET_ACCESS_TOKEN=$(curl \
  --fail \
  --header "Content-Type: application/json" \
  --data "{\"refresh_token\": \"${PCF_PIVNET_UAA_TOKEN}\"}" \
  https://network.pivotal.io/api/v2/authentication/access_tokens |\
    jq -r '.access_token')

RELEASE_JSON=$(curl \
  --header "Authorization: Bearer ${PIVNET_ACCESS_TOKEN}" \
  --fail \
  "https://network.pivotal.io/api/v2/products/${PRODUCT_SLUG}/releases/${RELEASE_ID}")
# eula acceptance link
EULA_ACCEPTANCE_URL=$(echo ${RELEASE_JSON} |\
  jq -r '._links.eula_acceptance.href')

DOWNLOAD_DIR_FULL=${DOWNLOAD_DIR}/${PRODUCT_SLUG}/${PCF_OSBA_VERSION}
mkdir  -p ${DOWNLOAD_DIR_FULL}

curl \
  --fail \
  --header "Authorization: Bearer ${PIVNET_ACCESS_TOKEN}" \
  --request POST \
  ${EULA_ACCEPTANCE_URL}


# download product using om cli
if  [ -z ${NO_DOWNLOAD} ] ; then
echo "$(date) start downloading ${PRODUCT_SLUG}"

om --skip-ssl-validation \
  download-product \
 --pivnet-api-token ${PCF_PIVNET_UAA_TOKEN} \
 --pivnet-file-glob "*.pivotal" \
 --pivnet-product-slug ${PRODUCT_SLUG} \
 --product-version ${PCF_OSBA_VERSION} \
 --stemcell-iaas azure \
 --download-stemcell \
 --output-directory ${DOWNLOAD_DIR_FULL}
echo "$(date) end downloading ${PRODUCT_SLUG}"
else 
echo "ignoring download by user "
fi

TARGET_FILENAME=$(cat ${DOWNLOAD_DIR_FULL}/download-file.json | jq -r '.product_path')
STEMCELL_FILENAME=$(cat ${DOWNLOAD_DIR_FULL}/download-file.json | jq -r '.stemcell_path')

# Import the tile to Ops Manager.
echo "$(date) start uploading ${PRODUCT_SLUG}"
om --skip-ssl-validation \
  --request-timeout 3600 \
  upload-product \
  --product ${TARGET_FILENAME}

echo "$(date) end uploading ${PRODUCT_SLUG}"

    # 1. Find the version of the product that was imported.
PRODUCTS=$(om --skip-ssl-validation \
  available-products \
    --format json)

VERSION=$(echo ${PRODUCTS} |\
  jq --arg product_name ${PRODUCT_SLUG} -r 'map(select(.name==$product_name)) | first | .version')


# 2.  Stage using om cli
echo "$(date) start staging ${PRODUCT_SLUG}"
om --skip-ssl-validation \
  stage-product \
  --product-name ${PRODUCT_SLUG} \
  --product-version ${VERSION}
echo "$(date) end staging ${PRODUCT_SLUG}" 


echo "$(date) start creating ${ENV_SHORT_NAME}redis"

az login --service-principal \
  --username ${AZURE_CLIENT_ID} \
  --password ${AZURE_CLIENT_SECRET} \
  --tenant ${AZURE_TENANT_ID}

if  [ -z ${NO_REDIS} ] ; then
    MY_REDIS=$(az redis create \
    --name ${ENV_SHORT_NAME}redis \
    --resource-group ${ENV_NAME} \
    --location ${LOCATION} \
    --sku Basic \
    --vm-size C0)

    while [[ $(az redis show \
            --name ${ENV_SHORT_NAME}redis \
            --resource-group ${ENV_NAME} \
            --out tsv \
            --query provisioningState) != 'Succeeded' ]]; do
        echo "Redis still not finished provisioning. Trying again in 20 seconds."
        sleep 20
        if [[ $(az redis show \
            --name ${ENV_SHORT_NAME}redis \
            --resource-group ${ENV_NAME} \
            --out tsv \
            --query provisioningState) == 'failed' ]]; then
            echo "Redis Provisioning failed."
            exit 1
        fi
    done
    echo "redis provisioned."
    echo "$(date) end creating ${ENV_SHORT_NAME}redis"
else
MY_REDIS=$(az redis show \
        --name ${ENV_SHORT_NAME}redis \
        --resource-group ${ENV_NAME})
fi

REDIS_KEY=$(az redis list-keys \
--name ${ENV_SHORT_NAME}redis \
--resource-group ${ENV_NAME}  \
--query primaryKey --out tsv)

cat << EOF > ~/osba_vars.yaml
product_name: ${PRODUCT_SLUG}
pcf_pas_network: pcf-pas-subnet
pcf_service_network: pcf-services-subnet
azure_subscription_id: ${AZURE_SUBSCRIPTION_ID}
azure_tenant_id: ${AZURE_TENANT_ID}
azure_client_id: ${AZURE_CLIENT_SECRET}
azure_client_secret: ${AZURE_CLIENT_ID}
storage_redis_host: $(echo $MY_REDIS | jq -r ".hostName")
storage_redis_password: ${REDIS_KEY}
crypto_aes256_key: $(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 32 | head -n 1)
async_redis_host: $(echo $MY_REDIS | jq -r ".hostName")
async_redis_password: ${REDIS_KEY}

EOF

om --skip-ssl-validation \
  configure-product \
  -c ${HOME_DIR}/osba.yaml -l ${HOME_DIR}/osba_vars.yaml

om --skip-ssl-validation \
upload-stemcell \
--stemcell ${STEMCELL_FILENAME}

echo "$(date) start apply ${PRODUCT_SLUG}"

if  [ -z ${NO_APPLY} ] ; then
om --skip-ssl-validation \
  apply-changes \
  --product-name ${PRODUCT_SLUG}
else
echo "No Product Apply"
fi
echo "$(date) end apply ${PRODUCT_SLUG}"