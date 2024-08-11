#! /bin/bash
# VERSION=25
#
# Change log:
#
# - Changed sync script to properly utilise curl options and not provide everything on the URI path
# - Various layout changes and coloring
#
# Script to sync data from an Ez Share WiFi SD card to a folder on your mac

##################
# GLOBAL VARIABLES
##################
me="$(echo "${0}" | sed -e 's|^./||')" # The script name but without the ./ if it has one. Otherwise use ${0}
sdCardDir="/Users/$(whoami)/Desktop/SD_Card" # The location where SD card files will be synchronised
uploadZipFileName="upload.zip" # The name of the zip file which will be uploaded to Sleep HQ
uploadZipFile="${sdCardDir}/${uploadZipFileName}" # The absolute path to the Zip file containing files needing to be uploaded
lastRunFile="${sdCardDir}/.sync_last_run_time" # stores the last time the script was executed. DO NOT CHANGE THE NAME OF THIS FILE WITHOUT UPDATING findFilesInDir
dirList=("dir?dir=A:") # contains a list of remote directories that need to be checked on the SD Card ie: dir?dir=A: dir?dir=A:\SETTINGS etc
ezshareURL="http://192.168.4.1/" # The base URL path to be prepended to each URL on the SD card
maxParallelDirChecks=15 # The number of directories to check in parallel new/changed files
maxParallelDownloads=5 # The number of files to download from the SD card at the same time
fastsyncEnabled=true # Controls whether or not to use .html files to speed up directory searching
ezShareSyncInProgress=0 # Added to allow the removal of partially sync'd directories
sleepHQuploadsEnabled=false # Determines whether to upload data to Sleep HQ.
sleepHQAPIBaseURL="https://sleephq.com" # The base URL for the Sleep HQ API
sleepDataSyncEnabled=true # Pulls data from SD Card and optionally pushes it to Sleep HQ
o2RingSyncEnabled=true # Scans the ${sdCardDir} for O2 Ring CSV export files and uploads them to Sleep HQ
o2RingDeviceID="69184" # The device ID for the O2 ring. This is hard coded on the server and shouldn't change.

# Colors!
red="\033[31m"
green="\033[32m"
reset="\033[0m"

################################
## SYNC.SH SPECIFIC FUNCTIONS ##
################################

# Uses output from the security command to provide
# more context as to the result of actions against
# keys in the users keychain.
verifyKeychainAction() {
  local action="${1}" # ie delete, add or verify
  local key="${2}" # The name of the key ie ezShareWifiSSID
  local retVal="${3}" # The return value of the 
  local output="${4}"

  if [ "${retVal}" -eq 0 ]; then
    echo -e "${green}Successfully performed ${action} against key ${key} in your keychain.${reset}"
  else
    echo
    echo -e "${red}Failed to perform ${action} against key ${key} in your keychain.${reset}"
    echo "Error Code: ${retVal}"
    echo "Error Info: ${output}"
  fi
}

# Function that blocks script
# execution until internet
# connectivity has been restored.
waitForConnectivity() {
  target="${1}"
  local output
  
  for ((i=1;i<=5;i++)); do
    if curl -s --connect-timeout 5 -I "${target}" | grep "^HTTP/" | awk '{print $2}' | egrep "200|302|301" >/dev/null; then
      return 0
    fi
    sleep 1
  done

  echo -e "${red} FAILED!${reset}\n\nFailed connectivity check to ${target}."
  echo "Please check network connectivity."
  echo
  echo "Cannot continue... exiting..."
  exit 1
}

# Connects to a given wifi network
connectToWifiNetwork() {
  local wifiAdaptor="${1}"
  local ssid="${2}"
  local password="${3}"
  local attempt=0
  local i=0

  while [ "${attempt}" -lt 5 ]; do
    echo -n "Connecting to WiFi network '${ssid}'... "
    if [[ -n $(networksetup -setairportnetwork "${wifiAdaptor}" "${ssid}" "${password}" 2>/dev/null) ]]; then
      echo -e "\n\n${red}Failed to connect to WiFi network ${ssid}.${reset}\n"
      echo -n "Trying again in 10 seconds or press Control + C to exit"
      while [ "${i}" -lt 10 ]; do
        echo -n "."
        sleep 1
        ((i+=1))
      done
      echo -e "\n\n"
    else
      echo -e "${green}DONE!${reset}"
      return 0 # we're connected to the WiFi network now..
    fi
    ((attempt+=1))
  done

  # Make sure we don't continue if 5 attempts if attempts > 5
  # this means we tried and failed to connect the EzShare WiFi network
  if [ "${attempt}" -eq 5 ]; then
    echo -e "\n\n${red}Failed to connect to WiFi network ${ssid}. Please make sure your SSID and password"
    echo -e "are correct and the WiFi network is available.${reset}"
    return 1
  fi
}

# Exit function which makes sure we clean up
# after ourselves and reconnect to the home WiFi
# if we're not already connected to it.
exitFunction() {
  if [ "${ezShareSyncInProgress}" -eq 1 ]; then
    echo -e "Something went wrong with the sync. Rolling back changes in the DATALOG directory...\n"

    wait # wait for any transfers to complete
    if [ -f "${transferListFile}" ]; then
      while IFS= read -r line || [[ -n "${line}" ]]; do
        (
          path=$(echo "${line}" | cut -f2 -d ';')
          # Remove the file if it's in the DATALOG directory
          if [ -f "${path}" ] && echo "${path}" | grep -q "DATALOG"; then
            rm -vf "${path}"
          fi
        ) &

        # Limit the number of parallel jobs
        if [[ $(jobs -r -p | wc -l) -ge "${maxParallelDownloads}" ]]; then
          wait
        fi
      done < "${transferListFile}"
      
      # find and remove any empty directories in the DATALOG directory as well
      find "${sdCardDir}/DATALOG" -mindepth 1 -maxdepth 1 -type d -empty -exec rmdir "{}" \;
    fi
    echo -e "\nCleanup complete"
  fi

  if [ "${numWifiAdaptors}" -eq 1 ]; then
    if [[ "${ezShareConnected}" -eq 1 ]]; then
      connectToWifiNetwork "${wifiAdaptor}" "${homeWiFiSSID}" "${homeWiFiPassword}"
    fi
  fi

  # If we have a sleep HQ Team ID, tell the user to delete it
  if [ -n "${sleepHQImportTaskID}" ]; then
    echo "sleepHQImportTaskID is currently set to ${sleepHQImportTaskID}."
    echo "Please make sure to visit the Data Imports section of the Sleep HQ"
    echo "website to delete the import because this script is not scoped for"
    echo "DELETE operations intentionally."
  fi

  trap - INT TERM EXIT
  exit
}

# Automatically updates the script to the latest version
# to make it easier for those who need it
versionCheck() {
  local me="${1}"
  local args="${2}"
  local lv
  local cv

  lv=$(curl -ks -o - https://raw.githubusercontent.com/iitggithub/ezshare_cpap/main/sync.sh 2>/dev/null | grep "^# VERSION=" | cut -f2 -d '=')
  cv=$(grep "^# VERSION=" "${me}" 2>/dev/null | cut -f2 -d '=')

  if [ -z "${lv}" ]; then
    lv=0 # something went wrong fetching latest version. Default to no update.
  fi

  if [ -z "${cv}" ]; then
    cv=0 # this version of the script doesn't have version checking enabled. Try to force an update.
  fi

  if [ "${lv}" -gt "${cv}" ]; then
    echo "Script update available. Auto-update from version ${cv} to ${lv} in progress..."
    curl -o "${me}" https://raw.githubusercontent.com/iitggithub/ezshare_cpap/main/sync.sh
    echo -e "${green}Done${reset}. Relaunching using ${me} ${args}"
    bash "${me}" "${args}"
    exit
  fi
}

# A failsafe function which is used to search the DATALOG
# directory for signs of last time the script was run. 
# if this fails, it'll sync everything as the last time
# is automatically set to the epoch.
getLastRunDate() {
  local dataDir="${1}"
  local latestFile
  local timestamp

  # this is a brand new sync since nothing exists
  if [ ! -d "${dataDir}" ]; then
    echo 0 # sync everything on the SD card
    return 0
  fi
  
  # Changed to use cut -f2- -d " " to allow for paths that contain a space
  latestFile=$(find "${dataDir}" -mindepth 2 -type f ! -name ".DS_Store" -exec stat -f "%m %N" "{}" + 2>/dev/null | sort -nr 2>/dev/null | head -n 1 | cut -f2- -d " ")

  # DATALOG directory exists but there's no files.
  # This is also a brand new sync.
  if [ -z "${latestFile}" ]; then
    echo 0 # sync everything on the SD card
    return 0
  fi

  # Get the last modified date
  timestamp=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "${latestFile}")

  # Convert the last modified date to seconds
  date -j -f "%Y-%m-%d %H:%M:%S" "${timestamp}" +"%s"
}

