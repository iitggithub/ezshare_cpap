# ezshare_cpap

Mac OSX script to pull CPAP Data from an Airsense 10 to a local machine for upload to SleepHQ. It might work with the Airsense 11 as well but I haven't tested it. Presumably if the directory structure and files are the same on the Airsense 11, it'll work no problem.

The script connects to the EZ Share WiFi SD card and synchronizes the data to a folder on your desktop called SD\_Card.

If there is sleep data, the script will create a zip file called upload.zip which you can use to upload the data to Sleep HQ. Using a zip file means quicker transmissions and less overhead since we're only uploading new sleep data.

The script doesn't store any WiFi credentials in the script itself. Instead, it will store them in your Login Keychain. When you first run the script, it will prompt you for the WiFi SSID and Password for both the Ez Share SD card, and your home WiFi network. Once these details are saved in your Keychain, you don't have to enter them again.

The script will automatically update itself when new features are added so you don't have to.

# Installation Pre-requisites

- A mac. Because the script only works on a mac
- Python3 installed on your mac (not the version installed via Xcode developer tools)

The ezshare-cli is built to work with Python 3. This guide doesn't go into installing Python 3 but you can download the macOS 64-bit universal2 installer for the latest stable version of Python3 from here: https://www.python.org/downloads/macos/ or you can try the homebrew method here: https://docs.python-guide.org/starting/install3/osx/

### How do i know if i have python installed?

Open a terminal and run the following command:

```
python3 -V
```

If you receive an error saying that the command was not found, you probably don't have python installed or it's not configured properly.

### Why do i need to install the official version of Python 3 when Mac already provides Python 3?

Because of incompatibilities between the Apple-provided version which really is designed for system use rather than use by external parties like you and me. If you want to read more information on the matter, see this topic which explains it in more detail:

https://github.com/urllib3/urllib3/issues/3020

# Installation

Open a terminal window and perform the following actions.

### Download the sync.sh script

```
curl -o sync.sh https://raw.githubusercontent.com/iitggithub/ezshare_cpap/main/sync.sh
```

### Make the script executable

```
chmod 755 sync.sh
```

That's it. The script is ready to use. The script will install the ezshare CLI and collect your WiFi details when you first run it.

# Running the script

```
./sync.sh
```

# Frequently Asked Questions

### How do i enabla automatic uploads to Sleep HQ?

If you've got an older version of the script, it will automatically update to version 9 which includes the functionality required interact with Sleep HQ. You'll need your Client UID and Client Secret in order to begin. These are generated in the Account Settings page of Sleep HQ.

If you choose not to enable Sleep HQ uploads, it won't ask you again nor will it create an upload.zip file containing the files that have changed.

### My script isn't automatically updating itself

Either there's no update available or you're probably running the original version of the script which didn't include the automatic update feature. Simply re-install the script to obtain the latest version which includes this feature.

### Does it work with the Resmed Airsense 11?

I don't know... does it?

### Does it work with INSERT\_CPAP\_MACHINE\_HERE?

The only machine i've tested it with is the Airsense 10.

### I get an AttributeError when trying to sync files

If you're seeing an error ending with something like this:

```
...
    for k,v in dirlist.items():
               ^^^^^^^^^^^^^
AttributeError: 'NoneType' object has no attribute 'items'
```

It's an issue with the files on the SD Card. Remove the SD Card from the machine and insert it into your computer. Create a blank file in the root directory of the SD card called "ezshare.cfg" (without quotes). Reinsert the SD card into the machine and try again.

The ezshare-cli command assumes that a directory will contain links to '.', '..', or 'ezshare.cfg' which is how it determines if it's in a valid directory. Since . and .. are only present in sub directories, this error usually only occurs in the root directory. Because of this, creating the ezshare.cfg file in the root directory is the only known workaround at present.

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

#### Do all of the above ^

```
./sync.sh --remove-all
```
