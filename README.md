# PowerShell Profiles

Personal PowerShell profiles and themes.

## Install

```powershell
.\install.ps1 -ProfileName 'decoyjoe', 'psreadline' -ThemeName 'decoyjoe.pure'
```

Will create a new `$PROFILE.CurrentUserAllHosts` PowerShell profile file, if one doesn't exist, and load the given personal profiles and the `decoyjoe.pure` _oh-my-posh_ theme.

Available profiles are in the `profiles` directory and custom themes are in `oh-my-posh_themes`.

Use `-Force` to overwrite an existing profile file.