# Stores date in seconds in the lastRunFile
# The number corresponds to the last time
# the script successfully synchronized files
# from the SD card 
storeLastRunTimestamp() {
  local timestamp="${1}"
  shift
  local lastRunFile="${@}"
  echo "${timestamp}" >"${lastRunFile}"
}

# finds the date in seconds of the last time the script was run
# If the file doesn't exist, it will try to use files in the DATALOG
# directory to determine the last time files were sync'd and if all
# else fails, it'll sync everything as the last time is automatically
# set to the epoch.
getLastRunTimestamp() {
  local file="${1}"
  local dataDir="${2}"

  # Either this is the first time the script has been run
  # or the file doesn't exist which holds the last run time
  if [ ! -f "${file}" ]; then
    # Use the getLastRunDate function to search the DATALOG
    # directory for signs of last time the script was run. 
    getLastRunDate "${dataDir}"
    return 0 # return so we don't continue with the function
  fi

  lastRunDateInSeconds=$(head -1 "${file}" | awk '{print $1}')
  if ! [[ "${lastRunDateInSeconds}" =~ ^[0-9]+$ ]]; then
    # Not sure what's going on but that's not a number
    # Use the getLastRunDate function to search the DATALOG
    # directory for signs of last time the script was run. 
    lastRunDateInSeconds=$(getLastRunDate "${dataDir}")
  fi
  echo "${lastRunDateInSeconds}"
}

###############################
## EZSHARE SD SYNC FUNCTIONS ##
###############################

# Checks if the remote files size has changed compared to the local file
# returns true if it has changed. false if it hasn't
fileSizeHasChanged() {
  local size="${1}"
  local file="${2}"
  local localFileSizeInBytes

  localFileSizeInBytes=$(stat -f%z "${file}")

  # if the number is divisible by 1024, do not round number up
  # else, round the number up to the nearest kilobyte
  # seems this was needed because the sizes reported by the SD card
  # aren't accurate.
  if (( localFileSizeInBytes % 1024 == 0 )); then
    localFileSizeInKB=$(awk -v size="${localFileSizeInBytes}" 'BEGIN { printf "%.0f", (size / 1024) }')
  else
    localFileSizeInKB=$(awk -v size="${localFileSizeInBytes}" 'BEGIN { printf "%.0f", (size / 1024 + 0.5) }')
  fi
  
  if [ "${size}" != "${localFileSizeInKB}" ]; then
    return 0 # file size is different
  fi
  return 1 # return false
}

getLocalPath() {
  local type="${1}"
  local decodedPath="${2}"
  local name="${3}"
  local directoryPath
  if [ "${type}" == "dir" ]; then
    # extracts the relative path by removing the "A:\" from the decoded link path
    # so A:\SETTINGS\Identification.crc becomes SETTINGS\Identification.crc
    echo "${decodedPath}" | sed -e 's/dir?dir=A:\\//' | tr '\' '/'
  else
    # extracts the relative path from the decoded link ie:
    # http://192.168.4.1/download?file=SETTINGS\AGL.TGT
    # becomes
    # SETTINGS\AGL.TGT
    directoryPath=$(dirname "$(echo "${decodedPath}" | cut -f2 -d '=' | tr '\' '/')")

    # The dirname command will return a . if the
    # file is in the root directory so just return name only
    if [ "${directoryPath}" == "." ]; then
      echo "${name}"
      return
    fi
    echo "${directoryPath}/${name}"
  fi
}

fileTimestampHasChanged() {
  local lastRunDateInSeconds="${1}"
  local remoteTimestamp="${2}"
  # Convert date/time string from "2024- 6-29   12: 0: 0" to "2024-6-29  12:0:0"
  normalizedDate=$(echo "${remoteTimestamp}" | sed 's/ -/-/g; s/- /-/g; s/ :/:/g; s/: /:/g; s/  / /g')
  # Use the normalized date/time string and convert it into seconds ie 1719626400
  targetDateInSeconds=$(date -j -f "%Y-%m-%d %H:%M:%S" "${normalizedDate}" "+%s")

  if [ "${lastRunDateInSeconds}" -lt "${targetDateInSeconds}" ]; then
    return 0 # target has been modified since the last time the script was run
  fi
  return 1 # target hasn't been modified
}

# Extract the file size from the line
# file size is the 3rd column ie 64KB
# 2024- 6- 7   20:50:24          64KB  <a href="http://192.168.4.1/download?file=JOURNAL.DAT"> Journal.dat</a>
# and then returns the INT only ie 64
getRemoteFileSize() {
  local line="${1}"
  local remoteFileSize
  remoteFileSize=$(echo "${line}" | grep -oE ' ([0-9]+)KB ' 2>/dev/null | awk '{$1=$1};1' 2>/dev/null | sed -e 's/KB//' 2>/dev/null)
  if [ -z "${remoteFileSize}" ]; then
    echo 0
  fi
  echo "${remoteFileSize}"
}

# Checks if a file does not exist
# Need to get rid of this after troubleshooting
fileDoesNotExist() {
  local file="${1}"
  if [ ! -f "${file}" ]; then
    if [ -f "/tmp/sync.tmp" ]; then
      rm -f /tmp/sync.tmp
    fi
    return 0
  fi
  return 1
}

findRemoteDirs() {
  local maxParallelDirChecks="${1}"
  local ezshareURL="${2}"
  local uri="${3}"
  local sdCardDir="${4}"
  local url="${ezshareURL}${uri}"
  local html

  local name
  local link
  local localPath

  html=$(curl -s "$url" 2>/dev/null)
  if [ -z "${html}" ]; then
    echo "Something went wrong executing the command below:"
    echo
    echo "curl \"${url}\""
    echo
    echo "Cannot process the url. Skipping..."
    exit 1
  fi

  # extracts lines similar to the following:
  # 2024- 6- 7   20:50:24          64KB  <a href="http://192.168.4.1/download?file=JOURNAL.DAT"> Journal.dat</a>
  # and then iterates over each line
  echo "${html}" | grep '&lt;DIR&gt;' | while read -r line; do
    # extracts the link value and strips leading whitespace ie:
    # Journal.dat
    name=$(echo "${line}" | grep -oE '>[^<]*</a>' | sed 's/^>//' | sed 's/<\/a>$//' | sed 's/^ *//')

    case "${name}" in
      # Skip processing directories we don't care about
      "."|".."|".fseventsd"|".Spotlight-V100"|"TRASHE~1")
        continue
      ;;
      *)
        # extracts the link to the file/directory ie:
        # http://192.168.4.1/download?file=JOURNAL.DAT
        # and appends it to the dirList array
        link=$(echo "${line}" | cut -f2- -d '"' | cut -f1 -d '"' | sed 's/%5C/\\/g')
        localPath=$(getLocalPath "dir" "${link}")

        # Create the directory if it doesn't exist
        if [ ! -d "${sdCardDir}/${localPath}" ]; then
          mkdir -p "${sdCardDir}/${localPath}"
        fi
        echo "${link}"
        findRemoteDirs "${maxParallelDirChecks}" "${ezshareURL}" "${link}" "${sdCardDir}" &
      ;;
    esac
    # Limit the number of parallel jobs
    if [[ $(jobs -r -p | wc -l) -ge ${maxParallelDirChecks} ]]; then
      wait
    fi
  done
}

