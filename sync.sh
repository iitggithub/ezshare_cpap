#! /bin/bash -e
# VERSION=7
# Script to sync data from an Ez Share WiFi SD card
# to a folder called "SD_Card" on the local users desktop.

ezShareSyncInProgress=0 # Added to allow the removal of partially sync'd directories

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
        rm -rf ${sdCardDir}/DATALOG/${dir}
      done
    fi
    echo
    echo "Cleanup complete"
  fi
  test -f ${fileSyncLog} && rm -f ${fileSyncLog}
  test -f ${localFileList} && rm -f ${localFileList}
  test -f ${sdCardFileList} && rm -f ${sdCardFileList}

  if [[ ${ezShareConnected} -eq 1 ]]
    then
    echo
    echo -n "Reconnecting to home WiFi Network... "
    networksetup -setairportnetwork ${wifiAdaptor} "${homeWiFiSSID}" "${homeWiFiPassword}"
    echo "done!"
  fi
  trap - INT TERM EXIT
  exit
}

# Automatically updates the script to the latest version
# to make it easier for those who need it
version_check() {
  lv="`curl -ks -o - https://raw.githubusercontent.com/iitggithub/ezshare_cpap/main/sync.sh 2>/dev/null | grep "^# VERSION=" | cut -f2 -d '='`"
  cv="`grep "^# VERSION=" $0 2>/dev/null | cut -f2 -d '='`"

  if [ -z "${lv}" ]
    then
    lv=0 # something went wrong fetching latest version. Default to no update.
  fi

  if [ -z "${cv}" ]
    then
    cv=0 # this version of the script doesn't have version checking enabled. Try to force an update.
  fi

  if [ ${lv} -gt ${cv} ]
    then
    echo "Script update available. Auto-update from version ${cv} to ${lv} in progress..."
    curl -o $0 https://raw.githubusercontent.com/iitggithub/ezshare_cpap/main/sync.sh
    echo "Done. Relaunching $0"
    $0
    exit
  fi
}
version_check

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

# The location where SD card files will be synchronised:
sdCardDir="/Users/`whoami`/Desktop/SD_Card"
uploadZipFile="${sdCardDir}/upload.zip" # Zip file containing files needing to be uploaded

# Create the SD card directory if it doesn't exist
if [ ! -d ${sdCardDir} ]
  then
  echo "SD Card directory does not exist. Creating..."
  mkdir ${sdCardDir}
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
ezShareWifiSSID="`security find-generic-password -ga "ezShareWifiSSID" 2>&1 | grep "password" | cut -f2 -d '"'`"
ezShareWiFiPassword="`security find-generic-password -ga "ezShareWiFiPassword" 2>&1 | grep "password" | cut -f2 -d '"'`"
homeWiFiSSID="`security find-generic-password -ga "homeWiFiSSID" 2>&1 | grep "password" | cut -f2 -d '"'`"
homeWiFiPassword="`security find-generic-password -ga "homeWiFiPassword" 2>&1 | grep "password" | cut -f2 -d '"'`"

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
  read ezShareWifiSSID
  if [ -z "${ezShareWifiSSID}" ]
    then
    ezShareWifiSSID="ez Share"
  fi
  echo -n "Please enter the WiFi password for the ezShare Wifi Card (Default: '88888888'): "
  read ezShareWiFiPassword
  if [ -z "${ezShareWiFiPassword}" ]
    then
    ezShareWiFiPassword="88888888"
  fi
  while [ -z "${homeWiFiSSID}" ]
    do
    echo -n "Please enter the SSID of your home WiFi network: "
    read homeWiFiSSID
  done
  while [ -z "${homeWiFiPassword}" ]
    do
    echo -n "Please enter the WiFi password for your home WiFi network: "
    read homeWiFiPassword
  done
  # Create the necessary entries in the users Login keychain.
  # 
  security add-generic-password -T "/usr/bin/security" -U -a "ezShareWifiSSID" -s "ezShare" -w "${ezShareWifiSSID}"
  security add-generic-password -T "/usr/bin/security" -U -a "ezShareWiFiPassword" -s "ezShare" -w "${ezShareWiFiPassword}"
  security add-generic-password -T "/usr/bin/security" -U -a "homeWiFiSSID" -s "ezShare" -w "${homeWiFiSSID}"
  security add-generic-password -T "/usr/bin/security" -U -a "homeWiFiPassword" -s "ezShare" -w "${homeWiFiPassword}"
fi

# Make sure we can connect to the home WiFi network
# because there's not much point in continuing if the
# the user hasn't got their own WiFi details set correctly
echo
echo -n "Checking WiFi connectivity to ${homeWiFiSSID}... "
if [ -n "`networksetup -setairportnetwork ${wifiAdaptor} \"${homeWiFiSSID}\" \"${homeWiFiPassword}\" 2>/dev/null`" ]
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
localFileList="${tmpDir}/sync.localFileList.log"
sdCardFileList="${tmpDir}/sync.sdCardFileList.log"

