#! /bin/bash -e
# VERSION=9
#
# Change log:
#
# - Added support for Sleep HQ automated uploads
# - Added command line parameters to remove keychain entries
# - Fixed check for python 3 installation
# - Various bug fixes, error checking and quality of life improvements
#
# Script to sync data from an Ez Share WiFi SD card
# to a folder called "SD_Card" on the local users desktop.

# Make sure we only run the script on a mac
# Not sure what would happen if you ran it on Linux
# ... would probably break a lot of stuff..
if [ "`uname 2>/dev/null | grep -c Darwin`" -eq 0 ]
  then
  echo "This script can only be run on a Mac (Darwin)."
  exit 1
fi

# Make sure we're not the root user
# root user permissions are not necessary
if [ "`id -u`" -eq 0 ]
  then
  echo "Don't run this script as the root user!"
  exit 1
fi

ezShareSyncInProgress=0 # Added to allow the removal of partially sync'd directories
sleepHQuploadsEnabled=false # Determines whether to upload data to Sleep HQ
sleepHQAPIBaseURL="https://sleephq.com" # The base URL for the Sleep HQ API

# Uses output from the security command to provide
# more context as to the result of actions against
# keys in the users keychain.
verifyKeychainAction() {
  action="${1}" # ie delete, add or verify
  key="${2}" # The name of the key ie ezShareWifiSSID
  retVal="${3}" # The return value of the 
  output="${4}"

  if [ "${retVal}" -eq 0 ]
    then
    echo "Successfully performed ${action} against key ${key} in your keychain."
    else
    echo
    echo "Failed to perform ${action} against key ${key} in your keychain."
    echo "Error Code: ${retVal}"
    echo "Error Info: ${output}"
  fi
}

# Function that blocks script
# execution until internet
# connectivity has been restored.
waitForConnectivity() {
  target="${1}"

  local failCount=0
  while [ -z "`dig +short ${target} 2>/dev/null`" ]
    do
    sleep 5
    if [ ${failCount} -gt 12 ]
      then
      echo "Failed connectivity check to ${target}."
      echo "Please check network connectivity."
      echo
      echo "Cannot continue... exiting..."
      exit 1
    fi
     ((failCount++))
  done
}

# Iterate over command line arguments
case "${@}" in
  "--remove-sleephq")
    output="`security -q delete-generic-password -a sleepHQClientUID 2>&1`"
    verifyKeychainAction delete sleepHQClientUID $? "${output}"
    output="`security -q delete-generic-password -a sleepHQClientSecret 2>&1`"
    verifyKeychainAction delete sleepHQClientSecret $? "${output}"
    output="`security -q delete-generic-password -a sleepHQDeviceID 2>&1`"
    verifyKeychainAction delete sleepHQDeviceID $? "${output}"
    echo
    exit 0
  ;;
  "--remove-ezshare")
    output="`security -q delete-generic-password -a ezShareWifiSSID 2>&1`"
    verifyKeychainAction delete ezShareWifiSSID $? "${output}"
    output="`security -q delete-generic-password -a ezShareWiFiPassword 2>&1`"
    verifyKeychainAction delete ezShareWiFiPassword $? "${output}"
    echo
    exit 0
  ;;
  "--remove-home")
    output="`security -q delete-generic-password -a homeWiFiSSID 2>&1`"
    verifyKeychainAction delete homeWiFiSSID $? "${output}"
    output="`security -q delete-generic-password -a homeWiFiPassword 2>&1`"
    verifyKeychainAction delete homeWiFiPassword $? "${output}"
    echo
    exit 0
  ;;
  "--remove-all")
    bash "${0}" --remove-sleephq
    bash "${0}" --remove-ezshare
    bash "${0}" --remove-home
    exit 0
  ;;
  "-v"|"--version")
  echo "sync.sh version $(grep '^# VERSION=' "$0" 2>/dev/null | cut -f2 -d '=')"
  ;;
  "-h"|"--help")
    echo "sync.sh <options>"
    echo
    echo "Options:"
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
    echo "Remove all of the above:"
    echo "${0} --remove-all"
    exit 0
  ;;
esac