findFilesInDir() {
  local ezshareURL="${1}"
  local uri="${2}"
  local sdCardDir="${3}"
  local transferListFile="${4}"
  local lastRunDateInSeconds="${5}"
  local fastsyncEnabled="${6}"
  local url="${ezshareURL}${uri}"
 
  local name
  local link
  local fileTimestamp
  local localPath
  local fileSize

  local localHTMLFile
  local tmpHTMLFile
  local directoryName
  local directoryPath

  directoryPath="$(getLocalPath "dir" "${uri}")" # extract DATASTORE/20240704 from dir?dir=A:\DATASTORE\20240704

  # Use the sdCardDir basename if we're in the root directory of the SD Card
  # otherwise use the name of the remote directory that's being checked.
  if [ "${directoryPath}" == "dir?dir=A:" ]; then
    directoryName="$(basename "${sdCardDir}")"
    localHTMLFile="${sdCardDir}/.${directoryName}.html"
  else
    directoryName="$(basename "${directoryPath}")" # extract 20240704 from DATASTORE/20240704
    localHTMLFile="${sdCardDir}/${directoryPath}/.${directoryName}.html"
  fi
  
  # Download the current contents of the directory on the SD card
  tmpHTMLFile="/tmp/.${directoryName}.html"

  # Remove the existing tmpHTMLFile so curl doesn't create a different file on us
  test -f "${tmpHTMLFile}" && rm -f "${tmpHTMLFile}"

  # Download the contents of the remote directory and store in the tmpFile
  curl -s -o "${tmpHTMLFile}" "${url}" 2>/dev/null

  if ${fastsyncEnabled}; then
    # If the contents of the directory hasn't changed, skip this directory.
    if diff -q "${tmpHTMLFile}" "${localHTMLFile}" >/dev/null 2>&1; then
      rm -f "${tmpHTMLFile}"
      return
    fi

    # Files in the directory have changed. Save the downloaded
    # html file as .<FOLDER_NAME>.html in the folder
    mv -f "${tmpHTMLFile}" "${localHTMLFile}"
  else
    # This is a full sync. Used the tmpHTMLFile and compare files instead of directories
    localHTMLFile="${tmpHTMLFile}"
  fi

  # extracts lines similar to the following:
  # 2024- 6- 7   20:50:24          64KB  <a href="http://192.168.4.1/download?file=JOURNAL.DAT"> Journal.dat</a>
  # and then iterates over each line
  
  grep "<a href=" "${localHTMLFile}" | grep -v '&lt;DIR&gt;' | while read -r line; do
    # extracts href value ie Journal.dat
    name=$(echo "${line}" | grep -oE '>[^<]*</a>' | cut -f2 -d '>' | cut -f1 -d '<' | sed 's/^ *//')

    # Sometimes the STR.EDF file extension is in upper case
    # make sure when it's downloaded, it's renamed to STR.edf
    if [[ "${name}" == *"STR.EDF" ]]; then
      name="STR.edf"
    fi

    case "${name}" in
      # Skip processing files we don't care about
      "back to photo"|"ezshare.cfg"|"sync.sh"|"UPLOAD.ZIP"|.*)
        continue
      ;;
      *)
        # extracts the link to the file/directory ie:
        # http://192.168.4.1/download?file=JOURNAL.DAT
        # and appends it to the dirList array
        link=$(echo "${line}" | cut -f2- -d '"' | cut -f1 -d '"' | sed 's/%5C/\\/g')

        # extracts the timestamp ie:
        # 2024- 6- 7   20:50:24
        fileTimestamp=$(echo "${line}" | grep -oE '[0-9]{4}- ?[0-9]{1,2}- ?[0-9]{1,2} *[0-9]{1,2}: ?[0-9]{1,2}: ?[0-9]{1,2}')

        # extracts the relative path to the file from the link
        # A URL such as: http://192.168.4.1/download?file=DATALOG\20240707\20KKOR~1.EDF
        # will become DATALOG/20240707/
        # the ${name} will then be appended to the path like so:
        # DATALOG/20240707/20240707_135658_CSL.edf
        localPath=$(getLocalPath "file" "${link}" "${name}")

        # Takes the entire line and extracts the size of the file on the SD Card
        # the value is usually expressed in KB
        fileSize=$(getRemoteFileSize "${line}")
      
        # Check if the file timestamp or size has changed or it doesn't exist locally
        if fileDoesNotExist "${sdCardDir}/${localPath}" || fileTimestampHasChanged "${lastRunDateInSeconds}" "${fileTimestamp}" || fileSizeHasChanged "$fileSize" "${sdCardDir}/${localPath}"; then
          # store the information in a file because the function runs in a subshell
          # so we can't populate an array from here
          echo "${link};${localPath}" >>"${transferListFile}"
        fi
      ;;
    esac
  done
}

# Function to process the file list and download files in parallel
downloadFiles() {
  local maxParallelDownloads="${1}"
  local transferListFile="${2}"
  local sdCardDir="${3}"

  # If we've gotten to this point and called the downloadFiles
  # function. There's probably a bug. The script should only
  # execute this function if the transferListFile exists.
  if [ ! -f "${transferListFile}" ]; then
    echo "No files have been marked for transfer yet"
    echo "the downloadFiles function has been called."
    echo "This is almost certainly a bug and needs to be"
    echo "reported."
    echo
    echo "Cannot continue... exiting..."
    exit 1
  fi

  # Process each item in the list
  while IFS= read -r line || [[ -n "${line}" ]]; do
    (
      url=$(echo "${line}" | cut -f1 -d ';')
      path=$(echo "${line}" | cut -f2 -d ';')
      echo "Downloading ${url} to ${sdCardDir}/${path}"
      curl -# -o "${sdCardDir}/${path}" "${url}"
    ) &

    # Limit the number of parallel jobs
    if [[ $(jobs -r -p | wc -l) -ge "${maxParallelDownloads}" ]]; then
      wait
    fi
  done < "${transferListFile}"

  # Wait for all background jobs to finish
  wait
}

############################
## SLEEP HQ ZIP FUNCTIONS ##
############################

