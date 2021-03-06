#!/usr/bin/env bash
source ~/.env.sh
MYSELF=$(basename $0)
echo "this is the updater"
mkdir -p ${LOG_DIR}
UPDATE_DIR=${HOME_DIR}/conductor/updates
mkdir -p ${UPDATE_DIR}
BASE_URI="https://raw.githubusercontent.com/bottkars/pcf-jump-azure/master/"


if ! which parallel > /dev/null; then
   sudo apt install parallel -y
fi   

wget -O om https://github.com/pivotal-cf/om/releases/download/1.1.0/om-linux && \
    chmod +x om && \
    sudo mv om /usr/local/bin/

echo "Preparing Updates"
declare -a DIRECTORIES=("scripts" "env" "templates")
 
# Read the array values with space
for DIRECTORY in "${DIRECTORIES[@]}"; do
    UPDATE_LIST=${BASE_URI}${DIRECTORY}/updates.txt
    echo "updating ${DIRECTORY}"
    wget -N -P ${UPDATE_DIR} ${UPDATE_LIST} --show-progress
    parallel -a ${UPDATE_DIR}/updates.txt --no-notice "wget -N -P ${HOME_DIR}/conductor/${DIRECTORY} {} -q --show-progress"
    echo "\n"
done

rm -rf ${UPDATE_DIR}/updates.txt
chmod +x ${HOME_DIR}/conductor/scripts/*
echo "done"



# wget -O - https://raw.githubusercontent.com/bottkars/pcf-jump-azure/master/scripts/update.sh | bash

