#! /bin/bash -e
VERSION=3
# Script to sync data from an Ez Share WiFi SD card
# to a folder called "SD_Card" on the local users desktop.

# Exit function which makes sure we clean up
# after ourselves and reconnect to the home WiFi
# if we're not already connected to it.
exit_function() {
  test -f ${fileSyncLog} && rm -f ${fileSyncLog}
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
  lv="`curl -ks https://raw.githubusercontent.com/iitggithub/ezshare_cpap/main/sync.sh | grep "^# VERSION=" | cut -f2 -d '='`"
  cv="`grep "^# VERSION=" $0 | cut -f2 -d '='`"

  if [ -z "${cv}" ]
    then
    cv=0
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
if [ "`uname | grep -c Darwin`" -eq 0 ]
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

# Create the SD card directory if it doesn't exist
if [ ! -d ${sdCardDir} ]
  then
  echo "SD Card directory does not exist. Creating..."
  mkdir ${sdCardDir}
fi

# Default list of files to always include in upload zip file
fileList="${sdCardDir}/Identification.crc"
fileList="${fileList} ${sdCardDir}/Identification.tgt"
fileList="${fileList} ${sdCardDir}/Journal.dat"
fileList="${fileList} ${sdCardDir}/SETTINGS"
fileList="${fileList} ${sdCardDir}/STR.edf"

# Get the WiFi adaptor name. If there's multiple it
# will choose the first one in the list. Typically
# this is en0.
wifiAdaptor="`networksetup -listallhardwareports | grep -A1 'Wi-Fi' | grep 'Device' | head -1 | awk '{print $2}'`"

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
if [ -n "`networksetup -setairportnetwork ${wifiAdaptor} \"${homeWiFiSSID}\" \"${homeWiFiPassword}\"`" ]
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
  fileSyncLog="/var/tmp/sync.log"
  else
  fileSyncLog="/tmp/sync.log"
fi

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
    pip install ezshare || exit_function
    ezShareCLICmd="`which ezshare-cli`"
    echo
    else
    echo "Please install python on your mac, and then try again."
    exit 1
  fi
  else
  ezShareCLICmd="`which ezshare-cli`" 
fi

echo -n "Connecting to WiFi network '${ezShareWifiSSID}'... "
trap exit_function INT TERM EXIT
if [ -n "`networksetup -setairportnetwork ${wifiAdaptor} \"${ezShareWifiSSID}\" \"${ezShareWiFiPassword}\"`" ]
  then
  echo -e "\n\nFailed to connect to ez Share WiFi network. Please make sure your SSID and password"
  echo "are correct and the ez Share WiFi SD card is powered on."
  exit 1
fi
ezShareConnected=1 # Ensures we reconnect to the home wifi network if anything fails
echo "done!"

# Added to fix a bug in ezshare CLI which only adds files that have changed in size
# this meant that minor changes to settings were not be captured.
for target in ${fileList}
  do
  test -f ${target} && rm -f ${target}
  test -d ${target} && rm -rf ${target}
done

echo
echo "Starting SD card sync at `date`"
echo
${ezShareCLICmd} -w -r -d / -t ${sdCardDir}/ 2>&1 | tee ${fileSyncLog}

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
  fileList="${fileList} ${sdCardDir}/DATALOG/${dir}"
  lastDir="${dir}"
done

# Create the zip file if there's data to be uploaded
if [ -n "${firstDir}" ]
  then
  echo
  echo "Creating upload.zip file..."
  zip -r ${sdCardDir}/upload.zip ${fileList} && echo -e "\nCreated ${sdCardDir}/upload.zip file in ${sdCardDir} which includes dates ${firstDir} to ${lastDir}."
  else
  echo
  echo "No dates detected that needed to be synchronised."
  echo "This usually occurs when you've already synchronised the latest"
  echo "data from the SD card."
fi

echo
echo "Script execution complete!"