# Creates a zip file of sleep data and CPAP machine files
# so it can be uploaded to Sleep HQ
createSleepDataZipFile() {
  local uploadZipFile="${1}"
  local sdCardDir
  local transferListFile="${2}"
  local fileList=()
  local mandatoryInclusions=()
  local startDate
  local endDate

  sdCardDir=$(dirname "${uploadZipFile}")
  mandatoryInclusions=("Identification.crc" "Identification.tgt" "Identification.json" "JOURNAL.JNL" "Journal.dat" "SETTINGS" "STR.edf")
  startDate=$(cut -f2 -d ';' "${transferListFile}" | cut -f2 -d '/' | grep -oE '[0-9]+' | sort | uniq | head -1)
  endDate=$(cut -f2 -d ';' "${transferListFile}" | cut -f2 -d '/' | grep -oE '[0-9]+' | sort | uniq | tail -1)

  echo -e "\nCreating upload.zip file..."

  # Double check we're in the SD card directory
  cd "${sdCardDir}"

  # Remove the existing upload.zip file
  test -f "${uploadZipFile}" && rm -f "${uploadZipFile}"

  # upload zip file has been copied to iCloud. Evict the local copy
  test -f "$(dirname "${uploadZipFile}")/.$(basename "${uploadZipFile}").icloud" && brctl evict "${uploadZipFile}"

  # Read each line from the input file
  while IFS= read -r line; do
    # Extract the local file path using ';' as the delimiter
    path=$(echo "${line}" | cut -d';' -f2)
    # Exclude files starting with SETTINGS/ because the whole SETTINGS
    # directory will be included by default
    if [[ "${path}" == SETTINGS/* ]]; then
      continue
    fi
    # Append the local file path to the array
    fileList+=("${path}")
  done < "${transferListFile}"

  # Ensure mandatory files are included
  for inclusion in "${mandatoryInclusions[@]}"; do
    if [[ ! " ${fileList[@]} " =~ " ${inclusion} " ]]; then
      # If it's a file or directory, add it to the file list
      if [ -e "${sdCardDir}/${inclusion}" ]; then
        fileList+=("${inclusion}")
      fi
    fi
  done

  # Create a zip archive containing the files with relative paths
  zip -r "${uploadZipFile}" "${fileList[@]}" --exclude '.*' --exclude 'SETTINGS/.*' --exclude '*DS_Store'

  # Don't bother continuing if the zip file hasn't been created.
  if [ ! -f "${uploadZipFile}" ]; then
    echo -e " ${red}FAILED!${reset}\n\nFailed to create ${uploadZipFile}."
    echo "Cannot continue with automatic upload. Please upload your data manually."
    echo
    exit 1
  else
    echo -e "\n${green}DONE!${reset}\nCreated ${uploadZipFile} which includes dates ${startDate} to ${endDate}."
  fi
}

# Creates a zip file consisting of o2 ring csv files
# for upload to Sleep HQ
createO2RingDataZipFile() {
  local uploadZipFile="${1}"
  local sdCardDir

  sdCardDir=$(dirname "${uploadZipFile}")

  echo -e "\nCreating upload.zip file..."

  # Double check we're in the SD card directory
  cd "${sdCardDir}"

  # Remove the existing upload.zip file
  test -f "${uploadZipFile}" && rm -f "${uploadZipFile}"

  # upload zip file has been copied to iCloud. Evict the local copy
  test -f "${sdCardDir}/.$(basename "${uploadZipFile}").icloud" && brctl evict "${uploadZipFile}"

  # Create a zip archive containing the files with relative paths
  find "${sdCardDir}" -mindepth 1 -maxdepth 1 -type f -name "O2Ring*.csv" -print0 | xargs -0 -n 1 zip -r "${uploadZipFile}"

  # Don't bother continuing if the zip file hasn't been created.
  if [ ! -f "${uploadZipFile}" ]; then
    echo -e " ${red}FAILED!${reset}\n\nFailed to create ${uploadZipFile}."
    echo "Cannot continue with automatic upload. Please upload your data manually."
    echo
    exit 1
  else
    echo -e "${green}DONE!${reset}\nCreated ${uploadZipFile}."
  fi
}

############################
## SLEEP HQ API FUNCTIONS ##
############################

# Get the access token which is needed to upload the files
generateSleepHQAccessToken() {
  local sleepHQAPIBaseURL="${1}"
  local sleepHQClientUID="${2}"
  local sleepHQClientSecret="${3}"
  local params

  params=()
  params+=('-H')
  params+=('Content-Type: application/x-www-form-urlencoded')
  params+=('-d')
  params+=('grant_type=password')
  params+=('-d')
  params+=("client_id=${sleepHQClientUID}")
  params+=('-d')
  params+=("client_secret=${sleepHQClientSecret}")
  params+=('-d')
  params+=('scope=read%20write')

  # Example json output:
  # {"access_token":"access_token_string_value","token_type":"Bearer","expires_in":7200,"refresh_token":"refresh_token_string_value","scope":"read write","created_at":1720655289}
  curl -s "${sleepHQAPIBaseURL}/oauth/token" "${params[@]}" 2>/dev/null | awk -F '[:,{}]' '{for(i=1;i<=NF;i++){if($i~/"access_token\"/){print $(i+1)}}}' | sed 's/["]*//g'
}

# Get the current SleepHQ team ID for the user
getSleepHQTeamID() {
  local sleepHQAccessToken="${1}"
  local sleepHQAPIBaseURL="${2}"

  local params

  params=()
  params+=('-H')
  params+=('Content-Type: application/x-www-form-urlencoded')
  params+=('-H')
  params+=('accept: application/vnd.api+json')
  params+=('-H')
  params+=("authorization: Bearer ${sleepHQAccessToken}")

  # Example json output:
  # {"data":{"id":1234,"email":"email@host.com","current_team_id":1234,"profile_photo_url":null,"owned_team_ids":[1234],"name":"My Name"}}
  curl -s "${sleepHQAPIBaseURL}/api/v1/me" "${params[@]}" 2>/dev/null | awk -F '[:,{}]' '{for(i=1;i<=NF;i++){if($i~/"current_team_id\"/){print $(i+1)}}}' | sed 's/[^0-9]*//g'
}

# Create a Sleep  HQ Import task
createImportTask() {
  local sleepHQAccessToken="${1}"
  local sleepHQAPIBaseURL="${2}"
  local sleepHQTeamID="${3}"
  local sleepHQDeviceID="${4}"

  local params

  params=()
  params+=('-H')
  params+=('Content-Type: application/x-www-form-urlencoded')
  params+=('-H')
  params+=('accept: application/vnd.api+json')
  params+=('-H')
  params+=("authorization: Bearer ${sleepHQAccessToken}")
  params+=('-d')
  params+=('programatic=true')
  params+=('-d')
  params+=("device_id=${sleepHQDeviceID}")

  # Example json output:
  # {"data":{"id":"1234567","type":"import","attributes":{"id":1234567,"team_id":1234,"name":null,"status":"uploading","file_size":null,"progress":0,"machine_id":null,"device_id":123456,"programatic":true,"failed_reason":null,"created_at":"2024-07-10 23:07:31 UTC","updated_at":"2024-07-10 23:07:31 UTC"},"relationships":{"files":{"data":[]}}}}
  curl -s "${sleepHQAPIBaseURL}/api/v1/teams/${sleepHQTeamID}/imports" "${params[@]}" 2>/dev/null | awk -F '[:,{}]' '{for(i=1;i<=NF;i++){if($i~/"attributes\"/ && $(i+2)~/"id\"/){print $(i+3)}}}' | sed 's/[^0-9]*//g'
}

generateContentHash() {
  local uploadZipFileName="${1}"
  # Generate content hash
  # Takes the contents of the file to be uploaded and appends "upload.zip"
  # which is the name of the file being uploaded to the end of the string.
  # Finally it performs an md5sum of the entire string
  (cat "${uploadZipFileName}"; echo "${uploadZipFileName}") | md5 -q
}

# Upload Zip file to Sleep HQ
uploadFileToSleepHQ() {
  local sleepHQAccessToken="${1}"
  local sleepHQAPIBaseURL="${2}"
  local sleepHQImportTaskID="${3}"
  local uploadZipFileName="${4}"
  local sleepHQcontentHash="${5}"

  local params

  params=()
  params+=('-H')
  params+=('accept: application/vnd.api+json')
  params+=('-H')
  params+=("authorization: Bearer ${sleepHQAccessToken}")
  params+=('-F')
  params+=("name=${uploadZipFileName}")
  params+=('-F')
  params+=('path=.%2F')
  params+=('-F')
  params+=("content_hash=${sleepHQcontentHash}")
  params+=('-F')
  params+=("file=@${uploadZipFileName}")

  curl -s "${sleepHQAPIBaseURL}/api/v1/imports/${sleepHQImportTaskID}/files" "${params[@]}" >/dev/null
}

# Instruct Sleep HQ to unpack the zip file and process the import
triggerDataImport() {
  local sleepHQAccessToken="${1}"
  local sleepHQAPIBaseURL="${2}"
  local sleepHQImportTaskID="${3}"
  local params

  params=()
  params+=('-H')
  params+=('accept: application/vnd.api+json')
  params+=('-H')
  params+=("authorization: Bearer ${sleepHQAccessToken}")

  curl -s -X 'POST' "${sleepHQAPIBaseURL}/api/v1/imports/${sleepHQImportTaskID}/process_files" "${params[@]}" >/dev/null
}

# wait for upload to complete and report upload progress
monitorImportProgress() {
  local sleepHQAccessToken="${1}"
  local sleepHQAPIBaseURL="${2}"
  local sleepHQImportTaskID="${3}"
  local progress=0
  local prevProgress=0
  local failCounter=0

  local params

  params=()
  params+=('-H')
  params+=('accept: application/vnd.api+json')
  params+=('-H')
  params+=("authorization: Bearer ${sleepHQAccessToken}")

  while [ "${progress}" -lt 100 ]; do
    if [ "${progress}" -ne 0 ]; then
      sleep 5 # Add a 5 second sleep timer to avoid API throttling
    fi
    # Example JSON output:
    # {"data":{"id":"1234567","type":"import","attributes":{"id":1234567,"team_id":1234,"name":null,"status":"complete","file_size":660936,"progress":100,"machine_id":12345,"device_id":12345,"programatic":true,"failed_reason":null,"created_at":"2024-07-10 22:49:20 UTC","updated_at":"2024-07-10 22:49:29 UTC"},"relationships":{"files":{"data":[{"id":"123456789","type":"imports/file"},{"id":"123456789","type":"imports/file"},{"id":"123456789","type":"imports/file"},{"id":"123456789","type":"imports/file"}]}}}}
    progress=$(curl -s "${sleepHQAPIBaseURL}/api/v1/imports/${sleepHQImportTaskID}" "${params[@]}" 2>/dev/null | awk -F '[:,]' '{for(i=1;i<=NF;i++){if($i~/"progress"/){print $(i+1)}}}' | sed 's/[^0-9]*//g')
    echo -ne "Progress: ${progress}% complete...\r"
    if [ "${prevProgress}" -eq "${progress}" ]; then
      if [ "${failCounter}" -eq 12 ]; then
        echo
        echo "Upload progress is still at ${progress}% after 60 seconds."
        echo
        echo "Abandoning monitoring of Data Import. Please check the Data Import page"
        echo "on the Sleep HQ website."
        break
      fi
      ((failCounter++))
    else
      failCounter=0
      prevProgress="${progress}"
    fi
  done
  echo -ne "Progress: ${green}${progress}% complete${reset}...\n"
}

################################################################################################################################################
################################################################################################################################################
########################################################## CODE STARTS HERE ####################################################################
################################################################################################################################################
################################################################################################################################################

# Make sure we only run the script on a mac
# Not sure what would happen if you ran it on Linux
# ... would probably break a lot of stuff..
if [ "$(uname 2>/dev/null | grep -c Darwin)" -eq 0 ]; then
  echo "This script can only be run on a Mac (Darwin)."
  exit 1
fi

# Make sure we're not the root user
# root user permissions are not necessary
if [ "$(id -u)" -eq 0 ]; then
  echo "Don't run this script as the root user!"
  exit 1
fi

# Check for updates and re-launch the script if necessary
versionCheck "${me}" "${@}"

overallStart="$(date +%s)"

#################################
## SD Card directory selection ##
#################################

# This code exists solely to allow users to store
# their sd card contents wherever they want
keychainSDCardDir="$(security find-generic-password -ga "ezSharesdCardDir" 2>&1 | grep password | cut -f2- -d '"' | sed -e 's/^"//' -e 's/"$//')"
if [ -n "${keychainSDCardDir}" ]; then
  sdCardDir="${keychainSDCardDir}"
fi

# Create the SD card directory if it doesn't exist
# If the directory doesn't exist, it's either a first time user
# or the user has opted to move the SD Card directory somewhere
# else.
# Ask the user where they want to store the SD card contents and 
# remember it for the future.
if [ ! -d "${sdCardDir}" ]; then
  echo -e "\nSD Card directory does not exist."
  echo -e "\nEnter the path where you would like to store SD Card files"
  echo "or press enter to accept the default location."
  echo -ne "\nYour selection (Default: ${sdCardDir}): "
  read -r answer
  if [ -n "${answer}" ]; then
    sdCardDir="${answer}"
    security add-generic-password -T "/usr/bin/security" -U -a "ezSharesdCardDir" -s "ezShare" -w "${sdCardDir}"
  fi
  echo
  if [ ! -d "${sdCardDir}" ]; then
    mkdir -p "${sdCardDir}"
  fi 
  echo
fi

# Reset the following global variables just in case they've changed
uploadZipFile="${sdCardDir}/${uploadZipFileName}" # The absolute path to the Zip file containing files needing to be uploaded
lastRunFile="${sdCardDir}/.sync_last_run_time" # stores the last time the script was executed. DO NOT CHANGE THE NAME OF THIS FILE WITHOUT UPDATING findFilesInDir

############################
## Wifi adaptor selection ##
############################

wifiAdaptor="$(networksetup -listallhardwareports | egrep -A1 '802.11|Wi-Fi' | grep "Device" | awk '{print $2}' | sort -n)"
numWifiAdaptors="$(echo "${wifiAdaptor}" | wc -l | awk '{print $1}')"

if [ "${numWifiAdaptors}" -eq 0 ]; then
  echo "Couldn't identify a valid Wifi adaptor. Below are the wifi adaptors we found"
  echo "using the command: \"networksetup -listallhardwareports | egrep -A1 '802.11|Wi-Fi'\""
  networksetup -listallhardwareports | egrep -A1 '802.11|Wi-Fi'
  exit 1
fi

###################################
## Wifi credential specification ##
###################################

if [ "${numWifiAdaptors}" -eq 1 ]; then
  # Check to see if we can successfully pull WiFi Credentials
  # from the users Login keychain.
  ezShareWifiSSID="$(security find-generic-password -ga "ezShareWifiSSID" 2>&1 | grep password | cut -f2- -d '"' | sed -e 's/^"//' -e 's/"$//')"
  ezShareWiFiPassword="$(security find-generic-password -ga "ezShareWiFiPassword" 2>&1 | grep password | cut -f2- -d '"' | sed -e 's/^"//' -e 's/"$//')"
  homeWiFiSSID="$(security find-generic-password -ga "homeWiFiSSID" 2>&1 | grep password | cut -f2- -d '"' | sed -e 's/^"//' -e 's/"$//')"
  homeWiFiPassword="$(security find-generic-password -ga "homeWiFiPassword" 2>&1 | grep password | cut -f2- -d '"' | sed -e 's/^"//' -e 's/"$//')"

  # If any of the credentials do not exist
  # prompt the user to create them.
  if [ -z "${ezShareWifiSSID}" ] ||
     [ -z "${ezShareWiFiPassword}" ] ||
     [ -z "${homeWiFiSSID}" ] ||
     [ -z "${homeWiFiPassword}" ]; then
    echo "Couldn't find WiFi details in your Login keychain. Setup process will"
    echo "now begin. Press enter to accept defaults if there are any."
    echo "Please note you may need to enter your password to make changes to"
    echo "your Login keychain."
    echo
    echo -n "Please enter the WiFi SSID of the ezShare Wifi Card (Default: 'ez Share'): "
    read -r ezShareWifiSSID
    if [ -z "${ezShareWifiSSID}" ]; then
      ezShareWifiSSID="ez Share"
    fi
    echo -n "Please enter the WiFi password for the ezShare Wifi Card (Default: '88888888'): "
    read -r ezShareWiFiPassword
    if [ -z "${ezShareWiFiPassword}" ]; then
      ezShareWiFiPassword="88888888"
    fi
    while [ -z "${homeWiFiSSID}" ]; do
      echo -n "Please enter the SSID of your home WiFi network: "
      read -r homeWiFiSSID
    done
    while [ -z "${homeWiFiPassword}" ]; do
      echo -n "Please enter the WiFi password for your home WiFi network: "
      read -r homeWiFiPassword
    done
    # Create the necessary entries in the users Login keychain 
    security add-generic-password -T "/usr/bin/security" -U -a "ezShareWifiSSID" -s "ezShare" -w "${ezShareWifiSSID}"
    security add-generic-password -T "/usr/bin/security" -U -a "ezShareWiFiPassword" -s "ezShare" -w "${ezShareWiFiPassword}"
    security add-generic-password -T "/usr/bin/security" -U -a "homeWiFiSSID" -s "ezShare" -w "${homeWiFiSSID}"
    security add-generic-password -T "/usr/bin/security" -U -a "homeWiFiPassword" -s "ezShare" -w "${homeWiFiPassword}"
  fi
fi

#######################################
## Sleep HQ credential specification ##
#######################################

# Sleep HQ Upload Credentials
sleepHQClientUID="$(security find-generic-password -ga "sleepHQClientUID" 2>&1 | grep password | cut -f2- -d '"' | sed -e 's/^"//' -e 's/"$//')"
sleepHQClientSecret="$(security find-generic-password -ga "sleepHQClientSecret" 2>&1 | grep password | cut -f2- -d '"' | sed -e 's/^"//' -e 's/"$//')"
sleepHQDeviceID="$(security find-generic-password -ga "sleepHQDeviceID" 2>&1 | grep password | cut -f2- -d '"' | sed -e 's/^"//' -e 's/"$//')"

# If any of the credentials do not exist
# it's assumed that they've never been asked to create them
# Explicitly saying "n" will permanently disable this check.
if [ -z "${sleepHQClientUID}" ] ||
   [ -z "${sleepHQClientSecret}" ] ||
   [ -z "${sleepHQDeviceID}" ]; then
  echo -n "Would you like to enable automatic uploads to SleepHQ? (y/n): "
  read -r answer

  case "${answer}" in
    [yY][eE][sS]|[yY])
      echo
      while [ -z "${sleepHQClientUID}" ]; do
        echo -n "Please enter your Sleep HQ Client UID: "
        read -r sleepHQClientUID
      done
      echo
      while [ -z "${sleepHQClientSecret}" ]; do
        echo -n "Please enter your Sleep HQ Client Secret: "
        read -r sleepHQClientSecret
      done

      # Create the necessary entries in the users Login keychain. 
      security add-generic-password -T "/usr/bin/security" -U -a "sleepHQClientUID" -s "ezShare" -w "${sleepHQClientUID}"
      security add-generic-password -T "/usr/bin/security" -U -a "sleepHQClientSecret" -s "ezShare" -w "${sleepHQClientSecret}"

      # Make sure the Client UID and Client Secret were added to the keychain
      if [ "${sleepHQClientUID}" == "$(security find-generic-password -ga "sleepHQClientUID" 2>&1 | grep password | cut -f2- -d '"' | sed -e 's/^"//' -e 's/"$//')" ] &&
         [ "${sleepHQClientSecret}" == "$(security find-generic-password -ga "sleepHQClientSecret" 2>&1 | grep password | cut -f2- -d '"' | sed -e 's/^"//' -e 's/"$//')" ]; then
        echo
        echo "Sleep HQ Client UID ( sleepHQClientUID ) and Client Secret ( sleepHQClientSecret ) are now saved to your keychain."
        echo

        echo
        echo -ne "Testing Sleep HQ API Credentials..."
        if [ -z "${sleepHQAccessToken}" ]; then
          sleepHQAccessToken=$(generateSleepHQAccessToken "${sleepHQAPIBaseURL}" "${sleepHQClientUID}" "${sleepHQClientSecret}")
        fi
        
        # Make sure we've got an access token.
        # If we've got an empty value for the ${sleepHQAccessToken}
        # we've failed to get one and can't continue
        if [ -z "${sleepHQAccessToken}" ]; then
          echo -e " ${red}FAILED!${reset}\n\nFailed to obtain a Sleep HQ API Access Token."
          echo "Make sure your Client UID and Secret are correct and"
          echo "you can access the https://sleephq.com website in your"
          echo "web browser."
          echo
          echo "Debug output for troubleshooting is shownn below: "
          echo
          echo "Command:"
          echo "curl -X 'POST' \"${sleepHQLoginURL}\""
          echo
          echo -n "Output: "
          curl -X 'POST' "${sleepHQLoginURL}"
          echo
          echo
          echo "Cannot continue... Rolling back Sleep HQ configuration and exiting..."
          echo
          bash "${me}" --remove-sleephq
          exit 1
        else
          echo -e " ${green}PASSED!${reset}"
        fi

        # Ask the user to provide their device type
        echo -e "\nWhat kind of CPAP device are you using with automated uploads? Enter an ID from the list below: \n"

        curl -s "${sleepHQAPIBaseURL}/api/v1/devices" -H 'accept: application/vnd.api+json' -H "authorization: Bearer ${sleepHQAccessToken}" | awk '
          function json_value(key) {
              match($0, "\"" key "\": *\"[^\"]*\"")
              value = substr($0, RSTART, RLENGTH)
              gsub("\"" key "\": *\"", "", value)
              gsub("\"", "", value)
              return value
          }

          {
              while (match($0, "\"id\"[ \t]*:[ \t]*\"[^\"]+\"")) {
                  device_id = json_value("id")
                  device_name = json_value("name")
                  if (device_id && device_name) {
                      device_ids[++id_count] = device_id
                      device_names[id_count] = device_name
                      sub("\"id\"[ \t]*:[ \t]*\"[^\"]+\"", "", $0)
                      sub("\"name\"[ \t]*:[ \t]*\"[^\"]+\"", "", $0)
                  }
              }
          }

          END {
              print "Device IDs\tDevice Names"
              for (i = 1; i <= id_count; i++) {
                  printf "%s\t\t%s\n", device_ids[i], device_names[i]
              }
          }'
        echo -ne "\nDevice ID: "
        read -r sleepHQDeviceID
        security add-generic-password -T "/usr/bin/security" -U -a "sleepHQDeviceID" -s "ezShare" -w "${sleepHQDeviceID}"

        if [ "${sleepHQDeviceID}" == "$(security find-generic-password -ga "sleepHQDeviceID" 2>&1 | grep password | cut -f2- -d '"' | sed -e 's/^"//' -e 's/"$//')" ]; then
          echo
          echo "Sleep HQ Device ID successfully added to your keychain."
        fi
        echo
        echo "Sleep HQ Automatic uploads are now enabled."
        sleepHQuploadsEnabled=true
      else
        echo
        echo "Failed to add Sleep HQ Client UID ( sleepHQClientUID ) and Client Secret ( sleepHQClientSecret ) to your keychain. Please try again..."
        exit 1
      fi
    ;;
    [nN][oO]|[nN])
      # Set the sleepHQClientUID and sleepHQClientSecret values to false
      # When the script starts, it will skip asking the user if they want to
      # configure Sleep HQ automatic uploads because there is a value set for
      # both sleepHQClientUID and sleepHQClientSecret in the users keychain
      sleepHQClientUID="false"
      sleepHQClientSecret="false"
      security add-generic-password -T "/usr/bin/security" -U -a "sleepHQClientUID" -s "ezShare" -w "${sleepHQClientUID}" # set the value to false
      security add-generic-password -T "/usr/bin/security" -U -a "sleepHQClientSecret" -s "ezShare" -w "${sleepHQClientSecret}" # set the value to false
    ;;
  esac
fi

# Enable automatic Sleep HQ uploads if credentials
# have been configured in the keychain and those credentials
# are not set to the string lteral "false"
if [ "${sleepHQClientUID}" != "false" ] &&
   [ -n "${sleepHQClientUID}" ] &&
   [ "${sleepHQClientSecret}" != "false" ] &&
   [ -n "${sleepHQClientSecret}" ]; then
  sleepHQuploadsEnabled=true
fi

# Iterate over command line arguments
# Command line arguments can perform overrides
# so must be performed just before the script
# actually begins execution.
for arg in ${@}; do
  case "${arg}" in
    "--dedicated")
      if [ "${numWifiAdaptors}" -lt 2 ]; then
        exit 0
      fi
    ;;
    "--full-sync")
    fastsyncEnabled=false
    ;;
    "--skip-sync")
    sleepDataSyncEnabled=false
    ;;
    "--skip-upload")
    sleepHQuploadsEnabled=false
    ;;
    "--skip-o2")
    o2RingSyncEnabled=false
    ;;
    "--remove-sleephq")
      output="$(security -q delete-generic-password -a sleepHQClientUID 2>&1)"
      verifyKeychainAction delete sleepHQClientUID $? "${output}"
      output="$(security -q delete-generic-password -a sleepHQClientSecret 2>&1)"
      verifyKeychainAction delete sleepHQClientSecret $? "${output}"
      output="$(security -q delete-generic-password -a sleepHQDeviceID 2>&1)"
      verifyKeychainAction delete sleepHQDeviceID $? "${output}"
      echo
      exit 0
    ;;
    "--remove-ezshare")
      output="$(security -q delete-generic-password -a ezShareWifiSSID 2>&1)"
      verifyKeychainAction delete ezShareWifiSSID $? "${output}"
      output="$(security -q delete-generic-password -a ezShareWiFiPassword 2>&1)"
      verifyKeychainAction delete ezShareWiFiPassword $? "${output}"
      echo
      exit 0
    ;;
    "--remove-home")
      output="$(security -q delete-generic-password -a homeWiFiSSID 2>&1)"
      verifyKeychainAction delete homeWiFiSSID $? "${output}"
      output="$(security -q delete-generic-password -a homeWiFiPassword 2>&1)"
      verifyKeychainAction delete homeWiFiPassword $? "${output}"
      echo
      exit 0
    ;;
    "--remove-all")
      bash "${me}" --remove-sleephq
      bash "${me}" --remove-ezshare
      bash "${me}" --remove-home
      exit 0
    ;;
    "--reset-sd")
      output="$(security -q delete-generic-password -a ezSharesdCardDir 2>&1)"
      verifyKeychainAction delete ezSharesdCardDir $? "${output}"
      echo
      exit 0
    ;;
    "--max-streams="*)
      maxParallelDirChecks="$(echo "${arg}" | cut -f2 -d '=')"
    ;;
    "--max-downloads="*)
      maxParallelDownloads="$(echo "${arg}" | cut -f2 -d '=')"
    ;;
    "-v"|"--version")
    echo "sync.sh version $(grep '^# VERSION=' "$0" 2>/dev/null | cut -f2 -d '=')"
    exit 0
    ;;
    "--connection-check")
    open -a safari https://youtu.be/dQw4w9WgXcQ?si=ciWPSSKqphW4gkvz
    exit 0
    ;;
    "-h"|"--help")
      echo "sync.sh <options>"
      echo
      echo "Options:"
      echo
      echo "Disables fast sync if missing files in a directory aren't being downloaded:"
      echo "${0} --full-sync"
      echo
      echo "Don't sync files from the SD Card:"
      echo "${0} --skip-sync"
      echo
      echo "Don't upload files to Sleep HQ:"
      echo "${0} --skip-upload"
      echo
      echo "Don't sync O2 CSV export files to Sleep HQ:"
      echo "${0} --skip-o2"
      echo
      echo "Set the number of parallel streams to run when checking files/directories:"
      echo "${0} --max-streams=15"
      echo
      echo "Set the number of parallel downloads to execute:"
      echo "${0} --max-downloads=5"
      echo
      echo "Remove Sleep HQ credentials from your keychain:"
      echo "${0} --remove-sleephq"
      echo
      echo "Remove Ezshare WiFi SD card WiFi SSID and password from your keychain:"
      echo "${0} --remove-ezshare"
      echo
      echo "Remove home WiFi credentials from your keychain:"
      echo "${0} --remove-home"
      echo
      echo "Remove all credentials (home/ezshare/sleephq):"
      echo "${0} --remove-credentials"
      echo
      echo "Reset SD Card location in keychain:"
      echo "${0} --reset-sd"
      ezSharesdCardDir
      echo
      echo "Dual wifi adaptor automation mode:"
      echo "${0} --dedicated"
      echo
      echo "Check internet connectivity:"
      echo "${0} --connection-check"
      echo
      echo "Show version information:"
      echo "${0} --version"
      exit 0
    ;;
  esac