# Check if the ezshare-cli command is available
# If not install it via pip if python is installed
# If python isn't installed, tell the user to go install it
if [ -z "`which ezshare-cli`" ]
  then
  echo "Can't find ezshare-cli utility."
  if [ -n "`which pip`" ]
    then
    echo
    echo "Installing ezshare-cli via pip.."
    echo
    pip install ezshare || exit
    ezShareCLICmd="`which ezshare-cli`"
    echo
    else
    echo "Please install python on your mac, and then try again."
    exit 1
  fi
  else
  ezShareCLICmd="`which ezshare-cli`" 
fi

trap exit_function INT TERM EXIT
attempt=0
while [ ${attempt} -lt 5 ]
  do
  echo -n "Connecting to WiFi network '${ezShareWifiSSID}'... "
  if [ -n "`networksetup -setairportnetwork ${wifiAdaptor} \"${ezShareWifiSSID}\" \"${ezShareWiFiPassword}\" 2>/dev/null`" ]
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

echo
echo "Starting SD card sync at `date`"
echo

# Generate a list of directories that are already present on the
# local system.
find ${sdCardDir}/DATALOG -mindepth 1 -maxdepth 1 -type d -name "20*" | awk -F '/' '{print $NF}' | sort -n | uniq >${localFileList}

ezShareSyncInProgress=1

# Get a list of directories in the DATALOG directory on the SD Card
# only sync the directories that are missing from the local system
# An arbitrary sleep value was also added because it sometimes takes
# a few seconds before the web interface can be accessed.
sleep 5
curl -s "http://192.168.4.1/dir?dir=DATALOG" | tee ${sdCardFileList}
touch ${fileSyncLog}
for dir in `cat ${sdCardFileList} | grep "DATALOG%5C20" | cut -f2 -d '"' | sed -e 's/dir\?dir=DATALOG%5C//' | sort -n | uniq`
  do
  echo "Checking ${dir}..."
  # If the directory exists on the sd card, but not in
  # the localFileList, we need to sync it to the local
  # filesystem
  if [ -z "`grep -o \"${dir}\" ${localFileList}`" ]
    then
    mkdir -vp ${sdCardDir}/DATALOG/${dir}
    echo "Connecting to ezshare card to sync DATALOG/${dir} to ${sdCardDir}/DATALOG/${dir}..."
    i=0
    while [ ${i} -lt 5 ]
      do
      echo "Connecting to ezshare card to sync /${remoteTargetFile} to ${target}..."
      ${ezShareCLICmd} -w -d DATALOG/${dir} -t ${sdCardDir}/DATALOG/${dir} 2>&1 | tee -a ${fileSyncLog}
      if [ $? -eq 0 ]
        then
        break # Break the loop if we've sync'd the file otherwise try again...
      fi
      sleep 5
      ((i+=1))
    done
  fi
done
ezShareSyncInProgress=0

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
  remoteTargetFile="`echo ${absTarget} | awk -F '/' '{print $NF}'`"
  if [ -f ${absTarget} ]
    then
    rm -f ${absTarget}
  fi
  if [ -d ${absTarget} ]
    then
    rm -rf ${absTarget}
    mkdir -p ${absTarget}
  fi
  i=0
  while [ ${i} -lt 5 ]
    do
    echo "Connecting to ezshare card to sync /${remoteTargetFile} to ${target}..."
    ${ezShareCLICmd} -w -d /${remoteTargetFile} -t ${absTarget} 2>&1 | tee -a ${fileSyncLog}
    if [ $? -eq 0 ]
      then
      break # Break the loop if we've sync'd the file otherwise try again...
    fi
    sleep 5
    ((i+=1))
  done
done

echo
echo "SD card sync complete at `date`"

echo
echo -n "Reconnecting to WiFi network '${homeWiFiSSID}'... "
networksetup -setairportnetwork ${wifiAdaptor} "${homeWiFiSSID}" "${homeWiFiPassword}"
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
  echo
  echo "Creating upload.zip file..."
  cd ${sdCardDir}
  test -f ${uploadZipFile} && rm -f ${uploadZipFile}
  zip -r ${uploadZipFile} ${fileList} && echo -e "\nCreated ${uploadZipFile} file in ${sdCardDir} which includes dates ${firstDir} to ${lastDir}."
  else
  echo
  echo "No dates detected that needed to be synchronised."
  echo "This usually occurs when you've already synchronised the latest"
  echo "data from the SD card."
fi

echo
echo "Script execution complete!"
