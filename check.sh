#!/bin/bash
set -eo pipefail

function delimiter() {
  color cyan "-------------------------------------------------------------"
}
function color(){

  NC='\033[0m'

  case $1 in
    cyan)
      COLOR='\033[0;36m'
    ;;
    green)
      COLOR='\033[0;32m'
    ;;
    red)
      COLOR='\033[0;31m'
    ;;
    yellow)
      COLOR='\033[1;33m'
    ;;
    orange)
      COLOR='\033[0;33m'
    ;;
    *)
      COLOR=$NC
    ;;
  esac

  echo -e "${COLOR}${2}${NC}"
}

# Fixed Versions 2.7.30, 2.8.16, 2.9.18, and 2.10.9
MIN_MAJOR=2
declare -A MIN_PATCH=( ['2.7']=30 ['2.8']=16 ['2.9']=18 ['2.10']=9 )
DATA_JSON=$(om  products -f json)
OM_VERSION=$( jq -r ".[] | select(.name == \"p-bosh\")| .staged" <<< $DATA_JSON | cut -f1 -d- )
OM_MAJOR=$( cut -f1 -d. <<< ${OM_VERSION} )
OM_MINOR=$( cut -f2 -d. <<< ${OM_VERSION} )
OM_PATCH=$( cut -f3 -d. <<< ${OM_VERSION} )

if [[ ${OM_PATCH} -lt ${MIN_PATCH[${OM_MAJOR}.${OM_MINOR}]} ]]; then
  echo -e "SAN Cert not supported in staged OpsMan Version: $(color red ${OM_VERSION})"
  echo -e "YOU STILL NEED TO UPDATE TO AT LEAST OPSMAN: $(color red ${OM_MAJOR}.${OM_MINOR}.${MIN_PATCH[${OM_MAJOR}.${OM_MINOR}]})"

  exit 1
fi

color green "SAN Cert supported in staged OpsMan Version: ${OM_VERSION}\nChecking deployed products"




# Get Opsman Data
PENDING_CHANGES_JSON="$(om pending-changes -f json --check )" || WARNING=true &> /dev/null
AVAILABLE_PRODUCTS="$(om products --available -f json | jq .[].name -r)"
DEPLOYED_PRODUCTS="$(om curl -s -p /api/v0/deployed/products)"


CERTS=$(om curl -s -p /api/v0/deployed/certificates | jq '.certificates' -r )


# Print warning about available but undeployed/unstaged products. We cannot check an undeployed/unstaged product for the presence of /opsmgr/bosh_dns/san_migrated

delimiter
color orange "There are poducts uploaded but not deployed. These cannot be checked until a deployment is done."
filter=$( jq '.[].type'  -r <<< ${DEPLOYED_PRODUCTS} | sed ':a;N;$!ba;s/\n/\\\|/g')


if [[ $WARNING == true ]]; then
  PENDING_PRODUCTS=$(echo "$AVAILABLE_PRODUCTS" | grep -v "$filter")
  echo "You have Pending changes. Applying them could fix this warning"
  for P in ${PENDING_PRODUCTS}; do
    P_GUID=$(jq -r ".[] | select( .action != \"unchanged\" and ( .guid | startswith(\"${P}\") ) ) | .guid"  <<< $PENDING_CHANGES_JSON)
    LIST_WARNING="${LIST_WARNING}\n${P_GUID}"
    color red "Product ${P} has pending changes."
    color yellow "$(jq ".[] | select( .action != \"unchanged\" and ( .guid | startswith(\"${P}\") ) )"  <<< $PENDING_CHANGES_JSON)"
  done
fi

delimiter

# Check deployed/staged products

