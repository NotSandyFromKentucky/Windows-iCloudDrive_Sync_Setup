# Windows-iCloudDrive_Sync_Setup
This simple .bat file will create windows personal folders (Desktop, Documents, Pictures, Videos, Downloads) to your iCloud drive folder on windows.

## This script:
- Verifies iCloud Drive installation by checking for the iCloud folder in the current user's directory
- Automatically creates necessary folders in iCloud Drive
- Redirects Windows system folders to iCloud Drive locations
- Creates a backup of "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"
- Provides verbose, user-friendly output
- Requires administrator privileges

## Usage:

Run the script with administrator privileges.

## Recovery:

If you feel that system was fucked a little after changes,, run with admin created file RestoreRegistry.bat, this will restore state of registry folder befure execution.

although backup is done, do it at your own risk, windows registry no penis canina.


BR
Slava :3