# Exit function which makes sure we clean up
# after ourselves and reconnect to the home WiFi
# if we're not already connected to it.
exit_function() {
  if [ ${ezShareSyncInProgress} -eq 1 ]
    then
    echo "Something went wrong with the sync. Rolling back changes in the DATALOG directory..."
    echo
    if [ -f ${fileSyncLog} ]
      then
      for dir in `cat ${fileSyncLog} | grep "100%" | cut -f1 -d ':' | grep DATALOG | awk -F '/' '{print $(NF -1)}' | sort | uniq`
        do
        echo "Removing ${sdCardDir}/DATALOG/${dir}"
        rm -rf "${sdCardDir}"/DATALOG/"${dir}"
      done
    fi
    echo
    echo "Cleanup complete"
  fi
  test -f ${fileSyncLog} && rm -f ${fileSyncLog}

  if [[ ${ezShareConnected} -eq 1 ]]
    then
    echo
    echo -n "Reconnecting to home WiFi Network... "
    networksetup -setairportnetwork "${wifiAdaptor}" "${homeWiFiSSID}" "${homeWiFiPassword}"
    echo "done!"
  fi

  # If we have a sleep HQ Team ID, delete it.
  # This only works if the access token is scoped
  # for a Delete operation. We don't check this output
  # because we don't mind if it fails.... at least we tried.
  if [ -n "${sleepHQImportTaskID}" ]
    then
    curl -s -X 'DELETE' "${sleepHQAPIBaseURL}/api/v1/imports/${sleepHQImportTaskID}?id=${sleepHQImportTaskID}" -H 'accept: application/vnd.api+json' -H "authorization: Bearer ${sleepHQAccessToken}" 2>&1 >/dev/null
  fi
  trap - INT TERM EXIT
  exit
}

# Automatically updates the script to the latest version
# to make it easier for those who need it
version_check() {
  lv="`curl -ks -o - https://raw.githubusercontent.com/iitggithub/ezshare_cpap/main/sync.sh 2>/dev/null | grep "^# VERSION=" | cut -f2 -d '='`"
  cv="`grep "^# VERSION=" "$0" 2>/dev/null | cut -f2 -d '='`"

  if [ -z "${lv}" ]
    then
    lv=0 # something went wrong fetching latest version. Default to no update.
  fi

  if [ -z "${cv}" ]
    then
    cv=0 # this version of the script doesn't have version checking enabled. Try to force an update.
  fi

  if [ "${lv}" -gt "${cv}" ]
    then
    echo "Script update available. Auto-update from version ${cv} to ${lv} in progress..."
    curl -o "$0" https://raw.githubusercontent.com/iitggithub/ezshare_cpap/main/sync.sh
    echo "Done. Relaunching $0"
    $0
    exit
  fi
}
version_check

# Check if Python 3 is installed and not the
# one that comes with Xcode developer tools
case "`which python3`" in
  ""|/usr/bin/python3)
    echo "Python 3 doesn't seem to be installed correctly on your mac."
    echo "Please install python 3 on your mac, and then try again."
    echo
    echo "Visit https://www.python.org/downloads/macos/ to download the latest version"
    echo "Follow the instructions to install python 3 before restarting your computer"
    echo "and executing the script again."
    echo
    echo "If you've just installed Python 3, try restarting your computer and try again."
    echo
    exit 1
  ;;
  *)
  python3cmd="`which python3`"
  ;;
esac

# Check if the ezshare-cli command is available
# If not install it via pip if python is installed
# If python isn't installed, tell the user to go install it
if [ -z "`which ezshare-cli`" ]
  then
  echo "Can't find ezshare-cli utility."
  echo "Installing ezshare-cli via pip.."
  echo
  pip3 install ezshare || exit
  ezShareCLICmd="`which ezshare-cli`"
  echo
  else
  ezShareCLICmd="`which ezshare-cli`" 
fi

# The location where SD card files will be synchronised:
sdCardDir="/Users/`whoami`/Desktop/SD_Card"
uploadZipFileName="upload.zip"
uploadZipFile="${sdCardDir}/${uploadZipFileName}" # Zip file containing files needing to be uploaded

# Create the SD card directory if it doesn't exist
if [ ! -d "${sdCardDir}" ]
  then
  echo "SD Card directory does not exist. Creating..."
  mkdir "${sdCardDir}"
fi

# Default list of files to always include in upload zip file
fileList="Identification.crc"
fileList="${fileList} Identification.tgt"
fileList="${fileList} Journal.dat"
fileList="${fileList} SETTINGS"
fileList="${fileList} STR.edf"

