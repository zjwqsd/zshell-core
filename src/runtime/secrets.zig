pub const device_token_environment = "ZSHELL_DEVICE_TOKEN";

pub const powershell_clear =
    "$env:ZSHELL_DEVICE_TOKEN=$null; ";

pub const posix_clear =
    "unset ZSHELL_DEVICE_TOKEN; ";
