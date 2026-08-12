pub const device_token_environment = "ZSHELL_DEVICE_TOKEN";
pub const oauth_admin_pin_environment = "ZSHELL_OAUTH_ADMIN_PIN";
pub const oauth_jwt_secret_environment = "ZSHELL_OAUTH_JWT_SECRET";

pub const powershell_clear =
    "$env:ZSHELL_DEVICE_TOKEN=$null; " ++
    "$env:ZSHELL_OAUTH_ADMIN_PIN=$null; " ++
    "$env:ZSHELL_OAUTH_JWT_SECRET=$null; ";

pub const posix_clear =
    "unset ZSHELL_DEVICE_TOKEN ZSHELL_OAUTH_ADMIN_PIN ZSHELL_OAUTH_JWT_SECRET; ";
