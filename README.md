# PowerShell Profiles

Personal PowerShell profiles and themes.

## Install

```powershell
./install.ps1
```

The install script will create a new `$PROFILE.CurrentUserAllHosts` PowerShell profile file, if one doesn't exist, and
install the `default`, `psreadline` profiles and the `decoyjoe.pure` theme (by default).

Available profiles are in the `profiles` directory and custom themes are in `themes`.

Use `-Force` to overwrite an existing profile file.