done

#############################################
## INSTALLATION/PRE-FLIGHT CHECKS COMPLETE ##
########## SCRIPT EXECUTION BEGINS ##########
#############################################

if ${sleepDataSyncEnabled}; then
  # Make sure we can connect to the home WiFi network
  # because there's not much point in continuing if the
  # the user hasn't got their own WiFi details set correctly
  if [ "${numWifiAdaptors}" -eq 1 ]; then
    echo -e "\nChecking WiFi connectivity to ${homeWiFiSSID} before we begin...\n"
    if ! connectToWifiNetwork "${wifiAdaptor}" "${homeWiFiSSID}" "${homeWiFiPassword}"; then
      exit 1 # Failed to connect to the wifi network
    fi
  fi

  lastRunDateInSeconds=$(getLastRunTimestamp "${lastRunFile}" "${sdCardDir}/DATALOG")
  if [ "${lastRunDateInSeconds}" -gt 0 ]; then
    echo -e "\nLast successful SD Card synchronization: $(date -r "${lastRunDateInSeconds}" +"%Y-%m-%d %H:%M:%S")\n"
  else
    echo -e "\nCould not reliably determine the last time a successful"
    echo "SD card synchronization was performed. This is usually because"
    echo "the ${sdCardDir} is empty."
    echo -e "\nScript will synchronize all data from the SD Card. Press"
    echo "any key to continue or Control + C to exit."
    read -r answer
  fi

  # Set a default path to the file sync log
  # The file is used to determine which directories
  # need to be added to the zip file
  if [ -d "/var/tmp" ]; then
    tmpDir="/var/tmp"
  else
    tmpDir="/tmp"
  fi

  transferListFile="${tmpDir}/sync_transfer_list.log" # Contains a semi-colon separated list of URLs and local directory paths

  # remove the transfer list file so we know if it doesn't exist
  # there were no files that needed to be downloaded
  test -f "${transferListFile}" && rm -f "${transferListFile}"

  trap exitFunction INT TERM EXIT

  # Connect to the wifi network
  if [ "${numWifiAdaptors}" -eq 1 ]; then
    if ! connectToWifiNetwork "${wifiAdaptor}" "${ezShareWifiSSID}" "${ezShareWiFiPassword}"; then
      exit 1 # We failed to connect to the wifi network
    fi
    ezShareConnected=1 # Ensures we reconnect to the home wifi network if anything fails
  fi

  echo -ne "\nVerifying connectivity to EZ Share Web Interface..."
  if waitForConnectivity "${ezshareURL}"
    then
    echo -e " ${green}DONE!${reset}"

  fi

  start="$(date +%s)"
  echo -ne "\nSearching SD Card for directories to check..."
  # Discover all of the directories on the SD card
  # store the URL in the dirList array
  while IFS=' ' read -r item; do
      dirList+=("$item")
  done <<< "$(findRemoteDirs "${maxParallelDirChecks}" "${ezshareURL}" "${dirList[0]}" "${sdCardDir}")"
  wait

  end="$(date +%s)"
  timeTaken="$(echo "${end}-${start}" | bc)"
  echo -e " ${green}DONE!${reset} Time taken: ${timeTaken} seconds."

  start="$(date +%s)"
  echo -e "\nSearching SD Card directories for files to download..."
  for remoteDirPath in "${dirList[@]}"; do
    echo "Checking ${ezshareURL}${remoteDirPath}"
    findFilesInDir "${ezshareURL}" "${remoteDirPath}" "${sdCardDir}" "${transferListFile}" "${lastRunDateInSeconds}" "${fastsyncEnabled}" &
    # Limit the number of parallel jobs
    if [[ $(jobs -r -p | wc -l) -ge ${maxParallelDirChecks} ]]; then
      wait
    fi
  done
  wait

  end="$(date +%s)"
  timeTaken="$(echo "${end}-${start}" | bc)"
  echo -e "\nDone searching SD card for files to download. Time taken: ${timeTaken} seconds."

  # Transfer list file is only populated when it's actually identified files to download
  # If there's no files to download, we must be up to date and there's no reason to continue
  if [ ! -f "${transferListFile}" ]; then
    if [ "${numWifiAdaptors}" -eq 1 ]; then
      # Make sure we reconnect to the home wifi network
      # because we don't need the SD card anymore
      if ! connectToWifiNetwork "${wifiAdaptor}" "${homeWiFiSSID}" "${homeWiFiPassword}"; then
        exit 1 # We failed to connect to the wifi network
      fi
      ezShareConnected=0 # disables automatic reconnection to home wifi because we're already connected
      waitForConnectivity "${sleepHQAPIBaseURL}"
    fi
    echo -e "\nLocal filesystem is already up to date with SD Card."
  else
    echo -e "\nStarting SD card sync\n"
    ezShareSyncInProgress=1
    start="$(date +%s)"
    numFiles="$(cat ${transferListFile} | wc -l | awk '{print $1}')"
    downloadFiles "${maxParallelDownloads}" "${transferListFile}" "${sdCardDir}"
    end="$(date +%s)"
    timeTaken="$(echo "${end}-${start}" | bc)"
    echo -e "\nSD card sync complete. Time taken: ${timeTaken} seconds. Files downloaded: ${numFiles} files.\n"
    ezShareSyncInProgress=0
    
    if [ "${numWifiAdaptors}" -eq 1 ]; then
      if ! connectToWifiNetwork "${wifiAdaptor}" "${homeWiFiSSID}" "${homeWiFiPassword}"; then
        exit 1 # We failed to connect to the wifi network
      fi
      ezShareConnected=0 # disables automatic reconnection to home wifi because we're already connected
    fi

    waitForConnectivity "${sleepHQAPIBaseURL}"

    # if there's no sleep data, there's no point continuing
    # user was probably uploading files only.
    if ! grep -qE ';DATALOG/[0-9]+/' ${transferListFile} 2>/dev/null; then
      echo
      echo "Data was synchronized from the SD card but none of it was sleep data."
      echo "This usually happens if configuration files have changed but you" 
      echo "haven't recorded new sleep data yet."
      storeLastRunTimestamp "$(date +%s)" "${lastRunFile}"
    else
      storeLastRunTimestamp "$(date +%s)" "${lastRunFile}"
      # If uploads to sleep HQ are enabled, create the zip file and upload it.
      if ${sleepHQuploadsEnabled}; then
        start="$(date +%s)"
        createSleepDataZipFile "${uploadZipFile}" "${transferListFile}"
        end="$(date +%s)"
        timeTaken="$(echo "${end}-${start}" | bc)"
        echo -e "\nZip file creation complete. Time taken: ${timeTaken} seconds.\n"

        # Disable trapping because API errors will cause the script to terminate prematurely with no explanation.
        trap - INT TERM EXIT

        start="$(date +%s)"

        # Generate an API token if necessary
        if [ -z "${sleepHQAccessToken}" ]; then
          echo -ne "\nConnecting to Sleep HQ..."
          sleepHQAccessToken=$(generateSleepHQAccessToken "${sleepHQAPIBaseURL}" "${sleepHQClientUID}" "${sleepHQClientSecret}")

          # Make sure we've got an access token.
          # If we've got an empty value for the ${sleepHQAccessToken}
          # we've failed to get one and can't continue
          if [ -z "${sleepHQAccessToken}" ]; then
            echo -e " ${red}FAILED!${reset}\n\nFailed to obtain a Sleep HQ API Access Token."
            echo "Make sure your Client UID and Secret are correct and"
            echo "you can access the https://sleephq.com website in your"
            echo "web browser."
            echo -e "\nDebug output for troubleshooting is shown below: "
            echo -e "\nCommand:"
            echo "curl -X 'POST' \"${sleepHQLoginURL}\""
            echo -ne "\nOutput: "
            curl -X 'POST' "${sleepHQLoginURL}"
            echo -e "\n\nCannot continue with upload... exiting now..."
            exit 1
          else
            echo -e " ${green} DONE!${reset}"
          fi
        fi

        # get the Sleep HQ team ID if necessary
        if [ -z "${sleepHQTeamID}" ];then
            echo -ne "\nObtaining Sleep HQ Team ID..."
            sleepHQTeamID=$(getSleepHQTeamID "${sleepHQAccessToken}" "${sleepHQAPIBaseURL}")
            # Team ID is expected to be a number. If it's not something went wrong.
            if ! [[ ${sleepHQTeamID} =~ ^[0-9]+$ ]]; then
              echo -e " ${red}FAILED!${reset}\n\nFailed to obtain your Sleep HQ Team ID. Debug output for troubleshooting is shownn below: "
              echo -e "\nCommand:"
              echo "curl \"${sleepHQAPIBaseURL}/api/v1/me\" -H 'accept: application/vnd.api+json' -H \"authorization: Bearer ${sleepHQAccessToken}\""
              echo -ne "\nOutput: "
              curl "${sleepHQAPIBaseURL}/api/v1/me" -H 'accept: application/vnd.api+json' -H "authorization: Bearer ${sleepHQAccessToken}"
              echo -e "\nCannot continue with upload... exiting now..."
              exit 1
            fi
            echo -e " ${green}DONE!${reset} Sleep HQ Team ID set to ${sleepHQTeamID}."
        fi

        # Create an Import task
        echo -ne "\nCreating Data Import task..."
        sleepHQImportTaskID=$(createImportTask "${sleepHQAccessToken}" "${sleepHQAPIBaseURL}" "${sleepHQTeamID}" "${sleepHQDeviceID}")
    

        # Import Task ID is expected to be a number. If it's not something went wrong.
        if ! [[ ${sleepHQImportTaskID} =~ ^[0-9]+$ ]]; then
          echo -e " ${red}FAILED!${reset}\n\nFailed to generate an Import Task ID. Debug output for troubleshooting is shownn below: \n"
          echo "Command:"
          echo -e "curl -X 'POST' \"${sleepHQImportTaskURL}\" -H 'accept: application/vnd.api+json' -H \"authorization: Bearer ${sleepHQAccessToken}\"\n"
          echo -n "Output: "
          curl -X 'POST' "${sleepHQImportTaskURL}" -H 'accept: application/vnd.api+json' -H "authorization: Bearer ${sleepHQAccessToken}"
          echo -e "\n\nCannot continue with upload... exiting now..."
          exit 1
        else
           echo -e "${green}DONE!${reset} Import Task ID: ${sleepHQImportTaskID}"
        fi  

        # Start trapping exit signals so we remove the
        # import task ID if anything goes wrong.
        trap exitFunction INT TERM EXIT

        sleepHQcontentHash=$(generateContentHash "${uploadZipFileName}")
        
        echo -ne "\nUploading ${uploadZipFileName} to Sleep HQ..."
        if uploadFileToSleepHQ "${sleepHQAccessToken}" "${sleepHQAPIBaseURL}" "${sleepHQImportTaskID}" "${uploadZipFileName}" "${sleepHQcontentHash}"
          then
          echo -e " ${green}DONE!${reset}"
          else
          echo -e " ${red}FAILED!${reset}"
          exit 1
        fi

        echo -e "\nBeginning Data Import processing of ${uploadZipFileName}...\n"
        triggerDataImport "${sleepHQAccessToken}" "${sleepHQAPIBaseURL}" "${sleepHQImportTaskID}"

        monitorImportProgress "${sleepHQAccessToken}" "${sleepHQAPIBaseURL}" "${sleepHQImportTaskID}"

        # Remove exit trapping because upload has either finished or been abandoned.
        trap - INT TERM EXIT

        end="$(date +%s)"
        timeTaken="$(echo "${end}-${start}" | bc)"
        echo -e "\nUpload to Sleep HQ complete. Time taken: ${timeTaken} seconds.\n"
      fi
    fi
  fi
