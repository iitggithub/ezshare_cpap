# ezshare_cpap

This is a Mac OSX compatible bash script which is used to synchronize sleep data to your mac via an Ezshare Wifi SD card. It can also be used to automate the upload of your data to Sleep HQ.

The script connects to the EZ Share WiFi SD card and synchronizes the data to a folder on your desktop called SD\_Card.

# Features

### PAP Compatibility

If all you're looking to do is synchronize the contents of the SD card with your mac (for review in Oscar etc), then the script will work for both the Airsense 10 and 11 machines as the directory structure on both machines are the same.

For uploading of data to Sleep HQ however, the script has only been tested against the Airsense 10. It has not been confirmed whether it works with the Resmed Airsense 11 but the Identification.json and JOURNAL.JNL files are automatically included in the upload.zip file if they're present in the SD_Card directory.

### Credentials securely stored in your Keychain

The script doesn't store any WiFi credentials in the script itself or on the filesystem. Instead, it will store them in your Login Keychain. When you first run the script, it will prompt you for the WiFi SSID and Password for both the Ez Share SD card, and your home WiFi network. Once these details are saved in your Keychain, you don't have to enter them again.

### Sleep HQ integration

The script can be configured to automatically upload your data to Sleep HQ for review. The script will perform the upload provided that there is new sleep data since the last time the script was run.

### Automatic updates

The script is configured to automatically update itself so you don't have to. When new features are implemented or bugs are fixed, the script will automatically download the latest version, and execute it.

### Parallelised operations and faster directory searching

The script is designed to perform operations against the SD card in parallel. This includes:

1. Determining which directories on the SD card need to be checked
2. Determining which files need to be downloaded
3. Downloading files from the SD card

The SD card that was used for testing contained 283 days worth of sleep data. Using the previous incarnation of the script which used the Python 3 ezshare module, the script took 260 seconds to check 283 days worth of sleep data, download 1 days worth of sleep data and upload that data to Sleep HQ.

That same operation using the new script took 88 seconds to perform the same operations. The new script also provides timings for most of the stages so we can break that down as follows:

1. Determining which directories on the SD card need to be checked: 13 seconds (285 directories)
2. Determining which files need to be downloaded: 18 seconds
3. Downloading files from the SD card: 7 seconds (17 files(1 days worth of sleep data))
4. Creating a zip file to upload to Sleep HQ: 1 second
5. Uploading the zip file to Sleep HQ: 34 seconds
6. Misc operations (like connecting to different wifi networks, checking connectivity etc): 15 seconds

### o2r (Wellue O2Ring) Sleep HQ integration

The script will automatically send any csv files in the SD\_Card directory to Sleep HQ. This allows you to view Sp02, Movement, and pulse rate data alongside your CPAP therapy data charts. Simply download your data from the ViHealth app or via a tool such as o2r and save it as a CSV file, and place the files in the SD_Card directory on your Desktop. When you next run the script, it will automatically upload them to Sleep HQ.

### Change the SD Card storage location

As of version 17, the script can be configured to use a different directory to store the contents of your SD Card. When the script finds that the default SD card directory doesn't exist (/Users/YOUR_USERNAME/Desktop/SD_Card), a setup process is initiated. The script will ask for the correct location to store files and keep a record of that location in your keychain.

If you have existing data in your SD_Card directory and would like to move it, simply rename and/or move your existing SD card directory. The next time the script executes, it will ask for the new directory location and store the location in your keychain.

### Support for Multiple Wifi adaptors

If you have more than one wifi adaptor, the script will assume that you're using one of them to connect to the ezshare wifi SD card. It will no longer switch wifi networks. Should you disconnect the USB wifi adaptor, normal functionality is restored and wifi switching is re-enabled automatically.

This means it's now possible to turn a mac into a magic uploader! Simply run the script every 10 to 15 minutes and it'll upload new sleep data to Sleep HQ!

If you want to know how to enable it, see the FAQ section for more information.

# Installation Pre-requisites

NOTHING! Well, you need a mac... but that's it. The script is written so it requires no additional software/tools.

