# ezshare_cpap

Mac OSX script to pull CPAP Data from an Airsense 10 to a local machine for upload to SleepHQ. It might work with the Airsense 11 as well but I haven't tested it. Presumably if the directory structure and files are the same on the Airsense 11, it'll work no problem.

The script connects to the EZ Share WiFi SD card and synchronizes the data to a folder on your desktop called SD\_Card.

If there is sleep data, the script will create a zip file called upload.zip which you can use to upload the data to Sleep HQ. Using a zip file means quicker transmissions and less overhead since we're only uploading new sleep data.

The script doesn't store any WiFi credentials in the script itself. Instead, it will store them in your Login Keychain. When you first run the script, it will prompt you for the WiFi SSID and Password for both the Ez Share SD card, and your home WiFi network. Once these details are saved in your Keychain, you don't have to enter them again.

# Installation Pre-requisites

- A mac. Because the script only works on a mac
- Python3 installed on your mac

The ezshare-cli is built to work with Pytho 3. This guide doesn't go into installing Python 3 but you can download the macOS 64-bit universal2 installer for the latest stable version of Python3 from here: https://www.python.org/downloads/macos/ or you can try the homebrew method here: https://docs.python-guide.org/starting/install3/osx/

### How do i know if i have python installed?

Open a terminal and run the following command:

```
python3 -V
```

If you receive an error saying that the command was not found, you probably don't have python installed or it's not configured properly.

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

### Does it work with the Resmed Airsense 11?

I don't know... does it?

### Does it work with INSERT\_CPAP\_MACHINE\_HERE?

The only machine i've tested it with is the Airsense 10.

### Help! I entered the wrong WiFi credentials!

No problem. Open the Keychain application on your mac and search for ezshare. It will return up to 4 entries all named ezShare.

You'll need to double click on each one to see the Account field. The four fields are described below:

- ezShareWifiSSID
- ezShareWiFiPassword
- homeWiFiSSID
- homeWiFiPassword

Delete the entry or entries which are incorrect and run the script again. It will prompt you to re-enter those details again.