fi

if ${o2RingSyncEnabled} && ${sleepHQuploadsEnabled}; then
  if ls "${sdCardDir}"/*.csv 1>/dev/null 2>&1; then
    echo -e "\nO2 Ring CSV files found in ${sdCardDir}. Uploading them to Sleep HQ."

    # Change the device ID to the "O2 Ring"
    sleepHQDeviceID="${o2RingDeviceID}"
    
    # Create a zip archive of the csv file(s)
    createO2RingDataZipFile "${uploadZipFile}"

    # Disable trapping because API errors will cause the script to terminate prematurely with no explanation.
    trap - INT TERM EXIT

    # Generate an API token if necessary
    if [ -z "${sleepHQAccessToken}" ]; then
      echo -ne "\nConnecting to Sleep HQ..."
      sleepHQAccessToken=$(generateSleepHQAccessToken "${sleepHQAPIBaseURL}" "${sleepHQClientUID}" "${sleepHQClientSecret}")

      # Make sure we've got an access token.
      # If we've got an empty value for the ${sleepHQAccessToken}
      # we've failed to get one and can't continue
      if [ -z "${sleepHQAccessToken}" ]; then
        echo -e " ${red}FAILED!${reset}\n\nFailed to obtain a Sleep HQ API Access Token."
        echo "Make sure your Client UID and Secret are correct and"
        echo "you can access the https://sleephq.com website in your"
        echo "web browser."
        echo -e "\nDebug output for troubleshooting is shownn below: "
        echo -e "\nCommand:"
        echo "curl -X 'POST' \"${sleepHQLoginURL}\""
        echo -ne "\nOutput: "
        curl -X 'POST' "${sleepHQLoginURL}"
        echo -e "\n\nCannot continue with upload... exiting now..."
        exit 1
      else
        echo -e " ${green}DONE!${reset}"
      fi
    fi

    # get the Sleep HQ team ID if necessary
    if [ -z "${sleepHQTeamID}" ];then
      echo -ne "\nObtaining Sleep HQ Team ID..."
      sleepHQTeamID=$(getSleepHQTeamID "${sleepHQAccessToken}" "${sleepHQAPIBaseURL}")
      # Team ID is expected to be a number. If it's not something went wrong.
      if ! [[ ${sleepHQTeamID} =~ ^[0-9]+$ ]]; then
        echo -e " ${red}FAILED!${reset}\n\nFailed to obtain your Sleep HQ Team ID. Debug output for troubleshooting is shown below: "
        echo -e "\nCommand:"
        echo "curl \"${sleepHQAPIBaseURL}/api/v1/me\" -H 'accept: application/vnd.api+json' -H \"authorization: Bearer ${sleepHQAccessToken}\""
        echo -ne "\nOutput: "
        curl "${sleepHQAPIBaseURL}/api/v1/me" -H 'accept: application/vnd.api+json' -H "authorization: Bearer ${sleepHQAccessToken}"
        echo -e "\nCannot continue with upload... exiting now..."
        exit 1
      fi
      echo -e " ${green}DONE!${reset} Sleep HQ Team ID set to ${sleepHQTeamID}."
    fi

    # Create an Import task
    echo -ne "\nCreating Data Import task..."
    sleepHQImportTaskID=$(createImportTask "${sleepHQAccessToken}" "${sleepHQAPIBaseURL}" "${sleepHQTeamID}" "${sleepHQDeviceID}")
    
    # Import Task ID is expected to be a number. If it's not something went wrong.
    if ! [[ ${sleepHQImportTaskID} =~ ^[0-9]+$ ]]; then
      echo -e " ${red}FAILED!${reset}\n\nFailed to generate an Import Task ID. Debug output for troubleshooting is shown below: \n"
      echo "Command:"
      echo -e "curl -X 'POST' \"${sleepHQImportTaskURL}\" -H 'accept: application/vnd.api+json' -H \"authorization: Bearer ${sleepHQAccessToken}\"\n"
      echo -n "Output: "
      curl -X 'POST' "${sleepHQImportTaskURL}" -H 'accept: application/vnd.api+json' -H "authorization: Bearer ${sleepHQAccessToken}"
      echo -e "\n\nCannot continue with upload... exiting now..."
      exit 1
    else
      echo -e " ${green}DONE!${reset}"
    fi  

    # Start trapping exit signals so we remove the
    # import task ID if anything goes wrong.
    trap exitFunction INT TERM EXIT

    sleepHQcontentHash=$(generateContentHash "${uploadZipFileName}")
    
    echo -e "\nUploading ${uploadZipFileName} to Sleep HQ..."
    uploadFileToSleepHQ "${sleepHQAccessToken}" "${sleepHQAPIBaseURL}" "${sleepHQImportTaskID}" "${uploadZipFileName}" "${sleepHQcontentHash}"

    echo -e "\nBeginning Data Import processing of ${uploadZipFileName} for Import Task ID ${sleepHQImportTaskID}..."
    triggerDataImport "${sleepHQAccessToken}" "${sleepHQAPIBaseURL}" "${sleepHQImportTaskID}"

    monitorImportProgress "${sleepHQAccessToken}" "${sleepHQAPIBaseURL}" "${sleepHQImportTaskID}"

    # Remove the csv files now they've been imported
    find "${sdCardDir}" -mindepth 1 -maxdepth 1 -type f -name "O2Ring*.csv" -exec rm -f "{}" \;

    trap - INT TERM EXIT
  fi
fi

overallEnd="$(date +%s)"
overallTimeTaken="$(echo "${overallEnd}-${overallStart}" | bc)"

echo -e "\nScript execution complete! Script execution time: ${overallTimeTaken} seconds."