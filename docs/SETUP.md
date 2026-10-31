# Setting up a real tenant

Use a lab or Microsoft 365 developer tenant first. These steps create an app registration that signs in with a certificate, so no person's password or MFA is involved and every change shows up in the audit logs under the app's name.

## 1. Create a certificate

On Windows:

```powershell
$cert = New-SelfSignedCertificate -Subject 'CN=M365-Offboarding-Toolkit' `
    -CertStoreLocation 'Cert:\CurrentUser\My' -KeyExportPolicy NonExportable `
    -KeySpec Signature -KeyLength 2048 -NotAfter (Get-Date).AddYears(1)
Export-Certificate -Cert $cert -FilePath ./offboarding.cer
$cert.Thumbprint   # keep this for Connect-OffboardingToolkit
```

The private key stays in your certificate store. Only the `.cer` (public part) is uploaded.

## 2. Register the app

1. Entra admin center > **Entra ID** > **App registrations** > **New registration**. Name it `M365 Offboarding Toolkit`, single tenant, no redirect URI.
2. **Certificates & secrets** > **Certificates** > upload `offboarding.cer`.
3. **API permissions** > **Add a permission** > **Microsoft Graph** > **Application permissions**. Add the Graph permissions from the README table, leaving out any for steps you turn off.
4. **Add a permission** > **APIs my organization uses** > search **Office 365 Exchange Online** > **Application permissions** > `Exchange.ManageAsApp`.
5. Click **Grant admin consent**.
6. Entra ID > **Roles & admins** > **Exchange Recipient Administrator** > **Add assignments** > select the app. Exchange app-only access needs this role in addition to `Exchange.ManageAsApp`.
7. Copy the **Application (client) ID** and your tenant's `.onmicrosoft.com` domain from the Overview page.

## 3. Connect and dry run

```powershell
Install-Module Microsoft.Graph.Authentication, ExchangeOnlineManagement -Scope CurrentUser
Import-Module ./src/OffboardingToolkit/OffboardingToolkit.psd1

Connect-OffboardingToolkit -TenantId contoso.onmicrosoft.com -ClientId <client-id> `
    -CertificateThumbprint <thumbprint> -Organization contoso.onmicrosoft.com

Invoke-UserOffboarding test.user@contoso.com -ConfigPath ./config/offboarding.config.json -WhatIf
```

Read the HTML report in `./reports`. If the plan is right, run it again without `-WhatIf`.

## Notes

- **Password reset** with application permissions: if Graph returns "Insufficient privileges" for the password step, the app may also need a role that can reset passwords for that user (for example User Administrator). Admin users always need a higher role, which is one more reason the tool blocks admins by default.
- **Interactive sign-in** (`Connect-OffboardingToolkit -Interactive`) uses your own account and delegated permissions. Fine for a lab; use app-only for anything scheduled or shared.
- **Lock the app down.** Only the people who run offboarding should have access to the certificate. Consider an Entra ID access review on the app's role assignment.
- Remove the app registration when you're done testing in a lab tenant.
