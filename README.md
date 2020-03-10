# PowerShell Profiles

Personal PowerShell profiles and themes.

## Install

```powershell
.\install.ps1 -ProfileName 'decoyjoe', 'psreadline'
```

Will create a new `$PROFILE.CurrentUserAllHosts` PowerShell profile file, if one doesn't exist, and load the given personal profiles. Use `-Force` to overwrite an existing profile file.

Available profiles are in the `profiles` directory.