# Get the WiFi adaptor name. If there's multiple it
# will choose the first one in the list. Typically
# this is en0.
wifiAdaptor="`networksetup -listallhardwareports 2>/dev/null | grep -A1 'Wi-Fi' | grep 'Device' | head -1 | awk '{print $2}'`"

# Can't continue without a WiFi adaptor...
if [ -z "${wifiAdaptor}" ]
  then
  echo "No WiFi adaptor found. Below are the wifi adaptors we found"
  echo "using the command: \"networksetup -listallhardwareports | grep -A1 'Wi-Fi'\""
  networksetup -listallhardwareports | grep -A1 'Wi-Fi'
  exit 1
fi

# Check to see if we can successfully pull WiFi Credentials
# from the users Login keychain.
ezShareWifiSSID="`security find-generic-password -ga "ezShareWifiSSID" 2>&1 | grep password | cut -f2- -d '"' | sed -e 's/^"//' -e 's/"$//'`"
ezShareWiFiPassword="`security find-generic-password -ga "ezShareWiFiPassword" 2>&1 | grep password | cut -f2- -d '"' | sed -e 's/^"//' -e 's/"$//'`"
homeWiFiSSID="`security find-generic-password -ga "homeWiFiSSID" 2>&1 | grep password | cut -f2- -d '"' | sed -e 's/^"//' -e 's/"$//'`"
homeWiFiPassword="`security find-generic-password -ga "homeWiFiPassword" 2>&1 | grep password | cut -f2- -d '"' | sed -e 's/^"//' -e 's/"$//'`"

# If any of the credentials do not exist
# prompt the user to create them.
if [ -z "${ezShareWifiSSID}" ] ||
   [ -z "${ezShareWiFiPassword}" ] ||
   [ -z "${homeWiFiSSID}" ] ||
   [ -z "${homeWiFiPassword}" ]
  then
  echo "Couldn't find WiFi details in your Login keychain. Setup process will"
  echo "now begin. Press enter to accept defaults if there are any."
  echo "Please note you may need to enter your password to make changes to"
  echo "your Login keychain."
  echo
  echo -n "Please enter the WiFi SSID of the ezShare Wifi Card (Default: 'ez Share'): "
  read -r ezShareWifiSSID
  if [ -z "${ezShareWifiSSID}" ]
    then
    ezShareWifiSSID="ez Share"
  fi
  echo -n "Please enter the WiFi password for the ezShare Wifi Card (Default: '88888888'): "
  read -r ezShareWiFiPassword
  if [ -z "${ezShareWiFiPassword}" ]
    then
    ezShareWiFiPassword="88888888"
  fi
  while [ -z "${homeWiFiSSID}" ]
    do
    echo -n "Please enter the SSID of your home WiFi network: "
    read -r homeWiFiSSID
  done
  while [ -z "${homeWiFiPassword}" ]
    do
    echo -n "Please enter the WiFi password for your home WiFi network: "
    read -r homeWiFiPassword
  done
  # Create the necessary entries in the users Login keychain 
  security add-generic-password -T "/usr/bin/security" -U -a "ezShareWifiSSID" -s "ezShare" -w "${ezShareWifiSSID}"
  security add-generic-password -T "/usr/bin/security" -U -a "ezShareWiFiPassword" -s "ezShare" -w "${ezShareWiFiPassword}"
  security add-generic-password -T "/usr/bin/security" -U -a "homeWiFiSSID" -s "ezShare" -w "${homeWiFiSSID}"
  security add-generic-password -T "/usr/bin/security" -U -a "homeWiFiPassword" -s "ezShare" -w "${homeWiFiPassword}"
fi

# Determines whether to upload data to Sleep HQ
sleepHQuploadsEnabled=false
sleepHQAPIBaseURL="https://sleephq.com"

# Sleep HQ Upload Credentials
sleepHQClientUID="`security find-generic-password -ga "sleepHQClientUID" 2>&1 | grep password | cut -f2- -d '"' | sed -e 's/^"//' -e 's/"$//'`"
sleepHQClientSecret="`security find-generic-password -ga "sleepHQClientSecret" 2>&1 | grep password | cut -f2- -d '"' | sed -e 's/^"//' -e 's/"$//'`"
sleepHQDeviceID="`security find-generic-password -ga "sleepHQDeviceID" 2>&1 | grep password | cut -f2- -d '"' | sed -e 's/^"//' -e 's/"$//'`"