### Performing an initial sync

If you've got a lot of data on your SD card already, it's significantly quicker to connect your SD card directly to your mac and copy the contents of the SD Card into the SD_Card folder on your desktop. Once an initial sync has been performed subsequent executions will be much faster.

1. Remove the SD Card from your CPAP device
2. Connect it to your computer
3. Create a folder on your desktop called SD_Card (The name is case sensitive!)
4. Copy the contents of your SD Card into the newly created folder
5. Place the SD card back into your CPAP device

The next time you execute the script, it will search for any files that have been added since the last time the folder was synchronized.

# Installation Pre-requisites

1. An EZ Share Wifi SD Card. You can purchase them from [Ali Express](https://www.aliexpress.com/w/wholesale-ez-share-wifi-sd-card.html). I recommend purchasing more than one just in case they die.
2. Your sleep data on the SD Card.
3. The wifi details for the EZ Share Wifi SD card.
4. The wifi details for your home Wifi network.

# Installation

Open a terminal window and perform the following actions.

### 1. Download the sync.sh script

```
curl -o sync.sh https://raw.githubusercontent.com/iitggithub/ezshare_cpap/main/sync.sh
```

### 2. Make the script executable

```
chmod 755 sync.sh
```

That's it. The script is ready to use. The script will collect your WiFi details and Sleep HQ credentials when you first run it.

# Running the script

```
./sync.sh
```

# Frequently Asked Questions

### How do i upload O2 ring data to sleep HQ?

Once you've synchronized your O2 data to your phone in the ViHealth Android app, you need to perform the following steps for each entry you would like to export in your History.

1. Under History, choose the entry you'd like to export to bring up your Oxygen Level, Pulse Rate and Motion information for that session.
2. In the top-right corner of the app, tap the button to share the data.
3. For Format, choose CSV.
4. Choose Share.
5. Save the file somewhere and download it to your computer.
6. Move the file into the SD_Card directory on the Desktop of your mac. If this folder does not exist, create it.
7. Repeat steps 1 - 6 until all of your O2 Ring CSV files are in the SD_Card directory on your mac.
8. Run the sync.sh script. If you want to skip synchronizing your sleep data and upload only the O2 Ring data, execute the following instead:

```
./sync.sh --skip-sync
```

The O2 ring CSV files will be zipped and uploaded to Sleep HQ using your Sleep HQ API Credentials.

### How do i enabla automatic uploads to Sleep HQ?

If you've got an older version of the script, you need to update to at least version 9 when the functionality was first implemented. Running the script should trigger an automatic update to the latest version. You'll need your Client UID and Client Secret in order to begin. These are generated in the Account Settings page of Sleep HQ.

If you choose not to enable Sleep HQ uploads, it won't ask you again nor will it create an upload.zip file containing the files that have changed.

### My script isn't automatically updating itself

Either there's no update available or you're probably running the original version of the script which didn't include the automatic update feature. Simply re-install the script to obtain the latest version which includes this feature.

### Does it work with the Resmed Airsense 11?

I don't know... does it? Some noteable changes have been made to accomate the Airsense 11 such as the inclusion of the Identification.json and JOURNAL.JNL in the upload.zip file but it still needs testing by an Airsense 11 user for confirmation.

### Does it work with INSERT\_CPAP\_MACHINE\_HERE?

The only machine i've tested it with is the Airsense 10.

### Help! I entered the wrong credentials

You can run the commands below to remove specific entries in the keychain. When you next run the script, it will prompt you for that information again.

#### Remove the EZ Share Wifi credentials from your keychain

```
./sync.sh --remove-ezshare
```

#### Remove the home Wifi credentials from your keychain

```
./sync.sh --remove-home
```

#### Remove Sleep HQ credentials and the device ID from your keychain

```
./sync.sh --remove-sleephq
```

#### How do i remove all credentials

```
./sync.sh --remove-all
```

### How do i skip the SD Card sync

```
./sync.sh --skip-sync
```

### How do i skip Sleep HQ uploads (even if configured)

```
./sync.sh --skip-upload
```

### How do i skip the upload of o2 csv files?

```
./sync.sh --skip-o2sync
```

### How do i check which version of the script i'm running?

```
./sync.sh --version
```

### How do i change the number of files/directories to check in parallel?

```
./sync.sh --max-streams=X
```

Note that X should be a number equal to the number of parallel checks you'd like to run. Default is 15 files/directories checked in parallel.

### How do i change the number of files to download in parallel?

```
./sync.sh --max-downloads=X
```

Note that X should be a number equal to the number of parallel downloads you'd like to run. Default is 5 downloads in parallel.

### I deleted files in a directory, Why are they not being downloaded again?

The script keeps track of the contents of the SD card locally on the mac. In each directory there is a hidden html file (such as .SETTINGS.html in the SETTINGS directory). You will need to remove the file to force the directory to be checked.

```
rm -f /path/to/hidden/file
```

OR you can simply run the script with the --full-sync option which checks each file in every directory rather than just checking the directory itself.

```
./sync.sh --full-sync
```

### How do i setup multiple wifi adaptors?

Firstly, at the time of writing there aren't any wifi adaptors that are supported on Apple Silicon. Getting multiple wifi adaptors working in Mac OS requires a compatible wifi adaptor such as the TP-Link Archer T3U Plus AC1300 Wireless USB Adapter which can be purchased on [Amazon](https://a.co/d/ipqSiyv) for less than $20 USD. You can get a list of working adaptors and download the latest release from [Github](https://github.com/chris1111/Wireless-USB-Big-Sur-Adapter?tab=readme-ov-file).

You then need to disable System Integrity Protection (SIP) which can only be performed in Mac OS Recovery mode. Instructions for this as well as driver installation can be found [here](https://github.com/chris1111/Wireless-USB-Big-Sur-Adapter/discussions/115).

Once the driver is installed and you've rebooted, there will be a icon for the Wireless Network Utility in your notification bar.

You MUST use the USB wifi adaptor to connect to your HOME Wifi. DNS and routing priorities are higher for the USB wifi adaptor so if you connect the wifi the other way around, you won't be able to connect to the internet or your local network and the only website you'll be able to resolve will be the ezshare.card website.

Next, connect your built-in wifi adaptor to your ezshare wifi SD card wifi network.

Now you've got your secondary wifi adaptor connected, you can run the sync.sh script whenever you want without interrupting your connection to the internet.

Finally, you'll need configure the script to perform a sync periodically. The easiest way to do this is using the commands below:

1. Open a new terminal window
2. Download the EzshareSync.plist file to ~/Library/LaunchAgents

```
curl -o ~/Library/LaunchAgents/EzshareSync.plist https://raw.githubusercontent.com/iitggithub/ezshare_cpap/main/EzshareSync.plist
```

3. Modify the file and update the path to the sync.sh script. By default the script contains the following which you will most likely need to change:

```
  <key>ProgramArguments</key>
  <array>
    <string>/usr/local/bin/sync.sh</string>
    <string>--dedicated</string>
  </array>
```

If your script is in the Downloads folder for example, you would update it to the following:

```
  <key>ProgramArguments</key>
  <array>
    <string>/Users/MYUSER/Downloads/sync.sh</string>
    <string>--dedicated</string>
  </array>
```

Note that you will have to change MYUSER to the user you run the script as.

4. Tell launchd about it

```
launchctl load ~/Library/LaunchAgents/EzshareSync.plist
```

5. (Optional) Add ezshare.card to the /etc/hosts file

This will allow the web interface to be accessed via http://ezshare.card/

```
sudo cat | tee -a /etc/hosts <<EOF
192.168.4.1\tezshare.card
EOF
```

Note this isn't needed for the script to function since the directory listing can be directly accessed via http://192.168.4.1/dir?dir=A: but if you want to access the web interface for any other reason, you'll need to perform step 5.

6. Try it out!

Using this method will result in a sync being performed every 15 minutes as long as the user is logged into the mac.