for P in `jq '.[].installation_name'  -r <<< ${DEPLOYED_PRODUCTS}`; do
  if [[ "${P}" == "p-bosh" ]]; then
    continue
  fi
  echo -e "Checking Product: $(color green "$P")"

  P_DATA_JSON=$( jq " .[] | select( .installation_name == \"${P}\")" -r <<< ${DEPLOYED_PRODUCTS} )


  CERT_DATA=$( jq ".[] | select( .variable_path == \"/opsmgr/bosh_dns/san_migrated\" and .product_guid == \"$P\" )" <<< ${CERTS} )

  #Check if cert is present more than once.
  CERT_COUNT=$(jq length -s <<< $CERT_DATA)

  SUCCESSFULLY_DEPLOYED_VERSION=$( jq -r ".[] | select( .guid == \"$P\") | .last_successful_deployed.version" <<< ${PENDING_CHANGES_JSON} )
  PRODUCT_VERSION=$( jq -r .product_version <<< ${P_DATA_JSON} )
  echo "Checking if deployed version matches last succesful apply ( \"${SUCCESSFULLY_DEPLOYED_VERSION}\" == \"${PRODUCT_VERSION}\" )"

  if [[ "${SUCCESSFULLY_DEPLOYED_VERSION}" == "${PRODUCT_VERSION}" && $CERT_COUNT -eq 1 ]]; then
    color=green
    LIST_SUCCESS="$LIST_SUCCESS\n${P}: passed checks"
  elif [[ $CERT_COUNT -gt 1 ]]; then
    color=red
    LIST_ERROR="${LIST_ERROR}\n${P}: found multiple versions ($CERT_COUNT) of cert indicates a failed/partial deploy"
  else
    color=red
    LIST_ERROR="${LIST_ERROR}\n${P}: deployed version ${SUCCESSFULLY_DEPLOYED_VERSION} doesn't match product version ${PRODUCT_VERSION}"
  fi

  echo -e "Product Data:\n$( color $color "${P_DATA_JSON}")"
  echo -e "Cert Data:\n$( color $color "${CERT_DATA}")"

done

delimiter
delimiter

# Login to director for service instances
source <(om bosh-env)

#Assuming only opsman native deployments on director. $filter contains product guids separated by '\|' (== OR) in grep. -v is inverse match. Leaving deployments that are not a product which should be only service instances.
#
for S in `bosh --json ds | jq '.Tables[].Rows[].name' -r | grep -v "$filter"`; do
  echo -e "Checking Service Deployment: $(color green "$S")"

  CERT_DATA=$( jq ".[] | select( .variable_path == \"/opsmgr/bosh_dns/san_migrated\" and .product_guid == \"$S\" )" <<< ${CERTS} )

  #Check if cert is present more than once.
  CERT_COUNT=$(jq length -s <<< $CERT_DATA)

  echo "Checking if last deploy was a success"

  S_DATA_JSON=$(bosh tasks --recent -d ${S} --json | jq '[.Tables[].Rows[] | select(.description == "create deployment" )][0]' -r)
  S_STATE=$(jq .state <<< "$S_DATA_JSON")

  if [[ "${S_STATE}" == "done" && $CERT_COUNT -eq 1 ]]; then
    color=green
    LIST_SUCCESS="$LIST_SUCCESS\n${S}: passed checks"
  else
    color=red
    LIST_ERROR="${LIST_ERROR}\n${S}: found deployment state == '$S_STATE' and cert count '$CERT_COUNT'"
  fi

  echo -e "Deployment Data:\n$( color $color "${S_DATA_JSON}")"
  echo -e "Cert Data:\n$( color $color "${CERT_DATA}")"

done

delimiter
delimiter


echo -e "SUMMARY

SUCCESS:`color green "$LIST_SUCCESS"`

WARNING:`color yellow "$LIST_WARNING"`

ERROR:`color red "$LIST_ERROR"`
"


  delimiter
if [[ ! $(wc -l <<< $LIST_ERROR) -eq 0 ]]; then
  color green "SUCCESS. SAN Cert migration successful"
else
  color red "ERROR. Check errors"
fi
  delimiter