# If any of the credentials do not exist
# it's assumed that they've never been asked to create them
# Explicitly saying "n" will permanently disable this check.
if [ -z "${sleepHQClientUID}" ] ||
   [ -z "${sleepHQClientSecret}" ]
  then
  echo -n "Would you like to enable automatic uploads to SleepHQ? (y/n): "
  read -r answer

  case "${answer}" in
    [yY][eE][sS]|[yY])
      echo
      while [ -z "${sleepHQClientUID}" ]
        do
        echo -n "Please enter your Sleep HQ Client UID: "
        read -r sleepHQClientUID
      done
      echo
      while [ -z "${sleepHQClientSecret}" ]
        do
        echo -n "Please enter your Sleep HQ Client Secret: "
        read -r sleepHQClientSecret
      done

      # Create the necessary entries in the users Login keychain. 
      security add-generic-password -T "/usr/bin/security" -U -a "sleepHQClientUID" -s "ezShare" -w "${sleepHQClientUID}"
      security add-generic-password -T "/usr/bin/security" -U -a "sleepHQClientSecret" -s "ezShare" -w "${sleepHQClientSecret}"

      # Make sure the Client UID and Client Secret were added to the keychain
      if [ "${sleepHQClientUID}" == "`security find-generic-password -ga "sleepHQClientUID" 2>&1 | grep password | cut -f2- -d '"' | sed -e 's/^"//' -e 's/"$//'`" ] &&
         [ "${sleepHQClientSecret}" == "`security find-generic-password -ga "sleepHQClientSecret" 2>&1 | grep password | cut -f2- -d '"' | sed -e 's/^"//' -e 's/"$//'`" ]
        then
        echo
        echo "Sleep HQ Client UID ( sleepHQClientUID ) and Client Secret ( sleepHQClientSecret ) are now saved to your keychain."
        echo

        echo
        echo -n "Testing Sleep HQ API Credentials... "
        sleepHQLoginURL="${sleepHQAPIBaseURL}/oauth/token?"
        sleepHQLoginURL="${sleepHQLoginURL}client_id=${sleepHQClientUID}"
        sleepHQLoginURL="${sleepHQLoginURL}&client_secret=${sleepHQClientSecret}"
        sleepHQLoginURL="${sleepHQLoginURL}&grant_type=password"
        sleepHQLoginURL="${sleepHQLoginURL}&scope=read%20write"

        # Get the access token which is needed to upload the files
        sleepHQAccessToken="`curl -s -X 'POST' "${sleepHQLoginURL}" 2>/dev/null | ${python3cmd} -c "import json;import sys;print(json.load(sys.stdin)['access_token'])" 2>/dev/null`"

        # Make sure we've got an access token.
        # If we've got an empty value for the ${sleepHQAccessToken}
        # we've failed to get one and can't continue
        if [ -z "${sleepHQAccessToken}" ]
          then
          echo
          echo "Failed to obtain a Sleep HQ API Access Token."
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
          bash "${0}" --remove-sleephq
          exit 1
          else
          echo "PASS!"
        fi

        # Ask the user to provide their device type
        echo
        echo -n "What kind of CPAP device are you using with automated uploads? Enter an ID from the list below: "
        echo
        curl -s -X 'GET' "${sleepHQAPIBaseURL}/api/v1/devices" -H 'accept: application/vnd.api+json' -H "authorization: Bearer ${sleepHQAccessToken}" | ${python3cmd} -c "import json, sys; print('Device ID\tDevice Type'); print('\n'.join([str(x['id']) + '\t\t' + x['attributes']['name'] for x in json.load(sys.stdin)['data']]))"
        echo 
        echo -n "Device ID: "
        read -r sleepHQDeviceID
        security add-generic-password -T "/usr/bin/security" -U -a "sleepHQDeviceID" -s "ezShare" -w "${sleepHQDeviceID}"

        if [ "${sleepHQDeviceID}" == "`security find-generic-password -ga "sleepHQDeviceID" 2>&1 | grep password | cut -f2- -d '"' | sed -e 's/^"//' -e 's/"$//'`" ]
          then
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
   [ -n "${sleepHQClientSecret}" ]
  then
  sleepHQuploadsEnabled=true
fi

# Make sure we can connect to the home WiFi network
# because there's not much point in continuing if the
# the user hasn't got their own WiFi details set correctly
echo
echo -n "Checking WiFi connectivity to ${homeWiFiSSID}... "
if [ -n "`networksetup -setairportnetwork "${wifiAdaptor}" \"${homeWiFiSSID}\" \"${homeWiFiPassword}\" 2>/dev/null`" ]
  then
  echo -e "\n\nFailed to connect to the WiFi network '${homeWiFiSSID}'."
  echo "Continuing will potentially leave you unable to connect to your"
  echo "home WiFi network. Please make sure your homeWiFiSSID and homeWiFiPassword"
  echo "are set correctly. Search for \"ezshare\" (without quotes) in your"
  echo "Login keychain."
  exit 1
fi
echo "PASS!"

# Set a default path to the file sync log
# The file is used to determine which directories
# need to be added to the zip file
if [ -d "/var/tmp" ]
  then
  tmpDir="/var/tmp"
  else
  tmpDir="/tmp"
fi

fileSyncLog="${tmpDir}/sync.log"

trap exit_function INT TERM EXIT
attempt=0
while [ ${attempt} -lt 5 ]
  do
  echo -n "Connecting to WiFi network '${ezShareWifiSSID}'... "
  if [ -n "`networksetup -setairportnetwork "${wifiAdaptor}" \"${ezShareWifiSSID}\" \"${ezShareWiFiPassword}\" 2>/dev/null`" ]
    then
    echo -e "\n\nFailed to connect to ez Share WiFi network."
    echo
    echo -n "Trying again in 10 seconds or press Control + C to exit"
    i=0
    while [ ${i} -lt 10 ]
      do
      echo -n "."
      sleep 1
      ((i+=1))
    done
    echo
    echo
    else
    echo "done!"
    ezShareConnected=1 # Ensures we reconnect to the home wifi network if anything fails
    break # we're connected to the WiFi network now..
  fi
  ((attempt+=1))
done

# Make sure we don't continue if 5 attempts if attempts > 5
# this means we tried and failed to connect the EzShare WiFi network
if [ ${attempt} -eq 5 ]
  then
  echo -e "\n\nFailed to connect to ez Share WiFi network. Please make sure your SSID and password"
  echo "are correct and the ez Share WiFi SD card is powered on."
  exit 1
fi

# Added to fix a bug in ezshare CLI which only adds files that have changed in size
# this meant that minor changes to settings were not be captured.
for target in ${fileList}
  do
  absTarget="${sdCardDir}/${target}"
  if [[ ${absTarget} =~ ^/$ ]]
    then
    echo "Skipping removal of target ${absTarget}. This is almost certainly a bug"
    echo "and should be reported here: https://github.com/iitggithub/ezshare_cpap/issues"
    continue
  fi
  #remoteTargetFile="`echo ${absTarget} | awk -F '/' '{print $NF}'`"
  if [ -f "${absTarget}" ]
    then
    rm -f "${absTarget}"
  fi
  if [ -d "${absTarget}" ]
    then
    rm -rf "${absTarget}"
  fi
done

echo
echo "Starting SD card sync at `date`"
echo

ezShareSyncInProgress=1
touch ${fileSyncLog}
i=0
while [ ${i} -lt 5 ]
  do
  echo "Connecting to ezshare card to synchronize SD card contents to ${sdCardDir}/"
  ${ezShareCLICmd} -w -r -d / -t "${sdCardDir}"/ 2>&1 | tee ${fileSyncLog}
  if [ $? -eq 0 ]
    then
    break # Break the loop if we've sync'd the file otherwise try again...
  fi
  sleep 5 # Try again in 5 seconds
  ((i+=1))
done
ezShareSyncInProgress=0

echo
echo "SD card sync complete at `date`"

echo
echo -n "Reconnecting to WiFi network '${homeWiFiSSID}'... "
networksetup -setairportnetwork "${wifiAdaptor}" "${homeWiFiSSID}" "${homeWiFiPassword}"
waitForConnectivity "`echo ${sleepHQAPIBaseURL} | sed -e 's/https:\/\///'`"
echo "done!"
ezShareConnected=0 # disables automatic reconnection to home wifi

firstDir=""
lastDir=""

# Add the remaining directories to the list
for dir in `cat ${fileSyncLog} | grep "100%" | cut -f1 -d ':' | grep DATALOG | awk -F '/' '{print $(NF -1)}' | sort | uniq`
  do
  if [ -z "${firstDir}" ]
    then
    firstDir="${dir}"
  fi
  fileList="${fileList} DATALOG/${dir}"
  lastDir="${dir}"
done

# Create the zip file if there's data to be uploaded
if [ -n "${firstDir}" ]
  then
  if [ ${sleepHQuploadsEnabled} ]
    then
    echo -e "\nCreating upload.zip file..."
    cd "${sdCardDir}"
    test -f "${uploadZipFile}" && rm -f "${uploadZipFile}"
    zip -r "${uploadZipFile}" ${fileList} && echo -e "\nCreated ${uploadZipFile} file in ${sdCardDir} which includes dates ${firstDir} to ${lastDir}."

    # Don't bother continuing if the zip file hasn't been created.
    if [ ! -f "${uploadZipFile}" ]
      then
      echo
      echo "Failed to create ${uploadZipFile} file in ${sdCardDir}."
      echo "Cannot continue with automatic upload. Please upload your data manually."
      echo
      exit 1
    fi

    if [ -z "${sleepHQAccessToken}" ]
      then
      # Login
      sleepHQLoginURL="${sleepHQAPIBaseURL}/oauth/token?"
      sleepHQLoginURL="${sleepHQLoginURL}client_id=${sleepHQClientUID}"
      sleepHQLoginURL="${sleepHQLoginURL}&client_secret=${sleepHQClientSecret}"
      sleepHQLoginURL="${sleepHQLoginURL}&grant_type=password"
      sleepHQLoginURL="${sleepHQLoginURL}&scope=read%20write"

      # Get the access token which is needed to upload the files
      echo
      echo "Connecting to Sleep HQ..."
      sleepHQAccessToken="`curl -s -X 'POST' "${sleepHQLoginURL}" 2>/dev/null | ${python3cmd} -c "import json;import sys;print(json.load(sys.stdin)['access_token'])" 2>/dev/null`"
    fi

    # Make sure we've got an access token.
    # If we've got an empty value for the ${sleepHQAccessToken}
    # we've failed to get one and can't continue
    if [ -z "${sleepHQAccessToken}" ]
      then
      echo
      echo "Failed to obtain a Sleep HQ API Access Token."
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
      echo "Cannot continue with upload... exiting now..."
      exit 1
    fi

    # Get the team ID
    echo
    echo "Obtaining Sleep HQ Team ID..."
    sleepHQTeamID="`curl -s -X 'GET' "${sleepHQAPIBaseURL}/api/v1/me" -H 'accept: application/vnd.api+json' -H "authorization: Bearer ${sleepHQAccessToken}" 2>/dev/null | ${python3cmd} -c "import json;import sys;print(json.load(sys.stdin)['data']['current_team_id'])" 2>/dev/null`"

    # Team ID is expected to be a number. If it's not something went wrong.
    if ! [[ ${sleepHQTeamID} =~ ^[0-9]+$ ]]
      then
      echo
      echo "Failed to obtain your Sleep HQ Team ID. Debug output for troubleshooting is shownn below: "
      echo
      echo "Command:"
      echo "curl -X 'GET' \"${sleepHQAPIBaseURL}/api/v1/me\" -H 'accept: application/vnd.api+json' -H \"authorization: Bearer ${sleepHQAccessToken}\""
      echo
      echo -n "Output: "
      curl -X 'GET' "${sleepHQAPIBaseURL}/api/v1/me" -H 'accept: application/vnd.api+json' -H "authorization: Bearer ${sleepHQAccessToken}"
      echo
      echo "Cannot continue with upload... exiting now..."
      exit 1
    fi

    # Create an Import task
    echo
    echo "Creating Data Import task..."
    sleepHQImportTaskURL="${sleepHQAPIBaseURL}/api/v1/teams/${sleepHQTeamID}/imports?"
    sleepHQImportTaskURL="${sleepHQImportTaskURL}team_id=${sleepHQTeamID}&"
    sleepHQImportTaskURL="${sleepHQImportTaskURL}programatic=true&"
    sleepHQImportTaskURL="${sleepHQImportTaskURL}device_id=${sleepHQDeviceID}"
    sleepHQImportTaskID="`curl -s -X 'POST' "${sleepHQImportTaskURL}" -H 'accept: application/vnd.api+json' -H "authorization: Bearer ${sleepHQAccessToken}" 2>/dev/null | ${python3cmd} -c "import json;import sys;print(json.load(sys.stdin)['data']['attributes']['id'])" 2>/dev/null`"

    # Import Task ID is expected to be a number. If it's not something went wrong.
    if ! [[ ${sleepHQImportTaskID} =~ ^[0-9]+$ ]]
      then
      echo
      echo "Failed to generate an Import Task ID. Debug output for troubleshooting is shownn below: "
      echo
      echo "Command:"
      echo "curl -X 'POST' \"${sleepHQImportTaskURL}\" -H 'accept: application/vnd.api+json' -H \"authorization: Bearer ${sleepHQAccessToken}\""
      echo
      echo -n "Output: "
      curl -X 'POST' "${sleepHQImportTaskURL}" -H 'accept: application/vnd.api+json' -H "authorization: Bearer ${sleepHQAccessToken}"
      echo
      echo
      echo "Cannot continue with upload... exiting now..."
      exit 1
    fi

    # Start trapping exit signals so we remove the
    # import task ID if anything goes wrong.
    trap exit_function INT TERM EXIT

    # Generate content hash
    # Takes the contents of the file to be uploaded and appends "upload.zip"
    # which is the name of the file being uploaded to the end of the string.
    # Finally it performs an md5sum of the entire string
    sleepHQcontentHash="`(cat ${uploadZipFileName} ; echo "${uploadZipFileName}") | md5 -q`"

    # Add zip file to import task
    sleepHQImportFileURL="${sleepHQAPIBaseURL}/api/v1/imports/${sleepHQImportTaskID}/files?"
    sleepHQImportFileURL="${sleepHQImportFileURL}import_id=${sleepHQImportTaskID}&"
    sleepHQImportFileURL="${sleepHQImportFileURL}name=${uploadZipFileName}&"
    sleepHQImportFileURL="${sleepHQImportFileURL}path=.%2F&"
    sleepHQImportFileURL="${sleepHQImportFileURL}content_hash=${sleepHQcontentHash}"

    # Import the file
    echo
    echo "Uploading ${uploadZipFileName} to Sleep HQ..."
    curl -s -X 'POST' "${sleepHQImportFileURL}" -H 'accept: application/vnd.api+json' -H "authorization: Bearer ${sleepHQAccessToken}" -F "file=@${uploadZipFileName}" >/dev/null

    # process the import
    echo
    echo "Beginning Data Import processing of ${uploadZipFileName} for Import Task ID ${sleepHQImportTaskID}..."
    curl -s -X 'POST' "${sleepHQAPIBaseURL}/api/v1/imports/${sleepHQImportTaskID}/process_files?id=${sleepHQImportTaskID}" -H 'accept: application/vnd.api+json' -H "authorization: Bearer ${sleepHQAccessToken}" >/dev/null

    # wait for upload to complete
    progress=0
    prevProgress=0
    failCounter=0
    while [ "${progress}" -lt 100 ]
      do
      if [ "${progress}" -ne 0 ]
        then
        sleep 5 # Add a 5 second sleep timer to avoid API throttling
      fi
      progress="`curl -s -X 'GET' "https://sleephq.com/api/v1/imports/${sleepHQImportTaskID}" -H 'accept: application/vnd.api+json' -H "authorization: Bearer ${sleepHQAccessToken}" 2>/dev/null | ${python3cmd} -c "import json;import sys;print(json.load(sys.stdin)['data']['attributes']['progress'])"`"
      echo -ne "Progress: ${progress}% complete...\r"
      if [ ${prevProgress} -eq "${progress}" ]
        then
        if [ ${failCounter} -eq 12 ]
          then
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
    echo -ne '\n'
    # Remove exit trapping because upload has either finished or been abandoned.
    trap - INT TERM EXIT
    else
    echo -e "\nSuccessfully synchronized dates from  ${firstDir} to ${lastDir}."
  fi
  else
  echo -e "\nNo dates detected that needed to be synchronised."
  echo "This usually occurs when you've already synchronised the latest"
  echo "data from the SD card."
fi

echo
echo "Script execution complete!"
