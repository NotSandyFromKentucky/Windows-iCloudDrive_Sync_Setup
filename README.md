# Windows-iCloudDrive_Sync_Setup
This simple .bat file will create windows personal folders (Desktop, Documents, Pictures, Videos, Downloads) to your iCloud drive folder on windows.

## This script:
- Verifies iCloud Drive installation by checking for the iCloud folder in the current user's directory
- Automatically creates necessary folders in iCloud Drive
- Redirects Windows system folders to iCloud Drive locations
- Creates a backup of "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"
- Provides verbose, user-friendly output
- Requires administrator privileges


## Download
Download archive from release https://github.com/NotSandyFromKentucky/Windows-iCloudDrive_Sync_Setup/releases/tag/Release

### OR

Copy file set_onedrivefolder.bat from https://github.com/NotSandyFromKentucky/Windows-iCloudDrive_Sync_Setup/blob/6f6f01653080d0669771d5feb4988c24688ab2c0/set_onedrivefolder.bat and save locally.

## Usage:

Run the script with administrator privileges.

## Recovery:

If you feel that system was fucked a little after changes,, run with admin created file RestoreRegistry.bat, this will restore state of registry folder befure execution.

although backup is done, do it at your own risk, windows registry no penis canina.


#### BR
#### Slava :3
